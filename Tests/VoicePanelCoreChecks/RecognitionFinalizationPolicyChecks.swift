import VoicePanelCore

let recognitionFinalizationPolicyChecks: [CheckCase] = [
    CheckCase(name: "Session-final text does not bypass queued recognition") {
        try expectEqual(
            RecognitionFinalizationPolicy.action(for: .transcriptUpdate(isSessionFinal: true)),
            .wait
        )
    },

    CheckCase(name: "Only engine queue completion produces success") {
        try expectEqual(
            RecognitionFinalizationPolicy.action(for: .engineFinished),
            .complete
        )
    },

    CheckCase(name: "Finalization timeout fails instead of copying partial text") {
        try expectEqual(
            RecognitionFinalizationPolicy.action(for: .timeout),
            .fail
        )
    },
]
