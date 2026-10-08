import Foundation
import VoicePanelCore

/// Runs a fast chunk-based draft engine before a slower chunk-based final engine.
/// Both engines receive the exact same AudioChunk, so final text can replace the
/// corresponding draft segment without timestamp guesses or duplicated text.
final class ChunkDraftRefinementRecognitionEngine: RecognitionEngine, @unchecked Sendable {
    let audioInputMode: RecognitionAudioInputMode = .vadChunks
    let finalTextPolicy: RecognitionFinalTextPolicy = .finalizedSegmentsOnly
    let finalizationTimeout: TimeInterval
    let displayName: String
    let providesLiveDraft = true

    var onUpdate: ((RecognitionUpdate) -> Void)?
    var onFinished: (() -> Void)?
    var onMetrics: ((RecognitionPerformanceMetrics) -> Void)?
    var onChunkOutcome: ((RecognitionChunkOutcome) -> Void)?
    var onError: ((Error) -> Void)?

    private let draftEngine: RecognitionEngine
    private let finalEngine: RecognitionEngine
    private let draftLocaleIdentifier: String
    private let finalLocaleIdentifier: String
    private let lock = NSLock()

    private var alignment = DraftFinalSegmentAlignment()
    private var active = false
    private var finishing = false
    private var draftFinished = false
    private var finalFinished = false
    private var didFinish = false

    init(
        displayName: String,
        draftLocaleIdentifier: String,
        finalLocaleIdentifier: String,
        draftEngine: RecognitionEngine,
        finalEngine: RecognitionEngine
    ) {
        self.displayName = displayName
        self.draftLocaleIdentifier = draftLocaleIdentifier
        self.finalLocaleIdentifier = finalLocaleIdentifier
        self.draftEngine = draftEngine
        self.finalEngine = finalEngine
        finalizationTimeout = finalEngine.finalizationTimeout
        configureChildren()
    }

    func requestAuthorization() async throws {
        try await draftEngine.requestAuthorization()
        try await finalEngine.requestAuthorization()
    }

    func start(localeIdentifier: String) async throws {
        cancel()
        lock.performLocked {
            active = true
            finishing = false
            draftFinished = false
            finalFinished = false
            didFinish = false
            alignment.reset()
        }
        try await draftEngine.start(localeIdentifier: draftLocaleIdentifier)
        try await finalEngine.start(localeIdentifier: finalLocaleIdentifier)
    }

    func append(_ chunk: AudioChunk) {
        lock.performLocked {
            _ = alignment.registerChunk(id: chunk.id, trailingOverlapDuration: chunk.trailingOverlapDuration)
        }
        draftEngine.append(chunk)
        finalEngine.append(chunk)
    }

    func finish() {
        let shouldFinish = lock.performLocked { () -> Bool in
            guard active, !finishing else { return false }
            finishing = true
            return true
        }
        guard shouldFinish else { return }
        draftEngine.finish()
        finalEngine.finish()
        completeIfReady()
    }

    func cancel() {
        draftEngine.cancel()
        finalEngine.cancel()
        lock.performLocked {
            active = false
            finishing = false
            draftFinished = false
            finalFinished = false
            didFinish = false
            alignment.reset()
        }
    }

    private func configureChildren() {
        draftEngine.onUpdate = { [weak self] update in
            self?.handleDraft(update)
        }
        draftEngine.onFinished = { [weak self] in
            self?.lock.performLocked { self?.draftFinished = true }
            self?.completeIfReady()
        }
        draftEngine.onError = { [weak self] _ in
            // Draft failure must not discard the higher-quality final engine.
            self?.lock.performLocked { self?.draftFinished = true }
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
                self.draftEngine.cancel()
            }
            self.completeIfReady()
        }
        finalEngine.onError = { [weak self] error in
            self?.onError?(error)
        }
    }

    private func handleDraft(_ update: RecognitionUpdate) {
        guard update.segment.kind != .sessionFinal else { return }
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
        let payload = lock.performLocked {
            RecognitionUpdate(
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
        }
        onUpdate?(payload)
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
