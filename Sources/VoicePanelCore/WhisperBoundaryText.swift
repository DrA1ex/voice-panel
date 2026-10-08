import Foundation

public struct WhisperBoundaryWord: Equatable, Sendable {
    public let original: String
    public let originalRange: Range<String.Index>
    public let normalized: String

    public init(
        original: String,
        originalRange: Range<String.Index>,
        normalized: String
    ) {
        self.original = original
        self.originalRange = originalRange
        self.normalized = normalized
    }
}

public struct WhisperBoundaryAnchor: Equatable, Sendable {
    public let leftWordRange: Range<Int>
    public let rightWordRange: Range<Int>

    public init(leftWordRange: Range<Int>, rightWordRange: Range<Int>) {
        self.leftWordRange = leftWordRange
        self.rightWordRange = rightWordRange
    }
}

public enum WhisperBoundaryText {
    public static let maximumAlignmentWords = 12
    public static let stableAnchorWordCount = 3
    public static let maximumBoundaryWords = 24

    public static func words(in text: String) -> [WhisperBoundaryWord] {
        var result: [WhisperBoundaryWord] = []
        var index = text.startIndex

        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }

            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }

            let range = start..<index
            let original = String(text[range])
            let normalized = original.filter { !$0.isPunctuation }.lowercased()
            result.append(
                WhisperBoundaryWord(
                    original: original,
                    originalRange: range,
                    normalized: normalized
                )
            )
        }

        return result
    }

    public static func longestSuffixPrefixMatch(
        left: [WhisperBoundaryWord],
        right: [WhisperBoundaryWord],
        maximumWords: Int = maximumAlignmentWords
    ) -> Int {
        let leftLexical = left.map(\.normalized).filter { !$0.isEmpty }
        let rightLexical = right.map(\.normalized).filter { !$0.isEmpty }
        let searchLimit = min(
            max(0, maximumWords),
            maximumAlignmentWords,
            leftLexical.count,
            rightLexical.count
        )
        guard searchLimit > 0 else { return 0 }

        for count in stride(from: searchLimit, through: 1, by: -1) {
            if leftLexical.suffix(count).elementsEqual(rightLexical.prefix(count)) {
                return count
            }
        }
        return 0
    }

    public static func stableAnchor(
        left: [WhisperBoundaryWord],
        right: [WhisperBoundaryWord]
    ) -> WhisperBoundaryAnchor? {
        let leftLexical = lexicalWords(in: left)
        let rightLexical = lexicalWords(in: right)
        let leftBoundary = Array(leftLexical.prefix(maximumBoundaryWords))
        let rightBoundary = Array(rightLexical.prefix(maximumBoundaryWords))

        guard leftBoundary.count >= stableAnchorWordCount,
            rightBoundary.count >= stableAnchorWordCount
        else {
            return nil
        }

        for leftStart in 0...(leftBoundary.count - stableAnchorWordCount) {
            let leftAnchor = leftBoundary[
                leftStart..<(leftStart + stableAnchorWordCount)
            ].map { $0.word.normalized }

            for rightStart in 0...(rightBoundary.count - stableAnchorWordCount) {
                let rightAnchor = rightBoundary[
                    rightStart..<(rightStart + stableAnchorWordCount)
                ].map { $0.word.normalized }
                guard leftAnchor == rightAnchor else { continue }

                let leftFirst = leftBoundary[leftStart].index
                let leftLast = leftBoundary[leftStart + stableAnchorWordCount - 1].index
                let rightFirst = rightBoundary[rightStart].index
                let rightLast = rightBoundary[rightStart + stableAnchorWordCount - 1].index
                return WhisperBoundaryAnchor(
                    leftWordRange: leftFirst..<(leftLast + 1),
                    rightWordRange: rightFirst..<(rightLast + 1)
                )
            }
        }

        return nil
    }

    private static func lexicalWords(
        in words: [WhisperBoundaryWord]
    ) -> [(index: Int, word: WhisperBoundaryWord)] {
        words.enumerated().compactMap { index, word in
            word.normalized.isEmpty ? nil : (index, word)
        }
    }
}
