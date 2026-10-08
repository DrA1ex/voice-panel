import VoicePanelCore

let audioInputRecoveryPolicyChecks: [CheckCase] = [
    CheckCase(name: "Unrelated input removal rebinds an active capture") {
        let decision = AudioInputRecoveryPolicy.decision(
            preferredSelection: 42,
            availableDeviceIDs: [42, 77],
            defaultDeviceID: 77,
            currentRequestedSelection: 42,
            currentResolvedDeviceID: 42,
            hasActiveSession: true,
            isCapturing: true,
            change: .deviceListChanged
        )

        try expectEqual(decision.persistedSelection, 42)
        try expectEqual(decision.reconnectSelection, 42)
        try expect(decision.shouldReconnect, "device-list changes must rebind the audio graph")
        try expect(!decision.usesSystemFallback, "an available selected input must remain selected")
    },

    CheckCase(name: "Missing selected input falls back to system default") {
        let decision = AudioInputRecoveryPolicy.decision(
            preferredSelection: 42,
            availableDeviceIDs: [77],
            defaultDeviceID: 77,
            currentRequestedSelection: 42,
            currentResolvedDeviceID: 42,
            hasActiveSession: true,
            isCapturing: false,
            change: .deviceListChanged
        )

        try expectEqual(decision.persistedSelection, 0)
        try expectEqual(decision.reconnectSelection, 0)
        try expect(decision.usesSystemFallback, "fallback must be visible to the caller")
        try expect(decision.shouldReconnect, "a suspended recording must reconnect to fallback")
    },

    CheckCase(name: "Idle missing selection is repaired without opening audio") {
        let decision = AudioInputRecoveryPolicy.decision(
            preferredSelection: 42,
            availableDeviceIDs: [77],
            defaultDeviceID: 77,
            currentRequestedSelection: nil,
            currentResolvedDeviceID: nil,
            hasActiveSession: false,
            isCapturing: false,
            change: .deviceListChanged
        )

        try expectEqual(decision.persistedSelection, 0)
        try expectEqual(decision.reconnectSelection, nil)
        try expect(!decision.shouldReconnect, "idle recovery must not start a microphone session")
    },

    CheckCase(name: "Missing selected input waits when no fallback exists") {
        let decision = AudioInputRecoveryPolicy.decision(
            preferredSelection: 42,
            availableDeviceIDs: [],
            defaultDeviceID: nil,
            currentRequestedSelection: 42,
            currentResolvedDeviceID: 42,
            hasActiveSession: true,
            isCapturing: false,
            change: .deviceListChanged
        )

        try expectEqual(decision.persistedSelection, 0)
        try expectEqual(decision.reconnectSelection, nil)
        try expect(decision.usesSystemFallback, "the missing explicit selection must still be repaired")
        try expect(!decision.shouldReconnect, "recovery must wait until a default input exists")
    },

    CheckCase(name: "System-default capture follows a new default input") {
        let decision = AudioInputRecoveryPolicy.decision(
            preferredSelection: 0,
            availableDeviceIDs: [77, 88],
            defaultDeviceID: 88,
            currentRequestedSelection: 0,
            currentResolvedDeviceID: 77,
            hasActiveSession: true,
            isCapturing: true,
            change: .defaultInputChanged
        )

        try expectEqual(decision.persistedSelection, 0)
        try expectEqual(decision.reconnectSelection, 0)
        try expect(decision.shouldReconnect, "system-default capture must move to the new default device")
    },

    CheckCase(name: "Fixed input ignores an unrelated default-device change") {
        let decision = AudioInputRecoveryPolicy.decision(
            preferredSelection: 42,
            availableDeviceIDs: [42, 77],
            defaultDeviceID: 77,
            currentRequestedSelection: 42,
            currentResolvedDeviceID: 42,
            hasActiveSession: true,
            isCapturing: true,
            change: .defaultInputChanged
        )

        try expect(!decision.shouldReconnect, "fixed input must not churn when only default changes")
    },
]
