import VoicePanelCore

let recognitionAudioTransmissionPolicyChecks: [CheckCase] = [
    CheckCase(name: "Silence suppression buffers silence and flushes on speech") {
        let policy = RecognitionAudioTransmissionPolicy(suppressDetectedSilence: true)

        try expectEqual(policy.disposition(for: .silence), .bufferForPreRoll)
        try expectEqual(policy.disposition(for: .speechStarted), .flushBufferedAndTransmit)
        try expectEqual(policy.disposition(for: .speechContinued), .transmit)
        try expectEqual(policy.disposition(for: .possiblePause(duration: 0.2)), .transmit)
        try expectEqual(policy.disposition(for: .speechEnded(silenceDuration: 0.7)), .transmit)
    },

    CheckCase(name: "Disabled silence suppression transmits every buffer") {
        let policy = RecognitionAudioTransmissionPolicy(suppressDetectedSilence: false)

        try expectEqual(policy.disposition(for: .silence), .transmit)
        try expectEqual(policy.disposition(for: .speechStarted), .transmit)
        try expectEqual(policy.disposition(for: .speechEnded(silenceDuration: 1.0)), .transmit)
    },
]
