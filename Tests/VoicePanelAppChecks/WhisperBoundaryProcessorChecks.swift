import Foundation
import VoicePanelCore

private enum ProcessorCheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private struct InferenceRequest: Sendable {
    let samples: [Float]
    let prompt: String
    let metadataLevel: WhisperInferenceMetadataLevel
}

private actor InferenceRecorder {
    private var results: [Result<WhisperTranscriptionResult, Error>]
    private(set) var requests: [InferenceRequest] = []

    init(_ results: [Result<WhisperTranscriptionResult, Error>]) {
        self.results = results
    }

    func transcribe(
        samples: [Float],
        languageCode: String,
        configuration: WhisperInferenceConfiguration,
        initialPrompt: String,
        metadataLevel: WhisperInferenceMetadataLevel
    ) async throws -> WhisperTranscriptionResult {
        requests.append(
            InferenceRequest(
                samples: samples,
                prompt: initialPrompt,
                metadataLevel: metadataLevel
            ))
        guard !results.isEmpty else {
            throw ProcessorCheckFailure.failed("unexpected extra inference")
        }
        return try results.removeFirst().get()
    }
}

private actor BlockingCandidateRecorder {
    private let translatesCancellationToDomainError: Bool
    private var requestCount = 0
    private var candidateStarted = false
    private var candidateWaiter: CheckedContinuation<Void, Never>?

    init(translatesCancellationToDomainError: Bool = false) {
        self.translatesCancellationToDomainError = translatesCancellationToDomainError
    }

    func waitForCandidate() async {
        if candidateStarted { return }
        await withCheckedContinuation { continuation in
            candidateWaiter = continuation
        }
    }

    func transcribe() async throws -> WhisperTranscriptionResult {
        requestCount += 1
        switch requestCount {
        case 1:
            return evidenceResult("prefix context слева один два")
        case 2:
            return evidenceResult("исходный текст остается полностью")
        case 3:
            candidateStarted = true
            candidateWaiter?.resume()
            candidateWaiter = nil
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                if translatesCancellationToDomainError {
                    throw ProcessorCheckFailure.failed("provider translated candidate cancellation")
                }
                throw error
            }
            throw ProcessorCheckFailure.failed("cancelled candidate resumed unexpectedly")
        case 4:
            return evidenceResult("следующий независимый результат")
        default:
            throw ProcessorCheckFailure.failed("cancelled retry leaked context into another inference")
        }
    }

    func count() -> Int { requestCount }
}

private actor BlockingBaselineRecorder {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var requestCount = 0

    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiter = continuation
        }
    }

    func transcribe() async throws -> WhisperTranscriptionResult {
        requestCount += 1
        started = true
        startWaiter?.resume()
        startWaiter = nil
        try await Task.sleep(nanoseconds: 30_000_000_000)
        throw ProcessorCheckFailure.failed("cancelled baseline resumed unexpectedly")
    }

    func count() -> Int { requestCount }
}

private final class MonotonicTimeSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval]

    init(_ values: [TimeInterval]) {
        self.values = values
    }

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return 0 }
        return values.removeFirst()
    }
}

private func evidenceResult(
    _ text: String,
    probability: Double = 0.8,
    inferenceDuration: TimeInterval = 0.1
) -> WhisperTranscriptionResult {
    WhisperTranscriptionResult(
        text: text,
        segments: [
            WhisperSegmentEvidence(
                text: text,
                startTime: 0,
                endTime: 2,
                noSpeechProbability: 0,
                tokens: [
                    WhisperTokenEvidence(
                        text: text,
                        startTime: nil,
                        endTime: nil,
                        probability: probability
                    )
                ]
            )
        ],
        detectedLanguage: "ru",
        inferenceDuration: inferenceDuration
    )
}

private func timedBridgeResult() -> WhisperTranscriptionResult {
    let tokens: [(String, TimeInterval, TimeInterval)] = [
        ("левый", 2.0, 2.2),
        (" общий", 2.2, 2.4),
        (" якорь", 2.4, 2.6),
        (" исправленный，", 3.0, 3.4),
        (" переход", 3.501, 3.502),
        (" правый", 3.502, 3.504),
        (" устойчивый", 3.504, 3.506),
        (" якорь", 3.506, 3.508),
    ]
    let text = tokens.map(\.0).joined()
    return WhisperTranscriptionResult(
        text: text,
        segments: [
            WhisperSegmentEvidence(
                text: text,
                startTime: 2,
                endTime: 4.6,
                noSpeechProbability: 0,
                tokens: tokens.map { token in
                    WhisperTokenEvidence(
                        text: token.0,
                        startTime: token.1,
                        endTime: token.2,
                        probability: 0.9
                    )
                }
            )
        ],
        detectedLanguage: "ru",
        inferenceDuration: 0.2
    )
}

private func configuration(
    strategy: WhisperBoundaryStrategy,
    promptMode: WhisperContextPromptMode = .lexicalOverlapAligned
) -> WhisperInferenceConfiguration {
    WhisperInferenceConfiguration(
        numberOfThreads: 4,
        usesCustomDecoding: false,
        decodingStrategy: .greedy,
        greedyBestOf: 1,
        beamSize: 1,
        initialPrompt: "  Static Context\nVocabulary  ",
        boundaryStrategy: strategy,
        overlapDuration: 0.2,
        contextPromptMode: promptMode
    )
}

private func chunk(
    id: UUID = UUID(),
    samples: [Float] = Array(repeating: 0.1, count: 16_000),
    sampleRate: Double = 16_000,
    boundaryReason: AudioChunkBoundaryReason,
    trailingOverlapDuration: TimeInterval = 0,
    speechRange: Range<Int>? = nil,
    speechEvidenceAnalyzed: Bool = false
) -> AudioChunk {
    AudioChunk(
        id: id,
        samples: samples,
        sampleRate: sampleRate,
        boundaryReason: boundaryReason,
        trailingOverlapDuration: trailingOverlapDuration,
        speechRange: speechRange,
        speechEvidenceAnalyzed: speechEvidenceAnalyzed
    )
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ProcessorCheckFailure.failed(message) }
}

private func requireBoundedDiagnosticMetadata(
    _ output: WhisperProcessedChunk,
    strategy: WhisperBoundaryStrategy,
    attempted: Bool,
    accepted: Bool,
    reason: WhisperBoundaryRepairReasonCode,
    inferenceCount: Int,
    privateValues: [String] = []
) throws {
    let metadata = output.diagnosticMetadata
    var expectedKeys = Set([
        "strategy",
        "attempted",
        "accepted",
        "reason",
        "inferences",
        "inferenceMilliseconds",
        "baselineBoundaryWords",
        "replacementBoundaryWords",
    ])
    if output.bridgeDuration != nil { expectedKeys.insert("bridgeMilliseconds") }

    try require(Set(metadata.keys) == expectedKeys, "diagnostic metadata fields were not bounded")
    try require(metadata["strategy"] == strategy.rawValue, "diagnostic strategy changed")
    try require(metadata["attempted"] == String(attempted), "diagnostic attempt changed")
    try require(metadata["accepted"] == String(accepted), "diagnostic selection changed")
    try require(metadata["reason"] == reason.rawValue, "diagnostic reason changed")
    try require(metadata["inferences"] == String(inferenceCount), "diagnostic inference count changed")

    guard
        let milliseconds = metadata["inferenceMilliseconds"].flatMap(Int.init),
        let baselineWords = metadata["baselineBoundaryWords"].flatMap(Int.init),
        let replacementWords = metadata["replacementBoundaryWords"].flatMap(Int.init)
    else {
        throw ProcessorCheckFailure.failed("diagnostic numeric metadata was not encoded as integers")
    }
    try require((0...3_600_000).contains(milliseconds), "diagnostic timing escaped its bound")
    try require((0...24).contains(baselineWords), "baseline word count escaped its bound")
    try require((0...24).contains(replacementWords), "replacement word count escaped its bound")
    try require(
        Set(metadata.values).isDisjoint(with: privateValues),
        "diagnostic metadata contained recognition or prompt text"
    )
}

private func makeProcessor(
    configuration: WhisperInferenceConfiguration,
    recorder: InferenceRecorder
) -> WhisperBoundaryProcessor {
    WhisperBoundaryProcessor(
        configuration: configuration,
        languageCode: "ru",
        hallucinationGuardConfiguration: .disabled,
        transcribe: { samples, language, configuration, prompt, metadata in
            try await recorder.transcribe(
                samples: samples,
                languageCode: language,
                configuration: configuration,
                initialPrompt: prompt,
                metadataLevel: metadata
            )
        }
    )
}

private func checkStandardUsesOneIndependentBaseline() async throws {
    let baseline = evidenceResult("baseline remains exact")
    let recorder = InferenceRecorder([.success(baseline)])
    let processor = makeProcessor(configuration: configuration(strategy: .standard), recorder: recorder)

    let output = await processor.process(chunk: chunk(boundaryReason: .maximumDuration), sequence: 4)
    let requests = await recorder.requests

    try require(requests.count == 1, "Standard performed repair inference")
    try require(requests[0].prompt == "Static Context\nVocabulary", "baseline prompt was not static-only")
    try require(requests[0].metadataLevel == .segments, "Standard enabled token timestamps")
    try require(output.baseline == baseline, "processor changed the baseline evidence")
    try require(output.revisions.map(\.text) == [baseline.text], "Standard changed baseline text")
    try require(output.diagnostics.inferenceCount == 1, "Standard diagnostic count was not one")
    try requireBoundedDiagnosticMetadata(
        output,
        strategy: .standard,
        attempted: false,
        accepted: false,
        reason: .baselineOnly,
        inferenceCount: 1,
        privateValues: [baseline.text, requests[0].prompt]
    )
}

private func checkContextualRetryIsGatedAndRevisesSameSegment() async throws {
    let previous = evidenceResult("prefix context слева один два")
    let baseline = evidenceResult("ошибка общий якорь здесь. неизменный хвост 你好。")
    let candidate = evidenceResult("один два исправление общий якорь здесь иначе")
    let recorder = InferenceRecorder([.success(previous), .success(baseline), .success(candidate)])
    let processor = makeProcessor(
        configuration: configuration(strategy: .contextualRetry, promptMode: .legacyFixedWords),
        recorder: recorder
    )
    _ = await processor.process(chunk: chunk(boundaryReason: .maximumDuration), sequence: 0)
    let segmentID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    let output = await processor.process(
        chunk: chunk(id: segmentID, boundaryReason: .stopped),
        sequence: 1
    )
    let requests = await recorder.requests

    try require(requests.count == 3, "suspicious forced boundary did not perform exactly one retry")
    try require(requests[1].prompt == "Static Context\nVocabulary", "retry baseline reused dynamic context")
    try require(
        requests[2].prompt == "Static Context\nVocabulary\nprefix context",
        "retry prompt did not keep static context independent from bounded dynamic context"
    )
    try require(output.revisions.count == 2, "accepted repair did not emit baseline and revision")
    try require(
        output.revisions.allSatisfy { $0.segmentID == segmentID && $0.sequence == 1 }, "revision identity changed")
    try require(output.revisions[0].text == baseline.text, "first revision was not exact baseline")
    try require(
        output.revisions[1].text == "один два исправление общий якорь здесь. неизменный хвост 你好。",
        "accepted patch escaped the boundary-local prefix"
    )
    try requireBoundedDiagnosticMetadata(
        output,
        strategy: .contextualRetry,
        attempted: true,
        accepted: true,
        reason: .accepted,
        inferenceCount: 2,
        privateValues: [previous.text, baseline.text, candidate.text] + requests.map(\.prompt)
    )
}

private func checkRejectedAndFailedAlternativesReturnExactBaseline() async throws {
    let previous = evidenceResult("prefix context слева один два")
    let baseline = evidenceResult("исходный текст остается полностью")
    let unalignable = evidenceResult("совсем другой кандидат без якоря")
    let failures: [(Result<WhisperTranscriptionResult, Error>, WhisperBoundaryRepairReasonCode)] = [
        (.success(unalignable), .missingStableAnchor),
        (.failure(ProcessorCheckFailure.failed("candidate failed")), .candidateFailed),
        (.failure(CancellationError()), .candidateCancelled),
    ]

    for (alternative, expectedReason) in failures {
        let recorder = InferenceRecorder([.success(previous), .success(baseline), alternative])
        let processor = makeProcessor(
            configuration: configuration(strategy: .contextualRetry, promptMode: .legacyFixedWords),
            recorder: recorder
        )
        _ = await processor.process(chunk: chunk(boundaryReason: .maximumDuration), sequence: 0)
        let output = await processor.process(chunk: chunk(boundaryReason: .stopped), sequence: 1)
        let requestCount = await recorder.requests.count

        try require(requestCount == 3, "alternative path used the wrong inference count")
        try require(output.baseline == baseline, "alternative path replaced baseline evidence")
        try require(output.revisions.map(\.text) == [baseline.text], "alternative path changed baseline text")
        try require(output.diagnostics.attempted, "alternative attempt was not diagnosed")
        try require(!output.diagnostics.accepted, "failed alternative was marked accepted")
        try requireBoundedDiagnosticMetadata(
            output,
            strategy: .contextualRetry,
            attempted: true,
            accepted: false,
            reason: expectedReason,
            inferenceCount: 2,
            privateValues: [previous.text, baseline.text, unalignable.text]
        )
    }
}

private func checkBaselineProviderFailureAndCancellationDiagnostics() async throws {
    let recorder = InferenceRecorder([
        .failure(ProcessorCheckFailure.failed("provider unavailable"))
    ])
    let clock = MonotonicTimeSequence([10, 10.25])
    let processor = WhisperBoundaryProcessor(
        configuration: configuration(strategy: .standard),
        languageCode: "ru",
        hallucinationGuardConfiguration: .disabled,
        monotonicNow: { clock.now() },
        transcribe: { samples, language, configuration, prompt, metadata in
            try await recorder.transcribe(
                samples: samples,
                languageCode: language,
                configuration: configuration,
                initialPrompt: prompt,
                metadataLevel: metadata
            )
        }
    )
    let output = await processor.process(chunk: chunk(boundaryReason: .stopped), sequence: 0)
    let requests = await recorder.requests

    try require(requests.count == 1, "baseline provider failure retried inference")
    try require(output.revisions.isEmpty, "baseline provider failure published text")
    try require(output.diagnostics.inferenceDuration == 0.25, "provider failure lost elapsed time")
    try requireBoundedDiagnosticMetadata(
        output,
        strategy: .standard,
        attempted: false,
        accepted: false,
        reason: .baselineFailed,
        inferenceCount: 1,
        privateValues: requests.map(\.prompt)
    )
}

private func checkBaselineRealCancellationDiagnostics() async throws {
    let recorder = BlockingBaselineRecorder()
    let clock = MonotonicTimeSequence([20, 20.5])
    let processor = WhisperBoundaryProcessor(
        configuration: configuration(strategy: .standard),
        languageCode: "ru",
        hallucinationGuardConfiguration: .disabled,
        monotonicNow: { clock.now() },
        transcribe: { _, _, _, _, _ in try await recorder.transcribe() }
    )
    let processing = Task {
        await processor.process(chunk: chunk(boundaryReason: .stopped), sequence: 0)
    }
    await recorder.waitForStart()
    processing.cancel()
    let output = await processing.value
    let requestCount = await recorder.count()

    try require(requestCount == 1, "baseline cancellation retried inference")
    try require(output.failure == .cancelled, "baseline cancellation became provider failure")
    try require(output.revisions.isEmpty, "baseline cancellation published text")
    try require(output.diagnostics.inferenceDuration == 0.5, "cancellation lost elapsed time")
    try requireBoundedDiagnosticMetadata(
        output,
        strategy: .standard,
        attempted: false,
        accepted: false,
        reason: .baselineCancelled,
        inferenceCount: 1
    )
}

private func checkTimestampResearchModeIsExplicit() async throws {
    let previous = evidenceResult("prefix context слева один два", probability: 0.1)
    let baseline = evidenceResult("ошибка общий якорь здесь. хвост", probability: 0.1)
    let candidate = evidenceResult("другой результат без якоря", probability: 0.1)
    let recorder = InferenceRecorder([.success(previous), .success(baseline), .success(candidate)])
    let processor = makeProcessor(
        configuration: configuration(strategy: .contextualRetry, promptMode: .timestampAligned),
        recorder: recorder
    )

    _ = await processor.process(chunk: chunk(boundaryReason: .maximumDuration), sequence: 0)
    _ = await processor.process(chunk: chunk(boundaryReason: .stopped), sequence: 1)
    let requests = await recorder.requests

    try require(requests.count == 3, "timestamp research path did not retry exactly once")
    try require(
        requests.allSatisfy { $0.metadataLevel == .tokenTimestamps }, "timestamp mode decoding was not explicit")
}

private func checkBoundaryBridgeUsesBoundedStaticTimestampInference() async throws {
    let previousID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let currentID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let previous = evidenceResult("KEEP левый общий якорь старое，")
    let current = evidenceResult("старое новое правый устойчивый якорь KEEP")
    let bridge = timedBridgeResult()
    let recorder = InferenceRecorder([.success(previous), .success(current), .success(bridge)])
    let processor = makeProcessor(
        configuration: configuration(strategy: .boundaryBridge),
        recorder: recorder
    )
    let previousSamples = (0..<20).map(Float.init)
    let currentSamples = (100..<120).map(Float.init)
    let first = await processor.process(
        chunk: chunk(
            id: previousID,
            samples: previousSamples,
            sampleRate: 4,
            boundaryReason: .maximumDuration
        ),
        sequence: 4
    )
    let output = await processor.process(
        chunk: chunk(
            id: currentID,
            samples: currentSamples,
            sampleRate: 4,
            boundaryReason: .stopped
        ),
        sequence: 5
    )
    let requests = await recorder.requests

    try require(requests.count == 3, "Boundary Bridge did not use exactly one extra inference")
    try require(
        requests.map(\.metadataLevel) == [.segments, .segments, .tokenTimestamps],
        "Boundary Bridge changed baseline metadata or omitted bridge timestamps"
    )
    try require(
        requests.map(\.prompt) == Array(repeating: "Static Context\nVocabulary", count: 3),
        "Boundary Bridge injected previous transcript text into a prompt"
    )
    try require(
        requests[2].samples == (6..<20).map(Float.init) + (101..<115).map(Float.init),
        "Boundary Bridge did not request exactly 3.5 seconds per side without overlap"
    )
    try require(output.baseline == current, "Boundary Bridge replaced the independent baseline")
    try require(output.revisions.count == 2, "accepted bridge did not emit exactly two revisions")
    try require(
        output.revisions.map(\.segmentID) == [previousID, currentID],
        "accepted bridge revisions were not previous then current"
    )
    try require(output.revisions.map(\.sequence) == [4, 5], "bridge revision sequence changed")
    try require(
        output.revisions.map(\.text) == [
            "KEEP левый общий якорь исправленный，",
            " переход правый устойчивый якорь KEEP",
        ],
        "accepted bridge published baseline or candidate text instead of aligned patches"
    )
    try require(output.diagnostics.inferenceCount == 2, "bridge inference count was not bounded")
    try require(output.diagnostics.accepted, "aligned bridge was diagnosed as rejected")
    try require(
        output.diagnostics.changedBoundaryWordCounts == .init(baseline: 3, replacement: 2),
        "accepted bridge did not diagnose exact combined boundary word changes"
    )
    try require(output.bridgeDuration == 7, "bridge duration did not describe the bounded audio")
    try requireBoundedDiagnosticMetadata(
        output,
        strategy: .boundaryBridge,
        attempted: true,
        accepted: true,
        reason: .accepted,
        inferenceCount: 2,
        privateValues: [previous.text, current.text, bridge.text] + requests.map(\.prompt)
    )
    try require(output.diagnosticMetadata["bridgeMilliseconds"] == "7000", "bridge duration changed")

    var transcript = TranscriptSession()
    for revision in first.revisions + output.revisions {
        transcript.apply(
            TranscriptSegmentUpdate(
                segmentID: revision.segmentID,
                sequence: revision.sequence,
                stableText: revision.text,
                partialText: "",
                kind: .segmentFinal
            ))
    }
    try require(transcript.segments.count == 2, "bridge publication created duplicate segments")
    try require(
        transcript.combinedText
            == "KEEP левый общий якорь исправленный， переход правый устойчивый якорь KEEP",
        "bridge publication duplicated or lost the repaired boundary"
    )
}

private func checkBoundaryBridgeRejectsAndFailsClosed() async throws {
    let previous = evidenceResult("KEEP левый общий якорь старое，")
    let current = evidenceResult("старое новое правый устойчивый якорь KEEP")
    let candidateText = "candidate text must never publish"
    let cases: [(Result<WhisperTranscriptionResult, Error>, WhisperBoundaryRepairReasonCode)] = [
        (.success(evidenceResult(candidateText)), .missingStableAnchor),
        (.failure(ProcessorCheckFailure.failed("bridge failed")), .candidateFailed),
        (.failure(CancellationError()), .candidateCancelled),
    ]

    for (candidate, expectedReason) in cases {
        let recorder = InferenceRecorder([.success(previous), .success(current), candidate])
        let processor = makeProcessor(
            configuration: configuration(strategy: .boundaryBridge),
            recorder: recorder
        )
        _ = await processor.process(chunk: chunk(boundaryReason: .maximumDuration), sequence: 0)
        let output = await processor.process(chunk: chunk(boundaryReason: .stopped), sequence: 1)
        let requests = await recorder.requests

        try require(requests.count == 3, "bridge rejection used more than one candidate call")
        try require(output.revisions.map(\.text) == [current.text], "bridge rejection changed baseline")
        try require(!output.revisions.contains { $0.text == candidateText }, "candidate text leaked")
        try require(output.diagnostics.reasonCode == expectedReason, "bridge rejection reason changed")
        try require(!output.diagnostics.accepted, "bridge rejection was marked accepted")
        try require(
            output.diagnostics.changedBoundaryWordCounts == .init(baseline: 0, replacement: 0),
            "rejected bridge reported accepted boundary word changes"
        )
        try requireBoundedDiagnosticMetadata(
            output,
            strategy: .boundaryBridge,
            attempted: true,
            accepted: false,
            reason: expectedReason,
            inferenceCount: 2,
            privateValues: [previous.text, current.text, candidateText]
        )
    }
}

private func checkBoundaryBridgeGuardUsesBridgeDurationForPlausibleCandidate() async throws {
    let previous = evidenceResult("KEEP левый общий якорь старое，")
    let current = evidenceResult("правый устойчивый якорь")
    let recorder = InferenceRecorder([
        .success(previous),
        .success(current),
        .success(timedBridgeResult()),
    ])
    let processor = WhisperBoundaryProcessor(
        configuration: configuration(strategy: .boundaryBridge),
        languageCode: "ru",
        hallucinationGuardConfiguration: .init(isEnabled: true),
        transcribe: { samples, language, configuration, prompt, metadata in
            try await recorder.transcribe(
                samples: samples,
                languageCode: language,
                configuration: configuration,
                initialPrompt: prompt,
                metadataLevel: metadata
            )
        }
    )
    _ = await processor.process(
        chunk: chunk(
            samples: Array(repeating: 0.1, count: 400),
            sampleRate: 100,
            boundaryReason: .maximumDuration
        ),
        sequence: 0
    )
    let output = await processor.process(
        chunk: chunk(
            samples: Array(repeating: 0.2, count: 21),
            sampleRate: 100,
            boundaryReason: .stopped,
            speechRange: 0..<1,
            speechEvidenceAnalyzed: true
        ),
        sequence: 1
    )

    try require(output.diagnostics.accepted, "short current chunk falsely rejected bridge-length text")
    try require(output.revisions.count == 2, "plausible bridge candidate did not revise both segments")
}

private func checkBoundaryBridgeGuardRejectsRateAgainstActualBridgeDuration() async throws {
    let previous = evidenceResult("previous boundary")
    let current = evidenceResult("this current baseline has enough ordinary words")
    let implausibleCandidate = evidenceResult(String(repeating: "a", count: 240))
    let recorder = InferenceRecorder([
        .success(previous),
        .success(current),
        .success(implausibleCandidate),
    ])
    let processor = WhisperBoundaryProcessor(
        configuration: configuration(strategy: .boundaryBridge),
        languageCode: "en",
        hallucinationGuardConfiguration: .init(isEnabled: true),
        transcribe: { samples, language, configuration, prompt, metadata in
            try await recorder.transcribe(
                samples: samples,
                languageCode: language,
                configuration: configuration,
                initialPrompt: prompt,
                metadataLevel: metadata
            )
        }
    )
    _ = await processor.process(
        chunk: chunk(
            samples: [0.1],
            sampleRate: 10,
            boundaryReason: .maximumDuration
        ),
        sequence: 0
    )
    let output = await processor.process(
        chunk: chunk(
            samples: Array(repeating: 0.2, count: 100),
            sampleRate: 10,
            boundaryReason: .stopped
        ),
        sequence: 1
    )

    try require(
        output.diagnostics.reasonCode == .candidateRejectedHallucination,
        "long current chunk hid an implausible text rate for the shorter bridge"
    )
    try require(output.revisions.map(\.text) == [current.text], "rejected candidate text leaked")
}

private func checkBoundaryBridgeFailureResetAndRejectedPromotion() async throws {
    let previous = evidenceResult("previous forced boundary words")
    let currentMaximum = evidenceResult("current independent forced baseline")
    let next = evidenceResult("next chunk remains independently suspicious")
    let unalignable = evidenceResult("unalignable bridge candidate")

    let failureRecorder = InferenceRecorder([
        .success(previous),
        .success(currentMaximum),
        .failure(ProcessorCheckFailure.failed("bridge failed")),
        .success(next),
    ])
    let failureProcessor = makeProcessor(
        configuration: configuration(strategy: .boundaryBridge),
        recorder: failureRecorder
    )
    _ = await failureProcessor.process(chunk: chunk(boundaryReason: .maximumDuration), sequence: 0)
    _ = await failureProcessor.process(chunk: chunk(boundaryReason: .maximumDuration), sequence: 1)
    _ = await failureProcessor.process(chunk: chunk(boundaryReason: .stopped), sequence: 2)
    let failureRequestCount = await failureRecorder.requests.count
    try require(
        failureRequestCount == 4,
        "failed bridge candidate retained an audio tail"
    )

    let rejectedRecorder = InferenceRecorder([
        .success(previous),
        .success(currentMaximum),
        .success(unalignable),
        .success(next),
        .success(unalignable),
    ])
    let rejectedProcessor = makeProcessor(
        configuration: configuration(strategy: .boundaryBridge),
        recorder: rejectedRecorder
    )
    _ = await rejectedProcessor.process(chunk: chunk(boundaryReason: .maximumDuration), sequence: 0)
    _ = await rejectedProcessor.process(chunk: chunk(boundaryReason: .maximumDuration), sequence: 1)
    _ = await rejectedProcessor.process(chunk: chunk(boundaryReason: .stopped), sequence: 2)
    let rejectedRequestCount = await rejectedRecorder.requests.count
    try require(
        rejectedRequestCount == 5,
        "rejected bridge did not promote the accepted forced current baseline"
    )

    let resetRecorder = InferenceRecorder([.success(previous), .success(next)])
    let resetProcessor = makeProcessor(
        configuration: configuration(strategy: .boundaryBridge),
        recorder: resetRecorder
    )
    _ = await resetProcessor.process(chunk: chunk(boundaryReason: .maximumDuration), sequence: 0)
    await resetProcessor.reset()
    _ = await resetProcessor.process(chunk: chunk(boundaryReason: .stopped), sequence: 1)
    let resetRequestCount = await resetRecorder.requests.count
    try require(resetRequestCount == 2, "processor reset retained bridge audio")
}

private func checkBoundaryBridgeParentCancellationClearsTail() async throws {
    let recorder = BlockingCandidateRecorder()
    let processor = WhisperBoundaryProcessor(
        configuration: configuration(strategy: .boundaryBridge),
        languageCode: "ru",
        hallucinationGuardConfiguration: .disabled,
        transcribe: { _, _, _, _, _ in try await recorder.transcribe() }
    )
    _ = await processor.process(chunk: chunk(boundaryReason: .maximumDuration), sequence: 0)
    let processing = Task {
        await processor.process(chunk: chunk(boundaryReason: .maximumDuration), sequence: 1)
    }
    await recorder.waitForCandidate()

    processing.cancel()
    let cancelled = await processing.value

    try require(cancelled.failure == .cancelled, "bridge parent cancellation became fallback")
    try require(cancelled.revisions.isEmpty, "cancelled bridge published a baseline")
    try requireBoundedDiagnosticMetadata(
        cancelled,
        strategy: .boundaryBridge,
        attempted: true,
        accepted: false,
        reason: .candidateCancelled,
        inferenceCount: 2
    )
    _ = await processor.process(chunk: chunk(boundaryReason: .stopped), sequence: 2)
    let requestCount = await recorder.count()
    try require(requestCount == 4, "cancelled bridge retained an audio tail")
}

private func checkParentCancellationDuringCandidatePublishesNoBaseline() async throws {
    let recorder = BlockingCandidateRecorder()
    let processor = WhisperBoundaryProcessor(
        configuration: configuration(strategy: .contextualRetry, promptMode: .legacyFixedWords),
        languageCode: "ru",
        hallucinationGuardConfiguration: .disabled,
        transcribe: { _, _, _, _, _ in try await recorder.transcribe() }
    )
    _ = await processor.process(chunk: chunk(boundaryReason: .maximumDuration), sequence: 0)
    let processing = Task {
        await processor.process(chunk: chunk(boundaryReason: .maximumDuration), sequence: 1)
    }
    await recorder.waitForCandidate()

    processing.cancel()
    let cancelled = await processing.value

    try require(cancelled.failure == .cancelled, "parent cancellation became baseline fallback")
    try require(cancelled.revisions.isEmpty, "parent cancellation published a baseline revision")
    try requireBoundedDiagnosticMetadata(
        cancelled,
        strategy: .contextualRetry,
        attempted: true,
        accepted: false,
        reason: .candidateCancelled,
        inferenceCount: 2
    )

    _ = await processor.process(chunk: chunk(boundaryReason: .stopped), sequence: 2)
    let requestCount = await recorder.count()
    try require(requestCount == 4, "parent cancellation retained retry continuity")
}

private func checkParentCancellationWinsOverCandidateDomainError() async throws {
    let recorder = BlockingCandidateRecorder(translatesCancellationToDomainError: true)
    let processor = WhisperBoundaryProcessor(
        configuration: configuration(strategy: .contextualRetry, promptMode: .legacyFixedWords),
        languageCode: "ru",
        hallucinationGuardConfiguration: .disabled,
        transcribe: { _, _, _, _, _ in try await recorder.transcribe() }
    )
    _ = await processor.process(chunk: chunk(boundaryReason: .maximumDuration), sequence: 0)
    let processing = Task {
        await processor.process(chunk: chunk(boundaryReason: .maximumDuration), sequence: 1)
    }
    await recorder.waitForCandidate()

    processing.cancel()
    let cancelled = await processing.value

    try require(cancelled.failure == .cancelled, "candidate domain error hid parent cancellation")
    try require(cancelled.revisions.isEmpty, "cancelled candidate domain error published baseline")

    _ = await processor.process(chunk: chunk(boundaryReason: .stopped), sequence: 2)
    let requestCount = await recorder.count()
    try require(requestCount == 4, "candidate domain error retained retry continuity")
}

private func checkBenchmarkPreservesProcessorHallucinationRejection() async throws {
    let baseline = evidenceResult("one two three four five")
    let recorder = InferenceRecorder([.success(baseline)])
    let processor = WhisperBoundaryProcessor(
        configuration: configuration(strategy: .standard),
        languageCode: "en",
        hallucinationGuardConfiguration: .init(isEnabled: true),
        transcribe: { samples, language, configuration, prompt, metadata in
            try await recorder.transcribe(
                samples: samples,
                languageCode: language,
                configuration: configuration,
                initialPrompt: prompt,
                metadataLevel: metadata
            )
        }
    )
    let source = AudioChunk(
        samples: Array(repeating: 0.1, count: 48_000),
        sampleRate: 48_000,
        boundaryReason: .stopped,
        speechRange: 2_400..<7_200,
        speechEvidenceAnalyzed: true
    )
    let resampled = WhisperAudioPreparation.resampledChunk(
        source,
        samples: Array(repeating: 0.1, count: 16_000),
        sampleRate: 16_000
    )

    let output = await processor.process(chunk: resampled, sequence: 0)
    let classification = WhisperBenchmarkChunkClassification(processed: output)

    try require(classification.text == baseline.text, "benchmark discarded rejected baseline evidence")
    try require(
        classification.rejectionReason == .baselineRejectedHallucination,
        "benchmark reclassified processor rejection as empty"
    )
}

private func checkBenchmarkPassCountsAndVisualizesStructuredRejection() throws {
    var accumulator = WhisperBenchmarkPassAccumulator()
    let state = accumulator.consume(
        WhisperBenchmarkChunkClassification(
            text: "rejected baseline evidence",
            rejectionReason: .baselineRejectedHallucination
        ),
        chunk: chunk(boundaryReason: .maximumDuration),
        appliesPresentationHallucinationGuard: false,
        hallucinationGuardConfiguration: .disabled
    )

    guard case .rejected(let text, let reason) = state else {
        throw ProcessorCheckFailure.failed("structured benchmark rejection did not visualize as rejected")
    }
    try require(text == "rejected baseline evidence", "benchmark rejection visualization lost text")
    try require(
        reason == WhisperBoundaryRepairReasonCode.baselineRejectedHallucination.rawValue,
        "benchmark rejection visualization lost structured reason"
    )
    try require(accumulator.rejectedResultCount == 1, "benchmark rejection count did not increment")
    try require(accumulator.transcript.isEmpty, "benchmark rejection entered accepted transcript")
    try require(accumulator.previousAcceptedText == nil, "benchmark rejection retained text continuity")
    try require(
        accumulator.previousAcceptedBoundaryReason == nil,
        "benchmark rejection retained boundary continuity"
    )
}

private func checkBenchmarkPassAppliesConfiguredFinalCleanup() throws {
    var accumulator = WhisperBenchmarkPassAccumulator()
    _ = accumulator.consume(
        WhisperBenchmarkChunkClassification(text: "need check boundary function"),
        chunk: chunk(
            boundaryReason: .maximumDuration,
            trailingOverlapDuration: 0.2
        ),
        appliesPresentationHallucinationGuard: false,
        hallucinationGuardConfiguration: .disabled
    )
    _ = accumulator.consume(
        WhisperBenchmarkChunkClassification(text: "check boundary functio after"),
        chunk: chunk(boundaryReason: .stopped),
        appliesPresentationHallucinationGuard: false,
        hallucinationGuardConfiguration: .disabled
    )

    let unprocessedWordCount = accumulator.transcript.split(separator: " ").count
    let cleanedWordCount = accumulator.transcript(
        postProcessing: .init(isEnabled: true)
    ).split(separator: " ").count

    try require(
        cleanedWordCount < unprocessedWordCount,
        "benchmark final cleanup did not stitch the recognized segment boundary"
    )
}

private func checkBenchmarkPassUsesForcedBoundaryForContinuationCasing() throws {
    var accumulator = WhisperBenchmarkPassAccumulator()
    _ = accumulator.consume(
        WhisperBenchmarkChunkClassification(text: "нам стоит обратно вернуть"),
        chunk: chunk(boundaryReason: .maximumDuration),
        appliesPresentationHallucinationGuard: false,
        hallucinationGuardConfiguration: .disabled
    )
    _ = accumulator.consume(
        WhisperBenchmarkChunkClassification(text: "Потому что цель ещё не достигнута"),
        chunk: chunk(boundaryReason: .stopped),
        appliesPresentationHallucinationGuard: false,
        hallucinationGuardConfiguration: .disabled
    )

    try require(
        accumulator.transcript(
            postProcessing: .init(isEnabled: true, languageCode: "ru-RU")
        ) == "нам стоит обратно вернуть потому что цель ещё не достигнута",
        "benchmark cleanup lost the forced chunk boundary"
    )
}

private func checkLowSignalArtifactsPreserveRealSpeechAndRejectedEvidence() async throws {
    let real = WhisperSegmentEvidence(
        text: "Настоящая речь.", startTime: 0, endTime: 1,
        noSpeechProbability: 0, tokens: [])
    let fake = WhisperSegmentEvidence(
        text: "Субтитры подготовил Иван Иванов", startTime: 1, endTime: 3,
        noSpeechProbability: 0, tokens: [])
    let mixed = WhisperTranscriptionResult(
        text: real.text + " " + fake.text, segments: [real, fake],
        detectedLanguage: "ru", inferenceDuration: 0.1)
    let gratitude = evidenceResult("Thank you.")
    let recorder = InferenceRecorder([.success(mixed), .success(gratitude)])
    let processor = WhisperBoundaryProcessor(
        configuration: configuration(strategy: .standard), languageCode: "ru",
        hallucinationGuardConfiguration: .init(isEnabled: true),
        transcribe: { samples, language, configuration, prompt, metadata in
            try await recorder.transcribe(
                samples: samples, languageCode: language,
                configuration: configuration, initialPrompt: prompt, metadataLevel: metadata)
        })
    let source = AudioChunk(
        samples: Array(repeating: Float(0.1), count: 100) + Array(repeating: 0, count: 200),
        sampleRate: 100, boundaryReason: .stopped)
    let accepted = await processor.process(chunk: source, sequence: 0)
    try require(
        accepted.revisions.map(\.text) == [real.text], "silent credits discarded real speech or escaped filtering")
    try require(accepted.revisions.first?.segmentID == source.id, "filtered final lost draft alignment")
    let rejected = await processor.process(
        chunk: AudioChunk(
            samples: Array(repeating: 0, count: 300),
            sampleRate: 100, boundaryReason: .stopped), sequence: 1)
    try require(rejected.revisions.isEmpty, "silent gratitude was published")
    try require(rejected.failure == nil, "hallucination rejection became an inference failure")
    try require(
        rejected.diagnostics.reasonCode == .baselineRejectedHallucination, "quiet artifact was classified as empty")
    try require(rejected.baseline?.text == gratitude.text, "rejected source evidence was lost")
    let requests = await recorder.requests
    try require(
        requests.allSatisfy { $0.metadataLevel == .segmentTimestamps },
        "hallucination guard did not request native segment boundaries")
}

@main
private struct WhisperBoundaryProcessorChecksMain {
    static func main() async {
        do {
            try await checkLowSignalArtifactsPreserveRealSpeechAndRejectedEvidence()
            try await checkStandardUsesOneIndependentBaseline()
            try await checkContextualRetryIsGatedAndRevisesSameSegment()
            try await checkRejectedAndFailedAlternativesReturnExactBaseline()
            try await checkBaselineProviderFailureAndCancellationDiagnostics()
            try await checkBaselineRealCancellationDiagnostics()
            try await checkTimestampResearchModeIsExplicit()
            try await checkBoundaryBridgeUsesBoundedStaticTimestampInference()
            try await checkBoundaryBridgeRejectsAndFailsClosed()
            try await checkBoundaryBridgeGuardRejectsRateAgainstActualBridgeDuration()
            try await checkBoundaryBridgeGuardUsesBridgeDurationForPlausibleCandidate()
            try await checkBoundaryBridgeFailureResetAndRejectedPromotion()
            try await checkBoundaryBridgeParentCancellationClearsTail()
            try await checkParentCancellationDuringCandidatePublishesNoBaseline()
            try await checkParentCancellationWinsOverCandidateDomainError()
            try await checkBenchmarkPreservesProcessorHallucinationRejection()
            try checkBenchmarkPassCountsAndVisualizesStructuredRejection()
            try checkBenchmarkPassAppliesConfiguredFinalCleanup()
            try checkBenchmarkPassUsesForcedBoundaryForContinuationCasing()
            print("Whisper boundary processor behavioral checks passed.")
        } catch {
            FileHandle.standardError.write(Data("Whisper processor check failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
