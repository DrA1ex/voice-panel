import VoicePanelCore

let recordingControlPolicyChecks: [CheckCase] = [
    CheckCase(name: "Hot key uses press and release edges") {
        try expectEqual(
            RecordingControlPolicy.decide(event: .hotKeyPressed, phase: .idle, activeSource: nil),
            .start(.hotKeyHold)
        )
        try expectEqual(
            RecordingControlPolicy.decide(event: .hotKeyReleased, phase: .listening, activeSource: .hotKeyHold),
            .stop
        )
    },

    CheckCase(name: "Hot-key release does not stop menu recording") {
        try expectEqual(
            RecordingControlPolicy.decide(event: .hotKeyReleased, phase: .listening, activeSource: .menu),
            .none
        )
    },

    CheckCase(name: "Hot-key recording can be latched for manual stop") {
        try expectEqual(
            RecordingControlPolicy.decide(
                event: .latchHotKey,
                phase: .listening,
                activeSource: .hotKeyHold
            ),
            .latchHotKey
        )
        try expectEqual(
            RecordingControlPolicy.decide(
                event: .hotKeyReleased,
                phase: .listening,
                activeSource: .hotKeyLatched
            ),
            .none
        )
    },

    CheckCase(name: "Latched recording can be stopped manually") {
        try expectEqual(
            RecordingControlPolicy.decide(
                event: .menuToggle,
                phase: .listening,
                activeSource: .hotKeyLatched
            ),
            .stop
        )
        try expectEqual(RecordingControlSource.hotKeyLatched.requiresManualStop, true)
    },

    CheckCase(name: "Menu toggle stops only menu recording") {
        try expectEqual(
            RecordingControlPolicy.decide(event: .menuToggle, phase: .listening, activeSource: .menu),
            .stop
        )
        try expectEqual(
            RecordingControlPolicy.decide(event: .menuToggle, phase: .listening, activeSource: .hotKeyHold),
            .none
        )
    },

    CheckCase(name: "Release during preparation preserves already captured audio") {
        try expectEqual(
            RecordingControlPolicy.decide(event: .hotKeyReleased, phase: .preparing, activeSource: .hotKeyHold),
            .finishPreparationThenStop
        )
    },
]
