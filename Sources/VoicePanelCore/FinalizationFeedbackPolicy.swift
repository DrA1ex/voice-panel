import Foundation

public enum FinalizationFeedbackPolicy {
    public static func remainingDelay(
        elapsed: TimeInterval,
        minimumVisibleDuration: TimeInterval
    ) -> TimeInterval {
        max(0, max(0, minimumVisibleDuration) - max(0, elapsed))
    }
}
