import Foundation

public struct WhisperBoundaryBridgeAudio: Equatable, Sendable {
    public let samples: [Float]
    public let cutTime: TimeInterval

    public init(samples: [Float], cutTime: TimeInterval) {
        self.samples = samples
        self.cutTime = cutTime
    }
}

public struct WhisperBoundaryBridgePatch: Equatable, Sendable {
    public let previousText: String
    public let currentText: String
    public let removedBoundaryWordCount: Int
    public let replacementBoundaryWordCount: Int

    public init(
        previousText: String,
        currentText: String,
        removedBoundaryWordCount: Int = 0,
        replacementBoundaryWordCount: Int = 0
    ) {
        let boundedCounts = WhisperBoundaryChangedWordCounts(
            baseline: removedBoundaryWordCount,
            replacement: replacementBoundaryWordCount
        )
        self.previousText = previousText
        self.currentText = currentText
        self.removedBoundaryWordCount = boundedCounts.baseline
        self.replacementBoundaryWordCount = boundedCounts.replacement
    }
}

public enum WhisperBoundaryBridgeBuilder {
    public static func make(
        previousSamples: [Float],
        currentSamples: [Float],
        sampleRate: Double,
        overlapDuration: TimeInterval,
        sideDuration: TimeInterval
    ) -> WhisperBoundaryBridgeAudio? {
        make(
            previousSamples: previousSamples,
            previousSampleRate: sampleRate,
            currentSamples: currentSamples,
            currentSampleRate: sampleRate,
            overlapDuration: overlapDuration,
            sideDuration: sideDuration
        )
    }

    public static func make(
        previousSamples: [Float],
        previousSampleRate: Double,
        currentSamples: [Float],
        currentSampleRate: Double,
        overlapDuration: TimeInterval,
        sideDuration: TimeInterval
    ) -> WhisperBoundaryBridgeAudio? {
        guard previousSampleRate.isFinite,
            previousSampleRate > 0,
            currentSampleRate == previousSampleRate,
            overlapDuration.isFinite,
            overlapDuration >= 0,
            sideDuration.isFinite,
            sideDuration > 0,
            let overlapSampleCount = boundedSampleCount(
                duration: overlapDuration,
                sampleRate: previousSampleRate,
                maximum: currentSamples.count
            ),
            let sideSampleCount = boundedSampleCount(
                duration: sideDuration,
                sampleRate: previousSampleRate,
                maximum: max(1, max(previousSamples.count, currentSamples.count))
            ),
            sideSampleCount > 0
        else {
            return nil
        }

        let retainedPreviousCount = min(sideSampleCount, previousSamples.count)
        let currentStart = min(overlapSampleCount, currentSamples.count)
        let retainedCurrentCount = min(
            sideSampleCount,
            currentSamples.count - currentStart
        )
        let previousSuffix = previousSamples.suffix(retainedPreviousCount)
        let currentEnd = currentStart + retainedCurrentCount
        let currentPrefix = currentSamples[currentStart..<currentEnd]

        return WhisperBoundaryBridgeAudio(
            samples: Array(previousSuffix) + currentPrefix,
            cutTime: Double(retainedPreviousCount) / previousSampleRate
        )
    }

    private static func boundedSampleCount(
        duration: TimeInterval,
        sampleRate: Double,
        maximum: Int
    ) -> Int? {
        let value = (duration * sampleRate).rounded()
        guard value.isFinite, value >= 0 else {
            return nil
        }
        guard value < Double(maximum) else { return maximum }
        return Int(value)
    }
}
