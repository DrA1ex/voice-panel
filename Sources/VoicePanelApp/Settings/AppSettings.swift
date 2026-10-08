import Combine
import Foundation
import VoicePanelCore

@MainActor
final class AppSettings: ObservableObject {
    enum AppearanceMode: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    enum RecognitionBackend: String, CaseIterable, Identifiable {
        case appleSpeech
        case whisper
        case gigaAM
        case qwen3ASR
        case parakeet

        var id: String { rawValue }

        var title: String {
            switch self {
            case .appleSpeech: return "Apple Speech"
            case .whisper: return "Whisper"
            case .gigaAM: return "GigaAM v3"
            case .qwen3ASR: return "Qwen3-ASR"
            case .parakeet: return "Parakeet TDT"
            }
        }
    }

    enum WhisperDraftSource: String, CaseIterable, Identifiable {
        case none
        case appleSpeech
        case localWhisper

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: return "No live draft"
            case .appleSpeech: return "Apple Speech"
            case .localWhisper: return "Local Whisper model"
            }
        }

        var detail: String {
            switch self {
            case .none:
                return "Wait for the selected final Whisper model. Pending feedback can use shimmer or a spinner."
            case .appleSpeech:
                return "Show immediate system draft text, then replace each completed chunk with final Whisper text."
            case .localWhisper:
                return "Use a separately selected faster Whisper model for draft text. Both models remain local."
            }
        }
    }

    enum GigaAMDraftSource: String, CaseIterable, Identifiable {
        case none
        case appleSpeech
        case localGigaAM

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: return "No live draft"
            case .appleSpeech: return "Apple Speech"
            case .localGigaAM: return "Local GigaAM model"
            }
        }

        var detail: String {
            switch self {
            case .none:
                return "Wait for the selected final GigaAM model. Pending feedback can use shimmer or a spinner."
            case .appleSpeech:
                return "Show immediate Russian draft text, then replace completed chunks with final GigaAM text."
            case .localGigaAM:
                return "Use a faster plain-text GigaAM v3 model as the Russian draft engine."
            }
        }
    }

    enum LocalASRDraftSource: String, CaseIterable, Identifiable {
        case none
        case appleSpeech

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: return "No live draft"
            case .appleSpeech: return "Apple Speech"
            }
        }

        var detail: String {
            switch self {
            case .none:
                return "Wait for the selected local model. Pending feedback can use shimmer or a spinner."
            case .appleSpeech:
                return "Show immediate system draft text, then replace completed chunks with the selected local model."
            }
        }
    }

    enum LocalONNXExecutionProvider: String, CaseIterable, Identifiable {
        case cpu
        case coreML

        var id: String { rawValue }
        var title: String {
            switch self {
            case .cpu: return "CPU"
            case .coreML: return "Core ML (experimental)"
            }
        }
        var runtimeValue: String { self == .coreML ? "coreml" : "cpu" }
    }

    enum GigaAMExecutionProvider: String, CaseIterable, Identifiable {
        case cpu
        case coreML

        var id: String { rawValue }
        var title: String {
            switch self {
            case .cpu: return "CPU"
            case .coreML: return "Core ML (experimental)"
            }
        }
        var runtimeValue: String { self == .coreML ? "coreml" : "cpu" }
    }

    enum VADPreset: String, CaseIterable, Identifiable {
        case sensitive
        case balanced
        case noiseResistant

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sensitive: return "Sensitive"
            case .balanced: return "Balanced"
            case .noiseResistant: return "Noise Resistant"
            }
        }

        var detail: String {
            switch self {
            case .sensitive: return "Quiet voice and quiet rooms"
            case .balanced: return "Recommended for most microphones"
            case .noiseResistant: return "Fans, keyboards, and noisier rooms"
            }
        }
    }

    enum HotKeyPreset: String, CaseIterable, Identifiable {
        case controlOptionSpace
        case commandShiftSpace
        case controlShiftSpace

        var id: String { rawValue }

        var title: String {
            switch self {
            case .controlOptionSpace: return "⌃⌥Space"
            case .commandShiftSpace: return "⌘⇧Space"
            case .controlShiftSpace: return "⌃⇧Space"
            }
        }
    }

    enum PanelSizePreset: String, CaseIterable, Identifiable {
        case compact
        case medium
        case large

        static let visualEffectInset: CGFloat = 48

        var id: String { rawValue }

        var title: String {
            switch self {
            case .compact: return "Compact"
            case .medium: return "Medium"
            case .large: return "Large"
            }
        }

        /// Visible panel size. The NSPanel window itself is larger so blurred
        /// voice-reactive effects are never clipped by the window boundary.
        var width: CGFloat {
            switch self {
            case .compact: return CompactAudioImportLayoutPolicy.productionCompact.panelWidth
            case .medium: return 600
            case .large: return 650
            }
        }

        var height: CGFloat {
            switch self {
            case .compact: return CompactAudioImportLayoutPolicy.productionCompact.panelHeight
            case .medium: return 150
            case .large: return 300
            }
        }

        var windowWidth: CGFloat { width + Self.visualEffectInset * 2 }
        var windowHeight: CGFloat { height + Self.visualEffectInset * 2 }
    }

    enum PanelPositionPreset: String, CaseIterable, Identifiable {
        case aboveDock
        case screenBottom
        case center

        var id: String { rawValue }

        var title: String {
            switch self {
            case .aboveDock: return "Above Dock"
            case .screenBottom: return "Screen bottom"
            case .center: return "Screen center"
            }
        }
    }

    enum PendingFeedbackStyle: String, CaseIterable, Identifiable {
        case blurredWords
        case gradientBars
        case pulse

        var id: String { rawValue }

        var title: String {
            switch self {
            case .blurredWords: return "Blurred words"
            case .gradientBars: return "Gradient bars"
            case .pulse: return "Pulse"
            }
        }

        var detail: String {
            switch self {
            case .blurredWords:
                return "Soft unreadable word shapes grow with unprocessed speech."
            case .gradientBars:
                return "A luminous gradient streak grows and shimmers while recognition is pending."
            case .pulse:
                return "A compact rhythmic pulse shows that recognition is active."
            }
        }
    }

    enum HotKeyCompletionBehavior: String, CaseIterable, Identifiable {
        case copyAndClose
        case copyAndOpenEditor

        var id: String { rawValue }

        var title: String {
            switch self {
            case .copyAndClose: return "Copy and close"
            case .copyAndOpenEditor: return "Copy and open editor"
            }
        }
    }

    enum MenuCompletionBehavior: String, CaseIterable, Identifiable {
        case compactResult
        case openEditor

        var id: String { rawValue }

        var title: String {
            switch self {
            case .compactResult: return "Show compact result"
            case .openEditor: return "Open editor"
            }
        }
    }

    enum HistoryRetentionPreset: String, CaseIterable, Identifiable {
        case thirtyMinutes
        case oneHour
        case oneDay
        case sevenDays
        case thirtyDays
        case forever

        var id: String { rawValue }

        var title: String {
            switch self {
            case .thirtyMinutes: return "30 minutes"
            case .oneHour: return "1 hour"
            case .oneDay: return "24 hours"
            case .sevenDays: return "7 days"
            case .thirtyDays: return "30 days"
            case .forever: return "Forever"
            }
        }

        var retentionInterval: TimeInterval? {
            switch self {
            case .thirtyMinutes: return 30 * 60
            case .oneHour: return 60 * 60
            case .oneDay: return 24 * 60 * 60
            case .sevenDays: return 7 * 24 * 60 * 60
            case .thirtyDays: return 30 * 24 * 60 * 60
            case .forever: return nil
            }
        }
    }

    enum HistoryStorageMode: String, CaseIterable, Identifiable {
        case none
        case encrypted

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: return "None"
            case .encrypted: return "Encrypted history"
            }
        }
    }

    private enum Key {
        static let recognitionBackend = "recognitionBackend"
        static let recognitionProfile = "recognitionProfileV1"
        static let microphoneEnvironmentProfile = "microphoneEnvironmentProfileV1"
        static let recognitionProfilesMigrated = "recognitionProfilesMigratedV1"
        static let recognitionCustomizationMigrated = "recognitionCustomizationMigratedV1"
        static let customRecognitionBaseProfile = "customRecognitionBaseProfileV1"
        static let savedRecognitionPresets = "savedRecognitionPresetsV1"
        static let whisperModelID = "whisperModelID"
        static let gigaAMModelID = "gigaAMModelID"
        static let qwen3ASRModelID = "qwen3ASRModelID"
        static let localONNXDraftSource = "localONNXDraftSource"
        static let localONNXPreferredChunkDuration = "localONNXPreferredChunkDuration"
        static let localONNXMaximumChunkDuration = "localONNXMaximumChunkDuration"
        static let localONNXOverlapDuration = "localONNXOverlapDuration"
        static let localONNXBoundarySearchDuration = "localONNXBoundarySearchDuration"
        static let localONNXRetryCount = "localONNXRetryCount"
        static let localONNXSplitOnFailure = "localONNXSplitOnFailure"
        static let localONNXThreadCount = "localONNXThreadCount"
        static let localONNXExecutionProvider = "localONNXExecutionProvider"
        static let appleSpeechAddsPunctuation = "appleSpeechAddsPunctuation"
        static let appleSpeechOnDeviceOnly = "appleSpeechOnDeviceOnly"
        static let appleSpeechContextualPhrases = "appleSpeechContextualPhrases"
        static let whisperChunkDuration = "whisperChunkDuration"
        static let pauseBalancedChunkingEnabled = "pauseBalancedChunkingEnabledV1"
        static let legacyWhisperChunkSchedulingMode = "whisperChunkSchedulingModeV1"
        static let whisperOverlapDuration = "whisperOverlapDuration"
        static let whisperThreadCount = "whisperThreadCount"
        static let whisperComputeMode = "whisperComputeModeV1"
        static let whisperFlashAttention = "whisperFlashAttentionV1"
        static let whisperCustomDecodingEnabled = "whisperCustomDecodingEnabledV1"
        static let whisperDecodingStrategy = "whisperDecodingStrategyV1"
        static let whisperGreedyBestOf = "whisperGreedyBestOfV1"
        static let whisperBeamSize = "whisperBeamSizeV1"
        static let whisperInitialPrompt = "whisperInitialPromptV1"
        static let whisperBoundaryStrategy = "whisperBoundaryStrategyV1"
        static let whisperFileTranscriptionMode = "whisperFileTranscriptionModeV1"
        static let whisperCarryContext = "whisperCarryContextV1"
        static let recognitionContext = "recognitionContextV1"
        static let recognitionVocabulary = "recognitionVocabularyV1"
        static let recognitionContextEnabled = "recognitionContextEnabledV1"
        static let recognitionVocabularyEnabled = "recognitionVocabularyEnabledV1"
        static let voiceActivityDetectionMode = "voiceActivityDetectionModeV1"
        static let sileroThreshold = "sileroThresholdV1"
        static let sileroMinimumSpeechDuration = "sileroMinimumSpeechDurationV1"
        static let voiceEndSilenceDuration = "voiceEndSilenceDurationV1"
        static let voicePreRollDuration = "voicePreRollDurationV1"
        static let voicePostRollDuration = "voicePostRollDurationV1"
        static let hallucinationProtectionEnabled = "hallucinationProtectionEnabledV1"
        static let finalTranscriptCleanupEnabled = "finalTranscriptCleanupEnabledV1"
        static let gigaAMRussianCorrectionEnabled = "gigaAMRussianCorrectionEnabledV1"
        static let whisperCompatibilityDefaultsMigrated = "whisperCompatibilityDefaultsMigratedV1"
        static let gigaAMPreferredChunkDuration = "gigaAMPreferredChunkDuration"
        static let gigaAMMaximumChunkDuration = "gigaAMMaximumChunkDuration"
        static let gigaAMOverlapDuration = "gigaAMOverlapDuration"
        static let gigaAMBoundarySearchDuration = "gigaAMBoundarySearchDuration"
        static let gigaAMRetryCount = "gigaAMRetryCount"
        static let gigaAMSplitOnFailure = "gigaAMSplitOnFailure"
        static let gigaAMThreadCount = "gigaAMThreadCount"
        static let gigaAMExecutionProvider = "gigaAMExecutionProvider"
        static let legacyGigaAMUseAppleDraft = "gigaAMUseAppleDraft"
        static let legacyGigaAMDraftBackend = "gigaAMDraftBackend"
        static let legacyWhisperUseAppleDraft = "whisperUseAppleDraft"
        static let whisperDraftSource = "whisperDraftSource"
        static let whisperDraftModelID = "whisperDraftModelID"
        static let whisperDraftChunkDuration = "whisperDraftChunkDuration"
        static let gigaAMDraftSource = "gigaAMDraftSource"
        static let gigaAMDraftModelID = "gigaAMDraftModelID"
        static let gigaAMDraftChunkDuration = "gigaAMDraftChunkDuration"
        static let legacyLanguageIdentifier = "languageIdentifier"
        static let appleSpeechLanguageIdentifier = "appleSpeechLanguageIdentifier"
        static let whisperLanguageCode = "whisperLanguageCode"
        static let hotKeyPreset = "hotKeyPreset"
        static let hotKeyReleaseTailEnabled = "hotKeyReleaseTailEnabledV1"
        static let hotKeyReleaseTailDuration = "hotKeyReleaseTailDurationV1"
        static let includeAudioCapturedWhilePreparing =
            "includeAudioCapturedWhilePreparingV1"
        static let showFullTranscriptAutomatically = "showFullTranscriptAutomatically"
        static let panelSizePreset = "panelSizePreset"
        static let panelPositionPreset = "panelPositionPresetV1"
        static let panelAlwaysOnTop = "panelAlwaysOnTopV1"
        static let panelBackgroundIsTransparent = "panelBackgroundIsTransparentV1"
        static let panelBackgroundBlurEnabled = "panelBackgroundBlurEnabledV1"
        static let legacyAppearanceMode = "appearanceModeV1"
        static let windowAppearanceMode = "windowAppearanceModeV1"
        static let panelAppearanceMode = "panelAppearanceModeV1"
        static let hotKeyCompletionBehavior = "hotKeyCompletionBehavior"
        static let menuCompletionBehavior = "menuCompletionBehavior"
        static let historyRetentionPreset = "historyRetentionPreset"
        static let historyStorageMode = "historyStorageModeV1"
        static let debugAudioRecordingEnabled = "debugAudioRecordingEnabledV1"
        static let vadPreset = "vadPreset"
        static let adaptiveVAD = "adaptiveVAD"
        static let manualThresholdDB = "manualThresholdDB"
        static let suppressDetectedSilence = "suppressDetectedSilence"
        static let selectedInputDeviceID = "selectedInputDeviceID"
        static let showPendingWordShimmer = "showPendingWordShimmerV2"
        static let pendingFeedbackStyle = "pendingFeedbackStyleV1"
    }

    private static let legacyPreferencesDomain = "dev.voicepanel.prototype"
    private static let legacyPreferencesMigrationKey = "legacyPrototypePreferencesMigratedV1"

    private static func liveDraftPreferenceKey(for profile: RecognitionProfileID) -> String {
        "liveDraftEnabled.\(profile.rawValue)"
    }

    private let defaults: UserDefaults
    private var isReconcilingDraftSelections = false
    private var suppressesProfileChangeTracking = false

    @Published var recognitionBackend: RecognitionBackend {
        didSet { defaults.set(recognitionBackend.rawValue, forKey: Key.recognitionBackend) }
    }

    @Published var recognitionProfile: RecognitionProfileID {
        didSet { defaults.set(recognitionProfile.rawValue, forKey: Key.recognitionProfile) }
    }

    @Published var customRecognitionBaseProfile: RecognitionProfileID {
        didSet {
            defaults.set(
                customRecognitionBaseProfile.rawValue,
                forKey: Key.customRecognitionBaseProfile
            )
        }
    }

    @Published private(set) var savedRecognitionPresets: [SavedRecognitionPreset] {
        didSet { persistSavedRecognitionPresets() }
    }

    @Published var microphoneEnvironmentProfile: MicrophoneEnvironmentProfileID {
        didSet {
            defaults.set(
                microphoneEnvironmentProfile.rawValue,
                forKey: Key.microphoneEnvironmentProfile
            )
        }
    }

    @Published var whisperModelID: WhisperModelID {
        didSet { defaults.set(whisperModelID.rawValue, forKey: Key.whisperModelID) }
    }

    @Published var gigaAMModelID: GigaAMModelID {
        didSet { defaults.set(gigaAMModelID.rawValue, forKey: Key.gigaAMModelID) }
    }

    @Published var qwen3ASRModelID: LocalONNXModelID {
        didSet { defaults.set(qwen3ASRModelID.rawValue, forKey: Key.qwen3ASRModelID) }
    }

    @Published var localONNXDraftSource: LocalASRDraftSource {
        didSet { defaults.set(localONNXDraftSource.rawValue, forKey: Key.localONNXDraftSource) }
    }

    @Published var localONNXPreferredChunkDuration: Double {
        didSet { defaults.set(localONNXPreferredChunkDuration, forKey: Key.localONNXPreferredChunkDuration) }
    }

    @Published var localONNXMaximumChunkDuration: Double {
        didSet { defaults.set(localONNXMaximumChunkDuration, forKey: Key.localONNXMaximumChunkDuration) }
    }

    @Published var localONNXOverlapDuration: Double {
        didSet { defaults.set(localONNXOverlapDuration, forKey: Key.localONNXOverlapDuration) }
    }

    @Published var localONNXBoundarySearchDuration: Double {
        didSet { defaults.set(localONNXBoundarySearchDuration, forKey: Key.localONNXBoundarySearchDuration) }
    }

    @Published var localONNXRetryCount: Int {
        didSet { defaults.set(localONNXRetryCount, forKey: Key.localONNXRetryCount) }
    }

    @Published var localONNXSplitOnFailure: Bool {
        didSet { defaults.set(localONNXSplitOnFailure, forKey: Key.localONNXSplitOnFailure) }
    }

    @Published var localONNXThreadCount: Int {
        didSet { defaults.set(localONNXThreadCount, forKey: Key.localONNXThreadCount) }
    }

    @Published var localONNXExecutionProvider: LocalONNXExecutionProvider {
        didSet { defaults.set(localONNXExecutionProvider.rawValue, forKey: Key.localONNXExecutionProvider) }
    }

    @Published var appleSpeechAddsPunctuation: Bool {
        didSet { defaults.set(appleSpeechAddsPunctuation, forKey: Key.appleSpeechAddsPunctuation) }
    }

    @Published var appleSpeechOnDeviceOnly: Bool {
        didSet { defaults.set(appleSpeechOnDeviceOnly, forKey: Key.appleSpeechOnDeviceOnly) }
    }

    @Published var appleSpeechContextualPhrases: String {
        didSet { defaults.set(appleSpeechContextualPhrases, forKey: Key.appleSpeechContextualPhrases) }
    }

    @Published var whisperChunkDuration: Double {
        didSet {
            defaults.set(whisperChunkDuration, forKey: Key.whisperChunkDuration)
            if oldValue != whisperChunkDuration { markRecognitionProfileCustom() }
        }
    }

    @Published var pauseBalancedChunkingEnabled: Bool {
        didSet {
            defaults.set(
                pauseBalancedChunkingEnabled,
                forKey: Key.pauseBalancedChunkingEnabled
            )
            if oldValue != pauseBalancedChunkingEnabled { markRecognitionProfileCustom() }
        }
    }

    @Published var whisperOverlapDuration: Double {
        didSet {
            defaults.set(whisperOverlapDuration, forKey: Key.whisperOverlapDuration)
            if oldValue != whisperOverlapDuration { markRecognitionProfileCustom() }
        }
    }

    @Published var whisperThreadCount: Int {
        didSet { defaults.set(whisperThreadCount, forKey: Key.whisperThreadCount) }
    }

    @Published var whisperComputeMode: WhisperComputeMode {
        didSet { defaults.set(whisperComputeMode.rawValue, forKey: Key.whisperComputeMode) }
    }

    @Published var whisperFlashAttention: Bool {
        didSet { defaults.set(whisperFlashAttention, forKey: Key.whisperFlashAttention) }
    }

    @Published var whisperCustomDecodingEnabled: Bool {
        didSet {
            defaults.set(
                whisperCustomDecodingEnabled,
                forKey: Key.whisperCustomDecodingEnabled
            )
            if oldValue != whisperCustomDecodingEnabled { markRecognitionProfileCustom() }
        }
    }

    @Published var whisperDecodingStrategy: WhisperDecodingStrategy {
        didSet {
            defaults.set(whisperDecodingStrategy.rawValue, forKey: Key.whisperDecodingStrategy)
            if oldValue != whisperDecodingStrategy { markRecognitionProfileCustom() }
        }
    }

    @Published var whisperGreedyBestOf: Int {
        didSet {
            defaults.set(whisperGreedyBestOf, forKey: Key.whisperGreedyBestOf)
            if oldValue != whisperGreedyBestOf { markRecognitionProfileCustom() }
        }
    }

    @Published var whisperBeamSize: Int {
        didSet {
            defaults.set(whisperBeamSize, forKey: Key.whisperBeamSize)
            if oldValue != whisperBeamSize { markRecognitionProfileCustom() }
        }
    }

    @Published var whisperInitialPrompt: String {
        didSet { defaults.set(whisperInitialPrompt, forKey: Key.whisperInitialPrompt) }
    }

    @Published var whisperBoundaryStrategy: WhisperBoundaryStrategy {
        didSet {
            defaults.set(whisperBoundaryStrategy.rawValue, forKey: Key.whisperBoundaryStrategy)
            if oldValue != whisperBoundaryStrategy { markRecognitionProfileCustom() }
        }
    }

    @Published var whisperFileTranscriptionMode: WhisperFileTranscriptionMode {
        didSet {
            defaults.set(
                whisperFileTranscriptionMode.rawValue,
                forKey: Key.whisperFileTranscriptionMode
            )
        }
    }

    @Published var recognitionContext: String {
        didSet { defaults.set(recognitionContext, forKey: Key.recognitionContext) }
    }

    @Published var recognitionVocabulary: String {
        didSet { defaults.set(recognitionVocabulary, forKey: Key.recognitionVocabulary) }
    }

    @Published var recognitionContextEnabled: Bool {
        didSet {
            defaults.set(recognitionContextEnabled, forKey: Key.recognitionContextEnabled)
            if oldValue != recognitionContextEnabled { markRecognitionProfileCustom() }
        }
    }

    @Published var recognitionVocabularyEnabled: Bool {
        didSet {
            defaults.set(recognitionVocabularyEnabled, forKey: Key.recognitionVocabularyEnabled)
            if oldValue != recognitionVocabularyEnabled { markRecognitionProfileCustom() }
        }
    }

    @Published var voiceActivityDetectionMode: VoiceActivityDetectionMode {
        didSet {
            defaults.set(
                voiceActivityDetectionMode.rawValue,
                forKey: Key.voiceActivityDetectionMode
            )
            if oldValue != voiceActivityDetectionMode { markRecognitionProfileCustom() }
        }
    }

    @Published var sileroThreshold: Double {
        didSet {
            defaults.set(sileroThreshold, forKey: Key.sileroThreshold)
            if oldValue != sileroThreshold { markRecognitionProfileCustom() }
        }
    }

    @Published var sileroMinimumSpeechDuration: Double {
        didSet {
            defaults.set(
                sileroMinimumSpeechDuration,
                forKey: Key.sileroMinimumSpeechDuration
            )
            if oldValue != sileroMinimumSpeechDuration { markRecognitionProfileCustom() }
        }
    }

    @Published var voiceEndSilenceDuration: Double {
        didSet {
            defaults.set(voiceEndSilenceDuration, forKey: Key.voiceEndSilenceDuration)
            if oldValue != voiceEndSilenceDuration { markRecognitionProfileCustom() }
        }
    }

    @Published var voicePreRollDuration: Double {
        didSet {
            defaults.set(voicePreRollDuration, forKey: Key.voicePreRollDuration)
            if oldValue != voicePreRollDuration { markRecognitionProfileCustom() }
        }
    }

    @Published var voicePostRollDuration: Double {
        didSet {
            defaults.set(voicePostRollDuration, forKey: Key.voicePostRollDuration)
            if oldValue != voicePostRollDuration { markRecognitionProfileCustom() }
        }
    }

    @Published var hallucinationProtectionEnabled: Bool {
        didSet {
            defaults.set(
                hallucinationProtectionEnabled,
                forKey: Key.hallucinationProtectionEnabled
            )
            if oldValue != hallucinationProtectionEnabled { markRecognitionProfileCustom() }
        }
    }

    @Published var finalTranscriptCleanupEnabled: Bool {
        didSet {
            defaults.set(finalTranscriptCleanupEnabled, forKey: Key.finalTranscriptCleanupEnabled)
            if oldValue != finalTranscriptCleanupEnabled { markRecognitionProfileCustom() }
        }
    }

    @Published var gigaAMRussianCorrectionEnabled: Bool {
        didSet {
            defaults.set(gigaAMRussianCorrectionEnabled, forKey: Key.gigaAMRussianCorrectionEnabled)
            if oldValue != gigaAMRussianCorrectionEnabled { markRecognitionProfileCustom() }
        }
    }

    @Published var gigaAMPreferredChunkDuration: Double {
        didSet { defaults.set(gigaAMPreferredChunkDuration, forKey: Key.gigaAMPreferredChunkDuration) }
    }

    @Published var gigaAMMaximumChunkDuration: Double {
        didSet { defaults.set(gigaAMMaximumChunkDuration, forKey: Key.gigaAMMaximumChunkDuration) }
    }

    @Published var gigaAMOverlapDuration: Double {
        didSet { defaults.set(gigaAMOverlapDuration, forKey: Key.gigaAMOverlapDuration) }
    }

    @Published var gigaAMBoundarySearchDuration: Double {
        didSet { defaults.set(gigaAMBoundarySearchDuration, forKey: Key.gigaAMBoundarySearchDuration) }
    }

    @Published var gigaAMRetryCount: Int {
        didSet { defaults.set(gigaAMRetryCount, forKey: Key.gigaAMRetryCount) }
    }

    @Published var gigaAMSplitOnFailure: Bool {
        didSet { defaults.set(gigaAMSplitOnFailure, forKey: Key.gigaAMSplitOnFailure) }
    }

    @Published var gigaAMThreadCount: Int {
        didSet { defaults.set(gigaAMThreadCount, forKey: Key.gigaAMThreadCount) }
    }

    @Published var gigaAMExecutionProvider: GigaAMExecutionProvider {
        didSet { defaults.set(gigaAMExecutionProvider.rawValue, forKey: Key.gigaAMExecutionProvider) }
    }

    @Published var whisperDraftSource: WhisperDraftSource {
        didSet { defaults.set(whisperDraftSource.rawValue, forKey: Key.whisperDraftSource) }
    }

    @Published var whisperDraftModelID: WhisperModelID {
        didSet { defaults.set(whisperDraftModelID.rawValue, forKey: Key.whisperDraftModelID) }
    }

    @Published var whisperDraftChunkDuration: Double {
        didSet { defaults.set(whisperDraftChunkDuration, forKey: Key.whisperDraftChunkDuration) }
    }

    @Published var gigaAMDraftSource: GigaAMDraftSource {
        didSet { defaults.set(gigaAMDraftSource.rawValue, forKey: Key.gigaAMDraftSource) }
    }

    @Published var gigaAMDraftModelID: GigaAMModelID {
        didSet { defaults.set(gigaAMDraftModelID.rawValue, forKey: Key.gigaAMDraftModelID) }
    }

    @Published var gigaAMDraftChunkDuration: Double {
        didSet { defaults.set(gigaAMDraftChunkDuration, forKey: Key.gigaAMDraftChunkDuration) }
    }

    @Published var appleSpeechLanguageIdentifier: String {
        didSet { defaults.set(appleSpeechLanguageIdentifier, forKey: Key.appleSpeechLanguageIdentifier) }
    }

    @Published var whisperLanguageCode: String {
        didSet { defaults.set(whisperLanguageCode, forKey: Key.whisperLanguageCode) }
    }

    @Published var hotKeyPreset: HotKeyPreset {
        didSet { defaults.set(hotKeyPreset.rawValue, forKey: Key.hotKeyPreset) }
    }

    @Published var hotKeyReleaseTailEnabled: Bool {
        didSet { defaults.set(hotKeyReleaseTailEnabled, forKey: Key.hotKeyReleaseTailEnabled) }
    }

    @Published var hotKeyReleaseTailDuration: Double {
        didSet { defaults.set(hotKeyReleaseTailDuration, forKey: Key.hotKeyReleaseTailDuration) }
    }

    @Published var includeAudioCapturedWhilePreparing: Bool {
        didSet {
            defaults.set(
                includeAudioCapturedWhilePreparing,
                forKey: Key.includeAudioCapturedWhilePreparing
            )
        }
    }

    @Published var showFullTranscriptAutomatically: Bool {
        didSet { defaults.set(showFullTranscriptAutomatically, forKey: Key.showFullTranscriptAutomatically) }
    }

    @Published var panelSizePreset: PanelSizePreset {
        didSet { defaults.set(panelSizePreset.rawValue, forKey: Key.panelSizePreset) }
    }

    @Published var panelPositionPreset: PanelPositionPreset {
        didSet { defaults.set(panelPositionPreset.rawValue, forKey: Key.panelPositionPreset) }
    }

    @Published var panelAlwaysOnTop: Bool {
        didSet { defaults.set(panelAlwaysOnTop, forKey: Key.panelAlwaysOnTop) }
    }

    @Published var panelBackgroundIsTransparent: Bool {
        didSet {
            defaults.set(panelBackgroundIsTransparent, forKey: Key.panelBackgroundIsTransparent)
        }
    }

    @Published var panelBackgroundBlurEnabled: Bool {
        didSet { defaults.set(panelBackgroundBlurEnabled, forKey: Key.panelBackgroundBlurEnabled) }
    }

    @Published var windowAppearanceMode: AppearanceMode {
        didSet {
            defaults.set(windowAppearanceMode.rawValue, forKey: Key.windowAppearanceMode)
        }
    }

    @Published var panelAppearanceMode: AppearanceMode {
        didSet {
            defaults.set(panelAppearanceMode.rawValue, forKey: Key.panelAppearanceMode)
        }
    }

    @Published var hotKeyCompletionBehavior: HotKeyCompletionBehavior {
        didSet { defaults.set(hotKeyCompletionBehavior.rawValue, forKey: Key.hotKeyCompletionBehavior) }
    }

    @Published var menuCompletionBehavior: MenuCompletionBehavior {
        didSet { defaults.set(menuCompletionBehavior.rawValue, forKey: Key.menuCompletionBehavior) }
    }

    @Published var historyRetentionPreset: HistoryRetentionPreset {
        didSet { defaults.set(historyRetentionPreset.rawValue, forKey: Key.historyRetentionPreset) }
    }

    @Published var historyStorageMode: HistoryStorageMode {
        didSet { defaults.set(historyStorageMode.rawValue, forKey: Key.historyStorageMode) }
    }

    @Published var debugAudioRecordingEnabled: Bool {
        didSet { defaults.set(debugAudioRecordingEnabled, forKey: Key.debugAudioRecordingEnabled) }
    }

    @Published var vadPreset: VADPreset {
        didSet {
            defaults.set(vadPreset.rawValue, forKey: Key.vadPreset)
            if oldValue != vadPreset { markMicrophoneEnvironmentCustom() }
        }
    }

    @Published var adaptiveVAD: Bool {
        didSet {
            defaults.set(adaptiveVAD, forKey: Key.adaptiveVAD)
            if oldValue != adaptiveVAD { markMicrophoneEnvironmentCustom() }
        }
    }

    @Published var manualThresholdDB: Double {
        didSet {
            defaults.set(manualThresholdDB, forKey: Key.manualThresholdDB)
            if oldValue != manualThresholdDB { markMicrophoneEnvironmentCustom() }
        }
    }

    @Published var suppressDetectedSilence: Bool {
        didSet { defaults.set(suppressDetectedSilence, forKey: Key.suppressDetectedSilence) }
    }

    /// Zero means "follow the current system input device".
    @Published var selectedInputDeviceID: UInt32 {
        didSet { defaults.set(Int(selectedInputDeviceID), forKey: Key.selectedInputDeviceID) }
    }

    @Published var pendingFeedbackStyle: PendingFeedbackStyle {
        didSet { defaults.set(pendingFeedbackStyle.rawValue, forKey: Key.pendingFeedbackStyle) }
    }

    var usesConfiguredLiveDraft: Bool {
        switch recognitionBackend {
        case .appleSpeech:
            return true
        case .whisper:
            return effectiveWhisperDraftSource != .none
        case .gigaAM:
            return effectiveGigaAMDraftSource != .none
        case .qwen3ASR, .parakeet:
            return effectiveLocalONNXDraftSource != .none
        }
    }

    var usesAppleSpeechForLiveDraft: Bool {
        switch recognitionBackend {
        case .appleSpeech:
            return true
        case .whisper:
            return effectiveWhisperDraftSource == .appleSpeech
        case .gigaAM:
            return effectiveGigaAMDraftSource == .appleSpeech
        case .qwen3ASR, .parakeet:
            return effectiveLocalONNXDraftSource == .appleSpeech
        }
    }

    var liveDraftEnabledForCurrentProfile: Bool {
        get {
            let key = Self.liveDraftPreferenceKey(for: recognitionProfile)
            return defaults.object(forKey: key) as? Bool ?? true
        }
        set {
            objectWillChange.send()
            defaults.set(
                newValue,
                forKey: Self.liveDraftPreferenceKey(for: recognitionProfile)
            )
        }
    }

    var effectiveWhisperDraftSource: WhisperDraftSource {
        guard liveDraftEnabledForCurrentProfile else { return .none }
        return whisperDraftSource == .none ? .appleSpeech : whisperDraftSource
    }

    var effectiveGigaAMDraftSource: GigaAMDraftSource {
        guard liveDraftEnabledForCurrentProfile else { return .none }
        return gigaAMDraftSource == .none ? .appleSpeech : gigaAMDraftSource
    }

    var effectiveLocalONNXDraftSource: LocalASRDraftSource {
        guard liveDraftEnabledForCurrentProfile else { return .none }
        return .appleSpeech
    }

    var effectivePendingFeedbackStyle: PendingFeedbackStyle {
        usesAppleSpeechForLiveDraft ? .pulse : pendingFeedbackStyle
    }

    var activeLanguageIdentifier: String {
        switch recognitionBackend {
        case .appleSpeech: return appleSpeechLanguageIdentifier
        case .whisper: return whisperLanguageCode
        case .gigaAM: return "ru-RU"
        case .qwen3ASR, .parakeet: return "auto"
        }
    }

    init(defaults: UserDefaults = .standard) {
        if defaults === UserDefaults.standard {
            Self.migrateLegacyPreferencesIfNeeded(into: defaults)
        }
        self.defaults = defaults

        recognitionBackend =
            RecognitionBackend(
                rawValue: defaults.string(forKey: Key.recognitionBackend) ?? ""
            ) ?? .appleSpeech
        let resolvedRecognitionProfile =
            RecognitionProfileID(
                rawValue: defaults.string(forKey: Key.recognitionProfile) ?? ""
            ) ?? .recommended
        recognitionProfile = resolvedRecognitionProfile
        let storedCustomBase = RecognitionProfileID(
            rawValue: defaults.string(forKey: Key.customRecognitionBaseProfile) ?? ""
        )
        let resolvedCustomRecognitionBaseProfile =
            storedCustomBase?.isBuiltIn == true ? storedCustomBase! : .recommended
        customRecognitionBaseProfile = resolvedCustomRecognitionBaseProfile
        savedRecognitionPresets = Self.loadSavedRecognitionPresets(from: defaults)
        microphoneEnvironmentProfile =
            MicrophoneEnvironmentProfileID(
                rawValue: defaults.string(forKey: Key.microphoneEnvironmentProfile) ?? ""
            ) ?? .balanced
        whisperModelID =
            WhisperModelID(
                rawValue: defaults.string(forKey: Key.whisperModelID) ?? ""
            ) ?? .base
        gigaAMModelID =
            GigaAMModelID(
                rawValue: defaults.string(forKey: Key.gigaAMModelID) ?? ""
            ) ?? .v3E2ERNNT
        let storedQwen3ASRModel = LocalONNXModelID(
            rawValue: defaults.string(forKey: Key.qwen3ASRModelID) ?? ""
        )
        qwen3ASRModelID =
            storedQwen3ASRModel.flatMap { model in
                model.family == .qwen3ASR ? model : nil
            } ?? .qwen3ASR06BInt8
        localONNXDraftSource =
            LocalASRDraftSource(
                rawValue: defaults.string(forKey: Key.localONNXDraftSource) ?? ""
            ) ?? .appleSpeech
        localONNXPreferredChunkDuration =
            defaults.object(forKey: Key.localONNXPreferredChunkDuration) as? Double ?? 15
        localONNXMaximumChunkDuration =
            defaults.object(forKey: Key.localONNXMaximumChunkDuration) as? Double ?? 20
        localONNXOverlapDuration =
            defaults.object(forKey: Key.localONNXOverlapDuration) as? Double ?? 0.4
        localONNXBoundarySearchDuration =
            defaults.object(forKey: Key.localONNXBoundarySearchDuration) as? Double ?? 2
        localONNXRetryCount = defaults.object(forKey: Key.localONNXRetryCount) as? Int ?? 1
        localONNXSplitOnFailure = defaults.object(forKey: Key.localONNXSplitOnFailure) as? Bool ?? true
        localONNXThreadCount =
            defaults.object(forKey: Key.localONNXThreadCount) as? Int
            ?? max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        localONNXExecutionProvider =
            LocalONNXExecutionProvider(
                rawValue: defaults.string(forKey: Key.localONNXExecutionProvider) ?? ""
            ) ?? .cpu
        appleSpeechAddsPunctuation = defaults.object(forKey: Key.appleSpeechAddsPunctuation) as? Bool ?? true
        appleSpeechOnDeviceOnly = defaults.object(forKey: Key.appleSpeechOnDeviceOnly) as? Bool ?? true
        appleSpeechContextualPhrases = defaults.string(forKey: Key.appleSpeechContextualPhrases) ?? ""
        whisperChunkDuration = defaults.object(forKey: Key.whisperChunkDuration) as? Double ?? 5
        if let storedPauseBalancing =
            defaults.object(forKey: Key.pauseBalancedChunkingEnabled) as? Bool
        {
            pauseBalancedChunkingEnabled = storedPauseBalancing
        } else {
            let migratedPauseBalancing =
                defaults.string(forKey: Key.legacyWhisperChunkSchedulingMode)
                == "deferredPauseBalanced"
            pauseBalancedChunkingEnabled = migratedPauseBalancing
            defaults.set(
                migratedPauseBalancing,
                forKey: Key.pauseBalancedChunkingEnabled
            )
        }
        whisperOverlapDuration = defaults.object(forKey: Key.whisperOverlapDuration) as? Double ?? 0.3
        whisperThreadCount =
            defaults.object(forKey: Key.whisperThreadCount) as? Int
            ?? max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        whisperComputeMode =
            WhisperComputeMode(
                rawValue: defaults.string(forKey: Key.whisperComputeMode) ?? ""
            ) ?? .metal
        whisperFlashAttention =
            defaults.object(forKey: Key.whisperFlashAttention) as? Bool ?? true
        whisperCustomDecodingEnabled =
            defaults.object(forKey: Key.whisperCustomDecodingEnabled) as? Bool ?? false
        whisperDecodingStrategy =
            WhisperDecodingStrategy(
                rawValue: defaults.string(forKey: Key.whisperDecodingStrategy) ?? ""
            ) ?? .greedy
        whisperGreedyBestOf =
            defaults.object(forKey: Key.whisperGreedyBestOf) as? Int ?? 5
        whisperBeamSize = defaults.object(forKey: Key.whisperBeamSize) as? Int ?? 5
        whisperInitialPrompt = defaults.string(forKey: Key.whisperInitialPrompt) ?? ""
        let selectedBuiltInProfile =
            resolvedRecognitionProfile.isBuiltIn
            ? resolvedRecognitionProfile : resolvedCustomRecognitionBaseProfile
        let profileBoundaryStrategy =
            RecognitionTuningValues.preset(for: selectedBuiltInProfile)?.whisperBoundaryStrategy
            ?? .standard
        whisperBoundaryStrategy = WhisperBoundarySettingsMigration.resolveBoundaryStrategy(
            newRawValue: defaults.string(forKey: Key.whisperBoundaryStrategy),
            legacyCarryContext: defaults.object(forKey: Key.whisperCarryContext) as? Bool,
            profileDefault: profileBoundaryStrategy
        )
        whisperFileTranscriptionMode =
            WhisperFileTranscriptionMode(
                rawValue: defaults.string(forKey: Key.whisperFileTranscriptionMode) ?? ""
            ) ?? .profileVAD
        recognitionContext =
            defaults.string(forKey: Key.recognitionContext)
            ?? defaults.string(forKey: Key.whisperInitialPrompt)
            ?? ""
        recognitionVocabulary =
            defaults.string(forKey: Key.recognitionVocabulary) ?? ""
        recognitionContextEnabled =
            defaults.object(forKey: Key.recognitionContextEnabled) as? Bool ?? true
        recognitionVocabularyEnabled =
            defaults.object(forKey: Key.recognitionVocabularyEnabled) as? Bool ?? true
        voiceActivityDetectionMode =
            VoiceActivityDetectionMode(
                rawValue: defaults.string(forKey: Key.voiceActivityDetectionMode) ?? ""
            ) ?? .energy
        sileroThreshold = defaults.object(forKey: Key.sileroThreshold) as? Double ?? 0.5
        sileroMinimumSpeechDuration =
            defaults.object(forKey: Key.sileroMinimumSpeechDuration) as? Double ?? 0.10
        voiceEndSilenceDuration =
            defaults.object(forKey: Key.voiceEndSilenceDuration) as? Double ?? 0.65
        voicePreRollDuration =
            defaults.object(forKey: Key.voicePreRollDuration) as? Double ?? 0.25
        voicePostRollDuration =
            defaults.object(forKey: Key.voicePostRollDuration) as? Double ?? 0.15
        hallucinationProtectionEnabled =
            defaults.object(forKey: Key.hallucinationProtectionEnabled) as? Bool ?? false
        finalTranscriptCleanupEnabled =
            defaults.object(forKey: Key.finalTranscriptCleanupEnabled) as? Bool ?? false
        gigaAMRussianCorrectionEnabled =
            defaults.object(forKey: Key.gigaAMRussianCorrectionEnabled) as? Bool ?? false
        gigaAMPreferredChunkDuration = defaults.object(forKey: Key.gigaAMPreferredChunkDuration) as? Double ?? 18
        gigaAMMaximumChunkDuration = defaults.object(forKey: Key.gigaAMMaximumChunkDuration) as? Double ?? 20
        gigaAMOverlapDuration = defaults.object(forKey: Key.gigaAMOverlapDuration) as? Double ?? 0.4
        gigaAMBoundarySearchDuration = defaults.object(forKey: Key.gigaAMBoundarySearchDuration) as? Double ?? 2
        gigaAMRetryCount = defaults.object(forKey: Key.gigaAMRetryCount) as? Int ?? 1
        gigaAMSplitOnFailure = defaults.object(forKey: Key.gigaAMSplitOnFailure) as? Bool ?? true
        gigaAMThreadCount =
            defaults.object(forKey: Key.gigaAMThreadCount) as? Int
            ?? max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        gigaAMExecutionProvider =
            GigaAMExecutionProvider(
                rawValue: defaults.string(forKey: Key.gigaAMExecutionProvider) ?? ""
            ) ?? .cpu
        let legacyWhisperUseAppleDraft = defaults.object(forKey: Key.legacyWhisperUseAppleDraft) as? Bool ?? true
        whisperDraftSource =
            WhisperDraftSource(
                rawValue: defaults.string(forKey: Key.whisperDraftSource) ?? ""
            ) ?? (legacyWhisperUseAppleDraft ? .appleSpeech : .none)
        whisperDraftModelID =
            WhisperModelID(
                rawValue: defaults.string(forKey: Key.whisperDraftModelID) ?? ""
            ) ?? .tiny
        whisperDraftChunkDuration = defaults.object(forKey: Key.whisperDraftChunkDuration) as? Double ?? 3

        let legacyGigaAMUseAppleDraft = defaults.object(forKey: Key.legacyGigaAMUseAppleDraft) as? Bool ?? true
        let legacyGigaAMDraft = defaults.string(forKey: Key.legacyGigaAMDraftBackend)
        let migratedGigaAMDraft: GigaAMDraftSource
        switch legacyGigaAMDraft {
        case "whisper":
            migratedGigaAMDraft = .localGigaAM
        case "none":
            migratedGigaAMDraft = .none
        case "appleSpeech":
            migratedGigaAMDraft = .appleSpeech
        default:
            migratedGigaAMDraft = legacyGigaAMUseAppleDraft ? .appleSpeech : .none
        }
        gigaAMDraftSource =
            GigaAMDraftSource(
                rawValue: defaults.string(forKey: Key.gigaAMDraftSource) ?? ""
            ) ?? migratedGigaAMDraft
        gigaAMDraftModelID =
            GigaAMModelID(
                rawValue: defaults.string(forKey: Key.gigaAMDraftModelID) ?? ""
            ) ?? .v3CTC
        gigaAMDraftChunkDuration = defaults.object(forKey: Key.gigaAMDraftChunkDuration) as? Double ?? 5

        let legacyLanguage = defaults.string(forKey: Key.legacyLanguageIdentifier)
        appleSpeechLanguageIdentifier =
            defaults.string(forKey: Key.appleSpeechLanguageIdentifier)
            ?? legacyLanguage
            ?? "ru-RU"
        whisperLanguageCode =
            defaults.string(forKey: Key.whisperLanguageCode)
            ?? legacyLanguage?.split(separator: "-").first.map(String.init)
            ?? "auto"

        hotKeyPreset = HotKeyPreset(rawValue: defaults.string(forKey: Key.hotKeyPreset) ?? "") ?? .controlOptionSpace
        hotKeyReleaseTailEnabled =
            defaults.object(forKey: Key.hotKeyReleaseTailEnabled) as? Bool ?? true
        hotKeyReleaseTailDuration =
            defaults.object(forKey: Key.hotKeyReleaseTailDuration) as? Double
            ?? HotKeyReleaseTailPolicy.defaultDuration
        includeAudioCapturedWhilePreparing =
            defaults.object(forKey: Key.includeAudioCapturedWhilePreparing) as? Bool ?? true
        showFullTranscriptAutomatically = defaults.object(forKey: Key.showFullTranscriptAutomatically) as? Bool ?? false
        panelSizePreset = PanelSizePreset(rawValue: defaults.string(forKey: Key.panelSizePreset) ?? "") ?? .compact
        panelPositionPreset =
            PanelPositionPreset(
                rawValue: defaults.string(forKey: Key.panelPositionPreset) ?? ""
            ) ?? .aboveDock
        panelAlwaysOnTop = defaults.object(forKey: Key.panelAlwaysOnTop) as? Bool ?? false
        panelBackgroundIsTransparent =
            defaults.object(forKey: Key.panelBackgroundIsTransparent) as? Bool ?? true
        panelBackgroundBlurEnabled =
            defaults.object(forKey: Key.panelBackgroundBlurEnabled) as? Bool ?? true
        let legacyAppearanceMode =
            AppearanceMode(
                rawValue: defaults.string(forKey: Key.legacyAppearanceMode) ?? ""
            ) ?? .system
        windowAppearanceMode =
            AppearanceMode(
                rawValue: defaults.string(forKey: Key.windowAppearanceMode) ?? ""
            ) ?? legacyAppearanceMode
        panelAppearanceMode =
            AppearanceMode(
                rawValue: defaults.string(forKey: Key.panelAppearanceMode) ?? ""
            ) ?? legacyAppearanceMode
        hotKeyCompletionBehavior =
            HotKeyCompletionBehavior(
                rawValue: defaults.string(forKey: Key.hotKeyCompletionBehavior) ?? ""
            ) ?? .copyAndClose
        menuCompletionBehavior =
            MenuCompletionBehavior(
                rawValue: defaults.string(forKey: Key.menuCompletionBehavior) ?? ""
            ) ?? .compactResult
        let legacyHistoryRetention = defaults.string(forKey: Key.historyRetentionPreset) ?? ""
        historyRetentionPreset =
            HistoryRetentionPreset(
                rawValue: legacyHistoryRetention
            ) ?? .sevenDays
        historyStorageMode =
            HistoryStorageMode(
                rawValue: defaults.string(forKey: Key.historyStorageMode) ?? ""
            ) ?? (legacyHistoryRetention == "doNotStore" ? .none : .encrypted)
        debugAudioRecordingEnabled =
            defaults.object(forKey: Key.debugAudioRecordingEnabled) as? Bool ?? false
        vadPreset = VADPreset(rawValue: defaults.string(forKey: Key.vadPreset) ?? "") ?? .balanced
        adaptiveVAD = defaults.object(forKey: Key.adaptiveVAD) as? Bool ?? true
        manualThresholdDB = defaults.object(forKey: Key.manualThresholdDB) as? Double ?? -42
        suppressDetectedSilence = defaults.object(forKey: Key.suppressDetectedSilence) as? Bool ?? false
        selectedInputDeviceID = UInt32(max(0, defaults.integer(forKey: Key.selectedInputDeviceID)))
        if let storedStyle = PendingFeedbackStyle(
            rawValue: defaults.string(forKey: Key.pendingFeedbackStyle) ?? ""
        ) {
            pendingFeedbackStyle = storedStyle
        } else {
            let legacyShimmer = defaults.object(forKey: Key.showPendingWordShimmer) as? Bool ?? false
            pendingFeedbackStyle = legacyShimmer ? .blurredWords : .pulse
            defaults.set(pendingFeedbackStyle.rawValue, forKey: Key.pendingFeedbackStyle)
        }

        restoreWhisperCompatibilityDefaultsIfNeeded()
        migrateRecognitionProfilesIfNeeded()
        migrateRecognitionCustomizationIfNeeded()
        reconcileDraftSelections()
    }

    private func restoreWhisperCompatibilityDefaultsIfNeeded() {
        guard !defaults.bool(forKey: Key.whisperCompatibilityDefaultsMigrated) else { return }

        suppressesProfileChangeTracking = true
        defer { suppressesProfileChangeTracking = false }

        // Advanced Whisper settings were introduced after the original release
        // path. Restore the original Metal + whisper.cpp-default decoding path
        // once so existing prerelease preferences do not silently lower quality.
        if whisperComputeMode == .automatic {
            whisperComputeMode = .metal
        }
        if whisperGreedyBestOf == 1 {
            whisperGreedyBestOf = 5
        }
        whisperCustomDecodingEnabled = false
        if abs(voicePreRollDuration - 0.30) < 0.001 {
            voicePreRollDuration = 0.25
        }
        if abs(voicePostRollDuration - 0.20) < 0.001 {
            voicePostRollDuration = 0.15
        }

        defaults.set(true, forKey: Key.whisperCompatibilityDefaultsMigrated)
    }

    private func migrateRecognitionProfilesIfNeeded() {
        guard !defaults.bool(forKey: Key.recognitionProfilesMigrated) else { return }

        suppressesProfileChangeTracking = true
        defer { suppressesProfileChangeTracking = false }

        if defaults.object(forKey: Key.recognitionProfile) == nil {
            let legacyRecognitionKeys = [
                Key.voiceActivityDetectionMode,
                Key.sileroThreshold,
                Key.sileroMinimumSpeechDuration,
                Key.voiceEndSilenceDuration,
                Key.voicePreRollDuration,
                Key.voicePostRollDuration,
                Key.whisperChunkDuration,
                Key.pauseBalancedChunkingEnabled,
                Key.legacyWhisperChunkSchedulingMode,
                Key.whisperOverlapDuration,
                Key.hallucinationProtectionEnabled,
                Key.finalTranscriptCleanupEnabled,
                Key.gigaAMRussianCorrectionEnabled,
                Key.whisperCustomDecodingEnabled,
                Key.whisperCarryContext,
                Key.recognitionContext,
                Key.recognitionVocabulary,
            ]
            let hasLegacyRecognitionPreferences = legacyRecognitionKeys.contains {
                defaults.object(forKey: $0) != nil
            }

            if !hasLegacyRecognitionPreferences {
                customRecognitionBaseProfile = .recommended
                recognitionProfile = .recommended
            } else {
                let classic = RecognitionTuningValues.classic
                let hasCustomRecognitionValues =
                    voiceActivityDetectionMode != classic.voiceActivityDetectionMode
                    || abs(sileroThreshold - classic.sileroThreshold) > 0.0001
                    || abs(sileroMinimumSpeechDuration - classic.sileroMinimumSpeechDuration) > 0.0001
                    || abs(voiceEndSilenceDuration - classic.endOfSpeechSilenceDuration) > 0.0001
                    || abs(voicePreRollDuration - classic.preRollDuration) > 0.0001
                    || abs(voicePostRollDuration - classic.postRollDuration) > 0.0001
                    || abs(whisperChunkDuration - classic.whisperChunkDuration) > 0.0001
                    || pauseBalancedChunkingEnabled != classic.pauseBalancedChunkingEnabled
                    || abs(whisperOverlapDuration - classic.whisperOverlapDuration) > 0.0001
                    || hallucinationProtectionEnabled
                    || finalTranscriptCleanupEnabled
                    || gigaAMRussianCorrectionEnabled
                    || whisperCustomDecodingEnabled
                    || whisperBoundaryStrategy != .standard
                    || !recognitionContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !recognitionVocabulary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                customRecognitionBaseProfile = .classic
                recognitionProfile = hasCustomRecognitionValues ? .custom : .classic
            }
        }

        if defaults.object(forKey: Key.microphoneEnvironmentProfile) == nil {
            if adaptiveVAD {
                switch vadPreset {
                case .sensitive: microphoneEnvironmentProfile = .quiet
                case .balanced: microphoneEnvironmentProfile = .balanced
                case .noiseResistant: microphoneEnvironmentProfile = .noisy
                }
            } else {
                microphoneEnvironmentProfile = .custom
            }
        }

        defaults.set(true, forKey: Key.recognitionProfilesMigrated)
    }

    private func migrateRecognitionCustomizationIfNeeded() {
        guard !defaults.bool(forKey: Key.recognitionCustomizationMigrated) else { return }

        if defaults.object(forKey: Key.customRecognitionBaseProfile) == nil {
            customRecognitionBaseProfile =
                recognitionProfile == .custom
                ? RecognitionTuningValues.closestBuiltInProfile(to: customRecognitionTuning)
                : recognitionProfile
        }
        defaults.set(true, forKey: Key.recognitionCustomizationMigrated)
    }

    private func markRecognitionProfileCustom() {
        guard !suppressesProfileChangeTracking, recognitionProfile != .custom else { return }
        if recognitionProfile.isBuiltIn {
            customRecognitionBaseProfile = recognitionProfile
        }
        recognitionProfile = .custom
    }

    private func markMicrophoneEnvironmentCustom() {
        guard !suppressesProfileChangeTracking, microphoneEnvironmentProfile != .custom else { return }
        microphoneEnvironmentProfile = .custom
    }

    func restoreOriginalWhisperBehavior() {
        suppressesProfileChangeTracking = true
        whisperComputeMode = .metal
        whisperFlashAttention = true
        whisperCustomDecodingEnabled = false
        whisperDecodingStrategy = .greedy
        whisperGreedyBestOf = 5
        whisperBeamSize = 5
        whisperBoundaryStrategy = .standard
        suppressesProfileChangeTracking = false
        recognitionProfile = .classic
    }

    func beginCustomizingMicrophoneEnvironment() {
        let configuration = effectiveRecognitionConfiguration.voiceActivityConfiguration
        suppressesProfileChangeTracking = true
        switch microphoneEnvironmentProfile {
        case .quiet:
            vadPreset = .sensitive
        case .balanced:
            vadPreset = .balanced
        case .noisy:
            vadPreset = .noiseResistant
        case .custom:
            break
        }
        adaptiveVAD = configuration.adaptiveThreshold
        if let manualThresholdDB = configuration.manualThresholdDB {
            self.manualThresholdDB = Double(manualThresholdDB)
        }
        suppressesProfileChangeTracking = false
        microphoneEnvironmentProfile = .custom
    }

    func beginCustomizingRecognitionProfile() {
        let sourceProfile =
            recognitionProfile.isBuiltIn
            ? recognitionProfile : customRecognitionBaseProfile
        let tuning = effectiveRecognitionConfiguration.tuning
        suppressesProfileChangeTracking = true
        customRecognitionBaseProfile = sourceProfile
        applyCustomRecognitionTuning(tuning)
        suppressesProfileChangeTracking = false
        recognitionProfile = .custom
    }

    var recognitionProfileBase: RecognitionProfileID {
        recognitionProfile == .custom ? customRecognitionBaseProfile : recognitionProfile
    }

    var recognitionOverrideFields: Set<RecognitionTuningField> {
        guard recognitionProfile == .custom,
            let base = RecognitionTuningValues.preset(for: customRecognitionBaseProfile)
        else {
            return []
        }
        return customRecognitionTuning.fieldsDiffering(from: base)
    }

    func resetRecognitionOverridesToBase() {
        guard let base = RecognitionTuningValues.preset(for: customRecognitionBaseProfile) else { return }
        suppressesProfileChangeTracking = true
        applyCustomRecognitionTuning(base)
        recognitionProfile = customRecognitionBaseProfile
        suppressesProfileChangeTracking = false
    }

    func resetRecognitionOverride(_ field: RecognitionTuningField) {
        guard let base = RecognitionTuningValues.preset(for: customRecognitionBaseProfile) else { return }
        suppressesProfileChangeTracking = true
        switch field {
        case .voiceActivityDetectionMode:
            voiceActivityDetectionMode = base.voiceActivityDetectionMode
        case .sileroThreshold:
            sileroThreshold = base.sileroThreshold
        case .sileroMinimumSpeechDuration:
            sileroMinimumSpeechDuration = base.sileroMinimumSpeechDuration
        case .endOfSpeechSilenceDuration:
            voiceEndSilenceDuration = base.endOfSpeechSilenceDuration
        case .preRollDuration:
            voicePreRollDuration = base.preRollDuration
        case .postRollDuration:
            voicePostRollDuration = base.postRollDuration
        case .whisperChunkDuration:
            whisperChunkDuration = base.whisperChunkDuration
        case .pauseBalancedChunkingEnabled:
            pauseBalancedChunkingEnabled = base.pauseBalancedChunkingEnabled
        case .whisperOverlapDuration:
            whisperOverlapDuration = base.whisperOverlapDuration
        case .usesRecognitionContext:
            recognitionContextEnabled = base.usesRecognitionContext
        case .usesRecognitionVocabulary:
            recognitionVocabularyEnabled = base.usesRecognitionVocabulary
        case .hallucinationProtectionEnabled:
            hallucinationProtectionEnabled = base.hallucinationProtectionEnabled
        case .finalTranscriptCleanupEnabled:
            finalTranscriptCleanupEnabled = base.finalTranscriptCleanupEnabled
        case .gigaAMRussianCorrectionEnabled:
            gigaAMRussianCorrectionEnabled = base.gigaAMRussianCorrectionEnabled
        case .whisperCustomDecodingEnabled:
            whisperCustomDecodingEnabled = base.whisperCustomDecodingEnabled
        case .whisperBoundaryStrategy:
            whisperBoundaryStrategy = base.whisperBoundaryStrategy
        }
        suppressesProfileChangeTracking = false
    }

    @discardableResult
    func saveCurrentRecognitionPreset(named rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard recognitionProfile == .custom, !name.isEmpty else { return false }

        let preset = SavedRecognitionPreset(
            name: name,
            basedOn: customRecognitionBaseProfile,
            tuning: customRecognitionTuning
        )
        if let index = savedRecognitionPresets.firstIndex(where: {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            var replacement = preset
            replacement = SavedRecognitionPreset(
                id: savedRecognitionPresets[index].id,
                name: name,
                basedOn: preset.basedOn,
                tuning: preset.tuning
            )
            savedRecognitionPresets[index] = replacement
        } else {
            savedRecognitionPresets.append(preset)
            savedRecognitionPresets.sort {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        return true
    }

    func applyRecognitionPreset(_ preset: SavedRecognitionPreset) {
        suppressesProfileChangeTracking = true
        customRecognitionBaseProfile = preset.basedOn.isBuiltIn ? preset.basedOn : .recommended
        applyCustomRecognitionTuning(preset.tuning)
        suppressesProfileChangeTracking = false
        recognitionProfile = .custom
    }

    func deleteRecognitionPreset(id: UUID) {
        savedRecognitionPresets.removeAll { $0.id == id }
    }

    private func applyCustomRecognitionTuning(_ tuning: RecognitionTuningValues) {
        voiceActivityDetectionMode = tuning.voiceActivityDetectionMode
        sileroThreshold = tuning.sileroThreshold
        sileroMinimumSpeechDuration = tuning.sileroMinimumSpeechDuration
        voiceEndSilenceDuration = tuning.endOfSpeechSilenceDuration
        voicePreRollDuration = tuning.preRollDuration
        voicePostRollDuration = tuning.postRollDuration
        whisperChunkDuration = tuning.whisperChunkDuration
        pauseBalancedChunkingEnabled = tuning.pauseBalancedChunkingEnabled
        whisperOverlapDuration = tuning.whisperOverlapDuration
        recognitionContextEnabled = tuning.usesRecognitionContext
        recognitionVocabularyEnabled = tuning.usesRecognitionVocabulary
        hallucinationProtectionEnabled = tuning.hallucinationProtectionEnabled
        finalTranscriptCleanupEnabled = tuning.finalTranscriptCleanupEnabled
        gigaAMRussianCorrectionEnabled = tuning.gigaAMRussianCorrectionEnabled
        whisperCustomDecodingEnabled = tuning.whisperCustomDecodingEnabled
        whisperBoundaryStrategy = tuning.whisperBoundaryStrategy
    }

    private func persistSavedRecognitionPresets() {
        guard let data = try? JSONEncoder().encode(savedRecognitionPresets) else { return }
        defaults.set(data, forKey: Key.savedRecognitionPresets)
    }

    private static func loadSavedRecognitionPresets(from defaults: UserDefaults) -> [SavedRecognitionPreset] {
        guard let data = defaults.data(forKey: Key.savedRecognitionPresets),
            let presets = try? JSONDecoder().decode([SavedRecognitionPreset].self, from: data)
        else {
            return []
        }
        return presets.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func migrateLegacyPreferencesIfNeeded(into defaults: UserDefaults) {
        guard !defaults.bool(forKey: legacyPreferencesMigrationKey) else { return }

        if let legacyValues = defaults.persistentDomain(forName: legacyPreferencesDomain) {
            for (key, value) in legacyValues where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        defaults.set(true, forKey: legacyPreferencesMigrationKey)
    }

    static func makeIsolatedPerformanceCopy(of source: AppSettings) -> AppSettings {
        let suiteName = "dev.voicepanel.performance-test"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return AppSettings()
        }
        defaults.removePersistentDomain(forName: suiteName)
        let copy = AppSettings(defaults: defaults)
        copy.replacePerformanceConfiguration(from: source)
        return copy
    }

    func replacePerformanceConfiguration(from source: AppSettings) {
        copyPerformanceConfiguration(from: source)
        reconcileDraftSelections()
    }

    private func copyPerformanceConfiguration(from source: AppSettings) {
        suppressesProfileChangeTracking = true
        defer { suppressesProfileChangeTracking = false }

        recognitionBackend = source.recognitionBackend
        microphoneEnvironmentProfile = source.microphoneEnvironmentProfile
        customRecognitionBaseProfile = source.customRecognitionBaseProfile

        whisperModelID = source.whisperModelID
        gigaAMModelID = source.gigaAMModelID
        qwen3ASRModelID = source.qwen3ASRModelID
        appleSpeechOnDeviceOnly = source.appleSpeechOnDeviceOnly
        appleSpeechAddsPunctuation = source.appleSpeechAddsPunctuation
        appleSpeechLanguageIdentifier = source.appleSpeechLanguageIdentifier
        whisperLanguageCode = source.whisperLanguageCode

        whisperThreadCount = source.whisperThreadCount
        whisperComputeMode = source.whisperComputeMode
        whisperFlashAttention = source.whisperFlashAttention
        whisperDecodingStrategy = source.whisperDecodingStrategy
        whisperGreedyBestOf = source.whisperGreedyBestOf
        whisperBeamSize = source.whisperBeamSize
        whisperInitialPrompt = source.whisperInitialPrompt

        gigaAMPreferredChunkDuration = source.gigaAMPreferredChunkDuration
        gigaAMMaximumChunkDuration = source.gigaAMMaximumChunkDuration
        gigaAMOverlapDuration = source.gigaAMOverlapDuration
        gigaAMBoundarySearchDuration = source.gigaAMBoundarySearchDuration
        gigaAMRetryCount = source.gigaAMRetryCount
        gigaAMSplitOnFailure = source.gigaAMSplitOnFailure
        gigaAMThreadCount = source.gigaAMThreadCount
        gigaAMExecutionProvider = source.gigaAMExecutionProvider

        localONNXPreferredChunkDuration = source.localONNXPreferredChunkDuration
        localONNXMaximumChunkDuration = source.localONNXMaximumChunkDuration
        localONNXOverlapDuration = source.localONNXOverlapDuration
        localONNXBoundarySearchDuration = source.localONNXBoundarySearchDuration
        localONNXRetryCount = source.localONNXRetryCount
        localONNXSplitOnFailure = source.localONNXSplitOnFailure
        localONNXThreadCount = source.localONNXThreadCount
        localONNXExecutionProvider = source.localONNXExecutionProvider

        recognitionContext = source.recognitionContext
        recognitionVocabulary = source.recognitionVocabulary
        recognitionContextEnabled = source.recognitionContextEnabled
        recognitionVocabularyEnabled = source.recognitionVocabularyEnabled
        voiceActivityDetectionMode = source.voiceActivityDetectionMode
        sileroThreshold = source.sileroThreshold
        sileroMinimumSpeechDuration = source.sileroMinimumSpeechDuration
        voiceEndSilenceDuration = source.voiceEndSilenceDuration
        voicePreRollDuration = source.voicePreRollDuration
        voicePostRollDuration = source.voicePostRollDuration
        whisperChunkDuration = source.whisperChunkDuration
        pauseBalancedChunkingEnabled = source.pauseBalancedChunkingEnabled
        whisperOverlapDuration = source.whisperOverlapDuration
        hallucinationProtectionEnabled = source.hallucinationProtectionEnabled
        finalTranscriptCleanupEnabled = source.finalTranscriptCleanupEnabled
        gigaAMRussianCorrectionEnabled = source.gigaAMRussianCorrectionEnabled
        whisperCustomDecodingEnabled = source.whisperCustomDecodingEnabled
        whisperBoundaryStrategy = source.whisperBoundaryStrategy
        whisperFileTranscriptionMode = source.whisperFileTranscriptionMode

        vadPreset = source.vadPreset
        adaptiveVAD = source.adaptiveVAD
        manualThresholdDB = source.manualThresholdDB
        selectedInputDeviceID = source.selectedInputDeviceID
        recognitionProfile = source.recognitionProfile
    }

    var whisperRuntimeConfiguration: WhisperRuntimeConfiguration {
        WhisperRuntimeConfiguration(
            requestedComputeMode: whisperComputeMode,
            flashAttention: whisperFlashAttention
        )
    }

    var whisperInferenceConfiguration: WhisperInferenceConfiguration {
        let tuning = effectiveRecognitionConfiguration.tuning
        return WhisperInferenceConfiguration(
            numberOfThreads: whisperThreadCount,
            usesCustomDecoding: tuning.whisperCustomDecodingEnabled,
            decodingStrategy: whisperDecodingStrategy,
            greedyBestOf: whisperGreedyBestOf,
            beamSize: whisperBeamSize,
            initialPrompt: combinedRecognitionPrompt,
            boundaryStrategy: tuning.whisperBoundaryStrategy,
            overlapDuration: tuning.whisperOverlapDuration,
            contextPromptMode: .lexicalOverlapAligned
        )
    }

    var selectedLocalONNXModel: LocalONNXModelID? {
        switch recognitionBackend {
        case .qwen3ASR: return qwen3ASRModelID
        case .parakeet: return .parakeetTDT06BV3Int8
        case .appleSpeech, .whisper, .gigaAM: return nil
        }
    }

    var availableWhisperDraftModels: [WhisperModelID] {
        WhisperModelID.draftChoices(
            for: whisperModelID,
            languageCode: whisperLanguageCode
        )
    }

    var availableGigaAMDraftModels: [GigaAMModelID] {
        GigaAMModelID.draftChoices(for: gigaAMModelID)
    }

    func reconcileDraftSelections() {
        guard !isReconcilingDraftSelections else { return }
        isReconcilingDraftSelections = true
        defer { isReconcilingDraftSelections = false }

        if whisperModelID.isEnglishOnly, whisperLanguageCode != "en" {
            whisperLanguageCode = "en"
        }

        let whisperChoices = availableWhisperDraftModels
        if !whisperChoices.contains(whisperDraftModelID) {
            let replacement = whisperChoices.first ?? .tiny
            if whisperDraftModelID != replacement {
                whisperDraftModelID = replacement
            }
        }
        if whisperChoices.isEmpty,
            whisperDraftSource == .localWhisper
        {
            whisperDraftSource = .appleSpeech
        }

        let gigaChoices = availableGigaAMDraftModels
        if !gigaChoices.contains(gigaAMDraftModelID) {
            let replacement = gigaChoices.first ?? .v3CTC
            if gigaAMDraftModelID != replacement {
                gigaAMDraftModelID = replacement
            }
        }
        if gigaChoices.isEmpty,
            gigaAMDraftSource == .localGigaAM
        {
            gigaAMDraftSource = .appleSpeech
        }
    }

    func makeLocalONNXChunkPolicy() -> OfflineASRChunkPolicy {
        OfflineASRChunkPolicy(
            preferredDuration: localONNXPreferredChunkDuration,
            maximumDuration: localONNXMaximumChunkDuration,
            overlapDuration: localONNXOverlapDuration,
            boundarySearchDuration: localONNXBoundarySearchDuration,
            retryCount: localONNXRetryCount,
            splitOnFailure: localONNXSplitOnFailure
        )
    }

    func makeGigaAMChunkPolicy() -> GigaAMChunkPolicy {
        GigaAMChunkPolicy(
            preferredDuration: gigaAMPreferredChunkDuration,
            maximumDuration: gigaAMMaximumChunkDuration,
            overlapDuration: gigaAMOverlapDuration,
            boundarySearchDuration: gigaAMBoundarySearchDuration,
            retryCount: gigaAMRetryCount,
            splitOnFailure: gigaAMSplitOnFailure
        )
    }

    private var customMicrophoneConfiguration: VoiceActivityDetector.Configuration {
        var configuration: VoiceActivityDetector.Configuration
        switch vadPreset {
        case .sensitive:
            configuration = .sensitive
        case .balanced:
            configuration = .balanced
        case .noiseResistant:
            configuration = .noiseResistant
        }
        configuration.adaptiveThreshold = adaptiveVAD
        configuration.manualThresholdDB = adaptiveVAD ? nil : Float(manualThresholdDB)
        return configuration
    }

    private var customRecognitionTuning: RecognitionTuningValues {
        RecognitionTuningValues(
            voiceActivityDetectionMode: voiceActivityDetectionMode,
            sileroThreshold: sileroThreshold,
            sileroMinimumSpeechDuration: sileroMinimumSpeechDuration,
            endOfSpeechSilenceDuration: voiceEndSilenceDuration,
            preRollDuration: voicePreRollDuration,
            postRollDuration: voicePostRollDuration,
            whisperChunkDuration: whisperChunkDuration,
            whisperOverlapDuration: whisperOverlapDuration,
            pauseBalancedChunkingEnabled: pauseBalancedChunkingEnabled,
            usesRecognitionContext: recognitionContextEnabled,
            usesRecognitionVocabulary: recognitionVocabularyEnabled,
            hallucinationProtectionEnabled: hallucinationProtectionEnabled,
            whisperCustomDecodingEnabled: whisperCustomDecodingEnabled,
            whisperBoundaryStrategy: whisperBoundaryStrategy,
            finalTranscriptCleanupEnabled: finalTranscriptCleanupEnabled,
            gigaAMRussianCorrectionEnabled: gigaAMRussianCorrectionEnabled
        )
    }

    var effectiveRecognitionConfiguration: EffectiveRecognitionConfiguration {
        RecognitionConfigurationResolver.resolve(
            recognitionProfile: recognitionProfile,
            microphoneEnvironmentProfile: microphoneEnvironmentProfile,
            customRecognitionTuning: customRecognitionTuning,
            customMicrophoneConfiguration: customMicrophoneConfiguration
        )
    }

    var effectiveVoiceActivityDetectionMode: VoiceActivityDetectionMode {
        effectiveRecognitionConfiguration.tuning.voiceActivityDetectionMode
    }

    func makeVADConfiguration() -> VoiceActivityDetector.Configuration {
        effectiveRecognitionConfiguration.voiceActivityConfiguration
    }

    var vocabularyTerms: [String] {
        Self.splitVocabularyTerms(recognitionVocabulary)
    }

    var appleSpeechVocabularyTerms: [String] {
        if effectiveRecognitionConfiguration.tuning.usesRecognitionVocabulary,
            !vocabularyTerms.isEmpty
        {
            return vocabularyTerms
        }
        return Self.splitVocabularyTerms(appleSpeechContextualPhrases)
    }

    private static func splitVocabularyTerms(_ value: String) -> [String] {
        value
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var combinedRecognitionPrompt: String {
        let tuning = effectiveRecognitionConfiguration.tuning
        // Whisper has no vocabulary-bias API. Feeding an unrelated term list
        // through `initial_prompt` can dominate a short multilingual chunk and
        // delete audible speech. Apple Speech receives the shared vocabulary
        // separately through its dedicated contextual-phrases mechanism.
        return
            tuning.usesRecognitionContext
            ? recognitionContext.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
    }

    var hallucinationGuardConfiguration: RecognitionHallucinationGuard.Configuration {
        let effective = effectiveRecognitionConfiguration
        let vad = effective.voiceActivityConfiguration
        return .init(
            isEnabled: effective.tuning.hallucinationProtectionEnabled,
            silenceThresholdDB: (vad.manualThresholdDB ?? vad.minimumThresholdDB) - vad.hysteresisDB
        )
    }

    var transcriptPostProcessingConfiguration: TranscriptPostProcessingConfiguration {
        .init(
            isEnabled: effectiveRecognitionConfiguration.tuning.finalTranscriptCleanupEnabled,
            languageCode: finalTranscriptLanguageCode
        )
    }

    var usesGigaAMRussianCorrection: Bool {
        recognitionBackend == .gigaAM
            && effectiveRecognitionConfiguration.tuning.gigaAMRussianCorrectionEnabled
    }

    private var finalTranscriptLanguageCode: String? {
        switch recognitionBackend {
        case .gigaAM:
            return "ru-RU"
        case .appleSpeech:
            return appleSpeechLanguageIdentifier
        case .whisper:
            return whisperLanguageCode == "auto" ? nil : whisperLanguageCode
        case .qwen3ASR, .parakeet:
            return nil
        }
    }

    var sileroRuntimeConfiguration: SileroVADRuntime.Configuration {
        let tuning = effectiveRecognitionConfiguration.tuning
        return .init(
            threshold: Float(min(max(tuning.sileroThreshold, 0.1), 0.9)),
            minimumSpeechDuration: max(0.05, tuning.sileroMinimumSpeechDuration),
            // The shared fusion layer applies the user-facing end-pause
            // duration. Keep Silero's internal release short to avoid adding
            // two independent silence windows.
            minimumSilenceDuration: 0.05,
            maximumSpeechDuration: 30
        )
    }

    func makeRecognitionSegmenterConfiguration() -> AudioSegmenter.Configuration {
        let tuning = effectiveRecognitionConfiguration.tuning
        let base: AudioSegmenter.Configuration
        switch recognitionBackend {
        case .appleSpeech:
            return tunedSegmenterConfiguration(
                overlapDuration: 0.20,
                maximumChunkDuration: 18
            )
        case .whisper:
            let maximumChunkDuration = max(2, min(30, tuning.whisperChunkDuration))
            base = tunedSegmenterConfiguration(
                overlapDuration: max(0, min(2, tuning.whisperOverlapDuration)),
                maximumChunkDuration: maximumChunkDuration,
                minimumChunkDuration: 0.25,
                forcedBoundaryLookbackDuration: min(2, maximumChunkDuration * 0.25)
            )
        case .gigaAM:
            var configuration = makeGigaAMChunkPolicy().segmenterConfiguration(
                maximumDurationLimit: effectiveRecognitionConfiguration.recognitionProfile
                    .defaultGigaAMChunkDuration
            )
            configuration.preRollDuration = tuning.preRollDuration
            configuration.postRollDuration = tuning.postRollDuration
            base = configuration
        case .qwen3ASR, .parakeet:
            var configuration = makeLocalONNXChunkPolicy().segmenterConfiguration()
            configuration.preRollDuration = tuning.preRollDuration
            configuration.postRollDuration = tuning.postRollDuration
            base = configuration
        }
        var limitedBase = base
        let maximumChunkDurationLimit: TimeInterval?
        switch recognitionBackend {
        case .whisper where effectiveWhisperDraftSource == .localWhisper:
            maximumChunkDurationLimit = max(2, min(30, whisperDraftChunkDuration))
        case .gigaAM where effectiveGigaAMDraftSource == .localGigaAM:
            maximumChunkDurationLimit = max(2, min(20, gigaAMDraftChunkDuration))
        case .appleSpeech, .whisper, .gigaAM, .qwen3ASR, .parakeet:
            maximumChunkDurationLimit = nil
        }
        if let maximumChunkDurationLimit,
            maximumChunkDurationLimit.isFinite,
            maximumChunkDurationLimit > 0
        {
            limitedBase.maximumChunkDuration = min(
                limitedBase.maximumChunkDuration,
                maximumChunkDurationLimit
            )
        }
        return limitedBase.applyingPauseBalancedChunking(
            tuning.pauseBalancedChunkingEnabled
        )
    }

    func makeFinalRecognitionSegmenterConfiguration() -> AudioSegmenter.Configuration {
        makeRecognitionSegmenterConfiguration()
    }

    func tunedSegmenterConfiguration(
        overlapDuration: TimeInterval,
        maximumChunkDuration: TimeInterval,
        minimumChunkDuration: TimeInterval = 0.20,
        forcedBoundaryLookbackDuration: TimeInterval = 0,
        forcedBoundaryMode: AudioSegmenter.ForcedBoundaryMode = .immediate,
        deferredBoundaryDecisionDuration: TimeInterval = 0
    ) -> AudioSegmenter.Configuration {
        let tuning = effectiveRecognitionConfiguration.tuning
        return .init(
            preRollDuration: min(max(tuning.preRollDuration, 0), 1),
            postRollDuration: min(max(tuning.postRollDuration, 0), 1),
            overlapDuration: max(0, overlapDuration),
            maximumChunkDuration: max(1, maximumChunkDuration),
            minimumChunkDuration: max(0.05, minimumChunkDuration),
            forcedBoundaryLookbackDuration: max(0, forcedBoundaryLookbackDuration),
            forcedBoundaryMode: forcedBoundaryMode,
            deferredBoundaryDecisionDuration: max(0, deferredBoundaryDecisionDuration)
        )
    }

    func previewThresholdDB(noiseFloorDB: Float) -> Float {
        makeVADConfiguration().threshold(for: noiseFloorDB)
    }
}
