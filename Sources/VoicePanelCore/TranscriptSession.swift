import Foundation

public enum TranscriptSegmentUpdateKind: String, Equatable, Sendable {
    case partial
    case segmentFinal
    case sessionFinal
}

public struct TranscriptSegmentUpdate: Equatable, Sendable {
    public let segmentID: UUID
    public let sequence: Int
    public let stableText: String
    public let partialText: String
    public let kind: TranscriptSegmentUpdateKind
    public let allowsLeadingOverlap: Bool

    public init(
        segmentID: UUID,
        sequence: Int,
        stableText: String,
        partialText: String,
        kind: TranscriptSegmentUpdateKind,
        allowsLeadingOverlap: Bool = true
    ) {
        self.segmentID = segmentID
        self.sequence = sequence
        self.stableText = stableText
        self.partialText = partialText
        self.kind = kind
        self.allowsLeadingOverlap = allowsLeadingOverlap
    }
}

public struct TranscriptSegment: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sequence: Int
    public private(set) var stableText: String
    public private(set) var partialText: String
    public private(set) var finalText: String?
    public private(set) var revision: Int
    public private(set) var allowsLeadingOverlap: Bool = true

    public init(
        id: UUID,
        sequence: Int,
        stableText: String = "",
        partialText: String = "",
        finalText: String? = nil,
        revision: Int = 0
    ) {
        self.id = id
        self.sequence = sequence
        self.stableText = stableText
        self.partialText = partialText
        self.finalText = finalText
        self.revision = revision
    }

    public var displayText: String {
        if let finalText {
            return finalText
        }
        return TranscriptTextMerger.join(stableText, partialText)
    }

    public var isFinal: Bool {
        finalText != nil
    }

    mutating func apply(_ update: TranscriptSegmentUpdate) {
        let nextStable = TranscriptTextNormalizer.normalize(update.stableText)
        let nextPartial = TranscriptTextNormalizer.normalize(update.partialText)
        let nextFinal: String?

        switch update.kind {
        case .partial:
            nextFinal = nil
        case .segmentFinal, .sessionFinal:
            let combined = TranscriptTextMerger.join(nextStable, nextPartial)
            nextFinal = combined
        }

        // A late draft cannot reopen a segment already refined by the final engine.
        if isFinal, update.kind == .partial { return }
        guard
            stableText != nextStable || partialText != nextPartial || finalText != nextFinal
                || allowsLeadingOverlap != update.allowsLeadingOverlap
        else {
            return
        }

        stableText = nextStable
        partialText = nextPartial
        finalText = nextFinal
        allowsLeadingOverlap = update.allowsLeadingOverlap
        revision += 1
    }
}

public struct TranscriptSession: Equatable, Sendable {
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var isFinal = false

    public init() {}

    public mutating func reset() {
        segments.removeAll(keepingCapacity: true)
        isFinal = false
    }

    public mutating func apply(_ update: TranscriptSegmentUpdate) {
        if let index = segments.firstIndex(where: { $0.id == update.segmentID }) {
            segments[index].apply(update)
        } else {
            var segment = TranscriptSegment(id: update.segmentID, sequence: update.sequence)
            segment.apply(update)
            if !segment.displayText.isEmpty {
                segments.append(segment)
                segments.sort { lhs, rhs in
                    if lhs.sequence == rhs.sequence {
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                    return lhs.sequence < rhs.sequence
                }
            }
        }

        if update.kind == .sessionFinal {
            isFinal = true
        }
    }

    public var stableText: String {
        return segments.reduce("") { accumulated, segment in
            let text: String
            if let final = segment.finalText {
                text = final
            } else {
                text = segment.stableText
            }
            return segment.allowsLeadingOverlap
                ? TranscriptTextMerger.merge(accumulated, text)
                : TranscriptTextMerger.join(accumulated, text)
        }
    }

    public var partialText: String {
        guard let segment = segments.last(where: { !$0.isFinal }) else { return "" }
        return TranscriptTextMerger.isEffectivelyEmpty(segment.partialText) ? "" : segment.partialText
    }

    public var combinedText: String {
        segments.reduce("") { accumulated, segment in
            segment.allowsLeadingOverlap
                ? TranscriptTextMerger.merge(accumulated, segment.displayText)
                : TranscriptTextMerger.join(accumulated, segment.displayText)
        }
    }

    public var finalizedText: String {
        segments.reduce("") { accumulated, segment in
            guard let finalText = segment.finalText,
                !TranscriptTextMerger.isEffectivelyEmpty(finalText)
            else { return accumulated }
            return segment.allowsLeadingOverlap
                ? TranscriptTextMerger.merge(accumulated, finalText)
                : TranscriptTextMerger.join(accumulated, finalText)
        }
    }
}

public enum TranscriptTextMerger {
    private static let horizontalWhitespace = CharacterSet(charactersIn: " \t\u{00A0}")
    private static let punctuationWithoutLeadingSpace = CharacterSet(charactersIn: ",.;:!?%…)]}")

    public static func isEffectivelyEmpty(_ text: String) -> Bool {
        text.trimmingCharacters(in: horizontalWhitespace).isEmpty
    }

    public static func join(_ lhs: String, _ rhs: String) -> String {
        concatenate(
            TranscriptTextNormalizer.normalize(lhs),
            TranscriptTextNormalizer.normalize(rhs)
        )
    }

    public static func merge(_ segments: [String]) -> String {
        segments.reduce("") { result, segment in
            merge(result, segment)
        }
    }

    public static func merge(_ accumulated: String, _ next: String) -> String {
        let left = TranscriptTextNormalizer.normalize(accumulated)
        let right = TranscriptTextNormalizer.normalize(next)

        if left.isEmpty { return right }
        if right.isEmpty { return left }

        // Newlines carry layout meaning. Do not rebuild newline-containing text
        // from whitespace-separated tokens, because that would flatten it.
        guard !left.contains("\n"), !right.contains("\n") else {
            return concatenate(left, right)
        }

        let leftWords = words(from: left)
        let rightWords = words(from: right)
        let maximumOverlap = min(12, leftWords.count, rightWords.count)
        var overlap = 0

        if normalized(leftWords) == normalized(rightWords) {
            overlap = rightWords.count
        } else if maximumOverlap >= 2 {
            for count in stride(from: maximumOverlap, through: 2, by: -1) {
                let suffix = Array(leftWords.suffix(count))
                let prefix = Array(rightWords.prefix(count))
                if normalized(suffix) == normalized(prefix) {
                    overlap = count
                    break
                }
            }
        }

        guard overlap < rightWords.count else { return left }
        let remainder = rightWords.dropFirst(overlap).joined(separator: " ")
        return concatenate(left, remainder)
    }

    private static func concatenate(_ lhs: String, _ rhs: String) -> String {
        if lhs.isEmpty { return rhs }
        if rhs.isEmpty { return lhs }

        if lhs.hasSuffix("\n") || rhs.hasPrefix("\n") {
            return TranscriptTextNormalizer.normalize(lhs + rhs)
        }

        if let first = rhs.unicodeScalars.first,
            punctuationWithoutLeadingSpace.contains(first)
        {
            return TranscriptTextNormalizer.normalize(lhs + rhs)
        }

        return TranscriptTextNormalizer.normalize("\(lhs) \(rhs)")
    }

    private static func words(from text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func normalized(_ words: [String]) -> [String] {
        words.map { word in
            word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
    }
}
