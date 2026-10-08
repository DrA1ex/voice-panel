import Foundation
import VoicePanelCore

let recognitionProfilesChecks: [CheckCase] = [
    CheckCase(name: "Recognition profile titles match the product vocabulary") {
        try expectEqual(RecognitionProfileID.classic.title, "Vanilla")
        try expectEqual(RecognitionProfileID.recommended.title, "Balanced")
        try expectEqual(RecognitionProfileID.quality.title, "Quality")
        try expectEqual(RecognitionProfileID.lowLatency.title, "Low Latency")
        try expectEqual(RecognitionProfileID.custom.title, "Unsaved")
        try expectEqual(MicrophoneEnvironmentProfileID.custom.title, "Custom")
    },
    CheckCase(name: "Vanilla profile preserves the original pipeline") {
        let values = try xctUnwrapCompat(RecognitionTuningValues.preset(for: .classic))
        try expectEqual(values.voiceActivityDetectionMode, .energy)
        try expectApproximatelyEqual(values.endOfSpeechSilenceDuration, 0.65, accuracy: 0.0001)
        try expectApproximatelyEqual(values.preRollDuration, 0.25, accuracy: 0.0001)
        try expectApproximatelyEqual(values.postRollDuration, 0.15, accuracy: 0.0001)
        try expect(!values.hallucinationProtectionEnabled, "Vanilla must not enable result filtering")
        try expect(!values.whisperCustomDecodingEnabled, "Vanilla must retain whisper.cpp decoding defaults")
        try expectEqual(values.whisperBoundaryStrategy, .standard)
        try expectApproximatelyEqual(values.whisperChunkDuration, 5.0, accuracy: 0.0001)
        try expectApproximatelyEqual(values.whisperOverlapDuration, 0.30, accuracy: 0.0001)
    },
    CheckCase(name: "Balanced profile applies safe article-derived improvements") {
        let values = try xctUnwrapCompat(RecognitionTuningValues.preset(for: .recommended))
        try expectEqual(values.voiceActivityDetectionMode, .hybrid)
        try expect(values.usesRecognitionContext, "Balanced must use configured context")
        try expect(values.usesRecognitionVocabulary, "Balanced must use configured vocabulary")
        try expect(values.hallucinationProtectionEnabled, "Balanced must enable conservative result protection")
        try expect(values.finalTranscriptCleanupEnabled, "Balanced must clean final chunk boundaries")
        try expect(
            !values.gigaAMRussianCorrectionEnabled,
            "Balanced must not enable the optional language-specific generative correction"
        )
        try expect(
            !values.whisperCustomDecodingEnabled, "Balanced must not force Beam Search or custom candidate counts")
        try expectEqual(values.whisperBoundaryStrategy, .standard)
    },
    CheckCase(name: "Quality profile changes boundaries without forcing experimental decoding") {
        let quality = try xctUnwrapCompat(RecognitionTuningValues.preset(for: .quality))
        let recommended = try xctUnwrapCompat(RecognitionTuningValues.preset(for: .recommended))
        try expect(quality.preRollDuration > recommended.preRollDuration, "Quality must preserve more leading audio")
        try expect(quality.postRollDuration > recommended.postRollDuration, "Quality must preserve more trailing audio")
        try expect(
            quality.endOfSpeechSilenceDuration > recommended.endOfSpeechSilenceDuration,
            "Quality must wait longer for phrase completion"
        )
        try expect(!quality.whisperCustomDecodingEnabled, "Quality must keep stable Whisper decoding")
        try expect(quality.finalTranscriptCleanupEnabled, "Quality must clean final chunk boundaries")
        try expect(
            quality.gigaAMRussianCorrectionEnabled,
            "Quality must enable optional Russian correction when the selected engine is GigaAM"
        )
        try expectEqual(recommended.whisperChunkDuration, 20)
        try expectEqual(quality.whisperChunkDuration, 20)
        try expect(quality.pauseBalancedChunkingEnabled, "Quality should balance real pauses")
        try expect(
            !recommended.pauseBalancedChunkingEnabled,
            "Balanced should retain immediate chunking by default"
        )
        try expectEqual(quality.whisperBoundaryStrategy, .standard)
        try expectEqual(RecognitionProfileID.recommended.defaultGigaAMChunkDuration, 15)
        try expectEqual(RecognitionProfileID.quality.defaultGigaAMChunkDuration, 20)
    },
    CheckCase(name: "Low-latency profile closes speech sooner") {
        let lowLatency = try xctUnwrapCompat(RecognitionTuningValues.preset(for: .lowLatency))
        let classic = try xctUnwrapCompat(RecognitionTuningValues.preset(for: .classic))
        try expect(
            lowLatency.endOfSpeechSilenceDuration < classic.endOfSpeechSilenceDuration, "Low latency must close sooner")
        try expect(lowLatency.preRollDuration < classic.preRollDuration, "Low latency must keep a smaller pre-roll")
        try expectEqual(lowLatency.voiceActivityDetectionMode, .energy)
        try expectEqual(lowLatency.whisperChunkDuration, 5)
        try expectEqual(RecognitionProfileID.lowLatency.defaultGigaAMChunkDuration, 3.5)
        try expectEqual(lowLatency.whisperBoundaryStrategy, .standard)
        try expect(
            lowLatency.finalTranscriptCleanupEnabled,
            "Low latency must clean its frequent forced chunk boundaries"
        )
    },
    CheckCase(name: "Microphone environments preserve existing detector presets") {
        let quiet = try xctUnwrapCompat(MicrophoneEnvironmentValues.preset(for: .quiet))
        let balanced = try xctUnwrapCompat(MicrophoneEnvironmentValues.preset(for: .balanced))
        let noisy = try xctUnwrapCompat(MicrophoneEnvironmentValues.preset(for: .noisy))
        try expect(
            quiet.baseConfiguration.thresholdMarginDB < balanced.baseConfiguration.thresholdMarginDB,
            "Quiet must be more sensitive")
        try expect(
            noisy.baseConfiguration.thresholdMarginDB > balanced.baseConfiguration.thresholdMarginDB,
            "Noisy must reject more background sound")
        try expect(
            noisy.baseConfiguration.minimumSpeechDuration > quiet.baseConfiguration.minimumSpeechDuration,
            "Noisy must require a longer speech candidate")
    },
    CheckCase(name: "Resolver combines a recognition profile with an environment") {
        let customRecognition = RecognitionTuningValues.classic
        let resolved = RecognitionConfigurationResolver.resolve(
            recognitionProfile: .quality,
            microphoneEnvironmentProfile: .noisy,
            customRecognitionTuning: customRecognition,
            customMicrophoneConfiguration: .sensitive
        )
        try expectEqual(resolved.tuning, .quality)
        try expectEqual(
            resolved.voiceActivityConfiguration.thresholdMarginDB,
            VoiceActivityDetector.Configuration.noiseResistant.thresholdMarginDB)
        try expectApproximatelyEqual(
            resolved.voiceActivityConfiguration.endOfSpeechSilenceDuration,
            RecognitionTuningValues.quality.endOfSpeechSilenceDuration,
            accuracy: 0.0001
        )
    },
    CheckCase(name: "Selecting Quality ignores stale Low Latency tuning") {
        let resolved = RecognitionConfigurationResolver.resolve(
            recognitionProfile: .quality,
            microphoneEnvironmentProfile: .balanced,
            customRecognitionTuning: .lowLatency,
            customMicrophoneConfiguration: .sensitive
        )
        try expectEqual(resolved.tuning, .quality)
        try expectApproximatelyEqual(
            resolved.tuning.whisperChunkDuration,
            RecognitionTuningValues.quality.whisperChunkDuration,
            accuracy: 0.0001
        )
        try expectEqual(
            resolved.tuning.voiceActivityDetectionMode,
            RecognitionTuningValues.quality.voiceActivityDetectionMode
        )
        try expectEqual(
            resolved.voiceActivityConfiguration.thresholdMarginDB,
            VoiceActivityDetector.Configuration.balanced.thresholdMarginDB
        )
        try expectApproximatelyEqual(
            resolved.voiceActivityConfiguration.endOfSpeechSilenceDuration,
            RecognitionTuningValues.quality.endOfSpeechSilenceDuration,
            accuracy: 0.0001
        )
    },
    CheckCase(name: "Override provenance reports only values that differ from the base") {
        var custom = RecognitionTuningValues.recommended
        custom.endOfSpeechSilenceDuration = 0.95
        custom.whisperBoundaryStrategy = .contextualRetry
        let fields = custom.fieldsDiffering(from: .recommended)
        try expectEqual(fields.count, 2)
        try expect(fields.contains(.endOfSpeechSilenceDuration), "Speech end pause override is missing")
        try expect(fields.contains(.whisperBoundaryStrategy), "Whisper boundary strategy override is missing")
    },
    CheckCase(name: "Existing Unsaved values infer the nearest built-in base") {
        var custom = RecognitionTuningValues.quality
        custom.postRollDuration += 0.05
        try expectEqual(RecognitionTuningValues.closestBuiltInProfile(to: custom), .quality)
    },
    CheckCase(name: "Named recognition presets preserve base and tuning") {
        let preset = SavedRecognitionPreset(
            name: "Desk microphone",
            basedOn: .recommended,
            tuning: .quality
        )
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(SavedRecognitionPreset.self, from: data)
        try expectEqual(decoded.name, "Desk microphone")
        try expectEqual(decoded.basedOn, .recommended)
        try expectEqual(decoded.tuning, .quality)
    },
    CheckCase(name: "Legacy true carry context decodes as contextual retry") {
        let legacyJSON = """
            {
              "voiceActivityDetectionMode":"energy",
              "sileroThreshold":0.5,
              "sileroMinimumSpeechDuration":0.12,
              "endOfSpeechSilenceDuration":0.65,
              "preRollDuration":0.25,
              "postRollDuration":0.15,
              "whisperChunkDuration":5,
              "whisperOverlapDuration":0.3,
              "usesRecognitionContext":false,
              "usesRecognitionVocabulary":false,
              "hallucinationProtectionEnabled":false,
              "whisperCustomDecodingEnabled":false,
              "whisperCarryContext":true
            }
            """
        let decoded = try JSONDecoder().decode(
            RecognitionTuningValues.self,
            from: Data(legacyJSON.utf8)
        )
        try expectEqual(decoded.whisperBoundaryStrategy, .contextualRetry)
        try expect(!decoded.finalTranscriptCleanupEnabled, "Legacy tuning must preserve prior behavior")
        try expect(!decoded.gigaAMRussianCorrectionEnabled, "Legacy tuning must not download a new model")
    },
    CheckCase(name: "Legacy false carry context decodes as standard") {
        let legacyJSON = """
            {
              "voiceActivityDetectionMode":"energy",
              "sileroThreshold":0.5,
              "sileroMinimumSpeechDuration":0.12,
              "endOfSpeechSilenceDuration":0.65,
              "preRollDuration":0.25,
              "postRollDuration":0.15,
              "whisperChunkDuration":5,
              "whisperOverlapDuration":0.3,
              "usesRecognitionContext":false,
              "usesRecognitionVocabulary":false,
              "hallucinationProtectionEnabled":false,
              "whisperCustomDecodingEnabled":false,
              "whisperCarryContext":false
            }
            """
        let decoded = try JSONDecoder().decode(
            RecognitionTuningValues.self,
            from: Data(legacyJSON.utf8)
        )
        try expectEqual(decoded.whisperBoundaryStrategy, .standard)
    },
    CheckCase(name: "Boundary strategy survives tuning JSON round trip") {
        var tuning = RecognitionTuningValues.recommended
        tuning.whisperBoundaryStrategy = .boundaryBridge
        let encoded = try JSONEncoder().encode(tuning)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        try expect(object?["whisperBoundaryStrategy"] != nil, "New boundary strategy must be encoded")
        try expect(object?["whisperCarryContext"] == nil, "Legacy carry context must not be encoded")
        let decoded = try JSONDecoder().decode(RecognitionTuningValues.self, from: encoded)
        try expectEqual(decoded.whisperBoundaryStrategy, .boundaryBridge)
    },
    CheckCase(name: "Prototype Whisper scheduling migrates to pause-balanced chunking") {
        let encoded = try JSONEncoder().encode(RecognitionTuningValues.recommended)
        var object = try xctUnwrapCompat(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "pauseBalancedChunkingEnabled")
        object["whisperChunkSchedulingMode"] = "deferredPauseBalanced"
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(RecognitionTuningValues.self, from: legacyData)
        try expect(decoded.pauseBalancedChunkingEnabled, "prototype setting was not migrated")
    },
    CheckCase(name: "Tuning exports only the universal pause-balanced setting") {
        let encoded = try JSONEncoder().encode(RecognitionTuningValues.quality)
        let object = try xctUnwrapCompat(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        try expectEqual(object["pauseBalancedChunkingEnabled"] as? Bool, true)
        try expect(
            object["whisperChunkSchedulingMode"] == nil,
            "new tuning exported the prototype Whisper field"
        )
    },
    CheckCase(name: "Unsaved resolver keeps explicit overrides") {
        var customMicrophone = VoiceActivityDetector.Configuration.sensitive
        customMicrophone.adaptiveThreshold = false
        customMicrophone.manualThresholdDB = -37
        let customRecognition = RecognitionTuningValues(
            voiceActivityDetectionMode: .silero,
            sileroThreshold: 0.62,
            sileroMinimumSpeechDuration: 0.18,
            endOfSpeechSilenceDuration: 0.91,
            preRollDuration: 0.33,
            postRollDuration: 0.27,
            whisperChunkDuration: 9.0,
            whisperOverlapDuration: 0.42,
            usesRecognitionContext: true,
            usesRecognitionVocabulary: false,
            hallucinationProtectionEnabled: true,
            whisperCustomDecodingEnabled: true,
            whisperBoundaryStrategy: .contextualRetry
        )
        let resolved = RecognitionConfigurationResolver.resolve(
            recognitionProfile: .custom,
            microphoneEnvironmentProfile: .custom,
            customRecognitionTuning: customRecognition,
            customMicrophoneConfiguration: customMicrophone
        )
        try expectEqual(resolved.tuning, customRecognition)
        try expectEqual(resolved.voiceActivityConfiguration.manualThresholdDB, -37)
        try expectApproximatelyEqual(
            resolved.voiceActivityConfiguration.endOfSpeechSilenceDuration, 0.91, accuracy: 0.0001)
    },
]

private func xctUnwrapCompat<T>(_ value: T?) throws -> T {
    guard let value else {
        throw CheckFailure(description: "Expected a non-nil value")
    }
    return value
}
