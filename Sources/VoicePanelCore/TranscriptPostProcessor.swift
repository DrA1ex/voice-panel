import Foundation

public struct TranscriptPostProcessingConfiguration: Equatable, Sendable {
    public var isEnabled: Bool
    public var languageCode: String?
    public var removesLanguageMismatchedHallucinations: Bool

    public init(
        isEnabled: Bool,
        languageCode: String? = nil,
        removesLanguageMismatchedHallucinations: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.languageCode = languageCode
        self.removesLanguageMismatchedHallucinations = removesLanguageMismatchedHallucinations
    }
}

public struct TranscriptPostProcessingResult: Equatable, Sendable {
    public let text: String
    public let removedSegmentCount: Int
    public let stitchedBoundaryCount: Int

    public init(text: String, removedSegmentCount: Int, stitchedBoundaryCount: Int) {
        self.text = text
        self.removedSegmentCount = removedSegmentCount
        self.stitchedBoundaryCount = stitchedBoundaryCount
    }

    public var didChange: Bool {
        removedSegmentCount > 0 || stitchedBoundaryCount > 0
    }
}

public struct TranscriptPostProcessingSegment: Equatable, Sendable {
    public let text: String
    public let boundaryMetadata: AudioChunkBoundaryMetadata?

    public var boundaryReason: AudioChunkBoundaryReason? {
        boundaryMetadata?.reason
    }

    public init(
        text: String,
        boundaryMetadata: AudioChunkBoundaryMetadata? = nil
    ) {
        self.text = text
        self.boundaryMetadata = boundaryMetadata
    }

    public init(
        text: String,
        boundaryReason: AudioChunkBoundaryReason?,
        trailingOverlapDuration: TimeInterval = 0
    ) {
        self.init(
            text: text,
            boundaryMetadata: boundaryReason.map {
                AudioChunkBoundaryMetadata(
                    reason: $0,
                    trailingOverlapDuration: trailingOverlapDuration
                )
            }
        )
    }
}

/// A conservative, language-independent final transcript cleanup pass.
///
/// It only edits relationships between independently recognized segments. It
/// deliberately avoids general grammar or spelling rewrites so already-correct
/// dictation cannot be silently paraphrased.
public enum TranscriptPostProcessor {
    private static let maximumOverlapWords = 16
    private static let sentenceEndingCharacters = CharacterSet(charactersIn: ".!?…\n")
    private static let punctuationCharacters = CharacterSet.punctuationCharacters

    private static let commonEnglishHallucinations: Set<String> = [
        "thank you",
        "thanks for watching",
        "thank you for watching",
        "please subscribe",
        "subscribe to the channel",
    ]

    public static func process(
        segments rawSegments: [String],
        configuration: TranscriptPostProcessingConfiguration
    ) -> TranscriptPostProcessingResult {
        process(
            segments: rawSegments.map { TranscriptPostProcessingSegment(text: $0) },
            configuration: configuration
        )
    }

    public static func process(
        segments rawSegments: [TranscriptPostProcessingSegment],
        configuration: TranscriptPostProcessingConfiguration
    ) -> TranscriptPostProcessingResult {
        let normalizedInput = rawSegments.compactMap { segment -> TranscriptPostProcessingSegment? in
            let text = TranscriptTextNormalizer.normalize(segment.text)
            guard !TranscriptTextMerger.isEffectivelyEmpty(text) else { return nil }
            return TranscriptPostProcessingSegment(
                text: text,
                boundaryMetadata: segment.boundaryMetadata
            )
        }

        guard configuration.isEnabled else {
            return TranscriptPostProcessingResult(
                text: TranscriptTextMerger.merge(normalizedInput.map(\.text)),
                removedSegmentCount: 0,
                stitchedBoundaryCount: 0
            )
        }

        var removedSegmentCount = 0
        var filtered: [TranscriptPostProcessingSegment] = []
        filtered.reserveCapacity(normalizedInput.count)

        for segment in normalizedInput {
            if shouldRemoveIsolatedHallucination(
                segment.text,
                languageCode: configuration.languageCode,
                enabled: configuration.removesLanguageMismatchedHallucinations
            ) {
                removedSegmentCount += 1
                continue
            }

            let segmentPhrase = canonicalPhrase(segment.text)
            if let previous = filtered.last,
                canonicalPhrase(previous.text) == segmentPhrase,
                segmentPhrase.split(separator: " ").count >= 2,
                (previous.boundaryMetadata?.trailingOverlapDuration ?? 0) > 0
            {
                removedSegmentCount += 1
                // The removed chunk still defines the audio boundary leading
                // into the following chunk. Preserve that boundary metadata on
                // the retained text so forced-continuation cleanup stays exact.
                filtered[filtered.count - 1] = TranscriptPostProcessingSegment(
                    text: previous.text,
                    boundaryMetadata: segment.boundaryMetadata
                )
                continue
            }
            filtered.append(segment)
        }

        guard let first = filtered.first else {
            return TranscriptPostProcessingResult(
                text: "",
                removedSegmentCount: removedSegmentCount,
                stitchedBoundaryCount: 0
            )
        }
        var result = first.text
        var previousBoundaryMetadata = first.boundaryMetadata

        var stitchedBoundaryCount = 0
        for segment in filtered.dropFirst() {
            let stitched = stitch(
                result,
                segment.text,
                boundaryMetadata: previousBoundaryMetadata
            )
            result = stitched.text
            if stitched.didStitch { stitchedBoundaryCount += 1 }
            previousBoundaryMetadata = segment.boundaryMetadata
        }

        return TranscriptPostProcessingResult(
            text: normalizeFinalText(result),
            removedSegmentCount: removedSegmentCount,
            stitchedBoundaryCount: stitchedBoundaryCount
        )
    }

    private struct StitchResult {
        let text: String
        let didStitch: Bool
    }

    private static func stitch(
        _ accumulated: String,
        _ next: String,
        boundaryMetadata: AudioChunkBoundaryMetadata?
    ) -> StitchResult {
        let left = TranscriptTextNormalizer.normalize(accumulated)
        let right = TranscriptTextNormalizer.normalize(next)
        guard !left.isEmpty else { return StitchResult(text: right, didStitch: false) }
        guard !right.isEmpty else { return StitchResult(text: left, didStitch: false) }
        guard !left.contains("\n"), !right.contains("\n") else {
            return StitchResult(text: TranscriptTextMerger.join(left, right), didStitch: false)
        }

        let leftWords = words(from: left)
        let rightWords = words(from: right)
        let maximumOverlap = min(maximumOverlapWords, leftWords.count, rightWords.count)
        let hasAudioOverlap = (boundaryMetadata?.trailingOverlapDuration ?? 0) > 0

        if hasAudioOverlap,
            leftWords.count >= 2,
            canonicalWords(leftWords) == canonicalWords(rightWords)
        {
            return StitchResult(text: left, didStitch: true)
        }

        if hasAudioOverlap, maximumOverlap >= 2 {
            for count in stride(from: maximumOverlap, through: 2, by: -1) {
                let leftOverlap = Array(leftWords.suffix(count))
                let rightOverlap = Array(rightWords.prefix(count))
                if overlaps(leftOverlap, rightOverlap) {
                    return StitchResult(
                        text: rebuild(
                            leftWords: leftWords,
                            rightWords: rightWords,
                            overlapCount: count
                        ),
                        didStitch: true
                    )
                }
            }
        }

        if hasAudioOverlap,
            maximumOverlap >= 1,
            shouldRemoveSingleBoundaryDuplicate(
                leftWords.last!,
                rightWords.first!,
                isForcedContinuation: boundaryMetadata?.reason == .maximumDuration
            )
        {
            return StitchResult(
                text: rebuild(leftWords: leftWords, rightWords: rightWords, overlapCount: 1),
                didStitch: true
            )
        }

        let continuation: String
        switch boundaryMetadata?.reason {
        case .maximumDuration:
            continuation = lowercasingFalseSentenceStart(in: right, after: left)
        case .balancedPause, .silence, .longSilence:
            continuation = adjustingOrdinarySentenceStart(in: right, after: left)
        case .stopped, .inputChanged, .none:
            continuation = right
        }
        return StitchResult(
            text: TranscriptTextMerger.join(left, continuation),
            didStitch: continuation != right
        )
    }

    private static func adjustingOrdinarySentenceStart(
        in right: String,
        after left: String
    ) -> String {
        guard let last = left.unicodeScalars.last else { return right }
        if sentenceEndingCharacters.contains(last) {
            return uppercasingOrdinarySentenceStart(in: right)
        }
        return lowercasingFalseSentenceStart(in: right, after: left)
    }

    private static func uppercasingOrdinarySentenceStart(in text: String) -> String {
        guard let letterIndex = text.firstIndex(where: { $0.isLetter }) else { return text }
        let firstWord = text[letterIndex...].prefix { !$0.isWhitespace }
        guard !isProtectedBoundaryToken(firstWord) else { return text }
        let letters = firstWord.filter(\.isLetter)
        guard let first = letters.first,
            first.isLowercase,
            !letters.dropFirst().contains(where: { $0.isUppercase })
        else { return text }

        var result = text
        result.replaceSubrange(letterIndex...letterIndex, with: String(first).uppercased())
        return result
    }

    private static func lowercasingFalseSentenceStart(
        in right: String,
        after left: String
    ) -> String {
        guard let last = left.unicodeScalars.last,
            !sentenceEndingCharacters.contains(last),
            let letterIndex = right.firstIndex(where: { $0.isLetter })
        else { return right }

        let leadingCharacters = right[..<letterIndex]
        guard
            leadingCharacters.allSatisfy({
                $0.isWhitespace || punctuationCharacters.contains($0.unicodeScalars.first!)
            })
        else { return right }

        let firstWord = right[letterIndex...].prefix { !$0.isWhitespace }
        guard !isProtectedBoundaryToken(firstWord) else { return right }
        let letters = firstWord.filter(\.isLetter)
        guard let first = letters.first,
            first.isUppercase,
            letters.dropFirst().contains(where: { $0.isLowercase }),
            !letters.dropFirst().contains(where: { $0.isUppercase })
        else { return right }

        var result = right
        result.replaceSubrange(
            letterIndex...letterIndex,
            with: String(first).lowercased()
        )
        return result
    }

    private static func isProtectedBoundaryToken(_ token: Substring) -> Bool {
        let value = token.lowercased()
        return value.contains("://")
            || value.hasPrefix("www.")
            || value.contains("@")
    }

    private static func overlaps(_ lhs: [String], _ rhs: [String]) -> Bool {
        let left = canonicalWords(lhs)
        let right = canonicalWords(rhs)
        if left == right { return true }
        guard left.count >= 3, left.count == right.count else { return false }

        var differingTokenCount = 0
        for (leftToken, rightToken) in zip(left, right) where leftToken != rightToken {
            differingTokenCount += 1
            guard differingTokenCount <= 1,
                tokenEditDistanceAtMostOne(leftToken, rightToken)
            else { return false }
        }
        return differingTokenCount == 1
    }

    private static func shouldRemoveSingleBoundaryDuplicate(
        _ lhs: String,
        _ rhs: String,
        isForcedContinuation: Bool
    ) -> Bool {
        let left = canonicalWord(lhs)
        let right = canonicalWord(rhs)
        guard !left.isEmpty, left == right else { return false }

        // A maximum-duration split is emitted with audio overlap. Matching
        // words on its two sides therefore describe the same audio even when
        // Whisper used identical lowercase spelling and no punctuation.
        if isForcedContinuation { return true }

        // A repeated lowercase word without punctuation can be intentional
        // ("очень очень"). Only consume a one-word overlap when the recognizers
        // visibly disagreed about boundary casing or punctuation.
        return lhs != rhs
            && (hasBoundaryPunctuation(lhs)
                || hasBoundaryPunctuation(rhs)
                || initialCaseDiffers(lhs, rhs))
    }

    private static func rebuild(
        leftWords: [String],
        rightWords: [String],
        overlapCount: Int
    ) -> String {
        let prefix = Array(leftWords.dropLast(overlapCount))
        let originalLeftOverlap = Array(leftWords.suffix(overlapCount))
        let recognizedRightOverlap = Array(rightWords.prefix(overlapCount))
        var mergedOverlap = zip(originalLeftOverlap, recognizedRightOverlap).map { left, right in
            mergeOverlappingWord(left: left, right: right)
        }
        let rightRemainder = Array(rightWords.dropFirst(overlapCount))

        if !prefix.isEmpty,
            let firstMerged = mergedOverlap.first,
            startsUppercase(firstMerged),
            !endsSentence(prefix.last!)
        {
            mergedOverlap[0] = lowercasingFirstCharacter(firstMerged)
        }

        return normalizeFinalText((prefix + mergedOverlap + rightRemainder).joined(separator: " "))
    }

    private static func mergeOverlappingWord(left: String, right: String) -> String {
        let leftCanonical = canonicalWord(left)
        let rightCanonical = canonicalWord(right)

        // Preserve the earlier recognizer's spelling when the overlap is only
        // approximate. There is no confidence signal here that would justify
        // replacing an already emitted word with a second, possibly worse,
        // hypothesis. Boundary punctuation comes from the right-hand segment,
        // because it was decoded with the continuation in context.
        let base =
            leftCanonical == rightCanonical
            ? stripBoundaryPunctuation(from: right)
            : stripBoundaryPunctuation(from: left)
        let suffix = trailingBoundaryPunctuation(in: right)
        return base + suffix
    }

    private static func stripBoundaryPunctuation(from word: String) -> String {
        word.trimmingCharacters(in: punctuationCharacters)
    }

    private static func trailingBoundaryPunctuation(in word: String) -> String {
        let suffix = word.unicodeScalars.reversed().prefix { punctuationCharacters.contains($0) }.reversed()
        return String(String.UnicodeScalarView(suffix))
    }

    private static func shouldRemoveIsolatedHallucination(
        _ segment: String,
        languageCode: String?,
        enabled: Bool
    ) -> Bool {
        guard enabled else { return false }
        let language = languageCode?.lowercased() ?? ""
        guard language.hasPrefix("ru") else { return false }
        return commonEnglishHallucinations.contains(canonicalPhrase(segment))
    }

    private static func normalizeFinalText(_ text: String) -> String {
        var normalized = TranscriptTextNormalizer.normalize(text)
        normalized = normalized.replacingOccurrences(of: " ,", with: ",")
        normalized = normalized.replacingOccurrences(of: " .", with: ".")
        normalized = normalized.replacingOccurrences(of: " !", with: "!")
        normalized = normalized.replacingOccurrences(of: " ?", with: "?")
        if normalized.hasSuffix(",") {
            normalized.removeLast()
            normalized.append("…")
        }
        return TranscriptTextNormalizer.normalize(normalized)
    }

    private static func words(from text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func canonicalWords(_ words: [String]) -> [String] {
        words.map(canonicalWord)
    }

    private static func canonicalWord(_ word: String) -> String {
        word.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: punctuationCharacters)
    }

    private static func canonicalPhrase(_ text: String) -> String {
        words(from: text).map(canonicalWord).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func hasBoundaryPunctuation(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first, let last = word.unicodeScalars.last else { return false }
        return punctuationCharacters.contains(first) || punctuationCharacters.contains(last)
    }

    private static func initialCaseDiffers(_ lhs: String, _ rhs: String) -> Bool {
        startsLowercase(lhs) != startsLowercase(rhs) || startsUppercase(lhs) != startsUppercase(rhs)
    }

    private static func startsLowercase(_ word: String) -> Bool {
        guard let character = word.first else { return false }
        let string = String(character)
        return string == string.lowercased() && string != string.uppercased()
    }

    private static func startsUppercase(_ word: String) -> Bool {
        guard let character = word.first else { return false }
        let string = String(character)
        return string == string.uppercased() && string != string.lowercased()
    }

    private static func lowercasingFirstCharacter(_ word: String) -> String {
        guard let first = word.first else { return word }
        return String(first).lowercased() + word.dropFirst()
    }

    private static func endsSentence(_ word: String) -> Bool {
        guard let scalar = word.unicodeScalars.last else { return false }
        return sentenceEndingCharacters.contains(scalar)
    }

    private static func tokenEditDistanceAtMostOne(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let left = Array(lhs)
        let right = Array(rhs)
        guard abs(left.count - right.count) <= 1 else { return false }
        if left.count == right.count {
            let differences = left.indices.filter { left[$0] != right[$0] }
            if differences.count == 2,
                differences[1] == differences[0] + 1,
                left[differences[0]] == right[differences[1]],
                left[differences[1]] == right[differences[0]]
            {
                return true
            }
        }

        var leftIndex = 0
        var rightIndex = 0
        var edits = 0
        while leftIndex < left.count, rightIndex < right.count {
            if left[leftIndex] == right[rightIndex] {
                leftIndex += 1
                rightIndex += 1
                continue
            }
            edits += 1
            guard edits <= 1 else { return false }
            if left.count > right.count {
                leftIndex += 1
            } else if right.count > left.count {
                rightIndex += 1
            } else {
                leftIndex += 1
                rightIndex += 1
            }
        }
        if leftIndex < left.count || rightIndex < right.count { edits += 1 }
        return edits <= 1
    }
}
