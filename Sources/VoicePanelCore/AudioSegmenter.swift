import Foundation

public enum AudioChunkBoundaryReason: String, Codable, Equatable, Sendable {
    case silence
    case longSilence
    case maximumDuration
    case balancedPause
    case stopped
    case inputChanged
}

public struct AudioChunkBoundaryMetadata: Codable, Equatable, Sendable {
    public let reason: AudioChunkBoundaryReason
    public let trailingOverlapDuration: TimeInterval

    public init(
        reason: AudioChunkBoundaryReason,
        trailingOverlapDuration: TimeInterval = 0
    ) {
        self.reason = reason
        self.trailingOverlapDuration = max(0, trailingOverlapDuration.isFinite ? trailingOverlapDuration : 0)
    }
}

public struct AudioChunk: Equatable, Sendable {
    public let id: UUID
    public let samples: [Float]
    public let sampleRate: Double
    public let boundaryReason: AudioChunkBoundaryReason
    /// Audio at the end of this chunk that the segmenter also placed at the
    /// beginning of its continuation. External and legacy chunks default to
    /// zero because duplicated PCM has not been proven.
    public let trailingOverlapDuration: TimeInterval
    /// Sample range that VAD classified as speech. `speechEvidenceAnalyzed`
    /// distinguishes a known silent chunk from legacy/external audio whose
    /// speech range is unknown.
    public let speechRange: Range<Int>?
    public let speechEvidenceAnalyzed: Bool
    /// Position in the captured session, before silence suppression or resampling.
    public let captureTimeRange: Range<TimeInterval>?

    public init(
        id: UUID = UUID(),
        samples: [Float],
        sampleRate: Double,
        boundaryReason: AudioChunkBoundaryReason,
        trailingOverlapDuration: TimeInterval = 0,
        speechRange: Range<Int>? = nil,
        speechEvidenceAnalyzed: Bool = false,
        captureTimeRange: Range<TimeInterval>? = nil
    ) {
        self.id = id
        self.samples = samples
        self.sampleRate = sampleRate
        self.boundaryReason = boundaryReason
        self.trailingOverlapDuration = max(
            0,
            trailingOverlapDuration.isFinite ? trailingOverlapDuration : 0
        )
        self.speechRange = speechRange
        self.speechEvidenceAnalyzed = speechEvidenceAnalyzed
        self.captureTimeRange = captureTimeRange
    }

    public var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }

    public var boundaryMetadata: AudioChunkBoundaryMetadata {
        AudioChunkBoundaryMetadata(
            reason: boundaryReason,
            trailingOverlapDuration: trailingOverlapDuration
        )
    }

    public func trimmingSilence(
        preRollDuration: TimeInterval,
        postRollDuration: TimeInterval
    ) -> AudioChunk? {
        guard speechEvidenceAnalyzed else { return self }
        guard let speechRange, !speechRange.isEmpty, sampleRate > 0 else { return nil }

        let speechLowerBound = min(max(0, speechRange.lowerBound), samples.count)
        let speechUpperBound = min(max(speechLowerBound, speechRange.upperBound), samples.count)
        guard speechLowerBound < speechUpperBound else { return nil }
        let preRoll = max(0, Int((preRollDuration * sampleRate).rounded()))
        let postRoll = max(0, Int((postRollDuration * sampleRate).rounded()))
        let lowerBound = max(0, speechLowerBound - preRoll)
        let upperBound = min(samples.count, speechUpperBound + postRoll)
        guard lowerBound < upperBound else { return nil }

        return AudioChunk(
            id: id,
            samples: Array(samples[lowerBound..<upperBound]),
            sampleRate: sampleRate,
            boundaryReason: boundaryReason,
            trailingOverlapDuration: trailingOverlapDuration,
            speechRange: (speechLowerBound - lowerBound)..<(speechUpperBound - lowerBound),
            speechEvidenceAnalyzed: true,
            captureTimeRange: captureTimeRange.map {
                ($0.lowerBound + Double(lowerBound) / sampleRate)..<($0.lowerBound + Double(upperBound) / sampleRate)
            }
        )
    }
}

public struct AudioSegmenter: Sendable {
    public enum ForcedBoundaryMode: String, Codable, Equatable, Sendable {
        /// Emit as soon as the current chunk reaches its maximum duration.
        case immediate
        /// Buffer a larger decision window, then divide it at the strongest
        /// usable pause. This trades latency for better-balanced chunks.
        case deferredPauseBalanced
    }

    public struct Configuration: Equatable, Sendable {
        public var preRollDuration: TimeInterval
        public var postRollDuration: TimeInterval
        public var overlapDuration: TimeInterval
        public var maximumChunkDuration: TimeInterval
        public var minimumChunkDuration: TimeInterval
        /// When a hard limit is reached, prefer the nearest recent VAD pause
        /// instead of cutting at the exact sample limit. Zero keeps exact cuts.
        public var forcedBoundaryLookbackDuration: TimeInterval
        public var minimumForcedBoundaryPauseDuration: TimeInterval
        public var forcedBoundaryMode: ForcedBoundaryMode
        /// Maximum audio retained while deferred pause balancing chooses a cut.
        public var deferredBoundaryDecisionDuration: TimeInterval

        public init(
            preRollDuration: TimeInterval = 0.25,
            postRollDuration: TimeInterval = 0.15,
            overlapDuration: TimeInterval = 0.20,
            maximumChunkDuration: TimeInterval = 18,
            minimumChunkDuration: TimeInterval = 0.20,
            forcedBoundaryLookbackDuration: TimeInterval = 0,
            minimumForcedBoundaryPauseDuration: TimeInterval = 0.40,
            forcedBoundaryMode: ForcedBoundaryMode = .immediate,
            deferredBoundaryDecisionDuration: TimeInterval = 0
        ) {
            self.preRollDuration = preRollDuration
            self.postRollDuration = postRollDuration
            self.overlapDuration = overlapDuration
            self.maximumChunkDuration = maximumChunkDuration
            self.minimumChunkDuration = minimumChunkDuration
            self.forcedBoundaryLookbackDuration = forcedBoundaryLookbackDuration
            self.minimumForcedBoundaryPauseDuration = minimumForcedBoundaryPauseDuration
            self.forcedBoundaryMode = forcedBoundaryMode
            self.deferredBoundaryDecisionDuration = deferredBoundaryDecisionDuration
        }

        /// Applies the one profile-level scheduling decision without changing
        /// backend-owned duration, overlap, padding, or minimum-chunk limits.
        public func applyingPauseBalancedChunking(_ enabled: Bool) -> Self {
            var result = self
            result.forcedBoundaryMode = enabled ? .deferredPauseBalanced : .immediate
            if enabled {
                result.forcedBoundaryLookbackDuration = max(0, maximumChunkDuration)
                result.deferredBoundaryDecisionDuration = max(0, maximumChunkDuration * 1.5)
            } else {
                result.forcedBoundaryLookbackDuration = max(0, maximumChunkDuration * 0.70)
                result.deferredBoundaryDecisionDuration = 0
            }
            return result
        }

    }

    public private(set) var configuration: Configuration
    public private(set) var isCollectingSpeech = false

    public var pendingDuration: TimeInterval {
        guard isCollectingSpeech, sampleRate > 0 else { return 0 }
        return Double(current.count) / sampleRate
    }

    private var sampleRate: Double = 0
    private var preRoll: [Float] = []
    private var preRollHead = 0
    private var current: [Float] = []
    private var currentCaptureStartTime: TimeInterval?
    private var currentSpeechRange: Range<Int>?
    private var pauseBoundaries: [PauseBoundary] = []

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public mutating func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
        trimPreRoll()
    }

    public mutating func reset() {
        currentCaptureStartTime = nil
        sampleRate = 0
        preRoll.removeAll(keepingCapacity: true)
        preRollHead = 0
        current.removeAll(keepingCapacity: true)
        currentSpeechRange = nil
        pauseBoundaries.removeAll(keepingCapacity: true)
        isCollectingSpeech = false
    }

    public mutating func seedSpeech(samples: [Float], sampleRate: Double) {
        reset()
        guard !samples.isEmpty, sampleRate > 0 else { return }
        self.sampleRate = sampleRate
        current = samples
        currentSpeechRange = 0..<samples.count
        isCollectingSpeech = true
    }

    public mutating func process(
        samples: [Float],
        sampleRate newSampleRate: Double,
        event: VoiceActivityEvent,
        boundaryPauseDuration: TimeInterval? = nil,
        speechEndBoundaryReason: AudioChunkBoundaryReason = .silence,
        captureStartTime: TimeInterval? = nil
    ) -> [AudioChunk] {
        guard !samples.isEmpty, newSampleRate > 0 else { return [] }

        if sampleRate != 0, abs(sampleRate - newSampleRate) > 0.5 {
            reset()
        }
        sampleRate = newSampleRate
        if !isCollectingSpeech, let captureStartTime {
            currentCaptureStartTime = captureStartTime - Double(preRoll.count - preRollHead) / sampleRate
        }

        var emitted: [AudioChunk] = []

        switch event {
        case .silence:
            if isCollectingSpeech {
                current.append(contentsOf: samples)
                recordPauseBoundary(duration: boundaryPauseDuration)
                emitted.append(contentsOf: emitMaximumDurationChunksIfNeeded())
            } else {
                appendToPreRoll(samples)
            }

        case .speechStarted:
            if !isCollectingSpeech {
                movePreRollToCurrent()
                isCollectingSpeech = true
            }
            markSpeech(startingAt: current.count, sampleCount: samples.count)
            current.append(contentsOf: samples)
            recordPauseBoundary(duration: boundaryPauseDuration)
            emitted.append(contentsOf: emitMaximumDurationChunksIfNeeded())

        case .speechContinued:
            if !isCollectingSpeech {
                movePreRollToCurrent()
                isCollectingSpeech = true
            }
            markSpeech(startingAt: current.count, sampleCount: samples.count)
            current.append(contentsOf: samples)
            recordPauseBoundary(duration: boundaryPauseDuration)
            emitted.append(contentsOf: emitMaximumDurationChunksIfNeeded())

        case .possiblePause(let duration):
            if !isCollectingSpeech {
                movePreRollToCurrent()
                isCollectingSpeech = true
            }
            current.append(contentsOf: samples)
            recordPauseBoundary(duration: max(duration, boundaryPauseDuration ?? 0))
            emitted.append(contentsOf: emitMaximumDurationChunksIfNeeded())

        case .speechEnded(let silenceDuration):
            if isCollectingSpeech {
                current.append(contentsOf: samples)
                recordPauseBoundary(duration: max(silenceDuration, boundaryPauseDuration ?? 0))
                emitted.append(contentsOf: emitMaximumDurationChunksIfNeeded())
                trimTrailingSilenceToPostRoll(detectedSilenceDuration: silenceDuration)
                let partitionedChunks = emitDeferredRemainderChunksIfOversized()
                emitted.append(contentsOf: partitionedChunks)
                if let chunk = makeChunk(
                    reason: speechEndBoundaryReason,
                    allowsSubminimumChunk: !partitionedChunks.isEmpty
                ) {
                    emitted.append(chunk)
                }
                isCollectingSpeech = false
                current.removeAll(keepingCapacity: true)
                currentSpeechRange = nil
                pauseBoundaries.removeAll(keepingCapacity: true)
                appendToPreRoll(samples)
            } else {
                appendToPreRoll(samples)
            }
        }

        return emitted
    }

    public mutating func finish(reason: AudioChunkBoundaryReason = .stopped) -> AudioChunk? {
        defer { resetBufferedAudio() }
        guard isCollectingSpeech else { return nil }
        return makeChunk(reason: reason)
    }

    public mutating func finishChunks(
        reason: AudioChunkBoundaryReason = .stopped
    ) -> [AudioChunk] {
        defer { resetBufferedAudio() }
        guard isCollectingSpeech else { return [] }

        var chunks: [AudioChunk] = []
        chunks.append(contentsOf: emitDeferredRemainderChunksIfOversized())
        if let chunk = makeChunk(
            reason: reason,
            allowsSubminimumChunk: !chunks.isEmpty
        ) {
            chunks.append(chunk)
        }
        return chunks
    }

    private mutating func resetBufferedAudio() {
        currentCaptureStartTime = nil
        current.removeAll(keepingCapacity: true)
        preRoll.removeAll(keepingCapacity: true)
        preRollHead = 0
        isCollectingSpeech = false
        currentSpeechRange = nil
        pauseBoundaries.removeAll(keepingCapacity: true)
    }

    private mutating func emitDeferredRemainderChunksIfOversized() -> [AudioChunk] {
        guard configuration.forcedBoundaryMode == .deferredPauseBalanced else { return [] }
        let maximumSamples = sampleCount(for: configuration.maximumChunkDuration)
        guard maximumSamples > 0 else { return [] }

        var chunks: [AudioChunk] = []
        while current.count > maximumSamples {
            chunks.append(emitChunk(at: forcedBoundary(maximumSamples: maximumSamples)))
        }
        return chunks
    }

    private mutating func emitMaximumDurationChunksIfNeeded() -> [AudioChunk] {
        let maximumSamples = sampleCount(for: configuration.maximumChunkDuration)
        let overlapSamples = min(
            sampleCount(for: configuration.overlapDuration),
            max(0, maximumSamples - 1)
        )
        guard maximumSamples > 0 else { return [] }
        let emissionThreshold: Int
        switch configuration.forcedBoundaryMode {
        case .immediate:
            emissionThreshold = maximumSamples
        case .deferredPauseBalanced:
            emissionThreshold = max(
                maximumSamples + 1,
                sampleCount(for: configuration.deferredBoundaryDecisionDuration)
            )
        }

        var chunks: [AudioChunk] = []
        while current.count >= emissionThreshold {
            chunks.append(
                emitChunk(
                    at: forcedBoundary(maximumSamples: maximumSamples),
                    configuredOverlapSamples: overlapSamples
                )
            )
        }
        return chunks
    }

    private mutating func emitChunk(
        at forcedBoundary: ForcedBoundary,
        configuredOverlapSamples: Int? = nil
    ) -> AudioChunk {
        let boundary = forcedBoundary.sampleIndex
        let emittedSamples = Array(current.prefix(boundary))
        let maximumSamples = sampleCount(for: configuration.maximumChunkDuration)
        let overlapLimit =
            configuredOverlapSamples
            ?? min(
                sampleCount(for: configuration.overlapDuration),
                max(0, maximumSamples - 1)
            )
        let retainedOverlapSamples = min(
            overlapLimit,
            forcedBoundary.maximumRetainedOverlapSamples,
            emittedSamples.count
        )
        let actualOverlapDuration =
            sampleRate > 0 ? Double(retainedOverlapSamples) / sampleRate : 0
        let chunk = AudioChunk(
            samples: emittedSamples,
            sampleRate: sampleRate,
            boundaryReason: forcedBoundary.reason,
            trailingOverlapDuration: actualOverlapDuration,
            speechRange: intersection(currentSpeechRange, with: 0..<boundary),
            speechEvidenceAnalyzed: true,
            captureTimeRange: currentCaptureStartTime.map { $0..<($0 + Double(boundary) / sampleRate) }
        )
        let overlap = Array(emittedSamples.suffix(retainedOverlapSamples))
        current = overlap + current.dropFirst(boundary)
        if let start = currentCaptureStartTime {
            currentCaptureStartTime = start + Double(boundary - overlap.count) / sampleRate
        }
        shiftSpeechRange(
            removing: boundary - overlap.count,
            newSampleCount: current.count
        )
        shiftPauseBoundaries(removing: boundary - overlap.count)
        return chunk
    }

    private mutating func recordPauseBoundary(duration: TimeInterval?) {
        guard configuration.forcedBoundaryLookbackDuration > 0 else { return }
        guard let duration else { return }
        let minimumPauseSamples = sampleCount(
            for: configuration.minimumForcedBoundaryPauseDuration
        )
        let pauseSamples = sampleCount(for: duration)
        guard minimumPauseSamples > 0, pauseSamples >= minimumPauseSamples else { return }

        let pauseStart = max(0, current.count - pauseSamples)
        let boundary = min(current.count, pauseStart + pauseSamples / 2)
        if pauseBoundaries.last?.pauseStart == pauseStart {
            pauseBoundaries[pauseBoundaries.count - 1] = PauseBoundary(
                pauseStart: pauseStart,
                sampleIndex: boundary,
                pauseDurationSamples: pauseSamples
            )
        } else if pauseBoundaries.last?.sampleIndex != boundary {
            pauseBoundaries.append(
                PauseBoundary(
                    pauseStart: pauseStart,
                    sampleIndex: boundary,
                    pauseDurationSamples: pauseSamples
                )
            )
        }
    }

    private func forcedBoundary(maximumSamples: Int) -> ForcedBoundary {
        let lookbackSamples = sampleCount(for: configuration.forcedBoundaryLookbackDuration)
        let minimumSamples = sampleCount(for: configuration.minimumChunkDuration)
        let configuredOverlapSamples = min(
            sampleCount(for: configuration.overlapDuration),
            max(0, maximumSamples - 1)
        )
        if configuration.forcedBoundaryMode == .deferredPauseBalanced {
            if let selected = balancedPauseBoundary(maximumSamples: maximumSamples) {
                return selected
            }
            return ForcedBoundary(
                sampleIndex: maximumSamples,
                maximumRetainedOverlapSamples: configuredOverlapSamples,
                reason: .maximumDuration
            )
        }
        guard lookbackSamples > 0, let latest = pauseBoundaries.last else {
            return ForcedBoundary(
                sampleIndex: maximumSamples,
                maximumRetainedOverlapSamples: configuredOverlapSamples,
                reason: .maximumDuration
            )
        }

        let earliestBoundary = max(
            minimumSamples,
            configuredOverlapSamples + 1,
            maximumSamples - lookbackSamples
        )
        guard latest.sampleIndex >= earliestBoundary,
            latest.sampleIndex <= maximumSamples
        else {
            return ForcedBoundary(
                sampleIndex: maximumSamples,
                maximumRetainedOverlapSamples: configuredOverlapSamples,
                reason: .maximumDuration
            )
        }
        return ForcedBoundary(
            sampleIndex: latest.sampleIndex,
            maximumRetainedOverlapSamples: 0,
            reason: .balancedPause
        )
    }

    private func balancedPauseBoundary(maximumSamples: Int) -> ForcedBoundary? {
        let minimumSamples = sampleCount(for: configuration.minimumChunkDuration)
        let minimumBoundary = minimumSamples
        let maximumBoundary = min(maximumSamples, current.count - minimumSamples)
        guard minimumBoundary <= maximumBoundary else { return nil }

        // Prefer a pause that balances the chunk being emitted with the
        // already-buffered continuation. Pause duration breaks close ties.
        let target = min(maximumBoundary, max(minimumBoundary, current.count / 2))
        guard
            let selected =
                pauseBoundaries
                .filter({ $0.sampleIndex >= minimumBoundary && $0.sampleIndex <= maximumBoundary })
                .min(by: { lhs, rhs in
                    let lhsDistance = abs(lhs.sampleIndex - target)
                    let rhsDistance = abs(rhs.sampleIndex - target)
                    if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                    if lhs.pauseDurationSamples != rhs.pauseDurationSamples {
                        return lhs.pauseDurationSamples > rhs.pauseDurationSamples
                    }
                    return lhs.sampleIndex > rhs.sampleIndex
                })
        else { return nil }

        return ForcedBoundary(
            sampleIndex: selected.sampleIndex,
            maximumRetainedOverlapSamples: 0,
            reason: .balancedPause
        )
    }

    private mutating func shiftPauseBoundaries(removing removedSamples: Int) {
        guard removedSamples > 0 else { return }
        pauseBoundaries = pauseBoundaries.compactMap { pause in
            let start = pause.pauseStart - removedSamples
            let boundary = pause.sampleIndex - removedSamples
            guard boundary > 0 else { return nil }
            return PauseBoundary(
                pauseStart: max(0, start),
                sampleIndex: boundary,
                pauseDurationSamples: pause.pauseDurationSamples
            )
        }
    }

    private struct PauseBoundary {
        let pauseStart: Int
        let sampleIndex: Int
        let pauseDurationSamples: Int
    }

    private struct ForcedBoundary {
        let sampleIndex: Int
        let maximumRetainedOverlapSamples: Int
        let reason: AudioChunkBoundaryReason
    }

    private mutating func trimTrailingSilenceToPostRoll(detectedSilenceDuration: TimeInterval) {
        let maximumTrailingSamples = sampleCount(for: configuration.postRollDuration)
        guard maximumTrailingSamples >= 0, !current.isEmpty else { return }

        // The VAD reports the complete trailing pause. Keep only the configured post-roll.
        let detectedSilenceSamples = sampleCount(for: detectedSilenceDuration)
        let removable = max(0, detectedSilenceSamples - maximumTrailingSamples)
        if removable > 0, current.count > removable {
            current.removeLast(removable)
            currentSpeechRange = intersection(
                currentSpeechRange,
                with: 0..<current.count
            )
        }
    }

    private func makeChunk(
        reason: AudioChunkBoundaryReason,
        allowsSubminimumChunk: Bool = false
    ) -> AudioChunk? {
        let minimumSamples =
            allowsSubminimumChunk
            ? 1 : sampleCount(for: configuration.minimumChunkDuration)
        guard current.count >= minimumSamples else { return nil }
        return AudioChunk(
            samples: current,
            sampleRate: sampleRate,
            boundaryReason: reason,
            speechRange: intersection(currentSpeechRange, with: 0..<current.count),
            speechEvidenceAnalyzed: true,
            captureTimeRange: currentCaptureStartTime.map { $0..<($0 + Double(current.count) / sampleRate) }
        )
    }

    private mutating func appendToPreRoll(_ samples: [Float]) {
        preRoll.append(contentsOf: samples)
        trimPreRoll()
    }

    private mutating func movePreRollToCurrent() {
        if preRollHead < preRoll.count {
            current = Array(preRoll[preRollHead...])
        } else {
            current.removeAll(keepingCapacity: true)
        }
        preRoll.removeAll(keepingCapacity: true)
        preRollHead = 0
    }

    private mutating func trimPreRoll() {
        let capacity = sampleCount(for: configuration.preRollDuration)
        guard capacity > 0 else {
            preRoll.removeAll(keepingCapacity: true)
            preRollHead = 0
            return
        }

        let activeCount = preRoll.count - preRollHead
        if activeCount > capacity {
            preRollHead += activeCount - capacity
        }
        compactPreRollIfNeeded()
    }

    private mutating func compactPreRollIfNeeded() {
        guard preRollHead >= 4_096, preRollHead * 2 >= preRoll.count else { return }
        preRoll.removeFirst(preRollHead)
        preRollHead = 0
    }

    private func sampleCount(for duration: TimeInterval) -> Int {
        guard sampleRate > 0 else { return 0 }
        return max(0, Int((duration * sampleRate).rounded()))
    }

    private mutating func markSpeech(startingAt start: Int, sampleCount: Int) {
        guard sampleCount > 0 else { return }
        let next = start..<(start + sampleCount)
        if let currentSpeechRange {
            let lower = min(currentSpeechRange.lowerBound, next.lowerBound)
            let upper = max(currentSpeechRange.upperBound, next.upperBound)
            self.currentSpeechRange = lower..<upper
        } else {
            currentSpeechRange = next
        }
    }

    private mutating func shiftSpeechRange(removing removedSamples: Int, newSampleCount: Int) {
        guard let currentSpeechRange else { return }
        let lower = max(0, currentSpeechRange.lowerBound - removedSamples)
        let upper = min(newSampleCount, currentSpeechRange.upperBound - removedSamples)
        self.currentSpeechRange = lower < upper ? lower..<upper : nil
    }

    private func intersection(_ range: Range<Int>?, with bounds: Range<Int>) -> Range<Int>? {
        guard let range else { return nil }
        let lower = max(range.lowerBound, bounds.lowerBound)
        let upper = min(range.upperBound, bounds.upperBound)
        return lower < upper ? lower..<upper : nil
    }
}
