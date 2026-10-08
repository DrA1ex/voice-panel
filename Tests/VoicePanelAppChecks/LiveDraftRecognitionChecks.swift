import AVFoundation
import Foundation
import Speech
import VoicePanelCore

enum SystemPromptFocusCoordinator {
    static func willBegin() {}
    static func didEnd() {}
}

final class DiagnosticLogger {
    static let shared = DiagnosticLogger()
    func warning(_ message: String, metadata: [String: String]) {}
    func info(_ message: String, metadata: [String: String]) {}
}

private final class FinalEngine: RecognitionEngine {
    let displayName = "Controlled final"
    let audioInputMode: RecognitionAudioInputMode = .vadChunks
    let finalizationTimeout: TimeInterval = 5
    var onUpdate: ((RecognitionUpdate) -> Void)?
    var onFinished: (() -> Void)?
    var onMetrics: ((RecognitionPerformanceMetrics) -> Void)?
    var onChunkOutcome: ((RecognitionChunkOutcome) -> Void)?
    var onError: ((Error) -> Void)?
    var chunks: [AudioChunk] = []
    func requestAuthorization() async throws {}
    func start(localeIdentifier: String) async throws {}
    func append(_ chunk: AudioChunk) { chunks.append(chunk) }
    func finish() { onFinished?() }
    func cancel() { chunks = [] }
    func complete(_ sequence: Int, text: String) {
        let chunk = chunks[sequence]
        onUpdate?(
            RecognitionUpdate(
                segment: TranscriptSegmentUpdate(
                    segmentID: chunk.id, sequence: sequence, stableText: text,
                    partialText: "", kind: .segmentFinal
                ), shouldDimPartialText: false
            )
        )
        onChunkOutcome?(.completed(chunk.id))
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: message, code: 1) }
}

@main
private enum LiveDraftRecognitionChecks {
    @MainActor
    static func main() async throws {
        try await checkRetrospectiveDraftReplacement()
        try await checkSuppressedSilenceTiming()
        try await checkUntimedInterimResults()
        try await checkUtteranceRestartAfterPause()
        try await checkLateInterimWordAtCut()
        SpeechStub.reset()
        let draft = SystemSpeechRecognitionEngine()
        let final = FinalEngine()
        let engine = AppleDraftRefinementRecognitionEngine(
            displayName: "Test", draftLocaleIdentifier: "ru-RU", draft: draft, finalEngine: final
        )
        var transcript = TranscriptSession()
        var finished = 0
        engine.onUpdate = { transcript.apply($0.segment) }
        engine.onFinished = { finished += 1 }
        try await engine.start(localeIdentifier: "ru-RU")
        let buffer = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!,
            frameCapacity: 160
        )!
        buffer.frameLength = 160

        SpeechStub.emit(0, text: "начало")
        SpeechStub.emit(0, text: "начало", final: true)
        try require(SpeechStub.requests.count == 2, "spontaneous final must restart")
        SpeechStub.emit(1, text: "продолжение")
        try require(transcript.combinedText == "начало продолжение", "restart must retain the draft timeline")

        // Two retrospective chunks can arrive in one audio callback, before
        // Apple has delivered either final callback.
        for _ in 0..<2 {
            engine.append(AudioChunk(samples: [0.1], sampleRate: 1, boundaryReason: .balancedPause))
        }
        try require(SpeechStub.requests.count == 4, "every chunk must switch the request immediately")
        engine.append(buffer)
        try require(SpeechStub.requests[3].appendedBuffers == 1, "fresh audio must enter the live request")
        try require(!SpeechStub.requests[3].ended, "fresh request must remain open")
        final.complete(0, text: "финал ноль")
        final.complete(1, text: "финал один")
        SpeechStub.emit(1, text: "запоздалый ответ", final: true)
        SpeechStub.emit(2, text: "еще один запоздалый ответ", final: true)
        SpeechStub.emit(3, text: "свежий драфт")
        try require(transcript.partialText == "свежий драфт", "late callbacks must not suppress fresh drafts")
        try require(!transcript.combinedText.contains("запоздалый"), "stale callbacks leaked into transcript")

        SpeechStub.fail(3)
        try require(engine.providesLiveDraft, "transient errors must not disable drafts")
        SpeechStub.emit(4, text: "после восстановления")
        try require(transcript.partialText.contains("после восстановления"), "draft must recover on the same sequence")

        // Exercise a session with far more boundaries than a minute of speech.
        for sequence in 2..<122 {
            let oldTask = SpeechStub.requests.count - 1
            engine.append(AudioChunk(samples: [0.1], sampleRate: 1, boundaryReason: .silence))
            final.complete(sequence, text: "готовый чанк \(sequence)")
            SpeechStub.emit(oldTask, text: "старый драфт", final: true)
            SpeechStub.emit(SpeechStub.requests.count - 1, text: "новые слова \(sequence)")
            try require(transcript.partialText == "новые слова \(sequence)", "long session lost the live draft")
        }
        engine.finish()
        try require(finished == 1, "final engine completion must finish the session once")
        try require(!transcript.finalizedText.contains("новые слова"), "draft-only text leaked into final output")

        // Exhausted draft retries must be reset for the next recording.
        try await engine.requestAuthorization()
        transcript.reset()
        try await engine.start(localeIdentifier: "ru-RU")
        for _ in 0..<3 { SpeechStub.fail(SpeechStub.requests.count - 1) }
        try require(!engine.providesLiveDraft, "repeated failures must stop retrying")
        try await engine.requestAuthorization()
        transcript.reset()
        try await engine.start(localeIdentifier: "ru-RU")
        SpeechStub.emit(SpeechStub.requests.count - 1, text: "новая запись")
        try require(engine.providesLiveDraft, "next recording must retry the draft")
        try require(transcript.partialText == "новая запись", "next recording draft did not restart")
        engine.cancel()

        // Preserve the independent Apple Speech backend's segment semantics.
        SpeechStub.reset()
        let standalone = SystemSpeechRecognitionEngine()
        var sequences: [Int] = []
        standalone.onUpdate = { sequences.append($0.segment.sequence) }
        try await standalone.start(localeIdentifier: "ru-RU")
        SpeechStub.emit(0, text: "первый", final: true)
        SpeechStub.emit(1, text: "второй")
        try require(sequences == [0, 1], "standalone Apple Speech must still advance segments")
        standalone.cancel()

        SpeechStub.reset()
        let racing = SystemSpeechRecognitionEngine()
        racing.onUpdate = { update in
            if update.segment.kind == .segmentFinal { racing.advanceDraftSegment(to: 1) }
        }
        try await racing.startDraft(localeIdentifier: "ru-RU")
        SpeechStub.emit(0, text: "граница", final: true)
        try require(SpeechStub.requests.count == 2, "stale automatic restart replaced the newer chunk request")
        racing.cancel()
        print(
            "Live draft checks passed: request handoff, stale callbacks, recovery, 122 chunks, and standalone Speech.")
    }

    @MainActor
    private static func checkRetrospectiveDraftReplacement() async throws {
        SpeechStub.reset()
        let final = FinalEngine()
        let engine = AppleDraftRefinementRecognitionEngine(
            displayName: "Timed test", draftLocaleIdentifier: "ru-RU",
            draft: SystemSpeechRecognitionEngine(), finalEngine: final
        )
        let state = AppState()
        state.phase = .listening
        engine.onUpdate = { state.applyRecognitionUpdate($0) }
        try await engine.start(localeIdentifier: "ru-RU")
        engine.append(buffer(seconds: 30), captureTimeRange: 0..<30)
        let words: [(String, TimeInterval, TimeInterval)] = [
            ("первый", 1, 0.3), ("фрагмент", 8, 0.3),
            ("второй", 16, 0.3), ("фрагмент", 18, 0.3),
            ("живое", 24, 0.3), ("продолжение", 27, 0.3),
        ]
        SpeechStub.emitTimed(0, words: words)
        let original = state.combinedTranscript
        engine.append(timedChunk(0..<12))
        try require(
            state.combinedTranscript == original, "Retrospective cut dropped the already-recognized continuation")
        final.complete(0, text: "Уточнённое начало.")
        try require(
            state.combinedTranscript == "Уточнённое начало. второй фрагмент живое продолжение",
            "Final replaced words outside its audio range")
        engine.append(timedChunk(12..<22))
        try require(SpeechStub.requests.count == 1, "A retrospective cut restarted the continuous Apple task")
        final.complete(1, text: "Уточнённая середина.")
        try require(
            state.compactTranscriptText == "Уточнённое начало. Уточнённая середина. живое продолжение",
            "Running preview lost its live tail after final refinement")
        SpeechStub.emitTimed(0, words: words)
        try require(
            state.combinedTranscript == state.compactTranscriptText,
            "A stale cumulative hypothesis reopened finalized chunks")
        final.complete(0, text: "Исправленное начало.")
        try require(
            state.combinedTranscript == "Исправленное начало. Уточнённая середина. живое продолжение",
            "An earlier final revision overwrote neighboring text")
        SpeechStub.emitTimed(0, words: words, final: true)
        engine.append(buffer(seconds: 2), captureTimeRange: 30..<32)
        SpeechStub.emitTimed(1, words: [("после", 0.2, 0.3), ("паузы", 1.2, 0.3)])
        try require(
            state.combinedTranscript.hasSuffix("живое продолжение после паузы"),
            "Apple's spontaneous restart reset the running preview")
        try require(!state.compactTranscriptText.contains("\n"), "A chunk or task boundary inserted a line break")
        try require(
            state.transcriptPresentation.runs.map(\.text).joined() == state.combinedTranscript,
            "Full and compact previews disagree after a retrospective cut")
        engine.cancel()
        print("PASS  Retrospective cuts, delayed finals, earlier revisions, and pause recovery retain the live tail")
    }

    @MainActor
    private static func checkSuppressedSilenceTiming() async throws {
        SpeechStub.reset()
        let final = FinalEngine()
        let engine = AppleDraftRefinementRecognitionEngine(
            displayName: "Suppression test", draftLocaleIdentifier: "ru-RU",
            draft: SystemSpeechRecognitionEngine(), finalEngine: final
        )
        var transcript = TranscriptSession()
        engine.onUpdate = { transcript.apply($0.segment) }
        try await engine.start(localeIdentifier: "ru-RU")
        engine.append(buffer(seconds: 1), captureTimeRange: 0..<1)
        engine.append(buffer(seconds: 1), captureTimeRange: 10..<11)
        SpeechStub.emitTimed(
            0, words: [("до", 0.1, 0.2), ("паузы", 0.4, 0.2), ("после", 1.1, 0.2), ("паузы", 1.4, 0.2)])
        engine.append(timedChunk(0..<5))
        final.complete(0, text: "Начало уточнено.")
        try require(
            transcript.combinedText == "Начало уточнено. после паузы",
            "Suppressed silence shifted draft words into the wrong final chunk")
        engine.cancel()
        print("PASS  Suppressed silence retains captured timestamps across draft/final boundaries")
    }

    private static func buffer(seconds: Int) -> AVAudioPCMBuffer {
        let result = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 160, channels: 1)!,
            frameCapacity: AVAudioFrameCount(seconds * 160)
        )!
        result.frameLength = result.frameCapacity
        return result
    }

    @MainActor
    private static func checkUntimedInterimResults() async throws {
        SpeechStub.reset()
        let final = FinalEngine()
        let engine = AppleDraftRefinementRecognitionEngine(
            displayName: "Untimed interim test", draftLocaleIdentifier: "ru-RU",
            draft: SystemSpeechRecognitionEngine(), finalEngine: final
        )
        var transcript = TranscriptSession()
        engine.onUpdate = { transcript.apply($0.segment) }
        try await engine.start(localeIdentifier: "ru-RU")
        engine.append(buffer(seconds: 5), captureTimeRange: 0..<5)
        SpeechStub.emitTimed(0, words: [("первый", 0, 0), ("фрагмент", 0, 0)])
        engine.append(buffer(seconds: 10), captureTimeRange: 5..<15)
        SpeechStub.emitTimed(0, words: [("первый", 0, 0), ("фрагмент", 0, 0), ("живое", 0, 0), ("продолжение", 0, 0)])
        engine.append(timedChunk(0..<10))
        final.complete(0, text: "Уточнённое начало.")
        try require(
            transcript.combinedText == "Уточнённое начало. живое продолжение",
            "Zero interim timestamps moved the live tail into a finalized chunk")
        SpeechStub.emitTimed(
            0, words: [("исправленный", 0, 0), ("фрагмент", 0, 0), ("живое", 0, 0), ("продолжение", 0, 0)])
        try require(
            transcript.combinedText == "Уточнённое начало. живое продолжение",
            "An untimed earlier correction overwrote finalized text")
        SpeechStub.emitTimed(
            0, words: [("первый", 1, 0.3), ("фрагмент", 4, 0.3), ("живое", 12, 0.3), ("продолжение", 14, 0.3)],
            final: true)
        try require(
            transcript.combinedText == "Уточнённое начало. живое продолжение",
            "Final word timings reset the provisional draft")
        engine.cancel()
        print("PASS  Zero interim word timings preserve the observed live tail and accept final timing corrections")
    }

    /// Mirrors a recorded macOS 26 trace: interim results carry zero word
    /// timings; after a long pause Apple sends the closed utterance with
    /// metadata and real timings, then restarts `formattedString` from empty
    /// without `isFinal`. The task's final result holds only its last utterance.
    @MainActor
    private static func checkUtteranceRestartAfterPause() async throws {
        SpeechStub.reset()
        let final = FinalEngine()
        let engine = AppleDraftRefinementRecognitionEngine(
            displayName: "Utterance restart test", draftLocaleIdentifier: "ru-RU",
            draft: SystemSpeechRecognitionEngine(), finalEngine: final
        )
        var transcript = TranscriptSession()
        engine.onUpdate = { transcript.apply($0.segment) }
        try await engine.start(localeIdentifier: "ru-RU")
        engine.append(buffer(seconds: 5), captureTimeRange: 0..<5)
        SpeechStub.emitTimed(0, words: [("Сегодня", 0, 0), ("мы", 0, 0), ("проверяем", 0, 0)])
        engine.append(buffer(seconds: 2), captureTimeRange: 5..<7)
        SpeechStub.emitTimed(
            0, words: [("Сегодня", 0.5, 0.5), ("мы", 1.1, 0.2), ("проверяем", 1.4, 0.6)], closesUtterance: true)
        engine.append(buffer(seconds: 2), captureTimeRange: 7..<9)
        SpeechStub.emitTimed(0, words: [("После", 0, 0)])
        try require(
            transcript.combinedText == "Сегодня мы проверяем После",
            "Apple's utterance restart erased the previous phrase: \(transcript.combinedText)")

        engine.append(timedChunk(0..<6.5))
        final.complete(0, text: "Сегодня мы проверяем.")
        engine.append(buffer(seconds: 3), captureTimeRange: 9..<12)
        SpeechStub.emitTimed(
            0, words: [("После", 0, 0), ("паузы", 0, 0), ("я", 0, 0), ("продолжаю", 0, 0), ("говорить", 0, 0)])
        try require(
            transcript.combinedText == "Сегодня мы проверяем. После паузы я продолжаю говорить",
            "Fresh speech after a pause was hidden in a finalized chunk: \(transcript.combinedText)")

        // Defensive path: a restart that arrives without closing metadata.
        engine.append(buffer(seconds: 3), captureTimeRange: 12..<15)
        SpeechStub.emitTimed(0, words: [("Третья", 0, 0)])
        try require(
            transcript.combinedText == "Сегодня мы проверяем. После паузы я продолжаю говорить Третья",
            "A restart without metadata erased the previous phrase: \(transcript.combinedText)")

        SpeechStub.emitTimed(
            0, words: [("Третья", 12.5, 0.4), ("фраза", 13, 0.4), ("готова", 13.5, 0.4)], final: true,
            closesUtterance: true)
        try require(
            transcript.combinedText == "Сегодня мы проверяем. После паузы я продолжаю говорить Третья фраза готова",
            "Apple's last-utterance final result dropped earlier phrases: \(transcript.combinedText)")
        engine.append(buffer(seconds: 1), captureTimeRange: 15..<16)
        SpeechStub.emitTimed(1, words: [("Дальше", 0, 0)])
        try require(
            transcript.combinedText.hasSuffix("Третья фраза готова Дальше"),
            "The restarted Apple task lost the earlier tail: \(transcript.combinedText)")
        engine.cancel()

        // The standalone Apple Speech backend has the same task semantics.
        SpeechStub.reset()
        let standalone = SystemSpeechRecognitionEngine()
        var standaloneTranscript = TranscriptSession()
        standalone.onUpdate = { standaloneTranscript.apply($0.segment) }
        try await standalone.start(localeIdentifier: "ru-RU")
        SpeechStub.emit(0, text: "первая фраза")
        SpeechStub.emit(0, text: "первая фраза", closesUtterance: true)
        SpeechStub.emit(0, text: "вторая")
        try require(
            standaloneTranscript.combinedText == "первая фраза вторая",
            "Standalone Apple Speech lost a phrase after a pause: \(standaloneTranscript.combinedText)")
        SpeechStub.emit(0, text: "вторая фраза", final: true, closesUtterance: true)
        try require(
            standaloneTranscript.finalizedText == "первая фраза вторая фраза",
            "Standalone final kept only the last utterance: \(standaloneTranscript.finalizedText)")
        SpeechStub.emit(1, text: "третья")
        SpeechStub.emit(1, text: "третья фраза", closesUtterance: true)
        SpeechStub.emit(1, text: "третья фраза и продолжение")
        try require(
            standaloneTranscript.combinedText == "первая фраза вторая фраза третья фраза и продолжение",
            "A cumulative hypothesis after metadata was duplicated: \(standaloneTranscript.combinedText)")
        standalone.cancel()
        print("PASS  Apple utterance restarts after pauses keep earlier phrases and show fresh speech")
    }

    /// Untimed interim words are stamped when Apple reports them, slightly after
    /// they were spoken. A word just before a cut can therefore land in the next
    /// draft segment; it must not repeat the preceding final text.
    @MainActor
    private static func checkLateInterimWordAtCut() async throws {
        SpeechStub.reset()
        let final = FinalEngine()
        let engine = AppleDraftRefinementRecognitionEngine(
            displayName: "Late interim test", draftLocaleIdentifier: "ru-RU",
            draft: SystemSpeechRecognitionEngine(), finalEngine: final
        )
        var transcript = TranscriptSession()
        engine.onUpdate = { transcript.apply($0.segment) }
        try await engine.start(localeIdentifier: "ru-RU")
        engine.append(buffer(seconds: 4), captureTimeRange: 0..<4)
        SpeechStub.emitTimed(0, words: [("мы", 0, 0), ("видим", 0, 0)])
        engine.append(buffer(seconds: 1), captureTimeRange: 4..<5)
        SpeechStub.emitTimed(0, words: [("мы", 0, 0), ("видим", 0, 0), ("результат", 0, 0)])
        engine.append(buffer(seconds: 2), captureTimeRange: 5..<7)
        SpeechStub.emitTimed(0, words: [("мы", 0, 0), ("видим", 0, 0), ("результат", 0, 0), ("дальше", 0, 0)])
        engine.append(timedChunk(0..<4.6))
        final.complete(0, text: "Мы видим результат.")
        try require(
            transcript.combinedText == "Мы видим результат. дальше",
            "A late-stamped draft word repeated the final text: \(transcript.combinedText)")

        // A deliberate repetition that Apple timed precisely is not a duplicate.
        engine.append(buffer(seconds: 3), captureTimeRange: 7..<10)
        SpeechStub.emitTimed(
            0,
            words: [
                ("мы", 1, 0.3), ("видим", 2, 0.3), ("результат", 4.2, 0.3), ("дальше", 6, 0.3),
                ("дальше", 8, 0.3),
            ], closesUtterance: true)
        engine.append(timedChunk(4.6..<7))
        final.complete(1, text: "Дальше")
        try require(
            transcript.combinedText == "Мы видим результат. Дальше дальше",
            "A precisely timed repetition was removed: \(transcript.combinedText)")
        engine.cancel()
        print("PASS  Late interim words at a cut do not duplicate the final text")
    }

    private static func timedChunk(_ range: Range<TimeInterval>) -> AudioChunk {
        AudioChunk(samples: [0.1], sampleRate: 1, boundaryReason: .balancedPause, captureTimeRange: range)
    }
}
