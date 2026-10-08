import Darwin
import VoicePanelCore

enum RuntimeArchitectureCompatibility {
    static var shouldWarnAboutRosetta: Bool {
        ApplicationArchitectureWarningPolicy.shouldWarnAboutRosetta(
            executableIsIntel: executableIsIntel,
            hostSupportsAppleSilicon: sysctlFlag(named: "hw.optional.arm64"),
            processIsTranslated: sysctlFlag(named: "sysctl.proc_translated")
        )
    }

    private static var executableIsIntel: Bool {
        #if arch(x86_64)
            true
        #else
            false
        #endif
    }

    private static func sysctlFlag(named name: String) -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return false }
        return value == 1
    }
}
