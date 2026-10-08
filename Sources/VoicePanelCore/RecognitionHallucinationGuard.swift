import Foundation

public struct RecognitionHallucinationGuard: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var isEnabled: Bool
        /// Conservative lower bound of the active microphone's speech threshold.
        public var silenceThresholdDB: Float

        public init(isEnabled: Bool = false, silenceThresholdDB: Float = -52) {
            self.isEnabled = isEnabled
            self.silenceThresholdDB = silenceThresholdDB
        }

        public static let disabled = Configuration()
    }

    public init() {}

    /// Returns a conservative rejection reason for patterns that are very
    /// unlikely to be a faithful transcript. The feature is opt-in because a
    /// user may intentionally dictate repetitive text.
    public func rejectionReason(
        for text: String,
        chunk: AudioChunk,
        configuration: Configuration
    ) -> String? {
        guard configuration.isEnabled else { return nil }
        let normalized = tokens(text)
        guard !normalized.isEmpty else { return nil }

        if isKnownArtifact(normalized),
            isLowSignal(chunk.samples[...], sampleRate: chunk.sampleRate, configuration: configuration)
        {
            return "typical hallucination phrase over low-level audio"
        }

        let speechDuration: TimeInterval
        if let speechRange = chunk.speechRange, chunk.sampleRate > 0 {
            speechDuration = Double(speechRange.count) / chunk.sampleRate
        } else {
            speechDuration = chunk.duration
        }

        if speechDuration < 0.22, normalized.count >= 5 {
            return "too much text for a very short speech fragment"
        }

        let nonWhitespaceCount = text.filter { !$0.isWhitespace }.count
        if speechDuration > 0, nonWhitespaceCount >= 24,
            Double(nonWhitespaceCount) / speechDuration > 55
        {
            return "implausible text rate"
        }

        if longestIdenticalTokenRun(normalized) >= 5 {
            return "repeated token loop"
        }

        let maximumPatternLength = min(3, normalized.count / 4)
        if maximumPatternLength >= 1 {
            for patternLength in 1...maximumPatternLength {
                let pattern = Array(normalized.prefix(patternLength))
                var matched = 0
                while matched + patternLength <= normalized.count,
                    Array(normalized[matched..<(matched + patternLength)]) == pattern
                {
                    matched += patternLength
                }
                if matched >= 8, Double(matched) / Double(normalized.count) >= 0.8 {
                    return "repeated phrase loop"
                }
            }
        }
        return nil
    }

    /// Remove only independently timed artifact segments. A silent tail must
    /// not discard real speech elsewhere in the same inference window.
    public func filteringLowSignalArtifacts(
        from result: WhisperTranscriptionResult,
        chunk: AudioChunk,
        configuration: Configuration
    ) -> WhisperTranscriptionResult {
        guard configuration.isEnabled else { return result }
        guard !result.segments.isEmpty else {
            guard isKnownArtifact(tokens(result.text)),
                isLowSignal(chunk.samples[...], sampleRate: chunk.sampleRate, configuration: configuration)
            else { return result }
            return WhisperTranscriptionResult(
                text: "", segments: [], detectedLanguage: result.detectedLanguage,
                inferenceDuration: result.inferenceDuration
            )
        }
        // Repair results may carry baseline evidence for different text. Do
        // not rebuild those transcripts from unrelated segment metadata.
        guard tokens(result.segments.map(\.text).joined(separator: " ")) == tokens(result.text) else {
            return result
        }
        let retained = result.segments.filter { segment in
            guard isKnownArtifact(tokens(segment.text)),
                chunk.sampleRate.isFinite, chunk.sampleRate > 0,
                segment.startTime.isFinite, segment.endTime.isFinite,
                segment.startTime >= 0, segment.endTime > segment.startTime,
                segment.startTime < chunk.duration
            else { return true }
            let lower = Int((segment.startTime * chunk.sampleRate).rounded(.down))
            let upper = Int((min(segment.endTime, chunk.duration) * chunk.sampleRate).rounded(.up))
            return !isLowSignal(
                chunk.samples[lower..<min(upper, chunk.samples.count)],
                sampleRate: chunk.sampleRate, configuration: configuration
            )
        }
        guard retained.count != result.segments.count else { return result }
        return WhisperTranscriptionResult(
            text: retained.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            segments: retained, detectedLanguage: result.detectedLanguage,
            inferenceDuration: result.inferenceDuration
        )
    }

    public func rejectionReason(
        for result: WhisperTranscriptionResult,
        chunk: AudioChunk,
        configuration: Configuration
    ) -> String? {
        let filtered = filteringLowSignalArtifacts(from: result, chunk: chunk, configuration: configuration)
        if filtered.text != result.text || filtered.segments.count != result.segments.count {
            return "typical hallucination phrase over low-level audio"
        }
        return rejectionReason(for: result.text, chunk: chunk, configuration: configuration)
    }

    private func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private func isKnownArtifact(_ words: [String]) -> Bool {
        let phrase = words.joined(separator: " ")
        if [
            "thank you", "thanks", "thanks for watching", "thank you for watching",
            "спасибо", "спасибо за просмотр", "спасибо за внимание",
        ].contains(phrase) {
            return true
        }
        return phrase.hasPrefix("субтитры подготовил ")
            || phrase.hasPrefix("субтитры подготовила ")
            || phrase.hasPrefix("субтитры сделал ")
            || phrase.hasPrefix("субтитры создал ")
            || phrase.hasPrefix("редактор субтитров ")
            || phrase.hasPrefix("корректор ")
    }

    private func isLowSignal(
        _ samples: ArraySlice<Float>,
        sampleRate: Double,
        configuration: Configuration
    ) -> Bool {
        guard !samples.isEmpty, sampleRate.isFinite, sampleRate > 0,
            configuration.silenceThresholdDB.isFinite
        else { return false }
        let windowSize = max(1, Int(min(sampleRate * 0.02, Double(samples.count))))
        let thresholdPower = pow(10.0, Double(configuration.silenceThresholdDB) / 10)
        var start = samples.startIndex
        while start < samples.endIndex {
            let end = min(start + windowSize, samples.endIndex)
            var power = 0.0
            for sample in samples[start..<end] {
                guard sample.isFinite else { return false }
                power += Double(sample) * Double(sample)
            }
            // A short spoken phrase must not disappear in a long silent
            // segment's average. Every 20 ms window must be below threshold.
            if power / Double(end - start) >= thresholdPower { return false }
            start = end
        }
        return true
    }

    private func longestIdenticalTokenRun(_ tokens: [String]) -> Int {
        var longest = 0
        var current = 0
        var previous: String?
        for token in tokens {
            if token == previous {
                current += 1
            } else {
                previous = token
                current = 1
            }
            longest = max(longest, current)
        }
        return longest
    }
}
