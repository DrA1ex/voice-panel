import Foundation
import VoicePanelCore

let recognitionHallucinationGuardChecks: [CheckCase] = [
    CheckCase(name: "Hallucination guard is disabled by default") {
        let chunk = AudioChunk(
            samples: Array(repeating: 0.1, count: 100),
            sampleRate: 100,
            boundaryReason: .silence
        )
        let reason = RecognitionHallucinationGuard().rejectionReason(
            for: "test test test test test test",
            chunk: chunk,
            configuration: .disabled
        )
        try expectEqual(reason, nil)
    },

    CheckCase(name: "Hallucination guard accepts short non-repeating transcripts") {
        let chunk = AudioChunk(
            samples: Array(repeating: 0.1, count: 300),
            sampleRate: 100,
            boundaryReason: .stopped
        )
        for text in ["hello", "hello world", "hello from VoicePanel"] {
            let reason = RecognitionHallucinationGuard().rejectionReason(
                for: text,
                chunk: chunk,
                configuration: .init(isEnabled: true)
            )
            try expectEqual(reason, nil)
        }
    },
    CheckCase(name: "Hallucination guard rejects repeated token loops") {
        let chunk = AudioChunk(
            samples: Array(repeating: 0.1, count: 500),
            sampleRate: 100,
            boundaryReason: .silence
        )
        let reason = RecognitionHallucinationGuard().rejectionReason(
            for: "hello hello hello hello hello hello",
            chunk: chunk,
            configuration: .init(isEnabled: true)
        )
        try expect(reason != nil, "a long repeated token loop should be rejected")
    },
    CheckCase(name: "Hallucination guard detects standalone gratitude and Russian subtitle credits over quiet audio") {
        let guardPolicy = RecognitionHallucinationGuard()
        let quiet = artifactChunk(Array(repeating: 0.0001, count: 300))
        for text in [
            "Thank you.", "THANK YOU!", "Спасибо за просмотр!",
            "Субтитры подготовил Иван Иванов", "Редактор субтитров А. Синецкая",
            "Корректор А. Егорова",
        ] {
            try expect(
                guardPolicy.rejectionReason(for: text, chunk: quiet, configuration: .init(isEnabled: true)) != nil,
                "quiet artifact escaped: \(text)")
            try expectEqual(
                guardPolicy.rejectionReason(
                    for: text, chunk: artifactChunk(Array(repeating: 0.1, count: 300)),
                    configuration: .init(isEnabled: true)), nil)
        }
        try expectEqual(
            guardPolicy.rejectionReason(
                for: "Я сказал thank you и продолжил", chunk: quiet,
                configuration: .init(isEnabled: true)), nil)
    },
    CheckCase(name: "Whisper filters a silent artifact tail without losing the real speech prefix") {
        let real = artifactSegment("Проверяем запись.", start: 0, end: 1)
        let fake = artifactSegment("Thank you.", start: 1, end: 3)
        let result = artifactResult([real, fake])
        let filtered = RecognitionHallucinationGuard().filteringLowSignalArtifacts(
            from: result,
            chunk: artifactChunk(Array(repeating: 0.1, count: 100) + Array(repeating: 0.0001, count: 200)),
            configuration: .init(isEnabled: true))
        try expectEqual(filtered.text, real.text)
        try expectEqual(filtered.segments, [real])
        try expectEqual(filtered.inferenceDuration, result.inferenceDuration)
    },
    CheckCase(name: "Whisper preserves audible gratitude even in a mostly silent segment") {
        let result = artifactResult([artifactSegment("Thank you.", start: 0, end: 10)])
        var samples = Array(repeating: Float(0.0001), count: 1000)
        samples.replaceSubrange(450..<470, with: Array(repeating: 0.1, count: 20))
        try expectEqual(
            RecognitionHallucinationGuard().filteringLowSignalArtifacts(
                from: result, chunk: artifactChunk(samples), configuration: .init(isEnabled: true)), result)
    },
    CheckCase(name: "Whisper leaves disabled protection and uncertain timestamps untouched") {
        let quiet = artifactChunk(Array(repeating: 0.0001, count: 300))
        let policy = RecognitionHallucinationGuard()
        let valid = artifactResult([artifactSegment("Thank you.", start: 0, end: 3)])
        try expectEqual(policy.filteringLowSignalArtifacts(from: valid, chunk: quiet, configuration: .disabled), valid)
        for (start, end) in [(Double.nan, 3.0), (0.0, Double.infinity), (-1.0, 2.0), (3.0, 4.0), (1.0, 1.0)] {
            let result = artifactResult([artifactSegment("Thank you.", start: start, end: end)])
            // NaN does not compare equal, so compare the untouched text instead.
            try expectEqual(
                policy.filteringLowSignalArtifacts(
                    from: result, chunk: quiet,
                    configuration: .init(isEnabled: true)
                ).text, result.text)
            try expectEqual(
                policy.rejectionReason(
                    for: result, chunk: artifactChunk(Array(repeating: 0.1, count: 300)),
                    configuration: .init(isEnabled: true)
                ), nil)
        }
    },
    CheckCase(name: "Whisper quiet ordinary text and mismatched evidence are preserved") {
        let quiet = artifactChunk(Array(repeating: 0.0001, count: 300))
        let result = artifactResult([artifactSegment("Тихая настоящая речь", start: 0, end: 3)])
        let policy = RecognitionHallucinationGuard()
        try expectEqual(
            policy.filteringLowSignalArtifacts(
                from: result, chunk: quiet,
                configuration: .init(isEnabled: true)), result)
        let patched = WhisperTranscriptionResult(
            text: "Исправленная настоящая речь",
            segments: [artifactSegment("Thank you.", start: 0, end: 3)], detectedLanguage: "ru", inferenceDuration: 0.1)
        try expectEqual(
            policy.filteringLowSignalArtifacts(
                from: patched, chunk: quiet,
                configuration: .init(isEnabled: true)), patched)
    },
    CheckCase(name: "Hallucination signal threshold is configurable and fails open on invalid PCM") {
        let policy = RecognitionHallucinationGuard()
        let quiet = artifactChunk(Array(repeating: 0.001, count: 300))
        try expect(
            policy.rejectionReason(
                for: "Thank you", chunk: quiet,
                configuration: .init(isEnabled: true, silenceThresholdDB: -55)) != nil,
            "below-threshold artifact survived")
        try expectEqual(
            policy.rejectionReason(
                for: "Thank you", chunk: quiet,
                configuration: .init(isEnabled: true, silenceThresholdDB: -65)), nil)
        try expectEqual(
            policy.rejectionReason(
                for: "Thank you", chunk: artifactChunk([.nan]),
                configuration: .init(isEnabled: true)), nil)
    },
    CheckCase(name: "Whisper artifacts without segment metadata use the complete audio window") {
        let result = artifactResult([], text: "Thank you.")
        let policy = RecognitionHallucinationGuard()
        try expectEqual(
            policy.filteringLowSignalArtifacts(
                from: result,
                chunk: artifactChunk(Array(repeating: 0, count: 300)), configuration: .init(isEnabled: true)
            ).text, "")
        try expectEqual(
            policy.filteringLowSignalArtifacts(
                from: result,
                chunk: artifactChunk(Array(repeating: 0.1, count: 300)), configuration: .init(isEnabled: true)), result)
    },
]

private func artifactChunk(_ samples: [Float]) -> AudioChunk {
    AudioChunk(samples: samples, sampleRate: 100, boundaryReason: .stopped)
}

private func artifactSegment(_ text: String, start: Double, end: Double) -> WhisperSegmentEvidence {
    WhisperSegmentEvidence(text: text, startTime: start, endTime: end, noSpeechProbability: 0, tokens: [])
}

private func artifactResult(_ segments: [WhisperSegmentEvidence], text: String? = nil) -> WhisperTranscriptionResult {
    WhisperTranscriptionResult(
        text: text ?? segments.map(\.text).joined(separator: " "), segments: segments,
        detectedLanguage: "ru", inferenceDuration: 0.1)
}
