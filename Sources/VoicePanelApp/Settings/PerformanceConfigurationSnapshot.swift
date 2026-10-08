import Foundation
import VoicePanelCore

extension AppSettings {
    fileprivate struct PerformanceConfigurationSnapshot: Codable {
        let schemaVersion: Int
        let recognitionBackend: String
        let recognitionProfile: String
        let customRecognitionBaseProfile: String
        let microphoneEnvironmentProfile: String
        let selectedInputDeviceID: UInt32

        let whisperModelID: String
        let gigaAMModelID: String
        let localONNXModelID: String
        let appleSpeechOnDeviceOnly: Bool
        let appleSpeechAddsPunctuation: Bool
        let appleSpeechLanguageIdentifier: String
        let whisperLanguageCode: String

        let whisperThreadCount: Int
        let whisperComputeMode: String
        let whisperFlashAttention: Bool
        let whisperCustomDecodingEnabled: Bool
        let whisperDecodingStrategy: String
        let whisperGreedyBestOf: Int
        let whisperBeamSize: Int
        let whisperInitialPrompt: String
        let whisperBoundaryStrategy: String
        let whisperFileTranscriptionMode: String

        let gigaAMPreferredChunkDuration: Double
        let gigaAMMaximumChunkDuration: Double
        let gigaAMOverlapDuration: Double
        let gigaAMBoundarySearchDuration: Double
        let gigaAMRetryCount: Int
        let gigaAMSplitOnFailure: Bool
        let gigaAMThreadCount: Int
        let gigaAMExecutionProvider: String

        let localONNXPreferredChunkDuration: Double
        let localONNXMaximumChunkDuration: Double
        let localONNXOverlapDuration: Double
        let localONNXBoundarySearchDuration: Double
        let localONNXRetryCount: Int
        let localONNXSplitOnFailure: Bool
        let localONNXThreadCount: Int
        let localONNXExecutionProvider: String

        let recognitionContext: String
        let recognitionVocabulary: String
        let recognitionContextEnabled: Bool
        let recognitionVocabularyEnabled: Bool
        let voiceActivityDetectionMode: String
        let sileroThreshold: Double
        let sileroMinimumSpeechDuration: Double
        let voiceEndSilenceDuration: Double
        let voicePreRollDuration: Double
        let voicePostRollDuration: Double
        let whisperChunkDuration: Double
        let effectiveRecognitionChunkDuration: Double?
        let whisperOverlapDuration: Double
        let pauseBalancedChunkingEnabled: Bool
        let hallucinationProtectionEnabled: Bool
        let finalTranscriptCleanupEnabled: Bool?
        let gigaAMRussianCorrectionEnabled: Bool?
        let vadPreset: String
        let adaptiveVAD: Bool
        let manualThresholdDB: Double
    }

    func encodedPerformanceConfigurationSnapshot() -> String? {
        let effectiveConfiguration = effectiveRecognitionConfiguration
        let tuning = effectiveConfiguration.tuning
        let vadConfiguration = effectiveConfiguration.voiceActivityConfiguration
        let effectiveVADPreset: VADPreset
        switch microphoneEnvironmentProfile {
        case .quiet:
            effectiveVADPreset = .sensitive
        case .balanced:
            effectiveVADPreset = .balanced
        case .noisy:
            effectiveVADPreset = .noiseResistant
        case .custom:
            effectiveVADPreset = vadPreset
        }

        let snapshot = PerformanceConfigurationSnapshot(
            schemaVersion: 1,
            recognitionBackend: recognitionBackend.rawValue,
            recognitionProfile: recognitionProfile.rawValue,
            customRecognitionBaseProfile: customRecognitionBaseProfile.rawValue,
            microphoneEnvironmentProfile: microphoneEnvironmentProfile.rawValue,
            selectedInputDeviceID: selectedInputDeviceID,
            whisperModelID: whisperModelID.rawValue,
            gigaAMModelID: gigaAMModelID.rawValue,
            localONNXModelID: qwen3ASRModelID.rawValue,
            appleSpeechOnDeviceOnly: appleSpeechOnDeviceOnly,
            appleSpeechAddsPunctuation: appleSpeechAddsPunctuation,
            appleSpeechLanguageIdentifier: appleSpeechLanguageIdentifier,
            whisperLanguageCode: whisperLanguageCode,
            whisperThreadCount: whisperThreadCount,
            whisperComputeMode: whisperComputeMode.rawValue,
            whisperFlashAttention: whisperFlashAttention,
            whisperCustomDecodingEnabled: tuning.whisperCustomDecodingEnabled,
            whisperDecodingStrategy: whisperDecodingStrategy.rawValue,
            whisperGreedyBestOf: whisperGreedyBestOf,
            whisperBeamSize: whisperBeamSize,
            whisperInitialPrompt: whisperInitialPrompt,
            whisperBoundaryStrategy: tuning.whisperBoundaryStrategy.rawValue,
            whisperFileTranscriptionMode: whisperFileTranscriptionMode.rawValue,
            gigaAMPreferredChunkDuration: gigaAMPreferredChunkDuration,
            gigaAMMaximumChunkDuration: gigaAMMaximumChunkDuration,
            gigaAMOverlapDuration: gigaAMOverlapDuration,
            gigaAMBoundarySearchDuration: gigaAMBoundarySearchDuration,
            gigaAMRetryCount: gigaAMRetryCount,
            gigaAMSplitOnFailure: gigaAMSplitOnFailure,
            gigaAMThreadCount: gigaAMThreadCount,
            gigaAMExecutionProvider: gigaAMExecutionProvider.rawValue,
            localONNXPreferredChunkDuration: localONNXPreferredChunkDuration,
            localONNXMaximumChunkDuration: localONNXMaximumChunkDuration,
            localONNXOverlapDuration: localONNXOverlapDuration,
            localONNXBoundarySearchDuration: localONNXBoundarySearchDuration,
            localONNXRetryCount: localONNXRetryCount,
            localONNXSplitOnFailure: localONNXSplitOnFailure,
            localONNXThreadCount: localONNXThreadCount,
            localONNXExecutionProvider: localONNXExecutionProvider.rawValue,
            recognitionContext: recognitionContext,
            recognitionVocabulary: recognitionVocabulary,
            recognitionContextEnabled: tuning.usesRecognitionContext,
            recognitionVocabularyEnabled: tuning.usesRecognitionVocabulary,
            voiceActivityDetectionMode: tuning.voiceActivityDetectionMode.rawValue,
            sileroThreshold: tuning.sileroThreshold,
            sileroMinimumSpeechDuration: tuning.sileroMinimumSpeechDuration,
            voiceEndSilenceDuration: tuning.endOfSpeechSilenceDuration,
            voicePreRollDuration: tuning.preRollDuration,
            voicePostRollDuration: tuning.postRollDuration,
            whisperChunkDuration: tuning.whisperChunkDuration,
            effectiveRecognitionChunkDuration: makeRecognitionSegmenterConfiguration()
                .maximumChunkDuration,
            whisperOverlapDuration: tuning.whisperOverlapDuration,
            pauseBalancedChunkingEnabled: tuning.pauseBalancedChunkingEnabled,
            hallucinationProtectionEnabled: tuning.hallucinationProtectionEnabled,
            finalTranscriptCleanupEnabled: tuning.finalTranscriptCleanupEnabled,
            gigaAMRussianCorrectionEnabled: tuning.gigaAMRussianCorrectionEnabled,
            vadPreset: effectiveVADPreset.rawValue,
            adaptiveVAD: vadConfiguration.adaptiveThreshold,
            manualThresholdDB: vadConfiguration.manualThresholdDB.map(Double.init)
                ?? manualThresholdDB
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func applyPerformanceConfigurationSnapshot(_ encodedSnapshot: String) -> Bool {
        guard let data = encodedSnapshot.data(using: .utf8),
            let snapshot = try? JSONDecoder().decode(
                PerformanceConfigurationSnapshot.self,
                from: data
            ),
            snapshot.schemaVersion == 1,
            let recognitionBackend = RecognitionBackend(rawValue: snapshot.recognitionBackend),
            let recognitionProfile = RecognitionProfileID(rawValue: snapshot.recognitionProfile),
            let customRecognitionBaseProfile = RecognitionProfileID(
                rawValue: snapshot.customRecognitionBaseProfile
            ),
            let microphoneEnvironmentProfile = MicrophoneEnvironmentProfileID(
                rawValue: snapshot.microphoneEnvironmentProfile
            ),
            let whisperModelID = WhisperModelID(rawValue: snapshot.whisperModelID),
            let gigaAMModelID = GigaAMModelID(rawValue: snapshot.gigaAMModelID),
            let localONNXModelID = LocalONNXModelID(rawValue: snapshot.localONNXModelID),
            let whisperComputeMode = WhisperComputeMode(rawValue: snapshot.whisperComputeMode),
            let whisperDecodingStrategy = WhisperDecodingStrategy(
                rawValue: snapshot.whisperDecodingStrategy
            ),
            let whisperBoundaryStrategy = WhisperBoundaryStrategy(
                rawValue: snapshot.whisperBoundaryStrategy
            ),
            let whisperFileTranscriptionMode = WhisperFileTranscriptionMode(
                rawValue: snapshot.whisperFileTranscriptionMode
            ),
            let gigaAMExecutionProvider = GigaAMExecutionProvider(
                rawValue: snapshot.gigaAMExecutionProvider
            ),
            let localONNXExecutionProvider = LocalONNXExecutionProvider(
                rawValue: snapshot.localONNXExecutionProvider
            ),
            let voiceActivityDetectionMode = VoiceActivityDetectionMode(
                rawValue: snapshot.voiceActivityDetectionMode
            ),
            let vadPreset = VADPreset(rawValue: snapshot.vadPreset)
        else {
            return false
        }

        self.recognitionBackend = recognitionBackend
        self.selectedInputDeviceID = snapshot.selectedInputDeviceID

        self.whisperModelID = whisperModelID
        self.gigaAMModelID = gigaAMModelID
        self.qwen3ASRModelID = localONNXModelID
        self.appleSpeechOnDeviceOnly = snapshot.appleSpeechOnDeviceOnly
        self.appleSpeechAddsPunctuation = snapshot.appleSpeechAddsPunctuation
        self.appleSpeechLanguageIdentifier = snapshot.appleSpeechLanguageIdentifier
        self.whisperLanguageCode = snapshot.whisperLanguageCode

        self.whisperThreadCount = snapshot.whisperThreadCount
        self.whisperComputeMode = whisperComputeMode
        self.whisperFlashAttention = snapshot.whisperFlashAttention
        self.whisperCustomDecodingEnabled = snapshot.whisperCustomDecodingEnabled
        self.whisperDecodingStrategy = whisperDecodingStrategy
        self.whisperGreedyBestOf = snapshot.whisperGreedyBestOf
        self.whisperBeamSize = snapshot.whisperBeamSize
        self.whisperInitialPrompt = snapshot.whisperInitialPrompt
        self.whisperBoundaryStrategy = whisperBoundaryStrategy
        self.whisperFileTranscriptionMode = whisperFileTranscriptionMode

        self.gigaAMPreferredChunkDuration = snapshot.gigaAMPreferredChunkDuration
        self.gigaAMMaximumChunkDuration = snapshot.gigaAMMaximumChunkDuration
        self.gigaAMOverlapDuration = snapshot.gigaAMOverlapDuration
        self.gigaAMBoundarySearchDuration = snapshot.gigaAMBoundarySearchDuration
        self.gigaAMRetryCount = snapshot.gigaAMRetryCount
        self.gigaAMSplitOnFailure = snapshot.gigaAMSplitOnFailure
        self.gigaAMThreadCount = snapshot.gigaAMThreadCount
        self.gigaAMExecutionProvider = gigaAMExecutionProvider

        self.localONNXPreferredChunkDuration = snapshot.localONNXPreferredChunkDuration
        self.localONNXMaximumChunkDuration = snapshot.localONNXMaximumChunkDuration
        self.localONNXOverlapDuration = snapshot.localONNXOverlapDuration
        self.localONNXBoundarySearchDuration = snapshot.localONNXBoundarySearchDuration
        self.localONNXRetryCount = snapshot.localONNXRetryCount
        self.localONNXSplitOnFailure = snapshot.localONNXSplitOnFailure
        self.localONNXThreadCount = snapshot.localONNXThreadCount
        self.localONNXExecutionProvider = localONNXExecutionProvider

        self.recognitionContext = snapshot.recognitionContext
        self.recognitionVocabulary = snapshot.recognitionVocabulary
        self.recognitionContextEnabled = snapshot.recognitionContextEnabled
        self.recognitionVocabularyEnabled = snapshot.recognitionVocabularyEnabled
        self.voiceActivityDetectionMode = voiceActivityDetectionMode
        self.sileroThreshold = snapshot.sileroThreshold
        self.sileroMinimumSpeechDuration = snapshot.sileroMinimumSpeechDuration
        self.voiceEndSilenceDuration = snapshot.voiceEndSilenceDuration
        self.voicePreRollDuration = snapshot.voicePreRollDuration
        self.voicePostRollDuration = snapshot.voicePostRollDuration
        self.whisperChunkDuration = snapshot.whisperChunkDuration
        self.whisperOverlapDuration = snapshot.whisperOverlapDuration
        self.pauseBalancedChunkingEnabled = snapshot.pauseBalancedChunkingEnabled
        self.hallucinationProtectionEnabled = snapshot.hallucinationProtectionEnabled
        if let finalTranscriptCleanupEnabled = snapshot.finalTranscriptCleanupEnabled {
            self.finalTranscriptCleanupEnabled = finalTranscriptCleanupEnabled
        }
        if let gigaAMRussianCorrectionEnabled = snapshot.gigaAMRussianCorrectionEnabled {
            self.gigaAMRussianCorrectionEnabled = gigaAMRussianCorrectionEnabled
        }
        self.vadPreset = vadPreset
        self.adaptiveVAD = snapshot.adaptiveVAD
        self.manualThresholdDB = snapshot.manualThresholdDB

        // Assign profiles last because individual tuning setters intentionally
        // mark built-in profiles and environments as custom while values change.
        self.customRecognitionBaseProfile = customRecognitionBaseProfile
        self.recognitionProfile = recognitionProfile
        self.microphoneEnvironmentProfile = microphoneEnvironmentProfile
        reconcileDraftSelections()
        return true
    }
}

private struct PerformanceSnapshotCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}

extension AppSettings.PerformanceConfigurationSnapshot {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PerformanceSnapshotCodingKey.self)

        func decode<Value: Decodable>(_ key: String, as type: Value.Type = Value.self) throws -> Value {
            try container.decode(type, forKey: PerformanceSnapshotCodingKey(key))
        }

        func decodeIfPresent<Value: Decodable>(
            _ key: String,
            as type: Value.Type = Value.self
        ) throws -> Value? {
            try container.decodeIfPresent(type, forKey: PerformanceSnapshotCodingKey(key))
        }

        schemaVersion = try decode("schemaVersion")
        recognitionBackend = try decode("recognitionBackend")
        recognitionProfile = try decode("recognitionProfile")
        customRecognitionBaseProfile = try decode("customRecognitionBaseProfile")
        microphoneEnvironmentProfile = try decode("microphoneEnvironmentProfile")
        selectedInputDeviceID = try decode("selectedInputDeviceID")

        whisperModelID = try decode("whisperModelID")
        gigaAMModelID = try decode("gigaAMModelID")
        localONNXModelID = try decode("localONNXModelID")
        appleSpeechOnDeviceOnly = try decode("appleSpeechOnDeviceOnly")
        appleSpeechAddsPunctuation = try decode("appleSpeechAddsPunctuation")
        appleSpeechLanguageIdentifier = try decode("appleSpeechLanguageIdentifier")
        whisperLanguageCode = try decode("whisperLanguageCode")

        whisperThreadCount = try decode("whisperThreadCount")
        whisperComputeMode = try decode("whisperComputeMode")
        whisperFlashAttention = try decode("whisperFlashAttention")
        whisperCustomDecodingEnabled = try decode("whisperCustomDecodingEnabled")
        whisperDecodingStrategy = try decode("whisperDecodingStrategy")
        whisperGreedyBestOf = try decode("whisperGreedyBestOf")
        whisperBeamSize = try decode("whisperBeamSize")
        whisperInitialPrompt = try decode("whisperInitialPrompt")
        whisperBoundaryStrategy =
            try decodeIfPresent("whisperBoundaryStrategy")
            ?? WhisperBoundaryStrategy.standard.rawValue
        whisperFileTranscriptionMode =
            try decodeIfPresent("whisperFileTranscriptionMode")
            ?? WhisperFileTranscriptionMode.profileVAD.rawValue

        gigaAMPreferredChunkDuration = try decode("gigaAMPreferredChunkDuration")
        gigaAMMaximumChunkDuration = try decode("gigaAMMaximumChunkDuration")
        gigaAMOverlapDuration = try decode("gigaAMOverlapDuration")
        gigaAMBoundarySearchDuration = try decode("gigaAMBoundarySearchDuration")
        gigaAMRetryCount = try decode("gigaAMRetryCount")
        gigaAMSplitOnFailure = try decode("gigaAMSplitOnFailure")
        gigaAMThreadCount = try decode("gigaAMThreadCount")
        gigaAMExecutionProvider = try decode("gigaAMExecutionProvider")

        localONNXPreferredChunkDuration = try decode("localONNXPreferredChunkDuration")
        localONNXMaximumChunkDuration = try decode("localONNXMaximumChunkDuration")
        localONNXOverlapDuration = try decode("localONNXOverlapDuration")
        localONNXBoundarySearchDuration = try decode("localONNXBoundarySearchDuration")
        localONNXRetryCount = try decode("localONNXRetryCount")
        localONNXSplitOnFailure = try decode("localONNXSplitOnFailure")
        localONNXThreadCount = try decode("localONNXThreadCount")
        localONNXExecutionProvider = try decode("localONNXExecutionProvider")

        recognitionContext = try decode("recognitionContext")
        recognitionVocabulary = try decode("recognitionVocabulary")
        recognitionContextEnabled = try decode("recognitionContextEnabled")
        recognitionVocabularyEnabled = try decode("recognitionVocabularyEnabled")
        voiceActivityDetectionMode = try decode("voiceActivityDetectionMode")
        sileroThreshold = try decode("sileroThreshold")
        sileroMinimumSpeechDuration = try decode("sileroMinimumSpeechDuration")
        voiceEndSilenceDuration = try decode("voiceEndSilenceDuration")
        voicePreRollDuration = try decode("voicePreRollDuration")
        voicePostRollDuration = try decode("voicePostRollDuration")
        whisperChunkDuration = try decode("whisperChunkDuration")
        effectiveRecognitionChunkDuration = try decodeIfPresent(
            "effectiveRecognitionChunkDuration"
        )
        whisperOverlapDuration = try decode("whisperOverlapDuration")
        if let enabled: Bool = try decodeIfPresent("pauseBalancedChunkingEnabled") {
            pauseBalancedChunkingEnabled = enabled
        } else {
            let legacyMode: String? = try decodeIfPresent("whisperChunkSchedulingMode")
            pauseBalancedChunkingEnabled = legacyMode == "deferredPauseBalanced"
        }
        hallucinationProtectionEnabled = try decode("hallucinationProtectionEnabled")
        finalTranscriptCleanupEnabled = try decodeIfPresent("finalTranscriptCleanupEnabled")
        gigaAMRussianCorrectionEnabled = try decodeIfPresent("gigaAMRussianCorrectionEnabled")
        vadPreset = try decode("vadPreset")
        adaptiveVAD = try decode("adaptiveVAD")
        manualThresholdDB = try decode("manualThresholdDB")
    }
}
