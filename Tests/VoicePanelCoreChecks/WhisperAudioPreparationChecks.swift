import VoicePanelCore

let whisperAudioPreparationChecks: [CheckCase] = [
    CheckCase(name: "Whisper short audio is padded without changing speech samples") {
        let input: [Float] = [0.25, -0.5, 0.75]
        let output = WhisperAudioPreparation.paddedToMinimumDuration(
            input,
            sampleRate: 10,
            minimumDuration: 1
        )
        try expectEqual(output.count, 10)
        try expectEqual(Array(output.prefix(input.count)), input)
        try expect(output.dropFirst(input.count).allSatisfy { $0 == 0 }, "Padding must be silence")
    },
    CheckCase(name: "Whisper long audio is not copied or truncated logically") {
        let input = Array(repeating: Float(0.2), count: 12)
        try expectEqual(
            WhisperAudioPreparation.paddedToMinimumDuration(
                input,
                sampleRate: 10,
                minimumDuration: 1
            ),
            input
        )
    },
    CheckCase(name: "Whisper resampling preserves short analyzed speech evidence") {
        let source = AudioChunk(
            samples: Array(repeating: 0.1, count: 48_000),
            sampleRate: 48_000,
            boundaryReason: .maximumDuration,
            trailingOverlapDuration: 0.4,
            speechRange: 2_400..<7_200,
            speechEvidenceAnalyzed: true
        )
        let resampled = WhisperAudioPreparation.resampledChunk(
            source,
            samples: Array(repeating: 0.1, count: 16_000),
            sampleRate: 16_000
        )

        try expectEqual(resampled.speechRange, 800..<2_400)
        try expectEqual(resampled.trailingOverlapDuration, 0.4)
        try expect(resampled.speechEvidenceAnalyzed, "resampling discarded analyzed speech evidence")
        let rejection = RecognitionHallucinationGuard().rejectionReason(
            for: "one two three four five",
            chunk: resampled,
            configuration: .init(isEnabled: true)
        )
        try expectEqual(rejection, "too much text for a very short speech fragment")
    },
    CheckCase(name: "Whisper resampling clamps analyzed speech evidence to output") {
        let source = AudioChunk(
            samples: Array(repeating: 0.1, count: 10),
            sampleRate: 10,
            boundaryReason: .stopped,
            speechRange: 8..<20,
            speechEvidenceAnalyzed: true
        )

        let resampled = WhisperAudioPreparation.resampledChunk(
            source,
            samples: Array(repeating: 0.1, count: 5),
            sampleRate: 5
        )

        try expectEqual(resampled.speechRange, 4..<5)
        try expect(resampled.speechEvidenceAnalyzed, "clamping discarded evidence provenance")
    },
]
