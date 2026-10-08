import Foundation

public enum WhisperAudioPreparation {
    public static let defaultMinimumDuration: TimeInterval = 1.0

    /// whisper.cpp 1.7.5 ignores audio shorter than one second. Preserve the
    /// complete input and add trailing silence instead of dropping a short
    /// spoken phrase.
    public static func paddedToMinimumDuration(
        _ samples: [Float],
        sampleRate: Double = LinearAudioResampler.whisperSampleRate,
        minimumDuration: TimeInterval = defaultMinimumDuration
    ) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0, minimumDuration > 0 else { return samples }
        let minimumSampleCount = max(1, Int((sampleRate * minimumDuration).rounded(.up)))
        guard samples.count < minimumSampleCount else { return samples }
        return samples + Array(repeating: 0, count: minimumSampleCount - samples.count)
    }

    public static func resampledChunk(
        _ source: AudioChunk,
        samples: [Float],
        sampleRate: Double
    ) -> AudioChunk {
        let scaledSpeechRange: Range<Int>?
        if let speechRange = source.speechRange,
            !source.samples.isEmpty,
            !samples.isEmpty
        {
            let sourceCount = source.samples.count
            let lower = min(max(0, speechRange.lowerBound), sourceCount)
            let upper = min(max(lower, speechRange.upperBound), sourceCount)
            let scale = Double(samples.count) / Double(sourceCount)
            let scaledLower = min(
                samples.count,
                max(0, Int((Double(lower) * scale).rounded(.down)))
            )
            var scaledUpper = min(
                samples.count,
                max(scaledLower, Int((Double(upper) * scale).rounded(.up)))
            )
            if upper > lower, scaledLower < samples.count {
                scaledUpper = max(scaledUpper, scaledLower + 1)
            }
            scaledSpeechRange = scaledLower..<min(samples.count, scaledUpper)
        } else {
            scaledSpeechRange = nil
        }

        return AudioChunk(
            id: source.id,
            samples: samples,
            sampleRate: sampleRate,
            boundaryReason: source.boundaryReason,
            trailingOverlapDuration: source.trailingOverlapDuration,
            speechRange: scaledSpeechRange,
            speechEvidenceAnalyzed: source.speechEvidenceAnalyzed,
            captureTimeRange: source.captureTimeRange
        )
    }
}
