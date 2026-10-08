import VoicePanelCore

let voiceActivityDetectorChecks: [CheckCase] = [
    CheckCase(name: "VAD starts and ends speech using hysteresis") {
        var detector = VoiceActivityDetector(
            configuration: .init(
                adaptiveThreshold: false,
                manualThresholdDB: -40,
                thresholdMarginDB: 12,
                hysteresisDB: 3,
                minimumSpeechDuration: 0.10,
                endOfSpeechSilenceDuration: 0.30
            ))

        try expectEqual(detector.process(rmsDB: -55, frameDuration: 0.05).0, .silence)
        try expectEqual(detector.process(rmsDB: -30, frameDuration: 0.05).0, .silence)
        try expectEqual(detector.process(rmsDB: -30, frameDuration: 0.05).0, .speechStarted)
        try expectEqual(detector.process(rmsDB: -39, frameDuration: 0.05).0, .speechContinued)
        try expectEqual(detector.process(rmsDB: -50, frameDuration: 0.10).0, .possiblePause(duration: 0.10))
        try expectEqual(detector.process(rmsDB: -50, frameDuration: 0.10).0, .possiblePause(duration: 0.20))

        let ended = detector.process(rmsDB: -50, frameDuration: 0.10).0
        guard case .speechEnded(let silenceDuration) = ended else {
            throw CheckFailure(description: "expected speechEnded, got \(ended)")
        }
        try expectApproximatelyEqual(silenceDuration, 0.30, accuracy: 0.000_001)
    },

    CheckCase(name: "Sensitivity presets produce visibly different thresholds") {
        let noiseFloor: Float = -58
        try expectEqual(VoiceActivityDetector.Configuration.sensitive.threshold(for: noiseFloor), -50)
        try expectEqual(VoiceActivityDetector.Configuration.balanced.threshold(for: noiseFloor), -46)
        try expectEqual(VoiceActivityDetector.Configuration.noiseResistant.threshold(for: noiseFloor), -42)
    },

    CheckCase(name: "Digital silence does not collapse adaptive noise calibration") {
        var detector = VoiceActivityDetector(configuration: .balanced)
        let initialNoiseFloor = detector.noiseFloorDB

        for _ in 0..<200 {
            _ = detector.process(rmsDB: -120, frameDuration: 0.02)
        }

        try expectEqual(detector.noiseFloorDB, initialNoiseFloor)
        try expectEqual(detector.thresholdDB, -46)

        detector.updateConfiguration(.sensitive)
        try expectEqual(detector.noiseFloorDB, initialNoiseFloor)
        try expectEqual(detector.thresholdDB, -50)

        detector.updateConfiguration(.noiseResistant)
        try expectEqual(detector.noiseFloorDB, initialNoiseFloor)
        try expectEqual(detector.thresholdDB, -42)
    },
    CheckCase(name: "Hysteresis-band noise cannot keep a chunk open forever") {
        var detector = VoiceActivityDetector(
            configuration: .init(
                adaptiveThreshold: false,
                manualThresholdDB: -40,
                hysteresisDB: 3,
                minimumSpeechDuration: 0.10,
                endOfSpeechSilenceDuration: 0.30,
                maximumHysteresisHoldDuration: 1.0
            ))

        _ = detector.process(rmsDB: -30, frameDuration: 0.10)
        for index in 0..<9 {
            let event = detector.process(rmsDB: -42, frameDuration: 0.10).0
            guard case .possiblePause(let duration) = event else {
                throw CheckFailure(description: "expected possiblePause, got \(event)")
            }
            try expectApproximatelyEqual(
                duration,
                Double(index + 1) / 10,
                accuracy: 0.000_001
            )
        }
        let ended = detector.process(rmsDB: -42, frameDuration: 0.10).0
        guard case .speechEnded(let duration) = ended else {
            throw CheckFailure(description: "expected bounded speechEnded, got \(ended)")
        }
        try expectApproximatelyEqual(duration, 1.0, accuracy: 0.000_001)
    },

    CheckCase(name: "Adaptive noise floor moves slowly upward") {
        var detector = VoiceActivityDetector(configuration: .balanced)
        let initial = detector.noiseFloorDB

        for _ in 0..<20 {
            _ = detector.process(rmsDB: -48, frameDuration: 0.02)
        }

        try expect(detector.noiseFloorDB > initial, "noise floor must rise toward persistent room noise")
        try expect(detector.noiseFloorDB < -48, "noise floor must not jump directly to the measured level")
        try expect(detector.thresholdDB > detector.noiseFloorDB, "speech threshold must stay above noise floor")
    },
]
