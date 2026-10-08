import Foundation
import VoicePanelCore

let recordingPreparationAudioPolicyChecks: [CheckCase] = [
    CheckCase(name: "Preparation audio up to one second is always included") {
        try expectEqual(
            RecordingPreparationAudioPolicy.decision(
                capturedDuration: 1.0,
                includeWhenPreparationIsLong: false
            ),
            .include
        )
    },
    CheckCase(name: "Long preparation audio follows the user preference") {
        try expectEqual(
            RecordingPreparationAudioPolicy.decision(
                capturedDuration: 1.01,
                includeWhenPreparationIsLong: false
            ),
            .discard
        )
        try expectEqual(
            RecordingPreparationAudioPolicy.decision(
                capturedDuration: 8,
                includeWhenPreparationIsLong: true
            ),
            .include
        )
    },
]
