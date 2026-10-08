import Foundation

public struct StabilizedTranscript: Equatable, Sendable {
    public let stableText: String
    public let partialText: String
    public let isFinal: Bool

    public init(stableText: String, partialText: String, isFinal: Bool) {
        self.stableText = stableText
        self.partialText = partialText
        self.isFinal = isFinal
    }

    public var combinedText: String {
        [stableText, partialText]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

public struct TranscriptStabilizer: Sendable {
    public var trailingUnstableWordCount: Int

    private var previousWords: [String] = []
    private var committedWords: [String] = []

    public init(trailingUnstableWordCount: Int = 3) {
        self.trailingUnstableWordCount = max(0, trailingUnstableWordCount)
    }

    public mutating func reset() {
        previousWords.removeAll(keepingCapacity: true)
        committedWords.removeAll(keepingCapacity: true)
    }

    public mutating func update(hypothesis: String, isFinal: Bool) -> StabilizedTranscript {
        let words = Self.words(from: hypothesis)

        if isFinal {
            committedWords = words
            previousWords = words
            return StabilizedTranscript(
                stableText: words.joined(separator: " "),
                partialText: "",
                isFinal: true
            )
        }

        let committedStillMatches = words.starts(with: committedWords)
        if !committedStillMatches {
            let preservedCount = Self.commonPrefixCount(committedWords, words)
            committedWords = Array(committedWords.prefix(preservedCount))
        }

        let commonWithPrevious = Self.commonPrefixCount(previousWords, words)
        let candidateStableCount = max(0, commonWithPrevious - trailingUnstableWordCount)
        if candidateStableCount > committedWords.count,
            words.starts(with: committedWords)
        {
            committedWords = Array(words.prefix(candidateStableCount))
        }

        previousWords = words
        let partialWords: ArraySlice<String>
        if words.starts(with: committedWords) {
            partialWords = words.dropFirst(committedWords.count)
        } else {
            partialWords = words[...]
        }

        return StabilizedTranscript(
            stableText: committedWords.joined(separator: " "),
            partialText: partialWords.joined(separator: " "),
            isFinal: false
        )
    }

    private static func words(from text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func commonPrefixCount(_ lhs: [String], _ rhs: [String]) -> Int {
        var index = 0
        while index < lhs.count, index < rhs.count, lhs[index] == rhs[index] {
            index += 1
        }
        return index
    }
}
