import VoicePanelCore

let hotKeyReleaseTailPolicyChecks: [CheckCase] = [
    CheckCase(name: "Hot-key release tail defaults to three hundred milliseconds") {
        try expectApproximatelyEqual(
            HotKeyReleaseTailPolicy.defaultDuration,
            0.3,
            accuracy: 0.000_001
        )
    },

    CheckCase(name: "Disabled hot-key release tail stops immediately") {
        try expectApproximatelyEqual(
            HotKeyReleaseTailPolicy.effectiveDuration(
                isEnabled: false,
                configuredDuration: 0.3
            ),
            0,
            accuracy: 0.000_001
        )
    },

    CheckCase(name: "Hot-key release tail duration is bounded") {
        try expectApproximatelyEqual(
            HotKeyReleaseTailPolicy.effectiveDuration(
                isEnabled: true,
                configuredDuration: 5
            ),
            2,
            accuracy: 0.000_001
        )
        try expectApproximatelyEqual(
            HotKeyReleaseTailPolicy.effectiveDuration(
                isEnabled: true,
                configuredDuration: -1
            ),
            0,
            accuracy: 0.000_001
        )
    },

    CheckCase(name: "Push-to-talk release tail covers preparation and listening") {
        for phase in [RecordingControlPhase.preparing, .listening] {
            try expectApproximatelyEqual(
                HotKeyReleaseTailPolicy.scheduledDuration(
                    isEnabled: true,
                    configuredDuration: 0.3,
                    phase: phase,
                    source: .hotKeyHold
                ),
                0.3,
                accuracy: 0.000_001
            )
        }
    },

    CheckCase(name: "Release tail does not delay unrelated recording controls") {
        try expectApproximatelyEqual(
            HotKeyReleaseTailPolicy.scheduledDuration(
                isEnabled: true,
                configuredDuration: 0.3,
                phase: .listening,
                source: .menu
            ),
            0,
            accuracy: 0.000_001
        )
        try expectApproximatelyEqual(
            HotKeyReleaseTailPolicy.scheduledDuration(
                isEnabled: true,
                configuredDuration: 0.3,
                phase: .finalizing,
                source: .hotKeyHold
            ),
            0,
            accuracy: 0.000_001
        )
    },
]
