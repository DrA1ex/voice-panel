import Foundation
import VoicePanelCore

#if VOICEPANEL_ENGINE_TESTING
    enum WhisperEnginePublicationAttempt: Equatable, Sendable {
        case metrics
        case revision
        case outcome
        case sessionFinal
        case finished
    }
#endif

final class WhisperRecognitionEngine: RecognitionEngine, @unchecked Sendable {
    let audioInputMode: RecognitionAudioInputMode = .vadChunks
    let finalizationTimeout: TimeInterval = 120

    var onUpdate: ((RecognitionUpdate) -> Void)? {
        get { lifecycle.sync { $0.onUpdate } }
        set { lifecycle.sync { $0.onUpdate = newValue } }
    }
    var onFinished: (() -> Void)? {
        get { lifecycle.sync { $0.onFinished } }
        set { lifecycle.sync { $0.onFinished = newValue } }
    }
    var onMetrics: ((RecognitionPerformanceMetrics) -> Void)? {
        get { lifecycle.sync { $0.onMetrics } }
        set { lifecycle.sync { $0.onMetrics = newValue } }
    }
    var onChunkOutcome: ((RecognitionChunkOutcome) -> Void)? {
        get { lifecycle.sync { $0.onChunkOutcome } }
        set { lifecycle.sync { $0.onChunkOutcome = newValue } }
    }
    var onError: ((Error) -> Void)? {
        get { lifecycle.sync { $0.onError } }
        set { lifecycle.sync { $0.onError = newValue } }
    }

    #if VOICEPANEL_ENGINE_TESTING
        var beforePublicationAttempt: (@Sendable (WhisperEnginePublicationAttempt) -> Void)?
        var afterPublicationAttempt: (@Sendable (WhisperEnginePublicationAttempt) -> Void)?
    #endif

    var displayName: String { "Whisper · \(model.title) · \(runtime.runtimeConfiguration.displayTitle)" }

    private struct PendingChunk: Sendable {
        let source: AudioChunk
        let admitted: AudioChunk?
        let sequence: Int
        let generation: Int
    }

    private final class LifecycleState {
        var generation = 0
        var active = false
        var pendingCount = 0
        var nextSequence = 0
        var pending = WhisperEnginePendingQueue<PendingChunk>()
        var processingTask: Task<Void, Never>?
        var processor: WhisperBoundaryProcessor?
        var finalizationGeneration: Int?
        var onUpdate: ((RecognitionUpdate) -> Void)?
        var onFinished: (() -> Void)?
        var onMetrics: ((RecognitionPerformanceMetrics) -> Void)?
        var onChunkOutcome: ((RecognitionChunkOutcome) -> Void)?
        var onError: ((Error) -> Void)?
    }

    private let model: WhisperModelID
    private let runtime: WhisperRuntime
    private let inferenceConfiguration: WhisperInferenceConfiguration
    private let hallucinationGuardConfiguration: RecognitionHallucinationGuard.Configuration
    private let lifecycle = WhisperEngineLifecycleExecutor(
        label: "io.github.dra1ex.VoicePanel.whisper-engine-lifecycle",
        initialState: LifecycleState()
    )

    init(
        model: WhisperModelID,
        runtime: WhisperRuntime,
        inferenceConfiguration: WhisperInferenceConfiguration,
        hallucinationGuardConfiguration: RecognitionHallucinationGuard.Configuration = .disabled
    ) {
        self.model = model
        self.runtime = runtime
        self.inferenceConfiguration = inferenceConfiguration
        self.hallucinationGuardConfiguration = hallucinationGuardConfiguration
    }

    func requestAuthorization() async throws {}

    func start(localeIdentifier: String) async throws {
        cancel()
        let language = localeIdentifier.isEmpty ? "auto" : localeIdentifier
        let processor = makeProcessor(languageCode: language)
        lifecycle.sync { state in
            state.generation += 1
            state.active = true
            state.pendingCount = 0
            state.nextSequence = 0
            state.pending.reset()
            state.processor = processor
            state.finalizationGeneration = nil
        }
    }

    func append(_ chunk: AudioChunk) {
        let admitted = RecognitionInferenceChunkPolicy.admittedChunk(chunk)
        let metric: (AudioChunk, Int)? = lifecycle.sync { state in
            guard state.active else { return nil }
            let work = PendingChunk(
                source: chunk,
                admitted: admitted,
                sequence: state.nextSequence,
                generation: state.generation
            )
            guard state.pending.append(work) else { return nil }
            state.nextSequence += 1
            if admitted != nil { state.pendingCount += 1 }
            startProcessingIfNeeded(state: state)
            guard let admitted else { return nil }
            return (admitted, state.generation)
        }

        if let (admitted, expectedGeneration) = metric {
            publishQueueMetrics(
                chunk: admitted,
                processingDuration: 0,
                generation: expectedGeneration
            )
        }
    }

    func finish() {
        lifecycle.sync { state in
            guard state.active else { return }
            state.pending.finish()
            startProcessingIfNeeded(state: state)
        }
    }

    func cancel() {
        let cancelled: (Task<Void, Never>?, WhisperBoundaryProcessor?) = lifecycle.sync { state in
            state.generation += 1
            state.active = false
            state.pendingCount = 0
            state.pending.reset()
            state.finalizationGeneration = nil
            let task = state.processingTask
            state.processingTask = nil
            let processor = state.processor
            state.processor = nil
            return (task, processor)
        }
        cancelled.0?.cancel()
        if let processor = cancelled.1 {
            Task { await processor.reset() }
        }
    }

    private func makeProcessor(languageCode: String) -> WhisperBoundaryProcessor {
        WhisperBoundaryProcessor(
            configuration: inferenceConfiguration,
            languageCode: languageCode,
            hallucinationGuardConfiguration: hallucinationGuardConfiguration,
            transcribe: { [runtime] samples, language, configuration, prompt, metadata in
                try await runtime.transcribe(
                    samples: samples,
                    languageCode: language,
                    configuration: configuration,
                    initialPrompt: prompt,
                    metadataLevel: metadata
                )
            }
        )
    }

    private func startProcessingIfNeeded(state: LifecycleState) {
        guard state.processingTask == nil else { return }
        let taskGeneration = state.generation
        state.processingTask = Task { [weak self] in
            await self?.drainPending(generation: taskGeneration)
        }
    }

    private func drainPending(generation taskGeneration: Int) async {
        var finalSequence: Int?
        drain: while true {
            while true {
                let next: (PendingChunk, WhisperBoundaryProcessor)? = lifecycle.sync { state in
                    guard state.generation == taskGeneration,
                        state.active,
                        let processor = state.processor,
                        let work = state.pending.removeFirst()
                    else {
                        return nil
                    }
                    return (work, processor)
                }
                guard let (work, processor) = next else { break }
                await process(work, with: processor)
            }

            let queueWasRefilled: Bool = lifecycle.sync { state in
                guard state.generation == taskGeneration, state.active else { return false }
                if !state.pending.isEmpty { return true }
                state.processingTask = nil
                guard state.pending.shouldFinalize else { return false }
                state.active = false
                state.finalizationGeneration = taskGeneration
                finalSequence = state.nextSequence
                return false
            }
            if queueWasRefilled { continue drain }
            break
        }
        guard let finalSequence else { return }

        publishSessionFinal(generation: taskGeneration, sequence: finalSequence)
        publishFinished(generation: taskGeneration)
    }

    private func process(
        _ work: PendingChunk,
        with processor: WhisperBoundaryProcessor
    ) async {
        guard let admitted = work.admitted else {
            await processor.reset()
            guard isCurrentProcessing(work.generation) else { return }
            DiagnosticLogger.shared.info(
                "Silent Whisper chunk skipped",
                metadata: [
                    "chunk": work.source.id.uuidString,
                    "seconds": String(format: "%.3f", work.source.duration),
                    "boundary": work.source.boundaryReason.rawValue,
                    "overlapSeconds": String(
                        format: "%.3f",
                        work.source.trailingOverlapDuration
                    ),
                ]
            )
            publishOutcome(.completed(work.source.id), generation: work.generation)
            return
        }

        let samples = LinearAudioResampler.resampleMono(
            samples: admitted.samples,
            from: admitted.sampleRate
        )
        guard !samples.isEmpty else {
            await processor.reset()
            completeEmpty(work)
            return
        }
        let inferenceChunk = WhisperAudioPreparation.resampledChunk(
            admitted,
            samples: samples,
            sampleRate: 16_000
        )
        let started = Date()
        let output = await processor.process(chunk: inferenceChunk, sequence: work.sequence)
        let elapsed = Date().timeIntervalSince(started)
        let remainingDepth = decrementPending(generation: work.generation)
        publishQueueMetrics(
            chunk: admitted,
            processingDuration: elapsed,
            queueDepth: remainingDepth,
            generation: work.generation
        )
        guard isCurrentProcessing(work.generation) else { return }

        var metadata = output.diagnosticMetadata
        metadata["chunk"] = work.source.id.uuidString
        metadata["chunkSeconds"] = String(format: "%.3f", admitted.duration)
        metadata["processingMilliseconds"] = String(Int(elapsed * 1_000))
        metadata["queueDepth"] = String(remainingDepth)
        DiagnosticLogger.shared.info(
            "Whisper boundary processing completed",
            metadata: metadata
        )
        for revision in output.revisions {
            guard publishRevision(revision, generation: work.generation) else { return }
        }

        let outcome: RecognitionChunkOutcome
        switch output.failure {
        case nil:
            outcome = .completed(work.source.id)
        case .cancelled:
            outcome = .cancelled(work.source.id)
        case .baselineFailed(let message):
            outcome = .failed(work.source.id, message: message)
        }
        publishOutcome(outcome, generation: work.generation)
    }

    private func completeEmpty(_ work: PendingChunk) {
        _ = decrementPending(generation: work.generation)
        publishOutcome(.completed(work.source.id), generation: work.generation)
    }

    @discardableResult
    private func decrementPending(generation expectedGeneration: Int) -> Int {
        lifecycle.sync { state in
            guard state.generation == expectedGeneration else { return 0 }
            state.pendingCount = max(0, state.pendingCount - 1)
            return state.pendingCount
        }
    }

    private func publishQueueMetrics(
        chunk: AudioChunk,
        processingDuration: TimeInterval,
        queueDepth: Int? = nil,
        generation expectedGeneration: Int
    ) {
        let depth = queueDepth ?? lifecycle.sync { $0.pendingCount }
        let metrics = RecognitionPerformanceMetrics(
            engineName: displayName,
            queueDepth: depth,
            chunkDuration: chunk.duration,
            processingDuration: processingDuration
        )
        #if VOICEPANEL_ENGINE_TESTING
            beforePublicationAttempt?(.metrics)
        #endif
        lifecycle.sync { state in
            guard state.generation == expectedGeneration, state.active else { return }
            state.onMetrics?(metrics)
        }
        #if VOICEPANEL_ENGINE_TESTING
            afterPublicationAttempt?(.metrics)
        #endif
    }

    @discardableResult
    private func publishRevision(
        _ revision: WhisperProcessedSegmentRevision,
        generation expectedGeneration: Int
    ) -> Bool {
        let update = RecognitionUpdate(
            segment: TranscriptSegmentUpdate(
                segmentID: revision.segmentID,
                sequence: revision.sequence,
                stableText: revision.text,
                partialText: "",
                kind: .segmentFinal
            ),
            shouldDimPartialText: false
        )
        #if VOICEPANEL_ENGINE_TESTING
            beforePublicationAttempt?(.revision)
        #endif
        let published = lifecycle.sync { state in
            guard state.generation == expectedGeneration, state.active else { return false }
            state.onUpdate?(update)
            return true
        }
        #if VOICEPANEL_ENGINE_TESTING
            afterPublicationAttempt?(.revision)
        #endif
        return published
    }

    private func publishOutcome(
        _ outcome: RecognitionChunkOutcome,
        generation expectedGeneration: Int
    ) {
        #if VOICEPANEL_ENGINE_TESTING
            beforePublicationAttempt?(.outcome)
        #endif
        lifecycle.sync { state in
            guard state.generation == expectedGeneration, state.active else { return }
            state.onChunkOutcome?(outcome)
        }
        #if VOICEPANEL_ENGINE_TESTING
            afterPublicationAttempt?(.outcome)
        #endif
    }

    private func publishSessionFinal(generation expectedGeneration: Int, sequence: Int) {
        let update = RecognitionUpdate(
            segment: TranscriptSegmentUpdate(
                segmentID: UUID(),
                sequence: sequence,
                stableText: "",
                partialText: "",
                kind: .sessionFinal
            ),
            shouldDimPartialText: false
        )
        #if VOICEPANEL_ENGINE_TESTING
            beforePublicationAttempt?(.sessionFinal)
        #endif
        lifecycle.sync { state in
            guard state.generation == expectedGeneration,
                state.finalizationGeneration == expectedGeneration
            else {
                return
            }
            state.onUpdate?(update)
        }
        #if VOICEPANEL_ENGINE_TESTING
            afterPublicationAttempt?(.sessionFinal)
        #endif
    }

    private func publishFinished(generation expectedGeneration: Int) {
        #if VOICEPANEL_ENGINE_TESTING
            beforePublicationAttempt?(.finished)
        #endif
        lifecycle.sync { state in
            guard state.generation == expectedGeneration,
                state.finalizationGeneration == expectedGeneration
            else {
                return
            }
            state.onFinished?()
        }
        #if VOICEPANEL_ENGINE_TESTING
            afterPublicationAttempt?(.finished)
        #endif
    }

    private func isCurrentProcessing(_ expectedGeneration: Int) -> Bool {
        lifecycle.sync { state in
            state.generation == expectedGeneration && state.active
        }
    }
}
