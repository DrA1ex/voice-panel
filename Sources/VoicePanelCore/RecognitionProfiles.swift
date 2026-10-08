import Foundation

public enum RecognitionProfileID: String, CaseIterable, Identifiable, Codable, Sendable {
    case classic
    case recommended
    case quality
    case lowLatency
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .classic: return "Vanilla"
        case .recommended: return "Balanced"
        case .quality: return "Quality"
        case .lowLatency: return "Low Latency"
        case .custom: return "Unsaved"
        }
    }

    public var detail: String {
        switch self {
        case .classic:
            return
                "Preserves the original VoicePanel speech boundaries and Whisper decoding behavior without profile tuning."
        case .recommended:
            return
                "Balances Hybrid voice detection, safer phrase boundaries, optional context, and conservative result protection."
        case .quality:
            return
                "Uses bounded lookahead to split chunked recognition audio at real pauses, cleans chunk boundaries, and enables safe edit-based Russian correction for GigaAM."
        case .lowLatency:
            return "Ends phrases sooner and keeps smaller audio margins for commands and short dictation."
        case .custom:
            return "Uses locally modified values that have not been saved as a named preset."
        }
    }

    public var isBuiltIn: Bool { self != .custom }

    /// Profile-owned latency cap for the final GigaAM recognizer. The backend's
    /// configured maximum remains an independent safety limit.
    public var defaultGigaAMChunkDuration: TimeInterval? {
        switch self {
        case .classic: return 20
        case .recommended: return 15
        case .quality: return 20
        case .lowLatency: return 3.5
        case .custom: return nil
        }
    }
}

public enum MicrophoneEnvironmentProfileID: String, CaseIterable, Identifiable, Sendable {
    case quiet
    case balanced
    case noisy
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .quiet: return "Quiet"
        case .balanced: return "Balanced"
        case .noisy: return "Noisy"
        case .custom: return "Custom"
        }
    }

    public var detail: String {
        switch self {
        case .quiet:
            return "More sensitive to a quiet voice in a room without continuous background noise."
        case .balanced:
            return "A reliable default for most built-in and external microphones."
        case .noisy:
            return "Rejects more fan, keyboard, and room noise before opening a speech segment."
        case .custom:
            return "Uses the manual energy detection values configured below."
        }
    }
}

public struct RecognitionTuningValues: Equatable, Codable, Sendable {
    public var voiceActivityDetectionMode: VoiceActivityDetectionMode
    public var sileroThreshold: Double
    public var sileroMinimumSpeechDuration: TimeInterval
    public var endOfSpeechSilenceDuration: TimeInterval
    public var preRollDuration: TimeInterval
    public var postRollDuration: TimeInterval
    public var whisperChunkDuration: TimeInterval
    public var whisperOverlapDuration: TimeInterval
    public var pauseBalancedChunkingEnabled: Bool
    public var usesRecognitionContext: Bool
    public var usesRecognitionVocabulary: Bool
    public var hallucinationProtectionEnabled: Bool
    public var whisperCustomDecodingEnabled: Bool
    public var whisperBoundaryStrategy: WhisperBoundaryStrategy
    public var finalTranscriptCleanupEnabled: Bool
    public var gigaAMRussianCorrectionEnabled: Bool

    public init(
        voiceActivityDetectionMode: VoiceActivityDetectionMode,
        sileroThreshold: Double,
        sileroMinimumSpeechDuration: TimeInterval,
        endOfSpeechSilenceDuration: TimeInterval,
        preRollDuration: TimeInterval,
        postRollDuration: TimeInterval,
        whisperChunkDuration: TimeInterval,
        whisperOverlapDuration: TimeInterval,
        pauseBalancedChunkingEnabled: Bool = false,
        usesRecognitionContext: Bool,
        usesRecognitionVocabulary: Bool,
        hallucinationProtectionEnabled: Bool,
        whisperCustomDecodingEnabled: Bool,
        whisperBoundaryStrategy: WhisperBoundaryStrategy,
        finalTranscriptCleanupEnabled: Bool = false,
        gigaAMRussianCorrectionEnabled: Bool = false
    ) {
        self.voiceActivityDetectionMode = voiceActivityDetectionMode
        self.sileroThreshold = sileroThreshold
        self.sileroMinimumSpeechDuration = sileroMinimumSpeechDuration
        self.endOfSpeechSilenceDuration = endOfSpeechSilenceDuration
        self.preRollDuration = preRollDuration
        self.postRollDuration = postRollDuration
        self.whisperChunkDuration = whisperChunkDuration
        self.whisperOverlapDuration = whisperOverlapDuration
        self.pauseBalancedChunkingEnabled = pauseBalancedChunkingEnabled
        self.usesRecognitionContext = usesRecognitionContext
        self.usesRecognitionVocabulary = usesRecognitionVocabulary
        self.hallucinationProtectionEnabled = hallucinationProtectionEnabled
        self.whisperCustomDecodingEnabled = whisperCustomDecodingEnabled
        self.whisperBoundaryStrategy = whisperBoundaryStrategy
        self.finalTranscriptCleanupEnabled = finalTranscriptCleanupEnabled
        self.gigaAMRussianCorrectionEnabled = gigaAMRussianCorrectionEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case voiceActivityDetectionMode
        case sileroThreshold
        case sileroMinimumSpeechDuration
        case endOfSpeechSilenceDuration
        case preRollDuration
        case postRollDuration
        case whisperChunkDuration
        case whisperOverlapDuration
        case pauseBalancedChunkingEnabled
        case whisperChunkSchedulingMode
        case usesRecognitionContext
        case usesRecognitionVocabulary
        case hallucinationProtectionEnabled
        case whisperCustomDecodingEnabled
        case whisperBoundaryStrategy
        case whisperCarryContext
        case finalTranscriptCleanupEnabled
        case gigaAMRussianCorrectionEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        voiceActivityDetectionMode = try container.decode(
            VoiceActivityDetectionMode.self, forKey: .voiceActivityDetectionMode)
        sileroThreshold = try container.decode(Double.self, forKey: .sileroThreshold)
        sileroMinimumSpeechDuration = try container.decode(TimeInterval.self, forKey: .sileroMinimumSpeechDuration)
        endOfSpeechSilenceDuration = try container.decode(TimeInterval.self, forKey: .endOfSpeechSilenceDuration)
        preRollDuration = try container.decode(TimeInterval.self, forKey: .preRollDuration)
        postRollDuration = try container.decode(TimeInterval.self, forKey: .postRollDuration)
        whisperChunkDuration = try container.decode(TimeInterval.self, forKey: .whisperChunkDuration)
        whisperOverlapDuration = try container.decode(TimeInterval.self, forKey: .whisperOverlapDuration)
        if let enabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .pauseBalancedChunkingEnabled
        ) {
            pauseBalancedChunkingEnabled = enabled
        } else {
            pauseBalancedChunkingEnabled =
                try container.decodeIfPresent(String.self, forKey: .whisperChunkSchedulingMode)
                == "deferredPauseBalanced"
        }
        usesRecognitionContext = try container.decode(Bool.self, forKey: .usesRecognitionContext)
        usesRecognitionVocabulary = try container.decode(Bool.self, forKey: .usesRecognitionVocabulary)
        hallucinationProtectionEnabled = try container.decode(Bool.self, forKey: .hallucinationProtectionEnabled)
        whisperCustomDecodingEnabled = try container.decode(Bool.self, forKey: .whisperCustomDecodingEnabled)
        whisperBoundaryStrategy = WhisperBoundarySettingsMigration.resolveBoundaryStrategy(
            newRawValue: try container.decodeIfPresent(String.self, forKey: .whisperBoundaryStrategy),
            legacyCarryContext: try container.decodeIfPresent(Bool.self, forKey: .whisperCarryContext),
            profileDefault: .standard
        )
        finalTranscriptCleanupEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .finalTranscriptCleanupEnabled) ?? false
        gigaAMRussianCorrectionEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .gigaAMRussianCorrectionEnabled) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(voiceActivityDetectionMode, forKey: .voiceActivityDetectionMode)
        try container.encode(sileroThreshold, forKey: .sileroThreshold)
        try container.encode(sileroMinimumSpeechDuration, forKey: .sileroMinimumSpeechDuration)
        try container.encode(endOfSpeechSilenceDuration, forKey: .endOfSpeechSilenceDuration)
        try container.encode(preRollDuration, forKey: .preRollDuration)
        try container.encode(postRollDuration, forKey: .postRollDuration)
        try container.encode(whisperChunkDuration, forKey: .whisperChunkDuration)
        try container.encode(whisperOverlapDuration, forKey: .whisperOverlapDuration)
        try container.encode(
            pauseBalancedChunkingEnabled,
            forKey: .pauseBalancedChunkingEnabled
        )
        try container.encode(usesRecognitionContext, forKey: .usesRecognitionContext)
        try container.encode(usesRecognitionVocabulary, forKey: .usesRecognitionVocabulary)
        try container.encode(hallucinationProtectionEnabled, forKey: .hallucinationProtectionEnabled)
        try container.encode(whisperCustomDecodingEnabled, forKey: .whisperCustomDecodingEnabled)
        try container.encode(whisperBoundaryStrategy, forKey: .whisperBoundaryStrategy)
        try container.encode(finalTranscriptCleanupEnabled, forKey: .finalTranscriptCleanupEnabled)
        try container.encode(gigaAMRussianCorrectionEnabled, forKey: .gigaAMRussianCorrectionEnabled)
    }

    public static let classic = RecognitionTuningValues(
        voiceActivityDetectionMode: .energy,
        sileroThreshold: 0.5,
        sileroMinimumSpeechDuration: 0.10,
        endOfSpeechSilenceDuration: 0.65,
        preRollDuration: 0.25,
        postRollDuration: 0.15,
        whisperChunkDuration: 5.0,
        whisperOverlapDuration: 0.30,
        usesRecognitionContext: false,
        usesRecognitionVocabulary: false,
        hallucinationProtectionEnabled: false,
        whisperCustomDecodingEnabled: false,
        whisperBoundaryStrategy: .standard,
        finalTranscriptCleanupEnabled: false,
        gigaAMRussianCorrectionEnabled: false
    )

    public static let recommended = RecognitionTuningValues(
        voiceActivityDetectionMode: .hybrid,
        sileroThreshold: 0.5,
        sileroMinimumSpeechDuration: 0.10,
        endOfSpeechSilenceDuration: 0.70,
        preRollDuration: 0.30,
        postRollDuration: 0.20,
        whisperChunkDuration: 20.0,
        whisperOverlapDuration: 0.40,
        usesRecognitionContext: true,
        usesRecognitionVocabulary: true,
        hallucinationProtectionEnabled: true,
        whisperCustomDecodingEnabled: false,
        whisperBoundaryStrategy: .standard,
        finalTranscriptCleanupEnabled: true,
        gigaAMRussianCorrectionEnabled: false
    )

    public static let quality = RecognitionTuningValues(
        voiceActivityDetectionMode: .hybrid,
        sileroThreshold: 0.45,
        sileroMinimumSpeechDuration: 0.08,
        endOfSpeechSilenceDuration: 0.80,
        preRollDuration: 0.40,
        postRollDuration: 0.30,
        // Pause-balanced delivery waits for 1.5x this window before selecting
        // a natural cut. Longer windows materially reduced punctuation in a
        // production-pipeline Russian dictation sweep, while shorter windows
        // added inference work without improving the lexical result.
        whisperChunkDuration: 20.0,
        whisperOverlapDuration: 0.50,
        pauseBalancedChunkingEnabled: true,
        usesRecognitionContext: true,
        usesRecognitionVocabulary: true,
        hallucinationProtectionEnabled: true,
        whisperCustomDecodingEnabled: false,
        whisperBoundaryStrategy: .standard,
        finalTranscriptCleanupEnabled: true,
        gigaAMRussianCorrectionEnabled: true
    )

    public static let lowLatency = RecognitionTuningValues(
        voiceActivityDetectionMode: .energy,
        sileroThreshold: 0.5,
        sileroMinimumSpeechDuration: 0.08,
        endOfSpeechSilenceDuration: 0.45,
        preRollDuration: 0.18,
        postRollDuration: 0.10,
        // A production-pipeline dictation sweep kept the same 1.56-second
        // first natural cut at 5 seconds, while reducing forced chunks and
        // improving both total inference time and lexical agreement.
        whisperChunkDuration: 5.0,
        whisperOverlapDuration: 0.15,
        usesRecognitionContext: false,
        usesRecognitionVocabulary: false,
        hallucinationProtectionEnabled: false,
        whisperCustomDecodingEnabled: false,
        whisperBoundaryStrategy: .standard,
        finalTranscriptCleanupEnabled: true,
        gigaAMRussianCorrectionEnabled: false
    )

    public func fieldsDiffering(from base: RecognitionTuningValues) -> Set<RecognitionTuningField> {
        var fields: Set<RecognitionTuningField> = []
        if voiceActivityDetectionMode != base.voiceActivityDetectionMode { fields.insert(.voiceActivityDetectionMode) }
        if abs(sileroThreshold - base.sileroThreshold) > 0.0001 { fields.insert(.sileroThreshold) }
        if abs(sileroMinimumSpeechDuration - base.sileroMinimumSpeechDuration) > 0.0001 {
            fields.insert(.sileroMinimumSpeechDuration)
        }
        if abs(endOfSpeechSilenceDuration - base.endOfSpeechSilenceDuration) > 0.0001 {
            fields.insert(.endOfSpeechSilenceDuration)
        }
        if abs(preRollDuration - base.preRollDuration) > 0.0001 { fields.insert(.preRollDuration) }
        if abs(postRollDuration - base.postRollDuration) > 0.0001 { fields.insert(.postRollDuration) }
        if abs(whisperChunkDuration - base.whisperChunkDuration) > 0.0001 {
            fields.insert(.whisperChunkDuration)
        }
        if abs(whisperOverlapDuration - base.whisperOverlapDuration) > 0.0001 {
            fields.insert(.whisperOverlapDuration)
        }
        if pauseBalancedChunkingEnabled != base.pauseBalancedChunkingEnabled {
            fields.insert(.pauseBalancedChunkingEnabled)
        }
        if usesRecognitionContext != base.usesRecognitionContext { fields.insert(.usesRecognitionContext) }
        if usesRecognitionVocabulary != base.usesRecognitionVocabulary { fields.insert(.usesRecognitionVocabulary) }
        if hallucinationProtectionEnabled != base.hallucinationProtectionEnabled {
            fields.insert(.hallucinationProtectionEnabled)
        }
        if whisperCustomDecodingEnabled != base.whisperCustomDecodingEnabled {
            fields.insert(.whisperCustomDecodingEnabled)
        }
        if whisperBoundaryStrategy != base.whisperBoundaryStrategy { fields.insert(.whisperBoundaryStrategy) }
        if finalTranscriptCleanupEnabled != base.finalTranscriptCleanupEnabled {
            fields.insert(.finalTranscriptCleanupEnabled)
        }
        if gigaAMRussianCorrectionEnabled != base.gigaAMRussianCorrectionEnabled {
            fields.insert(.gigaAMRussianCorrectionEnabled)
        }
        return fields
    }

    public static func closestBuiltInProfile(
        to values: RecognitionTuningValues
    ) -> RecognitionProfileID {
        let candidates: [RecognitionProfileID] = [.classic, .recommended, .quality, .lowLatency]
        return candidates.min { lhs, rhs in
            guard let lhsValues = preset(for: lhs), let rhsValues = preset(for: rhs) else {
                return false
            }
            return values.fieldsDiffering(from: lhsValues).count
                < values.fieldsDiffering(from: rhsValues).count
        } ?? .classic
    }

    public static func preset(for profile: RecognitionProfileID) -> RecognitionTuningValues? {
        switch profile {
        case .classic: return .classic
        case .recommended: return .recommended
        case .quality: return .quality
        case .lowLatency: return .lowLatency
        case .custom: return nil
        }
    }
}

public enum RecognitionTuningField: String, CaseIterable, Identifiable, Codable, Sendable {
    case voiceActivityDetectionMode
    case sileroThreshold
    case sileroMinimumSpeechDuration
    case endOfSpeechSilenceDuration
    case preRollDuration
    case postRollDuration
    case whisperChunkDuration
    case whisperOverlapDuration
    case pauseBalancedChunkingEnabled
    case usesRecognitionContext
    case usesRecognitionVocabulary
    case hallucinationProtectionEnabled
    case whisperCustomDecodingEnabled
    case whisperBoundaryStrategy
    case finalTranscriptCleanupEnabled
    case gigaAMRussianCorrectionEnabled

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .voiceActivityDetectionMode: return "VAD engine"
        case .sileroThreshold: return "Speech probability"
        case .sileroMinimumSpeechDuration: return "Minimum neural speech"
        case .endOfSpeechSilenceDuration: return "Speech end pause"
        case .preRollDuration: return "Audio before speech"
        case .postRollDuration: return "Audio after speech"
        case .whisperChunkDuration: return "Maximum Whisper chunk"
        case .whisperOverlapDuration: return "Whisper chunk overlap"
        case .pauseBalancedChunkingEnabled: return "Pause-balanced chunking"
        case .usesRecognitionContext: return "Use context"
        case .usesRecognitionVocabulary: return "Use vocabulary"
        case .hallucinationProtectionEnabled: return "Hallucination-loop protection"
        case .whisperCustomDecodingEnabled: return "Custom Whisper decoding"
        case .whisperBoundaryStrategy: return "Whisper boundary strategy"
        case .finalTranscriptCleanupEnabled: return "Final transcript cleanup"
        case .gigaAMRussianCorrectionEnabled: return "Russian correction for GigaAM"
        }
    }
}

public struct SavedRecognitionPreset: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var basedOn: RecognitionProfileID
    public var tuning: RecognitionTuningValues

    public init(
        id: UUID = UUID(),
        name: String,
        basedOn: RecognitionProfileID,
        tuning: RecognitionTuningValues
    ) {
        self.id = id
        self.name = name
        self.basedOn = basedOn.isBuiltIn ? basedOn : .recommended
        self.tuning = tuning
    }
}

public struct MicrophoneEnvironmentValues: Equatable, Sendable {
    public var baseConfiguration: VoiceActivityDetector.Configuration

    public init(baseConfiguration: VoiceActivityDetector.Configuration) {
        self.baseConfiguration = baseConfiguration
    }

    public static let quiet = MicrophoneEnvironmentValues(baseConfiguration: .sensitive)
    public static let balanced = MicrophoneEnvironmentValues(baseConfiguration: .balanced)
    public static let noisy = MicrophoneEnvironmentValues(baseConfiguration: .noiseResistant)

    public static func preset(
        for profile: MicrophoneEnvironmentProfileID
    ) -> MicrophoneEnvironmentValues? {
        switch profile {
        case .quiet: return .quiet
        case .balanced: return .balanced
        case .noisy: return .noisy
        case .custom: return nil
        }
    }
}

public struct EffectiveRecognitionConfiguration: Equatable, Sendable {
    public let recognitionProfile: RecognitionProfileID
    public let microphoneEnvironmentProfile: MicrophoneEnvironmentProfileID
    public let tuning: RecognitionTuningValues
    public let voiceActivityConfiguration: VoiceActivityDetector.Configuration

    public init(
        recognitionProfile: RecognitionProfileID,
        microphoneEnvironmentProfile: MicrophoneEnvironmentProfileID,
        tuning: RecognitionTuningValues,
        voiceActivityConfiguration: VoiceActivityDetector.Configuration
    ) {
        self.recognitionProfile = recognitionProfile
        self.microphoneEnvironmentProfile = microphoneEnvironmentProfile
        self.tuning = tuning
        self.voiceActivityConfiguration = voiceActivityConfiguration
    }
}

public enum RecognitionConfigurationResolver {
    public static func resolve(
        recognitionProfile: RecognitionProfileID,
        microphoneEnvironmentProfile: MicrophoneEnvironmentProfileID,
        customRecognitionTuning: RecognitionTuningValues,
        customMicrophoneConfiguration: VoiceActivityDetector.Configuration
    ) -> EffectiveRecognitionConfiguration {
        let tuning =
            RecognitionTuningValues.preset(for: recognitionProfile)
            ?? customRecognitionTuning
        var voiceActivityConfiguration =
            MicrophoneEnvironmentValues.preset(for: microphoneEnvironmentProfile)?
            .baseConfiguration
            ?? customMicrophoneConfiguration
        voiceActivityConfiguration.endOfSpeechSilenceDuration = max(
            0.15,
            tuning.endOfSpeechSilenceDuration
        )
        if tuning.voiceActivityDetectionMode != .energy {
            voiceActivityConfiguration.minimumSpeechDuration = max(
                0.05,
                tuning.sileroMinimumSpeechDuration
            )
        }

        return EffectiveRecognitionConfiguration(
            recognitionProfile: recognitionProfile,
            microphoneEnvironmentProfile: microphoneEnvironmentProfile,
            tuning: tuning,
            voiceActivityConfiguration: voiceActivityConfiguration
        )
    }
}
