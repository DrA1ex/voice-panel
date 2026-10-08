import Foundation

public enum WhisperBoundaryPromptBuilder {
    public static let maximumDynamicWords = 24
    public static let maximumDynamicCharacters = 320

    public static func prompt(
        staticPrompt: String,
        previous: WhisperTranscriptionResult,
        current: WhisperTranscriptionResult,
        previousAudioDuration: TimeInterval,
        overlapDuration: TimeInterval,
        mode: WhisperContextPromptMode
    ) -> String {
        let normalizedStaticPrompt = staticPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let dynamicTail: String

        switch mode {
        case .legacyFixedWords:
            let previousWords = WhisperBoundaryText.words(in: previous.text)
            let excludedWordCount = min(3, previousWords.count)
            dynamicTail = boundedTail(from: Array(previousWords.dropLast(excludedWordCount)))

        case .lexicalOverlapAligned:
            dynamicTail = lexicalTail(previous: previous, current: current)

        case .timestampAligned:
            guard !previous.tokens.isEmpty,
                previous.tokens.allSatisfy({ $0.endTime != nil })
            else {
                dynamicTail = lexicalTail(previous: previous, current: current)
                return combined(staticPrompt: normalizedStaticPrompt, dynamicTail: dynamicTail)
            }

            let cutoff = max(0, previousAudioDuration - overlapDuration)
            let eligibleTimedTokens = previous.tokens.filter { token in
                guard let endTime = token.endTime else { return false }
                return endTime <= cutoff
            }
            let eligibleText = eligibleTimedTokens.map(\.text).joined()
            dynamicTail = boundedTail(from: WhisperBoundaryText.words(in: eligibleText))
        }

        return combined(staticPrompt: normalizedStaticPrompt, dynamicTail: dynamicTail)
    }

    private static func lexicalTail(
        previous: WhisperTranscriptionResult,
        current: WhisperTranscriptionResult
    ) -> String {
        let previousWords = WhisperBoundaryText.words(in: previous.text)
        let currentWords = WhisperBoundaryText.words(in: current.text)
        let excludedWordCount = WhisperBoundaryText.longestSuffixPrefixMatch(
            left: previousWords,
            right: currentWords,
            maximumWords: 12
        )
        guard excludedWordCount > 0 else { return "" }

        var remainingLexicalWords = excludedWordCount
        var exclusionStart = previousWords.count
        while exclusionStart > 0, remainingLexicalWords > 0 {
            exclusionStart -= 1
            if !previousWords[exclusionStart].normalized.isEmpty {
                remainingLexicalWords -= 1
            }
        }
        return boundedTail(from: Array(previousWords[..<exclusionStart]))
    }

    private static func boundedTail(from words: [WhisperBoundaryWord]) -> String {
        var selectedWords = Array(words.suffix(maximumDynamicWords))
        while !selectedWords.isEmpty,
            selectedWords.map(\.original).joined(separator: " ").count
                > maximumDynamicCharacters
        {
            selectedWords.removeFirst()
        }
        return selectedWords.map(\.original).joined(separator: " ")
    }

    private static func combined(staticPrompt: String, dynamicTail: String) -> String {
        guard !dynamicTail.isEmpty else { return staticPrompt }
        guard !staticPrompt.isEmpty else { return dynamicTail }
        return staticPrompt + "\n" + dynamicTail
    }
}
