import Foundation

public enum RecordingStopAction: Equatable, Sendable {
    case discardTooShort
    case flushAndFinalize
}

public enum RecordingStopPolicy {
    public static let defaultMinimumDuration: TimeInterval = 1

    public static func action(
        for capturedDuration: TimeInterval,
        minimumDuration: TimeInterval = defaultMinimumDuration
    ) -> RecordingStopAction {
        capturedDuration < max(0, minimumDuration)
            ? .discardTooShort
            : .flushAndFinalize
    }
}
