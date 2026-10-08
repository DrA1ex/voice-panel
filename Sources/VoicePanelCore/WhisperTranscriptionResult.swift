import Foundation

public struct WhisperTokenEvidence: Codable, Equatable, Sendable {
    public let text: String
    public let startTime: TimeInterval?
    public let endTime: TimeInterval?
    public let probability: Double

    public init(
        text: String,
        startTime: TimeInterval?,
        endTime: TimeInterval?,
        probability: Double
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.probability = probability
    }
}

public struct WhisperSegmentEvidence: Codable, Equatable, Sendable {
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let noSpeechProbability: Double
    public let tokens: [WhisperTokenEvidence]

    public init(
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        noSpeechProbability: Double,
        tokens: [WhisperTokenEvidence]
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.noSpeechProbability = noSpeechProbability
        self.tokens = tokens
    }
}

public struct WhisperTranscriptionResult: Codable, Equatable, Sendable {
    public let text: String
    public let segments: [WhisperSegmentEvidence]
    public let detectedLanguage: String
    public let inferenceDuration: TimeInterval

    public init(
        text: String,
        segments: [WhisperSegmentEvidence],
        detectedLanguage: String,
        inferenceDuration: TimeInterval
    ) {
        self.text = text
        self.segments = segments
        self.detectedLanguage = detectedLanguage
        self.inferenceDuration = inferenceDuration
    }

    public var tokens: [WhisperTokenEvidence] {
        segments.flatMap(\.tokens)
    }

    public var meanTokenProbability: Double {
        let flattenedTokens = tokens
        guard !flattenedTokens.isEmpty else { return 0 }
        return flattenedTokens.reduce(0) { $0 + $1.probability } / Double(flattenedTokens.count)
    }

    public var maximumNoSpeechProbability: Double {
        segments.map(\.noSpeechProbability).max() ?? 0
    }
}

public enum WhisperInferenceMetadataLevel: String, Codable, Sendable {
    case segments
    /// Decode segment boundaries without computing per-token alignment.
    case segmentTimestamps
    case tokenTimestamps
}
