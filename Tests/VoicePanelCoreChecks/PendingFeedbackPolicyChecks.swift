import VoicePanelCore

let pendingFeedbackPolicyChecks: [CheckCase] = [
    CheckCase(name: "Pending feedback counts only accumulated voiced time") {
        try expectEqual(PendingFeedbackPolicy.itemCount(forVoicedDuration: 0), 0)
        try expectEqual(PendingFeedbackPolicy.itemCount(forVoicedDuration: 0.01), 1)
        try expectEqual(PendingFeedbackPolicy.itemCount(forVoicedDuration: 0.65), 2)
        try expectEqual(PendingFeedbackPolicy.itemCount(forVoicedDuration: 30), 8)
    },

    CheckCase(name: "Gradient feedback grows with continuous voiced time") {
        try expectApproximatelyEqual(
            PendingFeedbackPolicy.itemExtent(forVoicedDuration: 0),
            0,
            accuracy: 0.000_1
        )
        try expectApproximatelyEqual(
            PendingFeedbackPolicy.itemExtent(forVoicedDuration: 0.325),
            1.5,
            accuracy: 0.000_1
        )
        try expectApproximatelyEqual(
            PendingFeedbackPolicy.itemExtent(forVoicedDuration: 0.65),
            2,
            accuracy: 0.000_1
        )
        try expectApproximatelyEqual(
            PendingFeedbackPolicy.itemExtent(forVoicedDuration: 30),
            8,
            accuracy: 0.000_1
        )
    },

    CheckCase(name: "Possible pause freezes growth while pending feedback keeps animating") {
        let presentation = PendingFeedbackPolicy.presentation(
            isRecording: true,
            voiceActivityState: .possiblePause,
            activeVoicedDuration: 1.5,
            frozenItemCount: 2
        )
        try expectEqual(presentation.activeItemCount, 3)
        try expectEqual(presentation.frozenItemCount, 2)
        try expectEqual(presentation.itemCount, 5)
        try expect(presentation.animatesActiveTail, "unresolved recognition must remain visibly active")
    },

    CheckCase(name: "Pulse remains active while recognition work is unresolved") {
        let speaking = PendingFeedbackPolicy.presentation(
            isRecording: true,
            voiceActivityState: .speech,
            activeVoicedDuration: 0.4,
            frozenItemCount: 4
        )
        try expect(speaking.animatesActiveTail, "active speech must animate the pending tail")

        let silent = PendingFeedbackPolicy.presentation(
            isRecording: true,
            voiceActivityState: .silence,
            activeVoicedDuration: 0,
            frozenItemCount: 4
        )
        try expect(silent.animatesActiveTail, "queued work must keep the pulse visible during silence")
        try expectEqual(silent.frozenItemCount, 4)
    },

    CheckCase(name: "Live draft audio stays pending until final refinement") {
        let draftOnly = PendingFeedbackPolicy.presentation(
            isRecording: true,
            voiceActivityState: .speech,
            activeVoicedDuration: 1.5,
            frozenItemCount: 0,
        )
        try expectEqual(draftOnly.itemCount, 3)

        let refining = PendingFeedbackPolicy.presentation(
            isRecording: true,
            voiceActivityState: .speech,
            activeVoicedDuration: 1.5,
            frozenItemCount: 2,
        )
        try expectEqual(refining.activeItemCount, 3)
        try expectEqual(refining.frozenItemCount, 2)
    },

    CheckCase(name: "Feedback disappears outside recording") {
        try expectEqual(
            PendingFeedbackPolicy.presentation(
                isRecording: false,
                voiceActivityState: .speech,
                activeVoicedDuration: 5,
                frozenItemCount: 5
            ),
            PendingFeedbackPresentation(
                isActivelySpeaking: false,
                activeItemCount: 0,
                frozenItemCount: 0
            )
        )
    },

    CheckCase(name: "Pending feedback timing avoids short flashes") {
        try expectEqual(PendingFeedbackTimingPolicy.appearanceDelay, 0.30)
        try expectEqual(PendingFeedbackTimingPolicy.minimumVisibleDuration, 0.60)
        try expectApproximatelyEqual(
            PendingFeedbackTimingPolicy.remainingVisibleDuration(after: 0.10),
            0.50,
            accuracy: 0.000_1
        )
        try expectApproximatelyEqual(
            PendingFeedbackTimingPolicy.remainingVisibleDuration(after: 0.80),
            0,
            accuracy: 0.000_1
        )
    },
]
