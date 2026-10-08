import Foundation

public enum WhisperBoundaryStrategy: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard
    case contextualRetry
    case boundaryBridge

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: return "Standard"
        case .contextualRetry: return "Contextual Retry"
        case .boundaryBridge: return "Boundary Bridge"
        }
    }

    public var detail: String {
        switch self {
        case .standard:
            return "Keeps independently decoded Whisper chunks without an additional repair pass."
        case .contextualRetry:
            return "Retries suspicious forced boundaries with aligned previous-text context."
        case .boundaryBridge:
            return "Re-decodes a short continuous window across suspicious forced boundaries."
        }
    }
}

public enum WhisperFileTranscriptionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case profileVAD
    case continuousFullAudio

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .profileVAD: return "Profile VAD"
        case .continuousFullAudio: return "Continuous Full Audio"
        }
    }

    public var detail: String {
        switch self {
        case .profileVAD:
            return "Uses the active profile's VoicePanel segmentation for imported files."
        case .continuousFullAudio:
            return "Lets Whisper process the imported file as one continuous recording."
        }
    }
}

public enum WhisperContextPromptMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case legacyFixedWords
    case lexicalOverlapAligned
    case timestampAligned

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .legacyFixedWords: return "Legacy Fixed Words"
        case .lexicalOverlapAligned: return "Lexical Overlap Aligned"
        case .timestampAligned: return "Timestamp Aligned"
        }
    }

    public var detail: String {
        switch self {
        case .legacyFixedWords:
            return "Uses a fixed previous-word tail as a research control."
        case .lexicalOverlapAligned:
            return "Builds context by aligning the previous suffix with the current prefix."
        case .timestampAligned:
            return "Builds context from word timestamps before the current audio window."
        }
    }
}

public enum WhisperBoundarySettingsMigration {
    public static func resolveBoundaryStrategy(
        newRawValue: String?,
        legacyCarryContext: Bool?,
        profileDefault: WhisperBoundaryStrategy
    ) -> WhisperBoundaryStrategy {
        if let newRawValue, let value = WhisperBoundaryStrategy(rawValue: newRawValue) {
            return value
        }
        if let legacyCarryContext {
            return legacyCarryContext ? .contextualRetry : .standard
        }
        return profileDefault
    }
}
