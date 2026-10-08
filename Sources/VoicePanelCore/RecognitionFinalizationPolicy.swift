public enum RecognitionFinalizationSignal: Equatable, Sendable {
    case transcriptUpdate(isSessionFinal: Bool)
    case engineFinished
    case timeout
}

public enum RecognitionFinalizationAction: Equatable, Sendable {
    case wait
    case complete
    case fail
}

public enum RecognitionFinalizationPolicy {
    public static func action(for signal: RecognitionFinalizationSignal) -> RecognitionFinalizationAction {
        switch signal {
        case .transcriptUpdate:
            return .wait
        case .engineFinished:
            return .complete
        case .timeout:
            return .fail
        }
    }
}
