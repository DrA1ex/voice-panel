public enum RecordingControlSource: Equatable, Sendable {
    case hotKeyHold
    case hotKeyLatched
    case menu

    public var requiresManualStop: Bool {
        self != .hotKeyHold
    }
}

public enum RecordingControlPhase: Equatable, Sendable {
    case idle
    case preparing
    case listening
    case finalizing
}

public enum RecordingControlEvent: Equatable, Sendable {
    case hotKeyPressed
    case hotKeyReleased
    case latchHotKey
    case menuToggle
}

public enum RecordingControlDecision: Equatable, Sendable {
    case start(RecordingControlSource)
    case stop
    case cancelPreparation
    case finishPreparationThenStop
    case latchHotKey
    case none
}

public enum RecordingControlPolicy {
    public static func decide(
        event: RecordingControlEvent,
        phase: RecordingControlPhase,
        activeSource: RecordingControlSource?
    ) -> RecordingControlDecision {
        switch event {
        case .hotKeyPressed:
            return phase == .idle ? .start(.hotKeyHold) : .none

        case .hotKeyReleased:
            guard activeSource == .hotKeyHold else { return .none }
            switch phase {
            case .preparing: return .finishPreparationThenStop
            case .listening: return .stop
            case .idle, .finalizing: return .none
            }

        case .latchHotKey:
            guard activeSource == .hotKeyHold else { return .none }
            switch phase {
            case .preparing, .listening: return .latchHotKey
            case .idle, .finalizing: return .none
            }

        case .menuToggle:
            switch phase {
            case .idle:
                return .start(.menu)
            case .preparing where activeSource == .menu:
                return .cancelPreparation
            case .preparing where activeSource == .hotKeyLatched:
                return .cancelPreparation
            case .listening where activeSource == .menu:
                return .stop
            case .listening where activeSource == .hotKeyLatched:
                return .stop
            case .preparing, .listening, .finalizing:
                return .none
            }
        }
    }
}
