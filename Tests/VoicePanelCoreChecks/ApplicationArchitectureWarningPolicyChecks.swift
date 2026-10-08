import Foundation
import VoicePanelCore

let applicationArchitectureWarningPolicyChecks: [CheckCase] = [
    CheckCase(name: "Intel app on Apple Silicon through Rosetta shows a warning") {
        try expect(
            ApplicationArchitectureWarningPolicy.shouldWarnAboutRosetta(
                executableIsIntel: true,
                hostSupportsAppleSilicon: true,
                processIsTranslated: true
            ),
            "translated Intel execution on Apple Silicon must be visible to the user"
        )
    },
    CheckCase(name: "Native Apple Silicon app does not show an architecture warning") {
        try expect(
            !ApplicationArchitectureWarningPolicy.shouldWarnAboutRosetta(
                executableIsIntel: false,
                hostSupportsAppleSilicon: true,
                processIsTranslated: false
            ),
            "a native arm64 app must not warn"
        )
    },
    CheckCase(name: "Native Intel Mac does not show an architecture warning") {
        try expect(
            !ApplicationArchitectureWarningPolicy.shouldWarnAboutRosetta(
                executableIsIntel: true,
                hostSupportsAppleSilicon: false,
                processIsTranslated: false
            ),
            "an Intel app is native on an Intel Mac"
        )
    },
]
