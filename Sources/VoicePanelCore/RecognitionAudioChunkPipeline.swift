import Foundation

/// Pure, deterministic audio-to-chunk state used by the live capture service.
/// Keeping it outside AVAudioEngine lets the release/finalization path be
/// exercised with synthetic audio instead of a physical microphone.
public struct RecognitionAudioChunkPipeline: Sendable {
    public struct ProcessResult: Sendable {
        public let event: VoiceActivityEvent
        public let snapshot: VoiceActivitySnapshot
        public let chunks: [AudioChunk]
        public let capturedDuration: TimeInterval
        public let pendingDuration: TimeInterval
    }

    public struct StopResult: Sendable {
        public let capturedDuration: TimeInterval
        public let emittedChunkCount: Int
        public let finalChunks: [AudioChunk]
    }

    public private(set) var capturedDuration: TimeInterval = 0

    private var detector: VoiceActivityDetector
    private var fusion = VoiceActivityFusion()
    private var relativeEnergyPauseTracker = RelativeEnergyPauseTracker()
    private var detectionMode: VoiceActivityDetectionMode
    private var endOfSpeechSilenceDuration: TimeInterval
    private var segmenter: AudioSegmenter
    private var minimumChunkDeliveryDuration: TimeInterval
    private var deferredChunks: [AudioChunk] = []
    private var deliveredChunkCount = 0
    private var forcedChunkAccumulator: ForcedChunkAccumulator

    public init(
        vadConfiguration: VoiceActivityDetector.Configuration = .balanced,
        segmenterConfiguration: AudioSegmenter.Configuration = .init(),
        minimumChunkDeliveryDuration: TimeInterval = 0,
        detectionMode: VoiceActivityDetectionMode = .energy
    ) {
        detector = VoiceActivityDetector(configuration: vadConfiguration)
        self.detectionMode = detectionMode
        endOfSpeechSilenceDuration = vadConfiguration.endOfSpeechSilenceDuration
        segmenter = AudioSegmenter(configuration: segmenterConfiguration)
        self.minimumChunkDeliveryDuration = max(0, minimumChunkDeliveryDuration)
        forcedChunkAccumulator = ForcedChunkAccumulator(
            configuration: .init(
                maximumChunkDuration: segmenterConfiguration.maximumChunkDuration,
                overlapDuration: segmenterConfiguration.overlapDuration,
                minimumChunkDuration: segmenterConfiguration.minimumChunkDuration,
                minimumSpeechEvidenceDuration: 0.35
            ))
    }

    public mutating func updateVADConfiguration(
        _ configuration: VoiceActivityDetector.Configuration
    ) {
        detector.updateConfiguration(configuration)
        endOfSpeechSilenceDuration = configuration.endOfSpeechSilenceDuration
    }

    public mutating func updateDetectionMode(_ mode: VoiceActivityDetectionMode) {
        detectionMode = mode
        fusion.reset()
        relativeEnergyPauseTracker.reset()
    }

    public mutating func process(
        samples: [Float],
        sampleRate: Double,
        rmsDB: Float,
        neuralSpeechDetected: Bool? = nil
    ) -> ProcessResult? {
        guard !samples.isEmpty, sampleRate > 0 else { return nil }

        let duration = Double(samples.count) / sampleRate
        let captureStartTime = capturedDuration
        capturedDuration += duration
        let (energyEvent, energySnapshot) = detector.process(
            rmsDB: rmsDB,
            frameDuration: duration
        )
        let (event, snapshot) = fusion.process(
            mode: detectionMode,
            energyEvent: energyEvent,
            energySnapshot: energySnapshot,
            neuralSpeechDetected: neuralSpeechDetected,
            frameDuration: duration,
            endOfSpeechSilenceDuration: endOfSpeechSilenceDuration
        )
        let relativeEnergyPauseDuration = relativeEnergyPauseTracker.process(
            rmsDB: rmsDB,
            frameDuration: duration,
            tracksActiveSpeech: event.tracksActiveSpeech
        )
        let boundaryPauseDuration =
            [
                energyEvent.boundaryPauseDuration ?? 0,
                fusion.neuralPauseEvidenceDuration,
                relativeEnergyPauseDuration,
            ].max() ?? 0
        let closesLongHybridSilence =
            detectionMode == .hybrid
            && segmenter.isCollectingSpeech
            && fusion.neuralPauseEvidenceDuration
                >= max(1.5, endOfSpeechSilenceDuration * 2)
            && !event.endsSpeech
        let segmenterEvent: VoiceActivityEvent =
            closesLongHybridSilence
            ? .speechEnded(silenceDuration: fusion.neuralPauseEvidenceDuration)
            : event
        let segmenterSnapshot =
            closesLongHybridSilence
            ? VoiceActivitySnapshot(
                state: .silence,
                rmsDB: snapshot.rmsDB,
                noiseFloorDB: snapshot.noiseFloorDB,
                thresholdDB: snapshot.thresholdDB
            )
            : snapshot
        var generatedChunks = segmenter.process(
            samples: samples,
            sampleRate: sampleRate,
            event: segmenterEvent,
            boundaryPauseDuration: boundaryPauseDuration > 0
                ? boundaryPauseDuration : nil,
            speechEndBoundaryReason: closesLongHybridSilence ? .longSilence : .silence,
            captureStartTime: captureStartTime
        )
        if segmenterEvent.endsSpeech {
            relativeEnergyPauseTracker.reset()
        }
        if closesLongHybridSilence {
            fusion.reset()
        }

        if !generatedChunks.isEmpty || segmenter.isCollectingSpeech {
            forcedChunkAccumulator.reset()
        } else {
            let fallbackActivationDB = max(
                snapshot.noiseFloorDB + 4,
                snapshot.thresholdDB - 10
            )
            let hasExplicitNeuralSilence =
                detectionMode != .energy && neuralSpeechDetected == false
            generatedChunks.append(
                contentsOf: forcedChunkAccumulator.process(
                    samples: samples,
                    sampleRate: sampleRate,
                    hasSpeechEvidence: !hasExplicitNeuralSilence
                        && (snapshot.state != .silence || rmsDB >= fallbackActivationDB),
                    captureStartTime: captureStartTime
                ))
        }

        if !generatedChunks.isEmpty {
            deferredChunks.append(contentsOf: generatedChunks)
        }

        var chunksToEmit: [AudioChunk] = []
        if capturedDuration >= minimumChunkDeliveryDuration, !deferredChunks.isEmpty {
            chunksToEmit = deferredChunks
            deferredChunks.removeAll(keepingCapacity: true)
            deliveredChunkCount += chunksToEmit.count
        }

        let deferredDuration = deferredChunks.reduce(0) { $0 + $1.duration }
        let forcedPendingDuration =
            forcedChunkAccumulator.hasSpeechEvidence
            ? forcedChunkAccumulator.pendingDuration
            : 0
        let pendingDuration = max(
            segmenter.pendingDuration,
            max(deferredDuration, forcedPendingDuration)
        )
        return ProcessResult(
            event: segmenterEvent,
            snapshot: segmenterSnapshot,
            chunks: chunksToEmit,
            capturedDuration: capturedDuration,
            pendingDuration: pendingDuration
        )
    }

    public mutating func stop(
        flushFinalChunk: Bool = true,
        forceChunkIfDurationAtLeast minimumDuration: TimeInterval? = nil
    ) -> StopResult {
        let duration = capturedDuration
        var chunksToEmit: [AudioChunk] = []

        if flushFinalChunk {
            let finalChunks = segmenter.finishChunks(reason: .stopped)
            if !finalChunks.isEmpty {
                deferredChunks.append(contentsOf: finalChunks)
                forcedChunkAccumulator.reset()
            } else if duration >= max(0, minimumDuration ?? 0),
                let forcedTail = forcedChunkAccumulator.finish(
                    reason: .stopped,
                    requireSpeechEvidence: false
                )
            {
                deferredChunks.append(forcedTail)
            }
        } else {
            segmenter.reset()
            forcedChunkAccumulator.reset()
        }

        if flushFinalChunk, duration >= minimumChunkDeliveryDuration {
            chunksToEmit = deferredChunks
            deliveredChunkCount += chunksToEmit.count
        }

        let result = StopResult(
            capturedDuration: duration,
            emittedChunkCount: deliveredChunkCount,
            finalChunks: chunksToEmit
        )
        reset()
        return result
    }

    /// Closes the current device-specific tail without ending the recording
    /// session. Captured duration, deferred chunks, and delivery bookkeeping
    /// survive so a replacement input can continue the same transcript.
    public mutating func inputChanged() -> [AudioChunk] {
        let changedInputChunks = segmenter.finishChunks(reason: .inputChanged)
        if !changedInputChunks.isEmpty {
            deferredChunks.append(contentsOf: changedInputChunks)
            forcedChunkAccumulator.reset()
        } else if let forcedTail = forcedChunkAccumulator.finish(
            reason: .inputChanged,
            requireSpeechEvidence: true
        ) {
            deferredChunks.append(forcedTail)
        }
        detector.reset()
        fusion.reset()
        relativeEnergyPauseTracker.reset()

        guard capturedDuration >= minimumChunkDeliveryDuration, !deferredChunks.isEmpty else {
            return []
        }
        let chunks = deferredChunks
        deferredChunks.removeAll(keepingCapacity: true)
        deliveredChunkCount += chunks.count
        return chunks
    }

    private mutating func reset() {
        detector.reset()
        fusion.reset()
        relativeEnergyPauseTracker.reset()
        segmenter.reset()
        forcedChunkAccumulator.reset()
        capturedDuration = 0
        minimumChunkDeliveryDuration = 0
        deferredChunks.removeAll(keepingCapacity: true)
        deliveredChunkCount = 0
    }
}

extension VoiceActivityEvent {
    fileprivate var boundaryPauseDuration: TimeInterval? {
        switch self {
        case .possiblePause(let duration): return duration
        case .speechEnded(let silenceDuration): return silenceDuration
        case .silence, .speechStarted, .speechContinued: return nil
        }
    }

    fileprivate var tracksActiveSpeech: Bool {
        switch self {
        case .speechStarted, .speechContinued, .possiblePause:
            return true
        case .silence, .speechEnded:
            return false
        }
    }

    fileprivate var endsSpeech: Bool {
        if case .speechEnded = self { return true }
        return false
    }
}

private struct RelativeEnergyPauseTracker: Sendable {
    private static let minimumCalibrationDuration: TimeInterval = 0.20
    private static let pauseDropDB: Float = 12

    private var referenceDB: Float?
    private var calibrationDuration: TimeInterval = 0
    private var pauseDuration: TimeInterval = 0

    mutating func process(
        rmsDB: Float,
        frameDuration: TimeInterval,
        tracksActiveSpeech: Bool
    ) -> TimeInterval {
        guard tracksActiveSpeech, rmsDB.isFinite else {
            pauseDuration = 0
            return 0
        }

        let duration = max(0, frameDuration)
        guard let referenceDB else {
            self.referenceDB = rmsDB
            calibrationDuration = duration
            return 0
        }

        if calibrationDuration >= Self.minimumCalibrationDuration,
            referenceDB - rmsDB >= Self.pauseDropDB
        {
            pauseDuration += duration
            return pauseDuration
        }

        pauseDuration = 0
        calibrationDuration += duration
        let alpha: Float = rmsDB > referenceDB ? 0.20 : 0.04
        self.referenceDB = referenceDB + (rmsDB - referenceDB) * alpha
        return 0
    }

    mutating func reset() {
        referenceDB = nil
        calibrationDuration = 0
        pauseDuration = 0
    }
}
