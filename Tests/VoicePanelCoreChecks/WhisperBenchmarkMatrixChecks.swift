import Foundation
import VoicePanelCore

let whisperBenchmarkMatrixChecks: [CheckCase] = [
    CheckCase(name: "Whisper benchmark default matrix keeps the comparison control order") {
        try expectEqual(
            WhisperBenchmarkMatrix.defaultVariants,
            [
                .standard,
                .legacyContext,
                .contextualRetry(.legacyFixedWords),
                .contextualRetry(.lexicalOverlapAligned),
                .contextualRetry(.timestampAligned),
                .boundaryBridge,
                .continuousFullAudio,
            ]
        )
    },
    CheckCase(name: "Whisper benchmark edge padding expands only segmented variants") {
        let matrix = WhisperBenchmarkMatrix.make(
            edgePaddings: [0, 0.4, 1.0],
            maximumChunkDurationOffset: 1.25
        )

        try expectEqual(matrix.count, 19)
        for variant in WhisperBenchmarkMatrix.defaultVariants.dropLast() {
            let configurations =
                matrix
                .filter { $0.variant == variant }
                .compactMap(\.audioConfiguration)
            try expectEqual(configurations.map(\.edgePadding), [0, 0.4, 1.0])
            try expect(
                configurations.allSatisfy { $0.maximumChunkDurationOffset == 1.25 },
                "segmented variant lost its requested forced-cut offset"
            )
        }

        let continuous = matrix.filter { $0.variant == .continuousFullAudio }
        try expectEqual(continuous.count, 1)
        try expectEqual(continuous[0].audioConfiguration, nil)
    },
    CheckCase(name: "Whisper benchmark variants round trip stable report identifiers") {
        let expectedIdentifiers = [
            "standard",
            "legacy-context-control",
            "contextual-retry-legacy-fixed-words",
            "contextual-retry-lexical-overlap-aligned",
            "contextual-retry-timestamp-aligned",
            "boundary-bridge",
            "continuous-full-audio",
        ]

        for (variant, expectedIdentifier) in zip(
            WhisperBenchmarkMatrix.defaultVariants,
            expectedIdentifiers
        ) {
            try expectEqual(variant.id, expectedIdentifier)
            let data = try JSONEncoder().encode(variant)
            let encodedIdentifier = try JSONDecoder().decode(String.self, from: data)
            let decodedVariant = try JSONDecoder().decode(
                WhisperBenchmarkVariant.self,
                from: data
            )
            try expectEqual(encodedIdentifier, expectedIdentifier)
            try expectEqual(decodedVariant, variant)
        }
    },
    CheckCase(name: "Whisper benchmark audio configuration normalizes unsafe values") {
        let configuration = WhisperBenchmarkAudioConfiguration(
            edgePadding: -.infinity,
            maximumChunkDurationOffset: .nan
        )

        try expectEqual(configuration.edgePadding, 0)
        try expectEqual(configuration.maximumChunkDurationOffset, 0)
    },
    CheckCase(name: "Whisper benchmark audio configuration decoding reapplies normalization") {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        let infinite = try decoder.decode(
            WhisperBenchmarkAudioConfiguration.self,
            from: Data(
                """
                {"edgePadding":"Infinity","maximumChunkDurationOffset":"NaN"}
                """.utf8
            )
        )
        let extreme = try JSONDecoder().decode(
            WhisperBenchmarkAudioConfiguration.self,
            from: Data(
                """
                {"edgePadding":1e308,"maximumChunkDurationOffset":1e308}
                """.utf8
            )
        )

        try expectEqual(infinite.edgePadding, 0)
        try expectEqual(infinite.maximumChunkDurationOffset, 0)
        try expectEqual(extreme.edgePadding, 30)
        try expectEqual(extreme.maximumChunkDuration(from: 18), 30)
    },
    CheckCase(name: "Whisper benchmark matrix decoding isolates Continuous from boundary settings") {
        let decoded = try JSONDecoder().decode(
            WhisperBenchmarkMatrixEntry.self,
            from: Data(
                """
                {
                  "variant":"continuous-full-audio",
                  "audioConfiguration": {
                    "edgePadding":1,
                    "maximumChunkDurationOffset":12
                  }
                }
                """.utf8
            )
        )

        try expectEqual(decoded.variant, .continuousFullAudio)
        try expectEqual(decoded.audioConfiguration, nil)
    },
    CheckCase(name: "Whisper benchmark padding sample conversion rejects unrepresentable counts") {
        let configuration = WhisperBenchmarkAudioConfiguration(
            edgePadding: 30,
            maximumChunkDurationOffset: 0
        )

        try expectEqual(configuration.edgePaddingSampleCount(sampleRate: 16_000), 480_000)
        try expectEqual(
            configuration.edgePaddingSampleCount(sampleRate: .greatestFiniteMagnitude),
            nil
        )
    },
    CheckCase(name: "Whisper benchmark padding copies PCM with exact rounded silence edges") {
        let source: [Float] = [0.25, -0.5, 0.75]
        let configuration = WhisperBenchmarkAudioConfiguration(
            edgePadding: 0.000_1,
            maximumChunkDurationOffset: 0
        )

        let padded = configuration.paddedSamples(source, sampleRate: 16_000)

        try expectEqual(source, [0.25, -0.5, 0.75])
        try expectEqual(padded, [0, 0, 0.25, -0.5, 0.75, 0, 0])
    },
    CheckCase(name: "Whisper benchmark forced cut offset stays within processor limits") {
        try expectEqual(
            WhisperBenchmarkAudioConfiguration(
                edgePadding: 0,
                maximumChunkDurationOffset: -100
            ).maximumChunkDuration(from: 18),
            2
        )
        try expectEqual(
            WhisperBenchmarkAudioConfiguration(
                edgePadding: 0,
                maximumChunkDurationOffset: 100
            ).maximumChunkDuration(from: 18),
            30
        )
        try expectEqual(
            WhisperBenchmarkAudioConfiguration(
                edgePadding: 0,
                maximumChunkDurationOffset: 1.25
            ).maximumChunkDuration(from: 18),
            19.25
        )
    },
]
