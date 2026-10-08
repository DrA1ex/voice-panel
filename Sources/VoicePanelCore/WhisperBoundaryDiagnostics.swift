import Foundation

public enum WhisperBoundaryRepairReasonCode: String, Codable, Equatable, Sendable {
    case baselineOnly
    case previousBoundaryUnavailable
    case notSuspicious
    case unsupportedStrategy
    case accepted
    case baselineEmpty
    case baselineRejectedHallucination
    case baselineFailed
    case baselineCancelled
    case candidateEmpty
    case candidateRejectedHallucination
    case candidateFailed
    case candidateCancelled
    case missingStableAnchor
    case punctuationLoss
    case lowerTokenProbability
    case repeatedTrigram
    case insufficientImprovement
}

public struct WhisperBoundaryChangedWordCounts: Codable, Equatable, Sendable {
    private static let maximumChangedWords = 24

    public let baseline: Int
    public let replacement: Int

    public init(baseline: Int, replacement: Int) {
        self.baseline = min(max(0, baseline), Self.maximumChangedWords)
        self.replacement = min(max(0, replacement), Self.maximumChangedWords)
    }

    private enum CodingKeys: String, CodingKey {
        case baseline
        case replacement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            baseline: try container.decodeIfPresent(Int.self, forKey: .baseline) ?? 0,
            replacement: try container.decodeIfPresent(Int.self, forKey: .replacement) ?? 0
        )
    }
}

public struct WhisperBoundaryRepairDiagnostics: Codable, Equatable, Sendable {
    private static let maximumInferenceDuration: TimeInterval = 3_600

    public let strategy: WhisperBoundaryStrategy
    public let attempted: Bool
    public let accepted: Bool
    public let reasonCode: WhisperBoundaryRepairReasonCode
    public let inferenceCount: Int
    public let inferenceDuration: TimeInterval
    public let changedBoundaryWordCounts: WhisperBoundaryChangedWordCounts

    public init(
        strategy: WhisperBoundaryStrategy,
        attempted: Bool,
        accepted: Bool,
        reasonCode: WhisperBoundaryRepairReasonCode,
        inferenceCount: Int,
        inferenceDuration: TimeInterval,
        changedBoundaryWordCounts: WhisperBoundaryChangedWordCounts
    ) {
        self.strategy = strategy
        self.attempted = attempted
        self.accepted = accepted
        self.reasonCode = reasonCode
        self.inferenceCount = min(max(0, inferenceCount), 2)
        self.inferenceDuration =
            inferenceDuration.isFinite
            ? min(max(0, inferenceDuration), Self.maximumInferenceDuration) : 0
        self.changedBoundaryWordCounts = changedBoundaryWordCounts
    }

    private enum CodingKeys: String, CodingKey {
        case strategy
        case attempted
        case accepted
        case reasonCode
        case inferenceCount
        case inferenceDuration
        case changedBoundaryWordCounts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            strategy: try container.decodeIfPresent(
                WhisperBoundaryStrategy.self,
                forKey: .strategy
            ) ?? .standard,
            attempted: try container.decodeIfPresent(Bool.self, forKey: .attempted) ?? false,
            accepted: try container.decodeIfPresent(Bool.self, forKey: .accepted) ?? false,
            reasonCode: try container.decodeIfPresent(
                WhisperBoundaryRepairReasonCode.self,
                forKey: .reasonCode
            ) ?? .baselineOnly,
            inferenceCount: try container.decodeIfPresent(Int.self, forKey: .inferenceCount) ?? 0,
            inferenceDuration: try container.decodeIfPresent(
                TimeInterval.self,
                forKey: .inferenceDuration
            ) ?? 0,
            changedBoundaryWordCounts: try container.decodeIfPresent(
                WhisperBoundaryChangedWordCounts.self,
                forKey: .changedBoundaryWordCounts
            ) ?? .init(baseline: 0, replacement: 0)
        )
    }
}
