import Foundation

public enum RecordingPreparationAudioDecision: Equatable, Sendable {
    case include
    case discard
}

public enum RecordingPreparationAudioPolicy {
    public static let automaticInclusionDuration: TimeInterval = 1.0

    public static func decision(
        capturedDuration: TimeInterval,
        includeWhenPreparationIsLong: Bool,
        automaticInclusionDuration: TimeInterval = automaticInclusionDuration
    ) -> RecordingPreparationAudioDecision {
        let duration = max(0, capturedDuration)
        let threshold = max(0, automaticInclusionDuration)
        if duration <= threshold || includeWhenPreparationIsLong {
            return .include
        }
        return .discard
    }
}
