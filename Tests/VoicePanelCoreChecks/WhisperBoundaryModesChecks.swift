import VoicePanelCore

let whisperBoundaryModesChecks: [CheckCase] = [
    CheckCase(name: "legacy enabled context migrates to contextual retry") {
        let value = WhisperBoundarySettingsMigration.resolveBoundaryStrategy(
            newRawValue: nil,
            legacyCarryContext: true,
            profileDefault: .standard
        )
        try expectEqual(value, .contextualRetry)
    },
    CheckCase(name: "new boundary strategy wins over legacy context") {
        let value = WhisperBoundarySettingsMigration.resolveBoundaryStrategy(
            newRawValue: WhisperBoundaryStrategy.boundaryBridge.rawValue,
            legacyCarryContext: true,
            profileDefault: .standard
        )
        try expectEqual(value, .boundaryBridge)
    },
    CheckCase(name: "missing boundary preferences use profile default") {
        let value = WhisperBoundarySettingsMigration.resolveBoundaryStrategy(
            newRawValue: nil,
            legacyCarryContext: nil,
            profileDefault: .contextualRetry
        )
        try expectEqual(value, .contextualRetry)
    },
]
