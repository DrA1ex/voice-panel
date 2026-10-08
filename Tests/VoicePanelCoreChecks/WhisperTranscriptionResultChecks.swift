import VoicePanelCore

let whisperTranscriptionResultChecks: [CheckCase] = [
    CheckCase(name: "Whisper evidence preserves structured segment and token values") {
        let result = WhisperTranscriptionResult(
            text: "Hello, world.",
            segments: [
                WhisperSegmentEvidence(
                    text: "Hello,",
                    startTime: 0,
                    endTime: 0.8,
                    noSpeechProbability: 0.1,
                    tokens: [
                        WhisperTokenEvidence(
                            text: "Hel",
                            startTime: nil,
                            endTime: nil,
                            probability: 0.9
                        ),
                        WhisperTokenEvidence(
                            text: "lo,",
                            startTime: nil,
                            endTime: nil,
                            probability: 0.3
                        ),
                    ]
                ),
                WhisperSegmentEvidence(
                    text: " world.",
                    startTime: 0.8,
                    endTime: 1.4,
                    noSpeechProbability: 0.2,
                    tokens: [
                        WhisperTokenEvidence(
                            text: " world.",
                            startTime: nil,
                            endTime: nil,
                            probability: 0.75
                        )
                    ]
                ),
            ],
            detectedLanguage: "en",
            inferenceDuration: 0.4
        )

        try expectEqual(result.text, "Hello, world.")
        try expectEqual(result.tokens.map(\.text), ["Hel", "lo,", " world."])
        try expectApproximatelyEqual(
            result.meanTokenProbability,
            0.65,
            accuracy: 0.000_001
        )
        try expectApproximatelyEqual(
            result.maximumNoSpeechProbability,
            0.2,
            accuracy: 0.000_001
        )
        try expect(
            result.tokens.allSatisfy { $0.startTime == nil && $0.endTime == nil },
            "segment-only evidence must not fabricate token timestamps"
        )
    }
]
