import Foundation

public struct PendingFeedbackPresentation: Equatable, Sendable {
    public let isActivelySpeaking: Bool
    public let activeItemCount: Int
    public let frozenItemCount: Int

    public init(
        isActivelySpeaking: Bool,
        activeItemCount: Int,
        frozenItemCount: Int
    ) {
        self.isActivelySpeaking = isActivelySpeaking
        self.activeItemCount = activeItemCount
        self.frozenItemCount = frozenItemCount
    }

    public var itemCount: Int {
        activeItemCount + frozenItemCount
    }

    public var hasVisibleItems: Bool {
        itemCount > 0
    }

    public var animatesActiveTail: Bool {
        hasVisibleItems
    }
}

public enum PendingFeedbackPolicy {
    public static func itemExtent(
        forVoicedDuration voicedDuration: TimeInterval,
        activationDelay: TimeInterval = 0,
        growthCadence: TimeInterval = 0.65,
        maximumItemCount: Int = 8
    ) -> Double {
        guard activationDelay >= 0, growthCadence > 0, maximumItemCount > 0 else { return 0 }
        let duration = max(0, voicedDuration)
        guard duration > 0, duration >= activationDelay else { return 0 }
        return min(
            Double(maximumItemCount),
            1 + (duration - activationDelay) / growthCadence
        )
    }

    public static func itemCount(
        forVoicedDuration voicedDuration: TimeInterval,
        activationDelay: TimeInterval = 0,
        growthCadence: TimeInterval = 0.65,
        maximumItemCount: Int = 8
    ) -> Int {
        guard activationDelay >= 0, growthCadence > 0, maximumItemCount > 0 else { return 0 }
        let duration = max(0, voicedDuration)
        guard duration > 0, duration >= activationDelay else { return 0 }
        return min(
            maximumItemCount,
            max(1, Int(floor((duration - activationDelay) / growthCadence + 1e-9)) + 1)
        )
    }

    public static func presentation(
        isRecording: Bool,
        voiceActivityState: VoiceActivityState,
        activeVoicedDuration: TimeInterval,
        frozenItemCount: Int,
        maximumItemCount: Int = 8
    ) -> PendingFeedbackPresentation {
        guard isRecording, maximumItemCount > 0 else {
            return PendingFeedbackPresentation(
                isActivelySpeaking: false,
                activeItemCount: 0,
                frozenItemCount: 0
            )
        }

        let activeCount = itemCount(
            forVoicedDuration: activeVoicedDuration,
            maximumItemCount: maximumItemCount
        )
        let boundedFrozenCount = min(maximumItemCount, max(0, frozenItemCount))
        return PendingFeedbackPresentation(
            isActivelySpeaking: voiceActivityState == .speech,
            activeItemCount: activeCount,
            frozenItemCount: min(maximumItemCount - activeCount, boundedFrozenCount)
        )
    }
}

public enum PendingFeedbackTimingPolicy {
    public static let appearanceDelay: TimeInterval = 0.30
    public static let minimumVisibleDuration: TimeInterval = 0.60

    public static func remainingVisibleDuration(after elapsed: TimeInterval) -> TimeInterval {
        max(0, minimumVisibleDuration - max(0, elapsed))
    }
}
