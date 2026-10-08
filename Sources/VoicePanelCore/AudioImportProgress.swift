import Foundation

public struct AudioImportProgress: Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable {
        case preparing
        case converting
        case analyzing
        case transcribing
        case finalizing
        case cancelling
    }

    public let stage: Stage
    public let currentChunk: Int
    public let completedChunks: Int
    public let totalChunks: Int
    public let completedAudioDuration: TimeInterval
    public let totalAudioDuration: TimeInterval
    public let elapsedProcessingDuration: TimeInterval
    public let estimatedRemainingDuration: TimeInterval?
    public let fallbackDescription: String?

    public init(
        stage: Stage,
        currentChunk: Int = 0,
        completedChunks: Int = 0,
        totalChunks: Int = 0,
        completedAudioDuration: TimeInterval = 0,
        totalAudioDuration: TimeInterval = 0,
        elapsedProcessingDuration: TimeInterval = 0,
        estimatedRemainingDuration: TimeInterval? = nil,
        fallbackDescription: String? = nil
    ) {
        self.stage = stage
        self.currentChunk = max(0, currentChunk)
        self.completedChunks = max(0, completedChunks)
        self.totalChunks = max(0, totalChunks)
        self.completedAudioDuration = max(0, completedAudioDuration)
        self.totalAudioDuration = max(0, totalAudioDuration)
        self.elapsedProcessingDuration = max(0, elapsedProcessingDuration)
        self.estimatedRemainingDuration = estimatedRemainingDuration.map { max(0, $0) }
        self.fallbackDescription = fallbackDescription
    }

    public var fractionCompleted: Double? {
        guard totalChunks > 0 else { return nil }
        if totalAudioDuration > 0 {
            return min(max(completedAudioDuration / totalAudioDuration, 0), 1)
        }
        return min(max(Double(completedChunks) / Double(totalChunks), 0), 1)
    }

    public static func estimateRemainingDuration(
        elapsedProcessingDuration: TimeInterval,
        completedAudioDuration: TimeInterval,
        totalAudioDuration: TimeInterval
    ) -> TimeInterval? {
        guard elapsedProcessingDuration > 0,
            completedAudioDuration > 0,
            totalAudioDuration > completedAudioDuration
        else { return nil }

        let processingSecondsPerAudioSecond = elapsedProcessingDuration / completedAudioDuration
        let remainingAudioDuration = totalAudioDuration - completedAudioDuration
        let estimate = processingSecondsPerAudioSecond * remainingAudioDuration
        guard estimate.isFinite else { return nil }
        return max(0, estimate)
    }
}
