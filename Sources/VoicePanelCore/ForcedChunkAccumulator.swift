import Foundation

/// VAD-independent hard chunking for uninterrupted speech.
/// Keeps overlap so words crossing a forced boundary can be deduplicated.
public struct ForcedChunkAccumulator: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var maximumChunkDuration: TimeInterval
        public var overlapDuration: TimeInterval
        public var minimumChunkDuration: TimeInterval
        public var minimumSpeechEvidenceDuration: TimeInterval

        public init(
            maximumChunkDuration: TimeInterval,
            overlapDuration: TimeInterval,
            minimumChunkDuration: TimeInterval = 0.20,
            minimumSpeechEvidenceDuration: TimeInterval = 0.35
        ) {
            self.maximumChunkDuration = max(0.5, maximumChunkDuration)
            self.overlapDuration = max(0, min(overlapDuration, maximumChunkDuration * 0.5))
            self.minimumChunkDuration = max(0, minimumChunkDuration)
            self.minimumSpeechEvidenceDuration = max(0, minimumSpeechEvidenceDuration)
        }
    }

    public private(set) var configuration: Configuration
    public private(set) var sampleRate: Double = 0
    public private(set) var speechEvidenceDuration: TimeInterval = 0
    private var samples: [Float] = []
    private var speechRange: Range<Int>?
    private var captureStartTime: TimeInterval?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public var hasSpeechEvidence: Bool {
        speechEvidenceDuration >= configuration.minimumSpeechEvidenceDuration
    }

    public var pendingDuration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }

    public mutating func reset() {
        captureStartTime = nil
        sampleRate = 0
        samples.removeAll(keepingCapacity: true)
        speechEvidenceDuration = 0
        speechRange = nil
    }

    public mutating func process(
        samples nextSamples: [Float],
        sampleRate nextSampleRate: Double,
        hasSpeechEvidence nextHasSpeechEvidence: Bool,
        captureStartTime nextCaptureStartTime: TimeInterval? = nil
    ) -> [AudioChunk] {
        guard !nextSamples.isEmpty, nextSampleRate > 0 else { return [] }
        if sampleRate != 0, abs(sampleRate - nextSampleRate) > 0.5 { reset() }
        sampleRate = nextSampleRate
        if samples.isEmpty { captureStartTime = nextCaptureStartTime }
        if nextHasSpeechEvidence {
            markSpeech(startingAt: samples.count, sampleCount: nextSamples.count)
            speechEvidenceDuration += Double(nextSamples.count) / nextSampleRate
        }
        samples.append(contentsOf: nextSamples)

        let maximumSamples = sampleCount(for: configuration.maximumChunkDuration)
        let overlapSamples = min(sampleCount(for: configuration.overlapDuration), max(0, maximumSamples - 1))
        guard maximumSamples > 0 else { return [] }

        var emitted: [AudioChunk] = []
        while samples.count >= maximumSamples {
            let window = Array(samples.prefix(maximumSamples))
            if speechEvidenceDuration >= configuration.minimumSpeechEvidenceDuration,
                let emittedSpeechRange = intersection(speechRange, with: 0..<maximumSamples)
            {
                emitted.append(
                    AudioChunk(
                        samples: window,
                        sampleRate: sampleRate,
                        boundaryReason: .maximumDuration,
                        trailingOverlapDuration: sampleRate > 0
                            ? Double(overlapSamples) / sampleRate : 0,
                        speechRange: emittedSpeechRange,
                        speechEvidenceAnalyzed: true,
                        captureTimeRange: captureStartTime.map { $0..<($0 + Double(maximumSamples) / sampleRate) }
                    ))
            }
            let overlap = Array(window.suffix(overlapSamples))
            let remainder = Array(samples.dropFirst(maximumSamples))
            samples = overlap + remainder
            if let start = captureStartTime {
                captureStartTime = start + Double(maximumSamples - overlapSamples) / sampleRate
            }
            shiftSpeechRange(
                removing: maximumSamples - overlapSamples,
                newSampleCount: samples.count
            )
            if speechRange == nil {
                speechEvidenceDuration = 0
            } else {
                speechEvidenceDuration = min(speechEvidenceDuration, pendingDuration)
            }
        }
        return emitted
    }

    public mutating func finish(
        reason: AudioChunkBoundaryReason = .stopped,
        requireSpeechEvidence: Bool = true
    ) -> AudioChunk? {
        defer { reset() }
        guard sampleRate > 0,
            pendingDuration >= configuration.minimumChunkDuration,
            !requireSpeechEvidence
                || speechEvidenceDuration >= configuration.minimumSpeechEvidenceDuration
        else {
            return nil
        }
        let confirmedSpeechRange =
            hasSpeechEvidence
            ? intersection(speechRange, with: 0..<samples.count)
            : nil
        return AudioChunk(
            samples: samples,
            sampleRate: sampleRate,
            boundaryReason: reason,
            speechRange: confirmedSpeechRange,
            speechEvidenceAnalyzed: true,
            captureTimeRange: captureStartTime.map { $0..<($0 + pendingDuration) }
        )
    }

    private func sampleCount(for duration: TimeInterval) -> Int {
        guard sampleRate > 0 else { return 0 }
        return max(0, Int((duration * sampleRate).rounded()))
    }

    private mutating func markSpeech(startingAt start: Int, sampleCount: Int) {
        guard sampleCount > 0 else { return }
        let next = start..<(start + sampleCount)
        if let speechRange {
            let lower = min(speechRange.lowerBound, next.lowerBound)
            let upper = max(speechRange.upperBound, next.upperBound)
            self.speechRange = lower..<upper
        } else {
            speechRange = next
        }
    }

    private mutating func shiftSpeechRange(removing removedSamples: Int, newSampleCount: Int) {
        guard let speechRange else { return }
        let lower = max(0, speechRange.lowerBound - removedSamples)
        let upper = min(newSampleCount, speechRange.upperBound - removedSamples)
        self.speechRange = lower < upper ? lower..<upper : nil
    }

    private func intersection(_ range: Range<Int>?, with bounds: Range<Int>) -> Range<Int>? {
        guard let range else { return nil }
        let lower = max(range.lowerBound, bounds.lowerBound)
        let upper = min(range.upperBound, bounds.upperBound)
        return lower < upper ? lower..<upper : nil
    }
}
