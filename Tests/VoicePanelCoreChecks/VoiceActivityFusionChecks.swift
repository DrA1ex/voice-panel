import Foundation
import VoicePanelCore

let voiceActivityFusionChecks: [CheckCase] = [
    CheckCase(name: "Energy mode preserves the existing detector event") {
        var fusion = VoiceActivityFusion()
        let snapshot = VoiceActivitySnapshot(
            state: .speech,
            rmsDB: -20,
            noiseFloorDB: -55,
            thresholdDB: -43
        )
        let result = fusion.process(
            mode: .energy,
            energyEvent: .speechStarted,
            energySnapshot: snapshot,
            neuralSpeechDetected: false,
            frameDuration: 0.1,
            endOfSpeechSilenceDuration: 0.3
        )
        try expectEqual(result.0, .speechStarted)
        try expectEqual(result.1, snapshot)
    },

    CheckCase(name: "Silero mode starts and ends speech from neural decisions") {
        var fusion = VoiceActivityFusion()
        let silence = VoiceActivitySnapshot(
            state: .silence,
            rmsDB: -55,
            noiseFloorDB: -58,
            thresholdDB: -46
        )
        let started = fusion.process(
            mode: .silero,
            energyEvent: .silence,
            energySnapshot: silence,
            neuralSpeechDetected: true,
            frameDuration: 0.1,
            endOfSpeechSilenceDuration: 0.2
        )
        try expectEqual(started.0, .speechStarted)
        let pause = fusion.process(
            mode: .silero,
            energyEvent: .silence,
            energySnapshot: silence,
            neuralSpeechDetected: false,
            frameDuration: 0.1,
            endOfSpeechSilenceDuration: 0.2
        )
        try expectEqual(pause.0, .possiblePause(duration: 0.1))
        let ended = fusion.process(
            mode: .silero,
            energyEvent: .silence,
            energySnapshot: silence,
            neuralSpeechDetected: false,
            frameDuration: 0.1,
            endOfSpeechSilenceDuration: 0.2
        )
        try expectEqual(ended.0, .speechEnded(silenceDuration: 0.2))
    },

    CheckCase(name: "Missing neural output safely falls back to energy") {
        var fusion = VoiceActivityFusion()
        let snapshot = VoiceActivitySnapshot(
            state: .speech,
            rmsDB: -25,
            noiseFloorDB: -56,
            thresholdDB: -44
        )
        let result = fusion.process(
            mode: .hybrid,
            energyEvent: .speechStarted,
            energySnapshot: snapshot,
            neuralSpeechDetected: nil,
            frameDuration: 0.1,
            endOfSpeechSilenceDuration: 0.3
        )
        try expectEqual(result.0, .speechStarted)
    },
]
