import Foundation

public enum WhisperBoundarySuspicionReason: String, Codable, Equatable, Sendable {
    case repeatedTrigram
    case missingOverlapAnchor
    case shortCurrentText
    case lowTokenProbability
    case highNoSpeechProbability
}

public enum WhisperBoundaryRepairRejectionReason: String, Codable, Equatable, Sendable {
    case missingStableAnchor
    case punctuationLoss
    case lowerTokenProbability
    case repeatedTrigram
    case insufficientImprovement
}

public struct WhisperBoundaryRepairConfiguration: Equatable, Sendable {
    private static let defaultMinimumTokenProbability = 0.45
    private static let defaultMaximumNoSpeechProbability = 0.60
    private static let minimumBoundaryWordLimit = 3
    private static let maximumBoundaryWordLimit = 24
    private static let stableAnchorWordMinimum = 3
    private static let trigramLength = 3
    private static let maximumAllowedPunctuationLoss = 24

    public var boundaryWordLimit: Int
    public var minimumAnchorWords: Int
    public var repeatedNGramLength: Int
    public var minimumTokenProbability: Double
    public var maximumNoSpeechProbability: Double
    public var maximumPunctuationLoss: Int

    public init(
        boundaryWordLimit: Int = 24,
        minimumAnchorWords: Int = 3,
        repeatedNGramLength: Int = 3,
        minimumTokenProbability: Double = 0.45,
        maximumNoSpeechProbability: Double = 0.60,
        maximumPunctuationLoss: Int = 0
    ) {
        let boundedWordLimit = min(
            max(boundaryWordLimit, Self.minimumBoundaryWordLimit),
            Self.maximumBoundaryWordLimit
        )
        self.boundaryWordLimit = boundedWordLimit
        self.minimumAnchorWords = min(
            max(minimumAnchorWords, Self.stableAnchorWordMinimum),
            boundedWordLimit
        )
        self.repeatedNGramLength = Self.trigramLength
        self.minimumTokenProbability = Self.normalizedProbability(
            minimumTokenProbability,
            fallback: Self.defaultMinimumTokenProbability
        )
        self.maximumNoSpeechProbability = Self.normalizedProbability(
            maximumNoSpeechProbability,
            fallback: Self.defaultMaximumNoSpeechProbability
        )
        self.maximumPunctuationLoss = min(
            max(0, maximumPunctuationLoss),
            Self.maximumAllowedPunctuationLoss
        )
    }

    fileprivate func normalized() -> Self {
        Self(
            boundaryWordLimit: boundaryWordLimit,
            minimumAnchorWords: minimumAnchorWords,
            repeatedNGramLength: repeatedNGramLength,
            minimumTokenProbability: minimumTokenProbability,
            maximumNoSpeechProbability: maximumNoSpeechProbability,
            maximumPunctuationLoss: maximumPunctuationLoss
        )
    }

    private static func normalizedProbability(
        _ value: Double,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, 0), 1)
    }
}

public struct WhisperBoundaryPatch: Equatable, Sendable {
    public let text: String
    public let baselinePrefixWordCount: Int
    public let candidatePrefixWordCount: Int
    public let baselineScore: Double
    public let candidateScore: Double

    public init(
        text: String,
        baselinePrefixWordCount: Int,
        candidatePrefixWordCount: Int,
        baselineScore: Double,
        candidateScore: Double
    ) {
        self.text = text
        self.baselinePrefixWordCount = baselinePrefixWordCount
        self.candidatePrefixWordCount = candidatePrefixWordCount
        self.baselineScore = baselineScore
        self.candidateScore = candidateScore
    }
}

public enum WhisperBoundaryRepairDecision: Equatable, Sendable {
    case accepted(WhisperBoundaryPatch)
    case rejected(String, WhisperBoundaryRepairRejectionReason)

    public var text: String {
        switch self {
        case .accepted(let patch):
            patch.text
        case .rejected(let baseline, _):
            baseline
        }
    }

    public var rejectionReason: WhisperBoundaryRepairRejectionReason? {
        guard case .rejected(_, let reason) = self else { return nil }
        return reason
    }
}

public enum WhisperBoundaryRepairPolicy {
    private static let minimumSuspicionOverlapWords = 2
    private static let minimumScoreImprovement = 0.5
    private static let maximumConfidenceDecrease = 0.05
    /// Decimal quality thresholds are product semantics, while their inputs are
    /// often arithmetic means or differences. Treat values inside a tiny
    /// absolute-or-eight-ULP band as mathematically equal so ordinary binary
    /// rounding cannot flip an exact boundary; values outside remain strict.
    private static let absoluteComparisonTolerance = 1e-15
    private static let comparisonULPCount = 8.0

    public static func assess(
        previousBoundaryReason: AudioChunkBoundaryReason,
        previous: WhisperTranscriptionResult,
        current: WhisperTranscriptionResult,
        currentAudioDuration: TimeInterval,
        configuration: WhisperBoundaryRepairConfiguration = .init()
    ) -> [WhisperBoundarySuspicionReason] {
        guard previousBoundaryReason == .maximumDuration else { return [] }
        let configuration = configuration.normalized()

        let previousWords = WhisperBoundaryText.words(in: previous.text)
        let currentWords = WhisperBoundaryText.words(in: current.text)
        let repeatedNGramLength = max(1, configuration.repeatedNGramLength)
        var reasons: [WhisperBoundarySuspicionReason] = []

        if repeatedAcrossBoundaryCount(
            previousWords: previousWords,
            currentWords: currentWords,
            nGramLength: repeatedNGramLength
        ) > 0 {
            reasons.append(.repeatedTrigram)
        }

        let overlapWordCount = WhisperBoundaryText.longestSuffixPrefixMatch(
            left: previousWords,
            right: currentWords,
            maximumWords: WhisperBoundaryText.maximumAlignmentWords
        )
        if overlapWordCount < minimumSuspicionOverlapWords {
            reasons.append(.missingOverlapAnchor)
        }

        if isStrictlyGreater(currentAudioDuration, than: 1),
            lexicalWords(in: currentWords).count < 3
        {
            reasons.append(.shortCurrentText)
        }

        let meanTokenProbability = boundaryMeanTokenProbability(
            current,
            wordLimit: configuration.boundaryWordLimit
        )
        if isStrictlyLess(
            meanTokenProbability,
            than: configuration.minimumTokenProbability
        ) {
            reasons.append(.lowTokenProbability)
        }

        if isStrictlyGreater(
            maximumFiniteNoSpeechProbability(current),
            than: configuration.maximumNoSpeechProbability
        ) {
            reasons.append(.highNoSpeechProbability)
        }

        return reasons
    }

    public static func contextualPatch(
        previous: WhisperTranscriptionResult,
        baseline: WhisperTranscriptionResult,
        candidate: WhisperTranscriptionResult,
        configuration: WhisperBoundaryRepairConfiguration = .init()
    ) -> WhisperBoundaryRepairDecision {
        let configuration = configuration.normalized()
        let baselineWords = WhisperBoundaryText.words(in: baseline.text)
        let candidateWords = WhisperBoundaryText.words(in: candidate.text)
        guard
            let anchor = stableAnchor(
                candidateWords: candidateWords,
                baselineWords: baselineWords,
                configuration: configuration
            )
        else {
            return .rejected(baseline.text, .missingStableAnchor)
        }

        let candidateAnchorStart = candidateWords[anchor.candidateWordIndex]
            .originalRange.lowerBound
        let baselineAnchorStart = baselineWords[anchor.baselineWordIndex]
            .originalRange.lowerBound
        let candidatePrefix = candidate.text[..<candidateAnchorStart]
        let baselinePrefix = baseline.text[..<baselineAnchorStart]

        let candidatePunctuationCount = punctuationCount(in: candidatePrefix)
        let baselinePunctuationCount = punctuationCount(in: baselinePrefix)
        let allowedPunctuationLoss = max(0, configuration.maximumPunctuationLoss)
        if baselinePunctuationCount > candidatePunctuationCount,
            baselinePunctuationCount - candidatePunctuationCount > allowedPunctuationLoss
        {
            return .rejected(baseline.text, .punctuationLoss)
        }

        let baselineConfidence = boundaryMeanTokenProbability(
            baseline,
            wordLimit: configuration.boundaryWordLimit
        )
        let candidateConfidence = boundaryMeanTokenProbability(
            candidate,
            wordLimit: configuration.boundaryWordLimit
        )
        if isStrictlyGreater(
            baselineConfidence - candidateConfidence,
            than: maximumConfidenceDecrease
        ) {
            return .rejected(baseline.text, .lowerTokenProbability)
        }

        let baselineSuffix = baseline.text[baselineAnchorStart...]
        let patchedText = String(candidatePrefix) + String(baselineSuffix)
        let patchedWords = WhisperBoundaryText.words(in: patchedText)
        let candidateRepeatedTrigramCount = repeatedNGramCount(
            in: lexicalWords(in: patchedWords)
                .prefix(max(0, configuration.boundaryWordLimit))
                .map(\.normalized),
            length: max(1, configuration.repeatedNGramLength)
        )
        if candidateRepeatedTrigramCount > 0 {
            return .rejected(baseline.text, .repeatedTrigram)
        }

        let baselineScoreComponents = joinScoreComponents(
            previousWords: WhisperBoundaryText.words(in: previous.text),
            currentWords: baselineWords,
            meanTokenProbability: baselineConfidence,
            configuration: configuration
        )
        let candidateScoreComponents = joinScoreComponents(
            previousWords: WhisperBoundaryText.words(in: previous.text),
            currentWords: candidateWords,
            meanTokenProbability: candidateConfidence,
            configuration: configuration
        )
        let baselineScore = baselineScoreComponents.score
        let candidateScore = candidateScoreComponents.score
        guard
            isAtLeast(
                scoreImprovement(
                    candidate: candidateScoreComponents,
                    baseline: baselineScoreComponents
                ),
                minimumScoreImprovement
            )
        else {
            return .rejected(baseline.text, .insufficientImprovement)
        }

        return .accepted(
            WhisperBoundaryPatch(
                text: patchedText,
                baselinePrefixWordCount: anchor.baselineLexicalIndex,
                candidatePrefixWordCount: anchor.candidateLexicalIndex,
                baselineScore: baselineScore,
                candidateScore: candidateScore
            )
        )
    }

    public static func bridgePatch(
        previous: WhisperTranscriptionResult,
        current: WhisperTranscriptionResult,
        bridge: WhisperTranscriptionResult,
        cutTime: TimeInterval
    ) -> WhisperBoundaryBridgePatch? {
        guard cutTime.isFinite,
            cutTime >= 0,
            let bridgeEvidence = timedBridgeEvidence(bridge)
        else {
            return nil
        }

        let previousBoundary = Array(
            indexedLexicalWords(in: previous.text)
                .suffix(WhisperBoundaryText.maximumBoundaryWords)
        )
        let currentBoundary = Array(
            indexedLexicalWords(in: current.text)
                .prefix(WhisperBoundaryText.maximumBoundaryWords)
        )
        let bridgeWords = bridgeEvidence.words

        guard
            let leftAnchor = bridgeAnchor(
                sourceWords: previousBoundary,
                bridgeWords: bridgeWords,
                bridgeSide: .leftOfCut(cutTime)
            ),
            let rightAnchor = bridgeAnchor(
                sourceWords: currentBoundary,
                bridgeWords: bridgeWords,
                bridgeSide: .rightOfCut(cutTime)
            ),
            leftAnchor.bridgeWordRange.upperBound
                <= rightAnchor.bridgeWordRange.lowerBound
        else {
            return nil
        }

        let leftBridgeWord = bridgeWords[leftAnchor.bridgeWordRange.upperBound - 1]
        let rightBridgeWord = bridgeWords[rightAnchor.bridgeWordRange.lowerBound]
        let middleTokenRange =
            (leftBridgeWord.lastTokenIndex + 1)..<rightBridgeWord.firstTokenIndex
        guard !middleTokenRange.isEmpty else { return nil }

        let middleTokens = bridgeEvidence.tokenTimings[middleTokenRange]
        guard
            let firstRightTokenIndex = middleTokens.firstIndex(where: {
                $0.midpoint > cutTime
            }),
            firstRightTokenIndex > middleTokens.startIndex,
            !bridgeWords.contains(where: {
                $0.firstTokenIndex < firstRightTokenIndex
                    && firstRightTokenIndex <= $0.lastTokenIndex
            }),
            let splitUTF8Offset = bridgeEvidence.tokenStartUTF8Offsets[firstRightTokenIndex],
            let splitIndex = String.Index(
                bridge.text.utf8.index(
                    bridge.text.utf8.startIndex,
                    offsetBy: splitUTF8Offset
                ),
                within: bridge.text
            )
        else {
            return nil
        }

        let bridgeMiddleStart = leftBridgeWord.originalRange.upperBound
        let bridgeMiddleEnd = rightBridgeWord.originalRange.lowerBound
        guard bridgeMiddleStart <= splitIndex, splitIndex <= bridgeMiddleEnd else {
            return nil
        }

        let leftReplacement = bridge.text[bridgeMiddleStart..<splitIndex]
        let rightReplacement = bridge.text[splitIndex..<bridgeMiddleEnd]
        guard hasLexicalWord(leftReplacement), hasLexicalWord(rightReplacement) else {
            return nil
        }

        let previousAnchorWord =
            previousBoundary[leftAnchor.sourceWordRange.upperBound - 1].word
        let currentAnchorWord =
            currentBoundary[rightAnchor.sourceWordRange.lowerBound].word
        let previousPrefix = previous.text[..<previousAnchorWord.originalRange.upperBound]
        let currentSuffix = current.text[currentAnchorWord.originalRange.lowerBound...]

        let removedPrevious = previous.text[previousAnchorWord.originalRange.upperBound...]
        let removedCurrent = current.text[..<currentAnchorWord.originalRange.lowerBound]
        let removedPunctuation =
            punctuationCount(in: removedPrevious)
            + punctuationCount(in: removedCurrent)
        let replacementPunctuation =
            punctuationCount(in: leftReplacement)
            + punctuationCount(in: rightReplacement)
        guard replacementPunctuation >= removedPunctuation else { return nil }

        let patchedPrevious = String(previousPrefix) + leftReplacement
        let patchedCurrent = String(rightReplacement) + currentSuffix
        guard
            !hasRepeatedBoundaryTrigram(
                previous: patchedPrevious,
                current: patchedCurrent
            )
        else {
            return nil
        }

        return WhisperBoundaryBridgePatch(
            previousText: patchedPrevious,
            currentText: patchedCurrent,
            removedBoundaryWordCount: indexedLexicalWords(in: String(removedPrevious)).count
                + indexedLexicalWords(in: String(removedCurrent)).count,
            replacementBoundaryWordCount: indexedLexicalWords(in: String(leftReplacement)).count
                + indexedLexicalWords(in: String(rightReplacement)).count
        )
    }

    private struct LexicalWord {
        let wordIndex: Int
        let normalized: String
    }

    private struct StableAnchor {
        let candidateWordIndex: Int
        let baselineWordIndex: Int
        let candidateLexicalIndex: Int
        let baselineLexicalIndex: Int
    }

    private struct JoinScoreComponents {
        let overlapWordCount: Int
        let repeatedNGramCount: Int
        let meanTokenProbability: Double

        var score: Double {
            2 * Double(overlapWordCount)
                - 3 * Double(repeatedNGramCount)
                + meanTokenProbability
        }
    }

    private struct IndexedBoundaryWord {
        let word: WhisperBoundaryWord
    }

    private struct TimedTokenTiming {
        let startTime: TimeInterval
        let endTime: TimeInterval

        var midpoint: TimeInterval {
            startTime + (endTime - startTime) / 2
        }
    }

    private struct TimedBridgeWord {
        let originalRange: Range<String.Index>
        let normalized: String
        let firstTokenIndex: Int
        let lastTokenIndex: Int
        let startTime: TimeInterval
        let endTime: TimeInterval

        var midpoint: TimeInterval {
            startTime + (endTime - startTime) / 2
        }
    }

    private struct TimedBridgeEvidence {
        let tokenTimings: [TimedTokenTiming]
        let tokenStartUTF8Offsets: [Int?]
        let words: [TimedBridgeWord]
    }

    private struct WhitespaceRun {
        let utf8Range: Range<Int>
        let precedingContentUTF8Count: Int
        let bytes: [UInt8]
    }

    private enum WhitespaceEdge {
        case before
        case after
    }

    private enum BridgeSide {
        case leftOfCut(TimeInterval)
        case rightOfCut(TimeInterval)
    }

    private struct TimedBridgeAnchor {
        let sourceWordRange: Range<Int>
        let bridgeWordRange: Range<Int>
    }

    private static func indexedLexicalWords(
        in text: String
    ) -> [IndexedBoundaryWord] {
        WhisperBoundaryText.words(in: text).compactMap { word in
            word.normalized.isEmpty ? nil : IndexedBoundaryWord(word: word)
        }
    }

    private static func timedBridgeEvidence(
        _ bridge: WhisperTranscriptionResult
    ) -> TimedBridgeEvidence? {
        let evidenceTokens = bridge.tokens
        guard !evidenceTokens.isEmpty else { return nil }

        var tokenTimings: [TimedTokenTiming] = []
        var previousEndTime: TimeInterval?

        for token in evidenceTokens {
            guard let startTime = token.startTime,
                let endTime = token.endTime,
                startTime.isFinite,
                endTime.isFinite,
                startTime >= 0,
                endTime >= startTime,
                previousEndTime.map({ startTime >= $0 }) ?? true,
                !token.text.isEmpty
            else {
                return nil
            }

            tokenTimings.append(
                TimedTokenTiming(
                    startTime: startTime,
                    endTime: endTime
                )
            )
            previousEndTime = endTime
        }

        let visibleTokenIndexes = evidenceTokens.indices.filter { tokenIndex in
            !isWhisperControlToken(evidenceTokens[tokenIndex].text)
        }
        let rawText = visibleTokenIndexes.map { evidenceTokens[$0].text }.joined()
        var rawUTF8Offset = 0
        var rawTokenRanges: [(tokenIndex: Int, range: Range<Int>)] = []
        for tokenIndex in visibleTokenIndexes {
            let tokenText = evidenceTokens[tokenIndex].text
            let rawUTF8End = rawUTF8Offset + tokenText.utf8.count
            rawTokenRanges.append((tokenIndex, rawUTF8Offset..<rawUTF8End))
            rawUTF8Offset = rawUTF8End
        }

        let rawWords = WhisperBoundaryText.words(in: rawText).compactMap {
            word -> (normalized: String, firstTokenIndex: Int, lastTokenIndex: Int)? in
            guard !word.normalized.isEmpty else { return nil }
            let wordUTF8Start = rawText.utf8.distance(
                from: rawText.utf8.startIndex,
                to: word.originalRange.lowerBound
            )
            let wordUTF8End = rawText.utf8.distance(
                from: rawText.utf8.startIndex,
                to: word.originalRange.upperBound
            )
            let wordUTF8Range = wordUTF8Start..<wordUTF8End
            let tokenIndexes = rawTokenRanges.compactMap { tokenRange in
                rangesOverlap(tokenRange.range, wordUTF8Range)
                    ? tokenRange.tokenIndex : nil
            }
            guard let firstTokenIndex = tokenIndexes.first,
                let lastTokenIndex = tokenIndexes.last
            else {
                return nil
            }
            return (word.normalized, firstTokenIndex, lastTokenIndex)
        }
        let bridgeWords = WhisperBoundaryText.words(in: bridge.text).filter {
            !$0.normalized.isEmpty
        }
        guard
            nonWhitespaceUTF8Content(in: rawText)
                == nonWhitespaceUTF8Content(in: bridge.text),
            !rawWords.isEmpty,
            rawWords.map(\.normalized) == bridgeWords.map(\.normalized)
        else {
            return nil
        }

        var tokenStartUTF8Offsets = [Int?](
            repeating: nil,
            count: evidenceTokens.count
        )
        let rawWhitespaceRuns = whitespaceRuns(in: rawText)
        let bridgeWhitespaceRuns = whitespaceRuns(in: bridge.text)
        for tokenRange in rawTokenRanges {
            tokenStartUTF8Offsets[tokenRange.tokenIndex] = bridgeUTF8Offset(
                matchingRawUTF8Offset: tokenRange.range.lowerBound,
                rawText: rawText,
                rawWhitespaceRuns: rawWhitespaceRuns,
                bridgeText: bridge.text,
                bridgeWhitespaceRuns: bridgeWhitespaceRuns
            )
        }

        let words = zip(bridgeWords, rawWords).map { bridgeWord, rawWord in
            TimedBridgeWord(
                originalRange: bridgeWord.originalRange,
                normalized: bridgeWord.normalized,
                firstTokenIndex: rawWord.firstTokenIndex,
                lastTokenIndex: rawWord.lastTokenIndex,
                startTime: tokenTimings[rawWord.firstTokenIndex].startTime,
                endTime: tokenTimings[rawWord.lastTokenIndex].endTime
            )
        }
        return TimedBridgeEvidence(
            tokenTimings: tokenTimings,
            tokenStartUTF8Offsets: tokenStartUTF8Offsets,
            words: words
        )
    }

    private static func bridgeAnchor(
        sourceWords: [IndexedBoundaryWord],
        bridgeWords: [TimedBridgeWord],
        bridgeSide: BridgeSide
    ) -> TimedBridgeAnchor? {
        let length = WhisperBoundaryText.stableAnchorWordCount
        guard sourceWords.count >= length, bridgeWords.count >= length else {
            return nil
        }

        let sourceNGrams = nGrams(
            in: sourceWords.map { $0.word.normalized },
            length: length
        )
        let bridgeNGrams = nGrams(
            in: bridgeWords.map(\.normalized),
            length: length
        )
        let sourceCounts = nGramCounts(sourceNGrams)
        let bridgeCounts = nGramCounts(bridgeNGrams)
        var matches: [TimedBridgeAnchor] = []

        for sourceStart in sourceNGrams.indices {
            let words = sourceNGrams[sourceStart]
            guard sourceCounts[words] == 1, bridgeCounts[words] == 1,
                let bridgeStart = bridgeNGrams.firstIndex(of: words)
            else {
                continue
            }

            let bridgeRange = bridgeStart..<(bridgeStart + length)
            let isOnRequiredSide: Bool
            switch bridgeSide {
            case .leftOfCut(let cutTime):
                isOnRequiredSide = bridgeWords[bridgeRange.upperBound - 1].endTime <= cutTime
            case .rightOfCut(let cutTime):
                isOnRequiredSide = bridgeWords[bridgeRange.lowerBound].startTime >= cutTime
            }
            guard isOnRequiredSide else { continue }

            matches.append(
                TimedBridgeAnchor(
                    sourceWordRange: sourceStart..<(sourceStart + length),
                    bridgeWordRange: bridgeRange
                )
            )
        }

        switch bridgeSide {
        case .leftOfCut:
            return matches.max { left, right in
                left.bridgeWordRange.lowerBound < right.bridgeWordRange.lowerBound
            }
        case .rightOfCut:
            return matches.min { left, right in
                left.bridgeWordRange.lowerBound < right.bridgeWordRange.lowerBound
            }
        }
    }

    private static func rangesOverlap<Bound: Comparable>(
        _ left: Range<Bound>,
        _ right: Range<Bound>
    ) -> Bool {
        left.lowerBound < right.upperBound && right.lowerBound < left.upperBound
    }

    private static func isWhisperControlToken(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<|") && trimmed.hasSuffix("|>")
    }

    private static func nonWhitespaceUTF8Content(in text: String) -> [UInt8] {
        var content: [UInt8] = []
        content.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars where !scalar.properties.isWhitespace {
            content.append(contentsOf: String(scalar).utf8)
        }
        return content
    }

    private static func bridgeUTF8Offset(
        matchingRawUTF8Offset rawUTF8Offset: Int,
        rawText: String,
        rawWhitespaceRuns: [WhitespaceRun],
        bridgeText: String,
        bridgeWhitespaceRuns: [WhitespaceRun]
    ) -> Int? {
        guard isCharacterBoundary(rawUTF8Offset, in: rawText) else { return nil }

        for rawRun in rawWhitespaceRuns {
            if rawUTF8Offset == rawRun.utf8Range.lowerBound {
                return bridgeWhitespaceBoundary(
                    afterContentUTF8Count: rawRun.precedingContentUTF8Count,
                    edge: .before,
                    bridgeText: bridgeText,
                    bridgeWhitespaceRuns: bridgeWhitespaceRuns
                )
            }
            if rawUTF8Offset == rawRun.utf8Range.upperBound {
                return bridgeWhitespaceBoundary(
                    afterContentUTF8Count: rawRun.precedingContentUTF8Count,
                    edge: .after,
                    bridgeText: bridgeText,
                    bridgeWhitespaceRuns: bridgeWhitespaceRuns
                )
            }
            if rawRun.utf8Range.contains(rawUTF8Offset) {
                guard
                    let bridgeRun = bridgeWhitespaceRuns.first(where: {
                        $0.precedingContentUTF8Count == rawRun.precedingContentUTF8Count
                    }),
                    rawRun.bytes == bridgeRun.bytes
                else {
                    return nil
                }
                let mappedOffset =
                    bridgeRun.utf8Range.lowerBound
                    + rawUTF8Offset - rawRun.utf8Range.lowerBound
                return isCharacterBoundary(mappedOffset, in: bridgeText)
                    ? mappedOffset : nil
            }
        }

        let precedingContentUTF8Count = nonWhitespaceUTF8Count(
            beforeUTF8Offset: rawUTF8Offset,
            in: rawText
        )
        guard
            !bridgeWhitespaceRuns.contains(where: {
                $0.precedingContentUTF8Count == precedingContentUTF8Count
            })
        else {
            return nil
        }
        return utf8Offset(
            afterNonWhitespaceUTF8Count: precedingContentUTF8Count,
            in: bridgeText
        )
    }

    private static func whitespaceRuns(in text: String) -> [WhitespaceRun] {
        var runs: [WhitespaceRun] = []
        var utf8Offset = 0
        var contentUTF8Count = 0
        var runStart: Int?
        var runContentUTF8Count = 0
        var runBytes: [UInt8] = []

        for index in text.indices {
            let nextIndex = text.index(after: index)
            let bytes = Array(text[index..<nextIndex].utf8)
            if isWhitespaceCharacter(text[index]) {
                if runStart == nil {
                    runStart = utf8Offset
                    runContentUTF8Count = contentUTF8Count
                }
                runBytes.append(contentsOf: bytes)
            } else {
                if let start = runStart {
                    runs.append(
                        WhitespaceRun(
                            utf8Range: start..<utf8Offset,
                            precedingContentUTF8Count: runContentUTF8Count,
                            bytes: runBytes
                        )
                    )
                    runBytes = []
                    runStart = nil
                }
                contentUTF8Count += bytes.count
            }
            utf8Offset += bytes.count
        }
        if let runStart {
            runs.append(
                WhitespaceRun(
                    utf8Range: runStart..<utf8Offset,
                    precedingContentUTF8Count: runContentUTF8Count,
                    bytes: runBytes
                )
            )
        }
        return runs
    }

    private static func bridgeWhitespaceBoundary(
        afterContentUTF8Count contentUTF8Count: Int,
        edge: WhitespaceEdge,
        bridgeText: String,
        bridgeWhitespaceRuns: [WhitespaceRun]
    ) -> Int? {
        if let run = bridgeWhitespaceRuns.first(where: {
            $0.precedingContentUTF8Count == contentUTF8Count
        }) {
            switch edge {
            case .before: return run.utf8Range.lowerBound
            case .after: return run.utf8Range.upperBound
            }
        }
        return utf8Offset(
            afterNonWhitespaceUTF8Count: contentUTF8Count,
            in: bridgeText
        )
    }

    private static func nonWhitespaceUTF8Count(
        beforeUTF8Offset targetOffset: Int,
        in text: String
    ) -> Int {
        var utf8Offset = 0
        var contentUTF8Count = 0
        for index in text.indices {
            guard utf8Offset < targetOffset else { break }
            let nextIndex = text.index(after: index)
            let byteCount = text[index..<nextIndex].utf8.count
            if !isWhitespaceCharacter(text[index]) {
                contentUTF8Count += byteCount
            }
            utf8Offset += byteCount
        }
        return contentUTF8Count
    }

    private static func utf8Offset(
        afterNonWhitespaceUTF8Count targetCount: Int,
        in text: String
    ) -> Int? {
        var utf8Offset = 0
        var contentUTF8Count = 0
        if targetCount == 0 { return 0 }

        for index in text.indices {
            let nextIndex = text.index(after: index)
            let byteCount = text[index..<nextIndex].utf8.count
            if !isWhitespaceCharacter(text[index]) {
                contentUTF8Count += byteCount
                guard contentUTF8Count <= targetCount else { return nil }
                if contentUTF8Count == targetCount {
                    return utf8Offset + byteCount
                }
            }
            utf8Offset += byteCount
        }
        return nil
    }

    private static func isWhitespaceCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
    }

    private static func isCharacterBoundary(
        _ utf8Offset: Int,
        in text: String
    ) -> Bool {
        guard (0...text.utf8.count).contains(utf8Offset) else { return false }
        let utf8Index = text.utf8.index(
            text.utf8.startIndex,
            offsetBy: utf8Offset
        )
        guard let index = String.Index(utf8Index, within: text) else { return false }
        return index == text.endIndex || text.indices.contains(index)
    }

    private static func hasLexicalWord<S: StringProtocol>(_ text: S) -> Bool {
        text.contains { character in
            character.isLetter || character.isNumber
        }
    }

    private static func hasRepeatedBoundaryTrigram(
        previous: String,
        current: String
    ) -> Bool {
        let previousBoundary = indexedLexicalWords(in: previous)
            .suffix(WhisperBoundaryText.maximumBoundaryWords)
            .map { $0.word.normalized }
        let currentBoundary = indexedLexicalWords(in: current)
            .prefix(WhisperBoundaryText.maximumBoundaryWords)
            .map { $0.word.normalized }
        let trigrams = nGrams(
            in: Array(previousBoundary) + currentBoundary,
            length: WhisperBoundaryText.stableAnchorWordCount
        )
        return nGramCounts(trigrams).values.contains { $0 > 1 }
    }

    private static func stableAnchor(
        candidateWords: [WhisperBoundaryWord],
        baselineWords: [WhisperBoundaryWord],
        configuration: WhisperBoundaryRepairConfiguration
    ) -> StableAnchor? {
        let boundaryWordLimit = max(0, configuration.boundaryWordLimit)
        let anchorWordCount = max(1, configuration.minimumAnchorWords)
        let candidateBoundary = Array(
            lexicalWords(in: candidateWords).prefix(boundaryWordLimit)
        )
        let baselineBoundary = Array(
            lexicalWords(in: baselineWords).prefix(boundaryWordLimit)
        )
        guard candidateBoundary.count >= anchorWordCount,
            baselineBoundary.count >= anchorWordCount
        else {
            return nil
        }

        let candidateAnchors = indexedNGrams(
            in: candidateBoundary.map(\.normalized),
            length: anchorWordCount
        )
        let baselineAnchors = indexedNGrams(
            in: baselineBoundary.map(\.normalized),
            length: anchorWordCount
        )
        let candidateCounts = nGramCounts(candidateAnchors.map(\.words))
        let baselineCounts = nGramCounts(baselineAnchors.map(\.words))

        for baselineAnchor in baselineAnchors {
            guard baselineCounts[baselineAnchor.words] == 1,
                candidateCounts[baselineAnchor.words] == 1,
                let candidateAnchor = candidateAnchors.first(where: {
                    $0.words == baselineAnchor.words
                })
            else {
                continue
            }

            return StableAnchor(
                candidateWordIndex: candidateBoundary[candidateAnchor.start].wordIndex,
                baselineWordIndex: baselineBoundary[baselineAnchor.start].wordIndex,
                candidateLexicalIndex: candidateAnchor.start,
                baselineLexicalIndex: baselineAnchor.start
            )
        }
        return nil
    }

    private static func joinScoreComponents(
        previousWords: [WhisperBoundaryWord],
        currentWords: [WhisperBoundaryWord],
        meanTokenProbability: Double,
        configuration: WhisperBoundaryRepairConfiguration
    ) -> JoinScoreComponents {
        let overlapWordCount = WhisperBoundaryText.longestSuffixPrefixMatch(
            left: previousWords,
            right: currentWords,
            maximumWords: WhisperBoundaryText.maximumAlignmentWords
        )
        let repeatedTrigramCount = repeatedNGramCount(
            in: lexicalWords(in: currentWords)
                .prefix(max(0, configuration.boundaryWordLimit))
                .map(\.normalized),
            length: max(1, configuration.repeatedNGramLength)
        )
        return JoinScoreComponents(
            overlapWordCount: overlapWordCount,
            repeatedNGramCount: repeatedTrigramCount,
            meanTokenProbability: meanTokenProbability
        )
    }

    private static func scoreImprovement(
        candidate: JoinScoreComponents,
        baseline: JoinScoreComponents
    ) -> Double {
        let overlapImprovement = candidate.overlapWordCount - baseline.overlapWordCount
        let repetitionImprovement =
            candidate.repeatedNGramCount - baseline.repeatedNGramCount
        let confidenceImprovement =
            candidate.meanTokenProbability - baseline.meanTokenProbability
        return 2 * Double(overlapImprovement)
            - 3 * Double(repetitionImprovement)
            + confidenceImprovement
    }

    private static func lexicalWords(
        in words: [WhisperBoundaryWord]
    ) -> [LexicalWord] {
        words.enumerated().compactMap { index, word in
            guard !word.normalized.isEmpty else { return nil }
            return LexicalWord(wordIndex: index, normalized: word.normalized)
        }
    }

    private static func repeatedAcrossBoundaryCount(
        previousWords: [WhisperBoundaryWord],
        currentWords: [WhisperBoundaryWord],
        nGramLength: Int
    ) -> Int {
        let previousBoundary = lexicalWords(in: previousWords)
            .suffix(WhisperBoundaryText.maximumAlignmentWords)
            .map(\.normalized)
        let currentBoundary = lexicalWords(in: currentWords)
            .prefix(WhisperBoundaryText.maximumAlignmentWords)
            .map(\.normalized)
        let previousNGrams = Set(nGrams(in: previousBoundary, length: nGramLength))
        let currentNGrams = Set(nGrams(in: currentBoundary, length: nGramLength))
        return previousNGrams.intersection(currentNGrams).count
    }

    private static func repeatedNGramCount(
        in words: [String],
        length: Int
    ) -> Int {
        let counts = nGramCounts(nGrams(in: words, length: length))
        return counts.values.reduce(0) { total, count in
            total + max(0, count - 1)
        }
    }

    private struct IndexedNGram {
        let start: Int
        let words: [String]
    }

    private static func indexedNGrams(
        in words: [String],
        length: Int
    ) -> [IndexedNGram] {
        nGrams(in: words, length: length).enumerated().map { index, words in
            IndexedNGram(start: index, words: words)
        }
    }

    private static func nGramCounts(_ nGrams: [[String]]) -> [[String]: Int] {
        nGrams.reduce(into: [:]) { counts, nGram in
            counts[nGram, default: 0] += 1
        }
    }

    private static func nGrams(
        in words: [String],
        length: Int
    ) -> [[String]] {
        guard length > 0, words.count >= length else { return [] }
        return (0...(words.count - length)).map { start in
            Array(words[start..<(start + length)])
        }
    }

    /// Confidence is the raw probability of lexical Whisper tokens only.
    /// Boundary, EOT, timestamp, punctuation-only, and non-finite tokens are
    /// excluded so decoder control tokens cannot distort quality thresholds.
    private static func boundaryMeanTokenProbability(
        _ result: WhisperTranscriptionResult,
        wordLimit: Int
    ) -> Double {
        let limit = max(0, wordLimit)
        guard limit > 0 else { return 0 }
        var probabilities: [Double] = []
        for token in result.tokens.prefix(limit * 4) {
            guard isLexicalToken(token.text),
                token.probability.isFinite,
                (0...1).contains(token.probability)
            else {
                continue
            }
            probabilities.append(token.probability)
            if probabilities.count == limit { break }
        }
        guard !probabilities.isEmpty else { return 0 }
        return probabilities.reduce(0, +) / Double(probabilities.count)
    }

    private static func isLexicalToken(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("<|"), trimmed.hasSuffix("|>") {
            return false
        }
        return trimmed.contains { character in
            character.isLetter || character.isNumber
        }
    }

    private static func maximumFiniteNoSpeechProbability(
        _ result: WhisperTranscriptionResult
    ) -> Double {
        result.segments.compactMap { segment in
            let probability = segment.noSpeechProbability
            guard probability.isFinite, (0...1).contains(probability) else { return nil }
            return probability
        }.max() ?? 0
    }

    private static func punctuationCount<S: StringProtocol>(in text: S) -> Int {
        text.reduce(into: 0) { count, character in
            if character.isPunctuation {
                count += 1
            }
        }
    }

    private static func isStrictlyLess(_ value: Double, than boundary: Double) -> Bool {
        guard value.isFinite, boundary.isFinite else { return value < boundary }
        return value < boundary - comparisonTolerance(value, boundary)
    }

    private static func isStrictlyGreater(_ value: Double, than boundary: Double) -> Bool {
        guard value.isFinite, boundary.isFinite else { return value > boundary }
        return value > boundary + comparisonTolerance(value, boundary)
    }

    private static func isAtLeast(_ value: Double, _ boundary: Double) -> Bool {
        guard value.isFinite, boundary.isFinite else { return value >= boundary }
        return value >= boundary - comparisonTolerance(value, boundary)
    }

    private static func comparisonTolerance(_ left: Double, _ right: Double) -> Double {
        let scale = max(1, max(abs(left), abs(right)))
        return max(absoluteComparisonTolerance, scale.ulp * comparisonULPCount)
    }
}
