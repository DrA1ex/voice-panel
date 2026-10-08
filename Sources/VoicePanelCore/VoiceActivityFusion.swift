import Foundation

public enum VoiceActivityDetectionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case energy
    case silero
    case hybrid

    public var id: String { rawValue }
}

/// Combines the low-latency adaptive energy detector with an optional neural
/// speech decision. Missing neural output always falls back to energy so a
/// model load or runtime failure cannot silently discard a recording.
public struct VoiceActivityFusion: Sendable {
    private var isSpeechActive = false
    private var neuralSilenceDuration: TimeInterval = 0
    private var hasObservedNeuralSpeech = false
    public private(set) var neuralPauseEvidenceDuration: TimeInterval = 0

    public init() {}

    public mutating func process(
        mode: VoiceActivityDetectionMode,
        energyEvent: VoiceActivityEvent,
        energySnapshot: VoiceActivitySnapshot,
        neuralSpeechDetected: Bool?,
        frameDuration: TimeInterval,
        endOfSpeechSilenceDuration: TimeInterval
    ) -> (VoiceActivityEvent, VoiceActivitySnapshot) {
        updateNeuralPauseEvidence(
            mode: mode,
            neuralSpeechDetected: neuralSpeechDetected,
            frameDuration: frameDuration
        )
        guard mode != .energy, let neuralSpeechDetected else {
            isSpeechActive = energySnapshot.state != .silence
            neuralSilenceDuration = 0
            return (energyEvent, energySnapshot)
        }

        let effectiveSpeech: Bool
        switch mode {
        case .energy:
            effectiveSpeech = energySnapshot.state != .silence
        case .silero:
            effectiveSpeech = neuralSpeechDetected
        case .hybrid:
            // Silero decides when speech begins. Once a phrase is active, the
            // energy detector may keep a quiet tail open until both agree it ended.
            effectiveSpeech =
                neuralSpeechDetected
                || (isSpeechActive && energySnapshot.state != .silence)
        }

        let event: VoiceActivityEvent
        if effectiveSpeech {
            neuralSilenceDuration = 0
            event = isSpeechActive ? .speechContinued : .speechStarted
            isSpeechActive = true
        } else if isSpeechActive {
            neuralSilenceDuration += max(0, frameDuration)
            if neuralSilenceDuration >= max(0, endOfSpeechSilenceDuration) {
                event = .speechEnded(silenceDuration: neuralSilenceDuration)
                isSpeechActive = false
                neuralSilenceDuration = 0
            } else {
                event = .possiblePause(duration: neuralSilenceDuration)
            }
        } else {
            neuralSilenceDuration = 0
            event = .silence
        }

        let state: VoiceActivityState
        switch event {
        case .silence, .speechEnded:
            state = .silence
        case .speechStarted, .speechContinued:
            state = .speech
        case .possiblePause:
            state = .possiblePause
        }
        return (
            event,
            VoiceActivitySnapshot(
                state: state,
                rmsDB: energySnapshot.rmsDB,
                noiseFloorDB: energySnapshot.noiseFloorDB,
                thresholdDB: energySnapshot.thresholdDB
            )
        )
    }

    public mutating func reset() {
        isSpeechActive = false
        neuralSilenceDuration = 0
        hasObservedNeuralSpeech = false
        neuralPauseEvidenceDuration = 0
    }

    private mutating func updateNeuralPauseEvidence(
        mode: VoiceActivityDetectionMode,
        neuralSpeechDetected: Bool?,
        frameDuration: TimeInterval
    ) {
        guard mode != .energy, let neuralSpeechDetected else {
            hasObservedNeuralSpeech = false
            neuralPauseEvidenceDuration = 0
            return
        }
        if neuralSpeechDetected {
            hasObservedNeuralSpeech = true
            neuralPauseEvidenceDuration = 0
        } else if hasObservedNeuralSpeech {
            neuralPauseEvidenceDuration += max(0, frameDuration)
        }
    }
}
