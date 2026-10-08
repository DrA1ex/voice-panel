import Foundation
import VoicePanelCore

enum WhisperComputeMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case coreMLMetal
    case coreMLCPU
    case metal
    case cpu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Auto"
        case .coreMLMetal: return "Core ML encoder + Metal decoder"
        case .coreMLCPU: return "Core ML encoder + CPU decoder"
        case .metal: return "Metal GPU"
        case .cpu: return "CPU only"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "Use an installed Core ML encoder with Metal; otherwise use Metal for the complete model."
        case .coreMLMetal:
            return "Run the encoder through Core ML, which may use the Apple Neural Engine, and keep decoding on Metal."
        case .coreMLCPU:
            return "Run the encoder through Core ML and keep the decoder on the CPU for a direct comparison."
        case .metal:
            return "Disable Core ML and run supported Whisper operations on the Apple GPU through Metal."
        case .cpu:
            return "Disable Core ML and Metal. Useful for compatibility checks and processor comparisons."
        }
    }

    var requestsCoreML: Bool {
        self == .coreMLMetal || self == .coreMLCPU
    }

    var permitsCoreML: Bool {
        self == .automatic || requestsCoreML
    }

    var usesGPUDecoder: Bool {
        switch self {
        case .automatic, .coreMLMetal, .metal: return true
        case .coreMLCPU, .cpu: return false
        }
    }

    var supportsFlashAttention: Bool { usesGPUDecoder }
}

enum WhisperDecodingStrategy: String, CaseIterable, Identifiable, Sendable {
    case greedy
    case beamSearch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .greedy: return "Greedy"
        case .beamSearch: return "Beam search"
        }
    }

    var detail: String {
        switch self {
        case .greedy: return "Faster and suitable for interactive transcription."
        case .beamSearch: return "Explores several candidate sequences and can improve difficult audio at a speed cost."
        }
    }
}

struct WhisperRuntimeConfiguration: Equatable, Sendable {
    let requestedComputeMode: WhisperComputeMode
    let effectiveComputeMode: WhisperComputeMode
    let flashAttention: Bool

    init(
        requestedComputeMode: WhisperComputeMode,
        effectiveComputeMode: WhisperComputeMode? = nil,
        flashAttention: Bool
    ) {
        self.requestedComputeMode = requestedComputeMode
        self.effectiveComputeMode = effectiveComputeMode ?? requestedComputeMode
        self.flashAttention = flashAttention
    }

    var useGPU: Bool { effectiveComputeMode.usesGPUDecoder }
    var useFlashAttention: Bool { useGPU && flashAttention }

    var displayTitle: String {
        if requestedComputeMode == .automatic,
            requestedComputeMode != effectiveComputeMode
        {
            return "Auto → \(effectiveComputeMode.title)"
        }
        return effectiveComputeMode.title
    }
}

struct WhisperInferenceConfiguration: Equatable, Sendable {
    let numberOfThreads: Int
    let usesCustomDecoding: Bool
    let decodingStrategy: WhisperDecodingStrategy
    let greedyBestOf: Int
    let beamSize: Int
    let initialPrompt: String
    let boundaryStrategy: WhisperBoundaryStrategy
    let overlapDuration: TimeInterval
    let contextPromptMode: WhisperContextPromptMode

    init(
        numberOfThreads: Int,
        usesCustomDecoding: Bool,
        decodingStrategy: WhisperDecodingStrategy,
        greedyBestOf: Int,
        beamSize: Int,
        initialPrompt: String,
        boundaryStrategy: WhisperBoundaryStrategy,
        overlapDuration: TimeInterval,
        contextPromptMode: WhisperContextPromptMode
    ) {
        self.numberOfThreads = numberOfThreads
        self.usesCustomDecoding = usesCustomDecoding
        self.decodingStrategy = decodingStrategy
        self.greedyBestOf = greedyBestOf
        self.beamSize = beamSize
        self.initialPrompt = initialPrompt
        self.boundaryStrategy = boundaryStrategy
        self.overlapDuration = overlapDuration
        self.contextPromptMode = contextPromptMode
    }

    var normalizedInitialPrompt: String {
        initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
