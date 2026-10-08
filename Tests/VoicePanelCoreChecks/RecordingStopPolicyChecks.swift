import VoicePanelCore

let recordingStopPolicyChecks: [CheckCase] = [
    CheckCase(name: "Recordings shorter than one second are discarded") {
        try expectEqual(
            RecordingStopPolicy.action(for: 0.999),
            .discardTooShort
        )
    },

    CheckCase(name: "One-second recordings flush the final audio chunk") {
        try expectEqual(
            RecordingStopPolicy.action(for: 1),
            .flushAndFinalize
        )
    },
]
