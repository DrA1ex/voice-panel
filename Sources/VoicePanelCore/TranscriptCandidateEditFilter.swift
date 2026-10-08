import Foundation

public struct TranscriptSpellingReplacement: Hashable, Sendable {
    public let source: String
    public let replacement: String

    public init(source: String, replacement: String) {
        self.source = Self.canonical(source)
        self.replacement = Self.canonical(replacement)
    }

    fileprivate func matches(source: String, replacement: String) -> Bool {
        self.source == Self.canonical(source)
            && self.replacement == Self.canonical(replacement)
    }

    private static func canonical(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "ё", with: "е")
    }
}

public enum TranscriptCandidateEditKind: String, Equatable, Sendable {
    case caseChange
    case punctuation
    case spelling
    case lexicalReplacement
    case insertion
    case deletion
    case structural
}

public enum TranscriptCandidateEditDecision: String, Equatable, Sendable {
    case accepted
    case rejected
}

public struct TranscriptCandidateEdit: Equatable, Sendable {
    public let kind: TranscriptCandidateEditKind
    public let decision: TranscriptCandidateEditDecision
    public let source: String
    public let replacement: String

    public init(
        kind: TranscriptCandidateEditKind,
        decision: TranscriptCandidateEditDecision,
        source: String,
        replacement: String
    ) {
        self.kind = kind
        self.decision = decision
        self.source = source
        self.replacement = replacement
    }
}

public struct TranscriptCandidateEditConfiguration: Equatable, Sendable {
    public var allowsCaseChanges: Bool
    public var allowsPunctuationChanges: Bool
    public var allowedSpellingReplacements: Set<TranscriptSpellingReplacement>

    public init(
        allowsCaseChanges: Bool = true,
        allowsPunctuationChanges: Bool = true,
        allowedSpellingReplacements: Set<TranscriptSpellingReplacement> = []
    ) {
        self.allowsCaseChanges = allowsCaseChanges
        self.allowsPunctuationChanges = allowsPunctuationChanges
        self.allowedSpellingReplacements = allowedSpellingReplacements
    }
}

public struct TranscriptCandidateEditResult: Equatable, Sendable {
    public let text: String
    public let edits: [TranscriptCandidateEdit]

    public init(text: String, edits: [TranscriptCandidateEdit]) {
        self.text = text
        self.edits = edits
    }

    public var acceptedEditCount: Int {
        edits.filter { $0.decision == .accepted }.count
    }

    public var rejectedEditCount: Int {
        edits.filter { $0.decision == .rejected }.count
    }

    public var rejectedMeaningChangingEditCount: Int {
        edits.filter {
            $0.decision == .rejected
                && ($0.kind == .lexicalReplacement
                    || $0.kind == .insertion
                    || $0.kind == .deletion
                    || $0.kind == .structural)
        }.count
    }

    public var didChange: Bool { acceptedEditCount > 0 }
}

/// Converts a freely generated correction candidate into explicit local edits
/// and applies only operations that cannot silently rewrite transcript meaning.
///
/// Word insertion, deletion, reordering, and unvalidated lexical replacement
/// are rejected by construction. A caller may explicitly allow a spelling pair
/// after validating it with a language dictionary or acoustic evidence.
public enum TranscriptCandidateEditFilter {
    public static func lexicalReplacementCandidates(
        source: String,
        candidate: String
    ) -> [TranscriptSpellingReplacement] {
        let sourceDocument = TokenizedDocument(source)
        let candidateDocument = TokenizedDocument(candidate)
        guard sourceDocument.words.count == candidateDocument.words.count else { return [] }

        return zip(sourceDocument.words, candidateDocument.words).compactMap { sourceWord, candidateWord in
            guard canonical(sourceWord) != canonical(candidateWord),
                isPlausibleSpellingPair(source: sourceWord, replacement: candidateWord)
            else { return nil }
            return TranscriptSpellingReplacement(source: sourceWord, replacement: candidateWord)
        }
    }

    public static func apply(
        source: String,
        candidate: String,
        configuration: TranscriptCandidateEditConfiguration = .init()
    ) -> TranscriptCandidateEditResult {
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSource.isEmpty, !normalizedCandidate.isEmpty else {
            return TranscriptCandidateEditResult(text: normalizedSource, edits: [])
        }
        guard normalizedSource != normalizedCandidate else {
            return TranscriptCandidateEditResult(text: normalizedSource, edits: [])
        }

        let protected = protectedLexemes(in: normalizedSource)
        guard protected.allSatisfy({ normalizedCandidate.contains($0) }) else {
            return TranscriptCandidateEditResult(
                text: normalizedSource,
                edits: [
                    TranscriptCandidateEdit(
                        kind: .structural,
                        decision: .rejected,
                        source: normalizedSource,
                        replacement: normalizedCandidate
                    )
                ]
            )
        }

        let sourceDocument = TokenizedDocument(normalizedSource)
        let candidateDocument = TokenizedDocument(normalizedCandidate)
        guard sourceDocument.words.count == candidateDocument.words.count else {
            let kind: TranscriptCandidateEditKind =
                candidateDocument.words.count > sourceDocument.words.count ? .insertion : .deletion
            return TranscriptCandidateEditResult(
                text: normalizedSource,
                edits: [
                    TranscriptCandidateEdit(
                        kind: kind,
                        decision: .rejected,
                        source: normalizedSource,
                        replacement: normalizedCandidate
                    )
                ]
            )
        }

        var outputWords = sourceDocument.words
        var wordAccepted = [Bool](repeating: true, count: sourceDocument.words.count)
        var edits: [TranscriptCandidateEdit] = []

        for index in sourceDocument.words.indices {
            let sourceWord = sourceDocument.words[index]
            let candidateWord = candidateDocument.words[index]
            guard sourceWord != candidateWord else { continue }

            if canonical(sourceWord) == canonical(candidateWord) {
                let accepted =
                    configuration.allowsCaseChanges
                    && isSafeCaseChange(source: sourceWord, replacement: candidateWord)
                if accepted { outputWords[index] = candidateWord }
                wordAccepted[index] = accepted
                edits.append(
                    TranscriptCandidateEdit(
                        kind: .caseChange,
                        decision: accepted ? .accepted : .rejected,
                        source: sourceWord,
                        replacement: candidateWord
                    )
                )
                continue
            }

            let spellingAllowed = configuration.allowedSpellingReplacements.contains {
                $0.matches(source: sourceWord, replacement: candidateWord)
            }
            if spellingAllowed,
                isPlausibleSpellingPair(source: sourceWord, replacement: candidateWord)
            {
                outputWords[index] = candidateWord
                edits.append(
                    TranscriptCandidateEdit(
                        kind: .spelling,
                        decision: .accepted,
                        source: sourceWord,
                        replacement: candidateWord
                    )
                )
            } else {
                wordAccepted[index] = false
                edits.append(
                    TranscriptCandidateEdit(
                        kind: .lexicalReplacement,
                        decision: .rejected,
                        source: sourceWord,
                        replacement: candidateWord
                    )
                )
            }
        }

        var outputSeparators = sourceDocument.separators
        for index in sourceDocument.separators.indices {
            let sourceSeparator = sourceDocument.separators[index]
            let candidateSeparator = candidateDocument.separators[index]
            guard sourceSeparator != candidateSeparator else { continue }

            let leftWordAccepted = index == 0 || wordAccepted[index - 1]
            let rightWordAccepted = index == sourceDocument.words.count || wordAccepted[index]
            let accepted =
                configuration.allowsPunctuationChanges
                && leftWordAccepted
                && rightWordAccepted
                && isSafeSeparatorChange(source: sourceSeparator, replacement: candidateSeparator)
            if accepted { outputSeparators[index] = normalizedSeparator(candidateSeparator, at: index) }
            edits.append(
                TranscriptCandidateEdit(
                    kind: .punctuation,
                    decision: accepted ? .accepted : .rejected,
                    source: sourceSeparator,
                    replacement: candidateSeparator
                )
            )
        }

        var output = outputSeparators[0]
        for index in outputWords.indices {
            output += outputWords[index]
            output += outputSeparators[index + 1]
        }

        return TranscriptCandidateEditResult(
            text: output.trimmingCharacters(in: .whitespacesAndNewlines),
            edits: edits
        )
    }

    public static func isPlausibleSpellingPair(source: String, replacement: String) -> Bool {
        let left = canonical(source)
        let right = canonical(replacement)
        guard left != right,
            left.count >= 4,
            right.count >= 4,
            abs(left.count - right.count) <= 1,
            containsOnlyLetters(left),
            containsOnlyLetters(right),
            usesSameAlphabet(left, right)
        else { return false }
        return damerauLevenshteinDistanceAtMostOne(left, right)
    }

    private struct TokenizedDocument {
        var words: [String] = []
        var separators: [String] = []

        init(_ text: String) {
            var currentWord = ""
            var currentSeparator = ""
            var readingWord = false

            func finishWord() {
                guard !currentWord.isEmpty else { return }
                words.append(currentWord)
                currentWord = ""
            }

            for character in text {
                let isWord =
                    character.isLetter || character.isNumber
                    || ((character == "'" || character == "’") && readingWord)
                if isWord {
                    if !readingWord {
                        separators.append(currentSeparator)
                        currentSeparator = ""
                        readingWord = true
                    }
                    currentWord.append(character)
                } else {
                    if readingWord {
                        finishWord()
                        readingWord = false
                    }
                    currentSeparator.append(character)
                }
            }
            if readingWord { finishWord() }
            separators.append(currentSeparator)

            if words.isEmpty { separators = [text] }
            while separators.count < words.count + 1 { separators.append("") }
        }
    }

    private static func protectedLexemes(in text: String) -> [String] {
        let patterns = [
            #"https?://[^\s]+"#,
            #"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}"#,
            #"(?:^|\s)(?:[/~.]?[A-Za-z0-9_-]+)+(?:/[A-Za-z0-9_.-]+)+"#,
            #"\b(?:[A-Za-z]+[A-Za-z0-9_.+-]*|[A-Za-z0-9_.+-]*\d[A-Za-z0-9_.+-]*)\b"#,
            #"\b\d+(?:[.,]\d+)*\b"#,
        ]
        var values: [String] = []
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: text, range: fullRange) {
                guard let range = Range(match.range, in: text) else { continue }
                let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if value.count >= 2, !values.contains(value) { values.append(value) }
            }
        }
        return values
    }

    private static func canonical(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    private static func isSafeCaseChange(source: String, replacement: String) -> Bool {
        guard canonical(source) == canonical(replacement) else { return false }
        if isMixedCaseTechnicalToken(source) { return false }
        return true
    }

    private static func isMixedCaseTechnicalToken(_ value: String) -> Bool {
        let latinLetters = value.filter { $0.isASCII && $0.isLetter }
        guard latinLetters.count >= 2 else { return false }
        let uppercase = latinLetters.filter(\.isUppercase).count
        let lowercase = latinLetters.filter(\.isLowercase).count
        return uppercase > 0 && lowercase > 0 && uppercase != 1
    }

    private static func isSafeSeparatorChange(source: String, replacement: String) -> Bool {
        guard replacement.allSatisfy({ $0.isWhitespace || $0.isPunctuation || $0.isSymbol }) else {
            return false
        }
        if source.contains("\n") && !replacement.contains("\n") { return false }

        let sourceStrong = Set(source.filter { "?!".contains($0) })
        let replacementStrong = Set(replacement.filter { "?!".contains($0) })
        if sourceStrong != replacementStrong { return false }

        let typographicQuotes = CharacterSet(charactersIn: "«»„“”")
        let sourceQuotes = Array(source.unicodeScalars.filter { typographicQuotes.contains($0) })
        let replacementQuotes = Array(replacement.unicodeScalars.filter { typographicQuotes.contains($0) })
        if !sourceQuotes.isEmpty && sourceQuotes != replacementQuotes { return false }
        return true
    }

    private static func normalizedSeparator(_ value: String, at index: Int) -> String {
        if value.contains("\n") { return value }
        if index > 0, value.isEmpty { return " " }
        return value
    }

    private static func containsOnlyLetters(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy(\.isLetter)
    }

    private static func usesSameAlphabet(_ lhs: String, _ rhs: String) -> Bool {
        alphabet(of: lhs) == alphabet(of: rhs)
    }

    private enum Alphabet: Equatable {
        case cyrillic
        case latin
        case other
    }

    private static func alphabet(of value: String) -> Alphabet {
        var cyrillic = 0
        var latin = 0
        for scalar in value.unicodeScalars {
            if (0x0400...0x052F).contains(Int(scalar.value)) { cyrillic += 1 }
            if (0x0041...0x007A).contains(Int(scalar.value)) { latin += 1 }
        }
        if cyrillic > 0, latin == 0 { return .cyrillic }
        if latin > 0, cyrillic == 0 { return .latin }
        return .other
    }

    private static func damerauLevenshteinDistanceAtMostOne(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let left = Array(lhs)
        let right = Array(rhs)
        guard abs(left.count - right.count) <= 1 else { return false }

        if left.count == right.count {
            let differences = left.indices.filter { left[$0] != right[$0] }
            if differences.count == 1 { return true }
            if differences.count == 2,
                differences[1] == differences[0] + 1,
                left[differences[0]] == right[differences[1]],
                left[differences[1]] == right[differences[0]]
            {
                return true
            }
            return false
        }

        let longer = left.count > right.count ? left : right
        let shorter = left.count > right.count ? right : left
        var longIndex = 0
        var shortIndex = 0
        var skipped = false
        while longIndex < longer.count, shortIndex < shorter.count {
            if longer[longIndex] == shorter[shortIndex] {
                longIndex += 1
                shortIndex += 1
            } else if !skipped {
                skipped = true
                longIndex += 1
            } else {
                return false
            }
        }
        return true
    }
}
