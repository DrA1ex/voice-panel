import Foundation

public struct TimedDraftToken: Equatable, Sendable {
    public let text: String
    public let captureTime: TimeInterval
    /// The position is the capture time when Apple first reported the word,
    /// not its spoken time, so it lags the speech by the recognizer latency.
    public let isEstimated: Bool

    public init(text: String, captureTime: TimeInterval, isEstimated: Bool = false) {
        self.text = text
        self.captureTime = captureTime
        self.isEstimated = isEstimated
    }
}

public enum DraftTokenTiming {
    /// Interim Apple results can omit word timing. Keep the observed positions
    /// of unchanged words; a revised middle inherits only its previous span,
    /// and appended words belong to the currently captured audio.
    public static func observedTokens(
        text: String, previous: [TimedDraftToken], captureTime: TimeInterval
    ) -> [TimedDraftToken] {
        let source = text as NSString
        let expression = try! NSRegularExpression(pattern: #"\S+\s*"#)
        let pieces = expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            TranscriptTextNormalizer.normalize(source.substring(with: $0.range))
        }
        func key(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(
                in: .punctuationCharacters)
        }
        var prefix = 0
        while prefix < min(pieces.count, previous.count), key(pieces[prefix]) == key(previous[prefix].text) {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(pieces.count, previous.count) - prefix,
            key(pieces[pieces.count - suffix - 1]) == key(previous[previous.count - suffix - 1].text)
        {
            suffix += 1
        }
        return pieces.enumerated().map { index, piece in
            let source: TimedDraftToken?
            if index < prefix {
                source = previous[index]
            } else if index >= pieces.count - suffix {
                source = previous[previous.count - (pieces.count - index)]
            } else if index < previous.count - suffix {
                source = previous[index]
            } else if suffix > 0 {
                // An insertion before an unchanged suffix belongs to that
                // existing span, rather than jumping past the suffix in time.
                source = previous[previous.count - suffix]
            } else {
                source = nil
            }
            return TimedDraftToken(
                text: piece, captureTime: source?.captureTime ?? captureTime,
                isEstimated: source?.isEstimated ?? true
            )
        }
    }
}

/// Partitions the continuous Apple hypothesis at the actual captured audio cuts,
/// including cuts delivered retrospectively after a longer decision window.
public struct TimedDraftTimeline: Sendable {
    /// Upper bound of Apple's reporting delay for an untimed interim word.
    static let estimatedTimingLag: TimeInterval = 1.5
    private static let maximumLateDuplicateTokens = 4

    private var tokens: [TimedDraftToken] = []
    private var chunkEnds: [TimeInterval] = []
    private var finalTexts: [Int: String] = [:]
    private var publishedText: [Int: String] = [:]

    public init() {}

    public mutating func register(_ chunk: AudioChunk) {
        guard let range = chunk.captureTimeRange else { return }
        chunkEnds.append(range.upperBound)
    }

    public mutating func replaceTokens(_ tokens: [TimedDraftToken]) {
        self.tokens = tokens
    }

    public mutating func registerFinal(sequence: Int, text: String) {
        finalTexts[sequence] = text
    }

    public mutating func updates(alignment: inout DraftFinalSegmentAlignment) -> [TranscriptSegmentUpdate] {
        var tokensBySequence: [Int: [TimedDraftToken]] = [:]
        for token in tokens {
            guard token.captureTime.isFinite else { continue }
            let sequence = chunkEnds.firstIndex(where: { token.captureTime < $0 }) ?? chunkEnds.count
            guard !alignment.isFinalized(sequence: sequence) else { continue }
            tokensBySequence[sequence, default: []].append(token)
        }
        var textBySequence: [Int: String] = [:]
        for (sequence, sequenceTokens) in tokensBySequence {
            textBySequence[sequence] = trimmingLateDuplicates(sequenceTokens, sequence: sequence)
                .reduce("") { TranscriptTextMerger.join($0, $1.text) }
        }
        let sequences = Set(textBySequence.keys).union(publishedText.keys).sorted()
        var updates: [TranscriptSegmentUpdate] = []
        for sequence in sequences where !alignment.isFinalized(sequence: sequence) {
            let text = textBySequence[sequence] ?? ""
            guard text != publishedText[sequence] else { continue }
            updates.append(
                TranscriptSegmentUpdate(
                    segmentID: alignment.segmentIDForDraft(sequence: sequence), sequence: sequence,
                    stableText: "", partialText: text, kind: .partial, allowsLeadingOverlap: false
                )
            )
        }
        publishedText = textBySequence
        return updates
    }

    /// Estimated positions lag the speech, so the last words before a cut can
    /// land after it. Drop those the preceding final text already ends with.
    private func trimmingLateDuplicates(
        _ tokens: [TimedDraftToken], sequence: Int
    ) -> ArraySlice<TimedDraftToken> {
        guard sequence > 0, sequence - 1 < chunkEnds.count,
            let finalText = finalTexts[sequence - 1]
        else { return tokens[...] }
        let limit = chunkEnds[sequence - 1] + Self.estimatedTimingLag
        let candidates = tokens.prefix { $0.isEstimated && $0.captureTime < limit }
        let finalKeys = SpeechUtteranceAccumulator.keys(finalText)
        for count in stride(from: min(candidates.count, Self.maximumLateDuplicateTokens), through: 1, by: -1) {
            let draftKeys = candidates.prefix(count).flatMap { SpeechUtteranceAccumulator.keys($0.text) }
            if !draftKeys.isEmpty, draftKeys.count <= finalKeys.count,
                Array(finalKeys.suffix(draftKeys.count)) == draftKeys
            {
                return tokens.dropFirst(count)
            }
        }
        return tokens[...]
    }

    public mutating func reset() {
        tokens.removeAll(keepingCapacity: true)
        chunkEnds.removeAll(keepingCapacity: true)
        finalTexts.removeAll(keepingCapacity: true)
        publishedText.removeAll(keepingCapacity: true)
    }
}
