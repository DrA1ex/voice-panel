import Foundation
import VoicePanelCore

let recognitionPipelineValidatorChecks: [CheckCase] = [
    CheckCase(name: "Pipeline validation enforces the one-second product minimum") {
        let result = RecognitionPipelineValidator.process(
            samples: Array(repeating: 0.5, count: 8_000),
            sampleRate: 16_000,
            vadConfiguration: .sensitive,
            segmenterConfiguration: .init(
                preRollDuration: 0.2,
                postRollDuration: 0.1,
                overlapDuration: 0,
                maximumChunkDuration: 5,
                minimumChunkDuration: 0.05
            ),
            detectionMode: .energy
        )
        try expectEqual(result.summary.acceptedByRecordingPolicy, false)
        try expectEqual(result.chunks.count, 0)
    },

    CheckCase(name: "Pipeline validation reports detected speech and margins") {
        let silence = Array(repeating: Float(0), count: 3_200)
        let speech = Array(repeating: Float(0.5), count: 16_000)
        let samples = silence + speech + silence
        var vad = VoiceActivityDetector.Configuration.sensitive
        vad.endOfSpeechSilenceDuration = 0.1
        let result = RecognitionPipelineValidator.process(
            samples: samples,
            sampleRate: 16_000,
            vadConfiguration: vad,
            segmenterConfiguration: .init(
                preRollDuration: 0.2,
                postRollDuration: 0.1,
                overlapDuration: 0,
                maximumChunkDuration: 5,
                minimumChunkDuration: 0.05
            ),
            detectionMode: .energy
        )
        try expectEqual(result.summary.acceptedByRecordingPolicy, true)
        try expect(result.summary.detectedSpeech, "speech should be detected")
        try expect(
            result.summary.acceptedAudioDuration >= result.summary.detectedSpeechDuration,
            "accepted audio must include detected speech")
        try expect(result.summary.paddingDuration > 0, "configured margins should be visible")
        try expect(result.chunks.count >= 1, "at least one speech chunk should be emitted")
    },
    CheckCase(name: "Older validation chunks decode with zero overlap evidence") {
        let data = Data(
            #"{"boundaryReason":"maximumDuration","duration":2,"speechDuration":1.5}"#.utf8
        )
        let decoded = try JSONDecoder().decode(
            RecognitionPipelineValidationChunk.self,
            from: data
        )
        try expectEqual(decoded.boundaryReason, .maximumDuration)
        try expectEqual(decoded.trailingOverlapDuration, 0)
    },
]
