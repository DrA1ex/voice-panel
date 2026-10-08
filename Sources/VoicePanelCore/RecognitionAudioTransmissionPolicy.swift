import Foundation

public enum RecognitionBufferDisposition: Equatable, Sendable {
    case transmit
    case bufferForPreRoll
    case flushBufferedAndTransmit
}

/// Decides whether microphone buffers should be sent to recognition while
/// optional silence suppression is enabled. Speech candidates are retained in
/// a short pre-roll buffer so the beginning of a phrase is not clipped.
public struct RecognitionAudioTransmissionPolicy: Equatable, Sendable {
    public var suppressDetectedSilence: Bool

    public init(suppressDetectedSilence: Bool = false) {
        self.suppressDetectedSilence = suppressDetectedSilence
    }

    public func disposition(for event: VoiceActivityEvent) -> RecognitionBufferDisposition {
        guard suppressDetectedSilence else { return .transmit }

        switch event {
        case .silence:
            return .bufferForPreRoll
        case .speechStarted:
            return .flushBufferedAndTransmit
        case .speechContinued, .possiblePause, .speechEnded:
            return .transmit
        }
    }
}
