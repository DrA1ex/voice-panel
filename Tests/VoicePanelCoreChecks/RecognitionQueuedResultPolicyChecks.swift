import VoicePanelCore

let recognitionQueuedResultPolicyChecks: [CheckCase] = [
    CheckCase(name: "Accepted chunk still publishes while the input queue is finishing") {
        try expect(
            RecognitionQueuedResultPolicy.shouldPublish(
                generationMatches: true,
                sessionIsActive: true
            ),
            "A result accepted before finish must not be discarded"
        )
    },

    CheckCase(name: "Cancelled or replaced sessions reject late chunk results") {
        try expect(
            !RecognitionQueuedResultPolicy.shouldPublish(
                generationMatches: false,
                sessionIsActive: true
            ),
            "A stale generation must be rejected"
        )
        try expect(
            !RecognitionQueuedResultPolicy.shouldPublish(
                generationMatches: true,
                sessionIsActive: false
            ),
            "An inactive session must be rejected"
        )
    },
]
