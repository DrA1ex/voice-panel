import Foundation
import VoicePanelCore

private func whisperResult(
    _ text: String,
    tokens: [WhisperTokenEvidence] = []
) -> WhisperTranscriptionResult {
    WhisperTranscriptionResult(
        text: text,
        segments: [
            WhisperSegmentEvidence(
                text: text,
                startTime: 0,
                endTime: 10,
                noSpeechProbability: 0,
                tokens: tokens
            )
        ],
        detectedLanguage: "ru",
        inferenceDuration: 0
    )
}

let whisperBoundaryPromptBuilderChecks: [CheckCase] = [
    CheckCase(name: "Whisper boundary words preserve original multilingual ranges") {
        let text = "Привет,\tмир!  ¿Qué? —"
        let words = WhisperBoundaryText.words(in: text)

        try expectEqual(words.map { String(text[$0.originalRange]) }, ["Привет,", "мир!", "¿Qué?", "—"])
        try expectEqual(words.map(\.normalized), ["привет", "мир", "qué", ""])
    },
    CheckCase(name: "Whisper boundary words preserve an extended grapheme at a text boundary") {
        let text = "👩🏽‍💻, привет"
        let words = WhisperBoundaryText.words(in: text)

        try expectEqual(String(text[words[0].originalRange]), "👩🏽‍💻,")
        try expectEqual(words[0].normalized, "👩🏽‍💻")
    },
    CheckCase(name: "Whisper lexical alignment finds the longest bounded suffix and prefix") {
        let left = WhisperBoundaryText.words(
            in: "вступление это, как получается!"
        )
        let right = WhisperBoundaryText.words(
            in: "ЭТО КАК ПОЛУЧАЕТСЯ дальше"
        )

        try expectEqual(
            WhisperBoundaryText.longestSuffixPrefixMatch(
                left: left,
                right: right,
                maximumWords: 12
            ),
            3
        )
        try expectEqual(
            WhisperBoundaryText.longestSuffixPrefixMatch(
                left: left,
                right: WhisperBoundaryText.words(in: "совсем иначе"),
                maximumWords: 12
            ),
            0
        )
    },
    CheckCase(name: "Whisper lexical alignment never exceeds twelve words") {
        let repeatedWords = Array(repeating: "эхо", count: 13).joined(separator: " ")

        try expectEqual(
            WhisperBoundaryText.longestSuffixPrefixMatch(
                left: WhisperBoundaryText.words(in: repeatedWords),
                right: WhisperBoundaryText.words(in: repeatedWords),
                maximumWords: 100
            ),
            12
        )
    },
    CheckCase(name: "Whisper stable anchor requires three words inside the first boundary window") {
        let left = WhisperBoundaryText.words(in: "до общий устойчивый якорь после")
        let right = WhisperBoundaryText.words(in: "ввод общий устойчивый якорь конец")
        let anchor = WhisperBoundaryText.stableAnchor(left: left, right: right)

        try expectEqual(anchor?.leftWordRange, 1..<4)
        try expectEqual(anchor?.rightWordRange, 1..<4)
        try expectEqual(
            WhisperBoundaryText.stableAnchor(
                left: WhisperBoundaryText.words(in: "только два"),
                right: WhisperBoundaryText.words(in: "только два")
            ),
            nil
        )

        let leftPrefix = (1...24).map { "левое\($0)" }.joined(separator: " ")
        let rightPrefix = (1...24).map { "правое\($0)" }.joined(separator: " ")
        try expectEqual(
            WhisperBoundaryText.stableAnchor(
                left: WhisperBoundaryText.words(in: leftPrefix + " поздний общий якорь"),
                right: WhisperBoundaryText.words(in: rightPrefix + " поздний общий якорь")
            ),
            nil,
            "anchors after the first 24 boundary words must be ignored"
        )
    },
    CheckCase(name: "Whisper legacy prompt excludes three fixed trailing words") {
        let prompt = WhisperBoundaryPromptBuilder.prompt(
            staticPrompt: "",
            previous: whisperResult("one two three four five six"),
            current: whisperResult("four five six seven"),
            previousAudioDuration: 10,
            overlapDuration: 0.5,
            mode: .legacyFixedWords
        )

        try expectEqual(prompt, "one two three")
    },
    CheckCase(name: "Whisper lexical prompt excludes only the aligned overlap") {
        let prompt = WhisperBoundaryPromptBuilder.prompt(
            staticPrompt: "",
            previous: whisperResult("это как получается"),
            current: whisperResult("получается дальше"),
            previousAudioDuration: 10,
            overlapDuration: 0.5,
            mode: .lexicalOverlapAligned
        )

        try expectEqual(prompt, "это как")
    },
    CheckCase(name: "Whisper timestamp prompt includes only tokens ending by the overlap cutoff") {
        let previous = whisperResult(
            "ноль один два три",
            tokens: [
                WhisperTokenEvidence(text: "ноль", startTime: 0, endTime: 8, probability: 0.9),
                WhisperTokenEvidence(text: " один", startTime: 8, endTime: 9.5, probability: 0.9),
                WhisperTokenEvidence(text: " два", startTime: 9.4, endTime: 9.51, probability: 0.9),
                WhisperTokenEvidence(text: " три", startTime: 9.51, endTime: 10, probability: 0.9),
            ]
        )

        let prompt = WhisperBoundaryPromptBuilder.prompt(
            staticPrompt: "Контекст и словарь",
            previous: previous,
            current: whisperResult("два три дальше"),
            previousAudioDuration: 10,
            overlapDuration: 0.5,
            mode: .timestampAligned
        )

        try expectEqual(prompt, "Контекст и словарь\nноль один")
    },
    CheckCase(name: "Whisper timestamp prompt falls back when timestamp evidence is incomplete") {
        let previous = whisperResult(
            "alpha beta gamma",
            tokens: [
                WhisperTokenEvidence(text: "alpha", startTime: 0, endTime: 8, probability: 0.9),
                WhisperTokenEvidence(text: " beta", startTime: 8, endTime: nil, probability: 0.9),
                WhisperTokenEvidence(text: " gamma", startTime: nil, endTime: nil, probability: 0.9),
            ]
        )

        let prompt = WhisperBoundaryPromptBuilder.prompt(
            staticPrompt: "",
            previous: previous,
            current: whisperResult("gamma delta"),
            previousAudioDuration: 10,
            overlapDuration: 0.5,
            mode: .timestampAligned
        )

        try expectEqual(prompt, "alpha beta")
    },
    CheckCase(name: "Whisper lexical prompt without a match keeps only static context") {
        let prompt = WhisperBoundaryPromptBuilder.prompt(
            staticPrompt: "  Статика: C++, Rust.  ",
            previous: whisperResult("one two three four five six"),
            current: whisperResult("совсем другой текст"),
            previousAudioDuration: 10,
            overlapDuration: 0.5,
            mode: .lexicalOverlapAligned
        )

        try expectEqual(prompt, "Статика: C++, Rust.")
    },
    CheckCase(name: "Whisper dynamic prompt tail is bounded by words and characters") {
        let longWords = (1...40).map { index in
            "длинноеслово\(index)abcdefgh"
        }
        let prompt = WhisperBoundaryPromptBuilder.prompt(
            staticPrompt: "Статика",
            previous: whisperResult((longWords + ["совпадение"]).joined(separator: " ")),
            current: whisperResult("совпадение дальше"),
            previousAudioDuration: 10,
            overlapDuration: 0.5,
            mode: .lexicalOverlapAligned
        )
        let dynamicTail = String(prompt.split(separator: "\n", maxSplits: 1)[1])

        try expect(
            dynamicTail.split(whereSeparator: { $0.isWhitespace }).count <= 24,
            "dynamic context must contain at most 24 words"
        )
        try expect(
            dynamicTail.count <= 320,
            "dynamic context must contain at most 320 characters"
        )
        try expect(
            dynamicTail.hasSuffix("длинноеслово40abcdefgh"),
            "bounding must retain the most recent eligible whole words"
        )
    },
    CheckCase(name: "Whisper dynamic prompt keeps exactly the latest twenty-four short words") {
        let eligibleWords = (1...30).map { "w\($0)" }
        let prompt = WhisperBoundaryPromptBuilder.prompt(
            staticPrompt: "",
            previous: whisperResult((eligibleWords + ["match"]).joined(separator: " ")),
            current: whisperResult("match next"),
            previousAudioDuration: 10,
            overlapDuration: 0.5,
            mode: .lexicalOverlapAligned
        )

        try expectEqual(prompt, (7...30).map { "w\($0)" }.joined(separator: " "))
    },
    CheckCase(name: "Whisper dynamic prompt preserves a multi-scalar grapheme at character 320") {
        let boundaryWord = String(repeating: "а", count: 319) + "👩🏽‍💻"
        let prompt = WhisperBoundaryPromptBuilder.prompt(
            staticPrompt: "",
            previous: whisperResult(boundaryWord + " match"),
            current: whisperResult("match next"),
            previousAudioDuration: 10,
            overlapDuration: 0.5,
            mode: .lexicalOverlapAligned
        )

        try expectEqual(prompt, boundaryWord)
        try expectEqual(prompt.count, 320)
        try expectEqual(prompt.last, "👩🏽‍💻")
    },
    CheckCase(name: "Whisper dynamic prompt drops an oversized word whole") {
        let oversizedWord = String(repeating: "я", count: 321)
        let prompt = WhisperBoundaryPromptBuilder.prompt(
            staticPrompt: "Статика",
            previous: whisperResult(oversizedWord + " match"),
            current: whisperResult("match next"),
            previousAudioDuration: 10,
            overlapDuration: 0.5,
            mode: .lexicalOverlapAligned
        )

        try expectEqual(prompt, "Статика")
    },
]
