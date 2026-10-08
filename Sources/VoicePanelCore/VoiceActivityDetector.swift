import Foundation

public enum VoiceActivityState: String, Equatable, Sendable {
    case silence
    case speech
    case possiblePause
}

public enum VoiceActivityEvent: Equatable, Sendable {
    case silence
    case speechStarted
    case speechContinued
    case possiblePause(duration: TimeInterval)
    case speechEnded(silenceDuration: TimeInterval)
}

public struct VoiceActivitySnapshot: Equatable, Sendable {
    public let state: VoiceActivityState
    public let rmsDB: Float
    public let noiseFloorDB: Float
    public let thresholdDB: Float

    public init(state: VoiceActivityState, rmsDB: Float, noiseFloorDB: Float, thresholdDB: Float) {
        self.state = state
        self.rmsDB = rmsDB
        self.noiseFloorDB = noiseFloorDB
        self.thresholdDB = thresholdDB
    }
}

public struct VoiceActivityDetector: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var adaptiveThreshold: Bool
        public var manualThresholdDB: Float?
        public var thresholdMarginDB: Float
        public var hysteresisDB: Float
        public var minimumSpeechDuration: TimeInterval
        public var endOfSpeechSilenceDuration: TimeInterval
        public var maximumHysteresisHoldDuration: TimeInterval
        public var initialNoiseFloorDB: Float
        public var minimumThresholdDB: Float
        public var maximumThresholdDB: Float
        public var noiseRiseAlpha: Float
        public var noiseFallAlpha: Float
        public var minimumNoiseObservationDB: Float

        public init(
            adaptiveThreshold: Bool = true,
            manualThresholdDB: Float? = nil,
            thresholdMarginDB: Float = 12,
            hysteresisDB: Float = 3,
            minimumSpeechDuration: TimeInterval = 0.10,
            endOfSpeechSilenceDuration: TimeInterval = 0.65,
            maximumHysteresisHoldDuration: TimeInterval = 1.0,
            initialNoiseFloorDB: Float = -58,
            minimumThresholdDB: Float = -52,
            maximumThresholdDB: Float = -18,
            noiseRiseAlpha: Float = 0.015,
            noiseFallAlpha: Float = 0.08,
            minimumNoiseObservationDB: Float = -80
        ) {
            self.adaptiveThreshold = adaptiveThreshold
            self.manualThresholdDB = manualThresholdDB
            self.thresholdMarginDB = thresholdMarginDB
            self.hysteresisDB = hysteresisDB
            self.minimumSpeechDuration = minimumSpeechDuration
            self.endOfSpeechSilenceDuration = endOfSpeechSilenceDuration
            self.maximumHysteresisHoldDuration = maximumHysteresisHoldDuration
            self.initialNoiseFloorDB = initialNoiseFloorDB
            self.minimumThresholdDB = minimumThresholdDB
            self.maximumThresholdDB = maximumThresholdDB
            self.noiseRiseAlpha = noiseRiseAlpha
            self.noiseFallAlpha = noiseFallAlpha
            self.minimumNoiseObservationDB = minimumNoiseObservationDB
        }

        public static let sensitive = Configuration(
            thresholdMarginDB: 8,
            hysteresisDB: 2,
            minimumSpeechDuration: 0.08,
            endOfSpeechSilenceDuration: 0.75
        )

        public static let balanced = Configuration()

        public static let noiseResistant = Configuration(
            thresholdMarginDB: 16,
            hysteresisDB: 4,
            minimumSpeechDuration: 0.14,
            endOfSpeechSilenceDuration: 0.55
        )

        public func threshold(for noiseFloorDB: Float) -> Float {
            let raw = manualThresholdDB ?? (noiseFloorDB + thresholdMarginDB)
            return min(max(raw, minimumThresholdDB), maximumThresholdDB)
        }
    }

    public private(set) var configuration: Configuration
    public private(set) var state: VoiceActivityState = .silence
    public private(set) var noiseFloorDB: Float
    public private(set) var thresholdDB: Float

    private var speechCandidateDuration: TimeInterval = 0
    private var silenceDuration: TimeInterval = 0

    public init(configuration: Configuration = .balanced) {
        self.configuration = configuration
        self.noiseFloorDB = configuration.initialNoiseFloorDB
        self.thresholdDB =
            configuration.manualThresholdDB ?? configuration.initialNoiseFloorDB + configuration.thresholdMarginDB
        self.thresholdDB = min(
            max(self.thresholdDB, configuration.minimumThresholdDB), configuration.maximumThresholdDB)
    }

    public mutating func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
        if !noiseFloorDB.isFinite || noiseFloorDB < configuration.minimumNoiseObservationDB {
            noiseFloorDB = configuration.initialNoiseFloorDB
        }
        thresholdDB = resolvedThreshold()
    }

    public mutating func reset() {
        state = .silence
        noiseFloorDB = configuration.initialNoiseFloorDB
        thresholdDB = resolvedThreshold()
        speechCandidateDuration = 0
        silenceDuration = 0
    }

    @discardableResult
    public mutating func process(rmsDB: Float, frameDuration: TimeInterval) -> (
        VoiceActivityEvent, VoiceActivitySnapshot
    ) {
        let duration = max(0, frameDuration)
        thresholdDB = resolvedThreshold()

        let event: VoiceActivityEvent
        switch state {
        case .silence:
            if rmsDB >= thresholdDB {
                speechCandidateDuration += duration
                if speechCandidateDuration >= configuration.minimumSpeechDuration {
                    state = .speech
                    silenceDuration = 0
                    speechCandidateDuration = 0
                    event = .speechStarted
                } else {
                    event = .silence
                }
            } else {
                speechCandidateDuration = 0
                adaptNoiseFloor(with: rmsDB)
                thresholdDB = resolvedThreshold()
                event = .silence
            }

        case .speech, .possiblePause:
            let continuationThreshold = thresholdDB - configuration.hysteresisDB
            if rmsDB >= thresholdDB {
                state = .speech
                silenceDuration = 0
                event = .speechContinued
            } else {
                silenceDuration += duration
                let requiredSilence =
                    rmsDB >= continuationThreshold
                    ? max(
                        configuration.endOfSpeechSilenceDuration,
                        configuration.maximumHysteresisHoldDuration
                    )
                    : configuration.endOfSpeechSilenceDuration
                // Repeated audio-frame durations are floating-point values. A nominal
                // one-second pause can accumulate as 0.9999999999999999 and must not
                // require one extra hardware buffer before closing the chunk.
                if silenceDuration >= requiredSilence - 0.000_001 {
                    let endedAfter = silenceDuration
                    state = .silence
                    silenceDuration = 0
                    speechCandidateDuration = 0
                    adaptNoiseFloor(with: rmsDB)
                    thresholdDB = resolvedThreshold()
                    event = .speechEnded(silenceDuration: endedAfter)
                } else {
                    state = .possiblePause
                    event = .possiblePause(duration: silenceDuration)
                }
            }
        }

        let snapshot = VoiceActivitySnapshot(
            state: state,
            rmsDB: rmsDB,
            noiseFloorDB: noiseFloorDB,
            thresholdDB: thresholdDB
        )
        return (event, snapshot)
    }

    private mutating func adaptNoiseFloor(with rmsDB: Float) {
        guard configuration.adaptiveThreshold, configuration.manualThresholdDB == nil else { return }
        guard rmsDB.isFinite, rmsDB >= configuration.minimumNoiseObservationDB else { return }
        let alpha = rmsDB > noiseFloorDB ? configuration.noiseRiseAlpha : configuration.noiseFallAlpha
        noiseFloorDB += (rmsDB - noiseFloorDB) * alpha
        noiseFloorDB = min(max(noiseFloorDB, -90), -10)
    }

    private func resolvedThreshold() -> Float {
        configuration.threshold(for: noiseFloorDB)
    }
}
