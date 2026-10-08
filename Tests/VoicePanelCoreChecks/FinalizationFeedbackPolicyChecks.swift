import VoicePanelCore

let finalizationFeedbackPolicyChecks: [CheckCase] = [
    CheckCase(name: "Fast inference keeps finalization feedback briefly visible") {
        try expectApproximatelyEqual(
            FinalizationFeedbackPolicy.remainingDelay(
                elapsed: 0.05,
                minimumVisibleDuration: 0.35
            ),
            0.30,
            accuracy: 0.0001
        )
    },

    CheckCase(name: "Slow inference adds no artificial finalization delay") {
        try expectApproximatelyEqual(
            FinalizationFeedbackPolicy.remainingDelay(
                elapsed: 0.8,
                minimumVisibleDuration: 0.35
            ),
            0,
            accuracy: 0.0001
        )
    },
]
