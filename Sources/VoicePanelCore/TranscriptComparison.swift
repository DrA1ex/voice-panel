import Foundation

public struct TranscriptComparison: Equatable, Sendable {
    public struct Token: Equatable, Sendable {
        public let text: String
        public let isChanged: Bool

        public init(text: String, isChanged: Bool) {
            self.text = text
            self.isChanged = isChanged
        }
    }

    public let left: [Token]
    public let right: [Token]
    public let removedWordCount: Int
    public let insertedWordCount: Int

    public var changedWordCount: Int {
        removedWordCount + insertedWordCount
    }

    public static func compare(_ leftText: String, _ rightText: String) -> TranscriptComparison {
        let leftWords = words(in: leftText)
        let rightWords = words(in: rightText)
        let matches = longestCommonSubsequence(leftWords, rightWords)
        let leftMatches = Set(matches.map(\.left))
        let rightMatches = Set(matches.map(\.right))
        let left = leftWords.indices.map { index in
            Token(text: leftWords[index], isChanged: !leftMatches.contains(index))
        }
        let right = rightWords.indices.map { index in
            Token(text: rightWords[index], isChanged: !rightMatches.contains(index))
        }
        return TranscriptComparison(
            left: left,
            right: right,
            removedWordCount: left.count - leftMatches.count,
            insertedWordCount: right.count - rightMatches.count
        )
    }

    private struct Match {
        let left: Int
        let right: Int
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func longestCommonSubsequence(
        _ left: [String],
        _ right: [String]
    ) -> [Match] {
        guard !left.isEmpty, !right.isEmpty else { return [] }

        // Validation transcripts are normally a few hundred words. Bound the
        // quadratic table for unexpectedly large imports while retaining useful
        // prefix/suffix comparison instead of risking an oversized allocation.
        guard left.count <= 2_000, right.count <= 2_000 else {
            return boundedEdgeMatches(left, right)
        }

        let columnCount = right.count + 1
        var lengths = [Int](repeating: 0, count: (left.count + 1) * columnCount)
        func offset(_ row: Int, _ column: Int) -> Int { row * columnCount + column }

        for leftIndex in left.indices {
            for rightIndex in right.indices {
                if left[leftIndex] == right[rightIndex] {
                    lengths[offset(leftIndex + 1, rightIndex + 1)] =
                        lengths[offset(leftIndex, rightIndex)] + 1
                } else {
                    lengths[offset(leftIndex + 1, rightIndex + 1)] = max(
                        lengths[offset(leftIndex, rightIndex + 1)],
                        lengths[offset(leftIndex + 1, rightIndex)]
                    )
                }
            }
        }

        var matches: [Match] = []
        var leftIndex = left.count
        var rightIndex = right.count
        while leftIndex > 0, rightIndex > 0 {
            if left[leftIndex - 1] == right[rightIndex - 1] {
                matches.append(Match(left: leftIndex - 1, right: rightIndex - 1))
                leftIndex -= 1
                rightIndex -= 1
            } else if lengths[offset(leftIndex - 1, rightIndex)]
                >= lengths[offset(leftIndex, rightIndex - 1)]
            {
                leftIndex -= 1
            } else {
                rightIndex -= 1
            }
        }
        return matches.reversed()
    }

    private static func boundedEdgeMatches(_ left: [String], _ right: [String]) -> [Match] {
        var matches: [Match] = []
        var prefix = 0
        while prefix < min(left.count, right.count), left[prefix] == right[prefix] {
            matches.append(Match(left: prefix, right: prefix))
            prefix += 1
        }

        var leftIndex = left.count
        var rightIndex = right.count
        var suffix: [Match] = []
        while leftIndex > prefix, rightIndex > prefix,
            left[leftIndex - 1] == right[rightIndex - 1]
        {
            leftIndex -= 1
            rightIndex -= 1
            suffix.append(Match(left: leftIndex, right: rightIndex))
        }
        matches.append(contentsOf: suffix.reversed())
        return matches
    }
}
