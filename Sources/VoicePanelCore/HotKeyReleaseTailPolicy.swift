import Foundation

public enum HotKeyReleaseTailPolicy {
    public static let defaultDuration: TimeInterval = 0.3
    public static let maximumDuration: TimeInterval = 2.0

    public static func effectiveDuration(
        isEnabled: Bool,
        configuredDuration: TimeInterval
    ) -> TimeInterval {
        guard isEnabled else { return 0 }
        return min(max(0, configuredDuration), maximumDuration)
    }

    public static func scheduledDuration(
        isEnabled: Bool,
        configuredDuration: TimeInterval,
        phase: RecordingControlPhase,
        source: RecordingControlSource?
    ) -> TimeInterval {
        guard source == .hotKeyHold else { return 0 }
        switch phase {
        case .preparing, .listening:
            return effectiveDuration(
                isEnabled: isEnabled,
                configuredDuration: configuredDuration
            )
        case .idle, .finalizing:
            return 0
        }
    }
}
