import AVFoundation
import Foundation
import VoicePanelCore

/// Runs Apple Speech as a continuous low-latency draft beside a chunk-based
/// final engine. Chunk delivery advances the draft timeline; Apple's own task
/// completions never advance it, so delayed callbacks cannot hide fresh drafts.
final class AppleDraftRefinementRecognitionEngine: RecognitionEngine, @unchecked Sendable {
    let audioInputMode: RecognitionAudioInputMode = .continuousBuffersAndVADChunks
    let finalTextPolicy: RecognitionFinalTextPolicy = .finalizedSegmentsOnly
    let finalizationTimeout: TimeInterval

    var onUpdate: ((RecognitionUpdate) -> Void)?
    var onFinished: (() -> Void)?
    var onMetrics: ((RecognitionPerformanceMetrics) -> Void)?
    var onChunkOutcome: ((RecognitionChunkOutcome) -> Void)?
    var onError: ((Error) -> Void)?

    let displayName: String

    var providesLiveDraft: Bool {
        lock.performLocked { draftAvailable }
    }

    private let draft: SystemSpeechRecognitionEngine
    private let finalEngine: RecognitionEngine
    private let draftLocaleIdentifier: String
    private let lock = NSLock()

    private var alignment = DraftFinalSegmentAlignment()
    private var timedDraftTimeline = TimedDraftTimeline()
    private var usesTimedDraft = false
    private var draftAvailable = true
    private var draftFinished = false
    private var finalFinished = false
    private var active = false
    private var finishing = false
    private var didFinish = false

    init(
        displayName: String,
        draftLocaleIdentifier: String,
        draft: SystemSpeechRecognitionEngine,
        finalEngine: RecognitionEngine
    ) {
        self.displayName = displayName
        self.draftLocaleIdentifier = draftLocaleIdentifier
        self.draft = draft
        self.finalEngine = finalEngine
        finalizationTimeout = finalEngine.finalizationTimeout
        configureChildren()
    }

    func requestAuthorization() async throws {
        do {
            try await draft.requestAuthorization()
            lock.performLocked { draftAvailable = true }
        } catch {
            DiagnosticLogger.shared.warning(
                "Apple draft authorization failed", metadata: ["error": error.localizedDescription]
            )
            lock.performLocked { draftAvailable = false }
        }
        try await finalEngine.requestAuthorization()
    }

    func start(localeIdentifier: String) async throws {
        cancel()
        lock.performLocked {
            active = true
            finishing = false
            didFinish = false
            draftFinished = !draftAvailable
            finalFinished = false
            alignment.reset()
            timedDraftTimeline.reset()
            usesTimedDraft = false
        }

        if draftAvailable {
            do {
                try await draft.startDraft(localeIdentifier: draftLocaleIdentifier)
            } catch {
                DiagnosticLogger.shared.warning(
                    "Apple draft startup failed", metadata: ["error": error.localizedDescription]
                )
                lock.performLocked {
                    draftAvailable = false
                    draftFinished = true
                }
            }
        }
        try await finalEngine.start(localeIdentifier: localeIdentifier)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if providesLiveDraft {
            draft.append(buffer)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, captureTimeRange: Range<TimeInterval>) {
        lock.performLocked { usesTimedDraft = true }
        if providesLiveDraft {
            draft.append(buffer, captureTimeRange: captureTimeRange)
        }
    }

    func append(_ chunk: AudioChunk) {
        let registration = lock.performLocked { () -> (Int, Bool, [TranscriptSegmentUpdate]) in
            let sequence = alignment.registerChunk(id: chunk.id, trailingOverlapDuration: chunk.trailingOverlapDuration)
            if usesTimedDraft, chunk.captureTimeRange != nil {
                timedDraftTimeline.register(chunk)
                return (sequence, true, timedDraftTimeline.updates(alignment: &alignment))
            }
            return (sequence, false, [])
        }
        DiagnosticLogger.shared.info(
            "Apple draft chunk partitioned",
            metadata: [
                "sequence": String(registration.0), "timed": String(registration.1),
                "draftRevisions": String(registration.2.count),
                "captureStart": chunk.captureTimeRange.map { String(format: "%.3f", $0.lowerBound) } ?? "unknown",
                "captureEnd": chunk.captureTimeRange.map { String(format: "%.3f", $0.upperBound) } ?? "unknown",
            ]
        )
        for update in registration.2 {
            onUpdate?(RecognitionUpdate(segment: update, shouldDimPartialText: true))
        }
        if providesLiveDraft, !registration.1 {
            draft.advanceDraftSegment(to: registration.0 + 1)
        }
        finalEngine.append(chunk)
    }

    func finishCurrentSegment() {
        if providesLiveDraft {
            draft.finishCurrentSegment()
        }
    }

    func finish() {
        let shouldFinish = lock.performLocked { () -> Bool in
            guard active, !finishing else { return false }
            finishing = true
            return true
        }
        guard shouldFinish else { return }

        if providesLiveDraft {
            draft.finish()
        } else {
            lock.performLocked { draftFinished = true }
        }
        finalEngine.finish()
        completeIfReady()
    }

    func cancel() {
        draft.cancel()
        finalEngine.cancel()
        lock.performLocked {
            active = false
            finishing = false
            didFinish = false
            draftFinished = false
            finalFinished = false
            alignment.reset()
            timedDraftTimeline.reset()
            usesTimedDraft = false
        }
    }

    private func configureChildren() {
        draft.onUpdate = { [weak self] update in
            self?.handleDraft(update)
        }
        draft.onFinished = { [weak self] in
            self?.lock.performLocked { self?.draftFinished = true }
            self?.completeIfReady()
        }
        draft.onError = { [weak self] error in
            DiagnosticLogger.shared.warning(
                "Apple draft unavailable for this recording", metadata: ["error": error.localizedDescription]
            )
            self?.lock.performLocked {
                self?.draftAvailable = false
                self?.draftFinished = true
            }
            self?.completeIfReady()
        }

        finalEngine.onUpdate = { [weak self] update in
            self?.handleFinal(update)
        }
        finalEngine.onMetrics = { [weak self] metrics in
            guard let self else { return }
            self.onMetrics?(
                RecognitionPerformanceMetrics(
                    engineName: self.displayName,
                    queueDepth: metrics.queueDepth,
                    chunkDuration: metrics.chunkDuration,
                    processingDuration: metrics.processingDuration
                ))
        }
        finalEngine.onChunkOutcome = { [weak self] outcome in
            self?.handleFinalOutcome(outcome)
        }
        finalEngine.onFinished = { [weak self] in
            guard let self else { return }
            let shouldCancelDraft = self.lock.performLocked { () -> Bool in
                self.finalFinished = true
                guard !self.draftFinished else { return false }
                self.draftFinished = true
                return true
            }
            if shouldCancelDraft {
                self.draft.cancel()
            }
            self.completeIfReady()
        }
        finalEngine.onError = { [weak self] error in
            self?.onError?(error)
        }
    }

    private func handleDraft(_ update: RecognitionUpdate) {
        if let tokens = update.timedDraftTokens {
            let updates = lock.performLocked { () -> [TranscriptSegmentUpdate] in
                guard active else { return [] }
                timedDraftTimeline.replaceTokens(tokens)
                return timedDraftTimeline.updates(alignment: &alignment)
            }
            for segment in updates {
                onUpdate?(RecognitionUpdate(segment: segment, shouldDimPartialText: true))
            }
            return
        }
        let sequence = update.segment.sequence
        let text = TranscriptTextMerger.join(
            update.segment.stableText,
            update.segment.partialText
        )
        guard !text.isEmpty else { return }

        let payload: RecognitionUpdate? = lock.performLocked {
            guard active, !alignment.isFinalized(sequence: sequence) else {
                return nil
            }
            return RecognitionUpdate(
                segment: TranscriptSegmentUpdate(
                    segmentID: alignment.segmentIDForDraft(sequence: sequence),
                    sequence: sequence,
                    stableText: "",
                    partialText: text,
                    kind: .partial,
                    allowsLeadingOverlap: alignment.allowsLeadingOverlap(sequence: sequence)
                ),
                shouldDimPartialText: true
            )
        }
        if let payload {
            onUpdate?(payload)
        }
    }

    private func handleFinal(_ update: RecognitionUpdate) {
        guard update.segment.kind != .sessionFinal else { return }
        let sequence = update.segment.sequence
        let (remapped, draftRevisions) = lock.performLocked { () -> (RecognitionUpdate, [TranscriptSegmentUpdate]) in
            let remapped = RecognitionUpdate(
                segment: TranscriptSegmentUpdate(
                    segmentID: alignment.segmentIDForFinal(
                        sequence: sequence,
                        engineSegmentID: update.segment.segmentID
                    ),
                    sequence: sequence,
                    stableText: update.segment.stableText,
                    partialText: update.segment.partialText,
                    kind: .segmentFinal,
                    allowsLeadingOverlap: alignment.allowsLeadingOverlap(sequence: sequence)
                ),
                shouldDimPartialText: false
            )
            guard usesTimedDraft else { return (remapped, []) }
            // The next draft segment may repeat late-stamped words of this final.
            timedDraftTimeline.registerFinal(
                sequence: sequence,
                text: TranscriptTextMerger.join(update.segment.stableText, update.segment.partialText)
            )
            return (remapped, timedDraftTimeline.updates(alignment: &alignment))
        }
        onUpdate?(remapped)
        for segment in draftRevisions {
            onUpdate?(RecognitionUpdate(segment: segment, shouldDimPartialText: true))
        }
    }

    private func handleFinalOutcome(_ outcome: RecognitionChunkOutcome) {
        let chunkID: UUID
        switch outcome {
        case .completed(let id):
            chunkID = id
        case .failed(let id, _):
            chunkID = id
        case .cancelled(let id):
            chunkID = id
        }

        let emptyFinal: RecognitionUpdate? = lock.performLocked {
            guard let empty = alignment.finalizeEmptyChunk(id: chunkID) else { return nil }
            return RecognitionUpdate(
                segment: TranscriptSegmentUpdate(
                    segmentID: empty.segmentID,
                    sequence: empty.sequence,
                    stableText: "",
                    partialText: "",
                    kind: .segmentFinal
                ),
                shouldDimPartialText: false
            )
        }
        if let emptyFinal { onUpdate?(emptyFinal) }
        onChunkOutcome?(outcome)
    }

    private func completeIfReady() {
        let completion: RecognitionUpdate? = lock.performLocked {
            guard active, finishing, draftFinished, finalFinished, !didFinish else {
                return nil
            }
            didFinish = true
            active = false
            return RecognitionUpdate(
                segment: TranscriptSegmentUpdate(
                    segmentID: UUID(),
                    sequence: alignment.nextSessionSequence,
                    stableText: "",
                    partialText: "",
                    kind: .sessionFinal
                ),
                shouldDimPartialText: false
            )
        }
        guard let completion else { return }
        onUpdate?(completion)
        onFinished?()
    }
}

extension NSLock {
    fileprivate func performLocked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
