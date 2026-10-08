import Foundation
import VoicePanelCore

private typealias TimedToken = (text: String, start: TimeInterval?, end: TimeInterval?)

private func bridgeResult(
    _ tokens: [TimedToken],
    text: String? = nil
) -> WhisperTranscriptionResult {
    let resultText = text ?? tokens.map(\.text).joined()
    let evidence = tokens.map { token in
        WhisperTokenEvidence(
            text: token.text,
            startTime: token.start,
            endTime: token.end,
            probability: 0.9
        )
    }
    return WhisperTranscriptionResult(
        text: resultText,
        segments: [
            WhisperSegmentEvidence(
                text: resultText,
                startTime: 0,
                endTime: tokens.compactMap(\.end).max() ?? 0,
                noSpeechProbability: 0,
                tokens: evidence
            )
        ],
        detectedLanguage: "ru",
        inferenceDuration: 0
    )
}

private func untimedResult(_ text: String) -> WhisperTranscriptionResult {
    bridgeResult([], text: text)
}

private let acceptedPreviousText = "KEEP👩🏽‍💻  левый общий якорь старое，"
private let acceptedCurrentText = "старое новое правый устойчивый якорь  KEEP 你好。"

private func acceptedBridgeTokens() -> [TimedToken] {
    [
        ("левый", 0.0, 0.2),
        (" общий", 0.2, 0.4),
        (" якорь", 0.4, 0.6),
        (" исправленный，", 0.8, 1.2),
        (" переход", 1.2, 1.4),
        (" правый", 1.4, 1.6),
        (" устойчивый", 1.6, 1.8),
        (" якорь", 1.8, 2.0),
    ]
}

private func bridgePatch(
    previous: String = acceptedPreviousText,
    current: String = acceptedCurrentText,
    tokens: [TimedToken] = acceptedBridgeTokens(),
    bridgeText: String? = nil,
    cutTime: TimeInterval = 1
) -> WhisperBoundaryBridgePatch? {
    WhisperBoundaryRepairPolicy.bridgePatch(
        previous: untimedResult(previous),
        current: untimedResult(current),
        bridge: bridgeResult(tokens, text: bridgeText),
        cutTime: cutTime
    )
}

let whisperBoundaryBridgeChecks: [CheckCase] = [
    CheckCase(name: "Whisper bridge drops one configured overlap and aligns the cut") {
        let bridge = WhisperBoundaryBridgeBuilder.make(
            previousSamples: [0, 1, 2, 3, 4],
            currentSamples: [4, 5, 6, 7],
            sampleRate: 1,
            overlapDuration: 1,
            sideDuration: 3
        )

        try expectEqual(bridge?.samples, [2, 3, 4, 5, 6, 7])
        try expectApproximatelyEqual(bridge?.cutTime ?? -1, 3, accuracy: 0.000_001)
    },
    CheckCase(name: "Whisper bridge sample counts round to the nearest integer") {
        let bridge = WhisperBoundaryBridgeBuilder.make(
            previousSamples: [0, 1, 2, 3, 4],
            currentSamples: [4, 5, 6, 7],
            sampleRate: 4,
            overlapDuration: 0.375,
            sideDuration: 0.375
        )

        try expectEqual(bridge?.samples, [3, 4, 6, 7])
        try expectApproximatelyEqual(bridge?.cutTime ?? -1, 0.5, accuracy: 0.000_001)
    },
    CheckCase(name: "Whisper bridge clamps overlap and bounds retained sample work") {
        let bridge = WhisperBoundaryBridgeBuilder.make(
            previousSamples: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
            currentSamples: [9, 10, 11, 12],
            sampleRate: 1,
            overlapDuration: 99,
            sideDuration: 2
        )

        try expectEqual(bridge?.samples, [8, 9])
        try expectApproximatelyEqual(bridge?.cutTime ?? -1, 2, accuracy: 0.000_001)
    },
    CheckCase(name: "Whisper bridge preserves current samples when overlap is zero") {
        let bridge = WhisperBoundaryBridgeBuilder.make(
            previousSamples: [0, 1, 2],
            currentSamples: [2, 3, 4],
            sampleRate: 1,
            overlapDuration: 0,
            sideDuration: 2
        )

        try expectEqual(bridge?.samples, [1, 2, 2, 3])
    },
    CheckCase(name: "Whisper bridge rejects zero nonfinite and unequal sample rates") {
        try expectEqual(
            WhisperBoundaryBridgeBuilder.make(
                previousSamples: [0],
                currentSamples: [1],
                sampleRate: 0,
                overlapDuration: 0,
                sideDuration: 1
            ),
            nil
        )
        try expectEqual(
            WhisperBoundaryBridgeBuilder.make(
                previousSamples: [0],
                currentSamples: [1],
                sampleRate: .infinity,
                overlapDuration: 0,
                sideDuration: 1
            ),
            nil
        )
        try expectEqual(
            WhisperBoundaryBridgeBuilder.make(
                previousSamples: [0],
                previousSampleRate: 16_000,
                currentSamples: [1],
                currentSampleRate: 48_000,
                overlapDuration: 0,
                sideDuration: 1
            ),
            nil
        )
    },
    CheckCase(name: "Whisper bridge rejects invalid durations and a zero side window") {
        let invalidDurations: [(TimeInterval, TimeInterval)] = [
            (-1, 1),
            (.nan, 1),
            (0, 0),
            (0, .infinity),
        ]

        for (overlapDuration, sideDuration) in invalidDurations {
            let bridge = WhisperBoundaryBridgeBuilder.make(
                previousSamples: [0, 1],
                currentSamples: [1, 2],
                sampleRate: 1,
                overlapDuration: overlapDuration,
                sideDuration: sideDuration
            )
            try expectEqual(bridge, nil)
        }
    },
    CheckCase(name: "Whisper bridge saturates extreme finite sample counts without trapping") {
        let bridge = WhisperBoundaryBridgeBuilder.make(
            previousSamples: [0],
            currentSamples: [1],
            sampleRate: Double(Int.max),
            overlapDuration: 0,
            sideDuration: 1
        )

        try expectEqual(bridge?.samples, [0, 1])
    },
    CheckCase(name: "Whisper timed patch changes only between unique three-word anchors") {
        guard let patch = bridgePatch() else {
            throw CheckFailure(description: "complete ordered bridge evidence must be accepted")
        }

        let expectedPreviousPrefix = "KEEP👩🏽‍💻  левый общий якорь"
        let expectedCurrentSuffix = "правый устойчивый якорь  KEEP 你好。"
        try expectEqual(patch.previousText, expectedPreviousPrefix + " исправленный，")
        try expectEqual(patch.currentText, " переход " + expectedCurrentSuffix)
        try expectEqual(patch.removedBoundaryWordCount, 3)
        try expectEqual(patch.replacementBoundaryWordCount, 2)
        try expect(
            Array(patch.previousText.utf8).prefix(Array(expectedPreviousPrefix.utf8).count)
                .elementsEqual(expectedPreviousPrefix.utf8),
            "the previous outside prefix must be byte-identical"
        )
        try expect(
            Array(patch.currentText.utf8).suffix(Array(expectedCurrentSuffix.utf8).count)
                .elementsEqual(expectedCurrentSuffix.utf8),
            "the current outside suffix must be byte-identical"
        )
    },
    CheckCase(name: "Whisper timed patch assigns a token at the cut midpoint to previous") {
        guard let patch = bridgePatch() else {
            throw CheckFailure(description: "a midpoint equal to the cut must be accepted")
        }

        try expect(patch.previousText.hasSuffix(" исправленный，"), "cut equality belongs left")
        try expect(patch.currentText.hasPrefix(" переход "), "later evidence belongs right")
    },
    CheckCase(name: "Whisper timed patch aligns raw token evidence to normalized whitespace") {
        let normalizedText =
            "  левый общий якорь\nисправленный，   переход правый устойчивый якорь\t "
        guard let patch = bridgePatch(bridgeText: normalizedText) else {
            throw CheckFailure(
                description: "text normalization must not discard complete timed token evidence"
            )
        }

        try expect(patch.previousText.hasSuffix("\nисправленный，"), "bridge spacing is retained")
        try expect(patch.currentText.hasPrefix("   переход "), "normalized spacing is retained")
    },
    CheckCase(name: "Whisper timed patch rejects punctuation fabricated by normalized text") {
        let fabricatedPunctuation = acceptedBridgeTokens().map(\.text).joined()
            .replacingOccurrences(of: "，", with: "。")

        try expectEqual(bridgePatch(bridgeText: fabricatedPunctuation), nil)
    },
    CheckCase(name: "Whisper timed patch maps decomposed subword evidence without trapping") {
        let decomposed: [TimedToken] = [
            ("левый", 0.0, 0.2),
            (" общий", 0.2, 0.4),
            (" якорь", 0.4, 0.6),
            (" cafe", 0.6, 0.8),
            ("\u{0301}，", 0.8, 1.0),
            (" переход", 1.2, 1.4),
            (" правый", 1.4, 1.6),
            (" устойчивый", 1.6, 1.8),
            (" якорь", 1.8, 2.0),
        ]

        guard let patch = bridgePatch(tokens: decomposed) else {
            throw CheckFailure(description: "valid decomposed token boundaries must be accepted")
        }
        try expect(
            patch.previousText.hasSuffix(" cafe\u{0301}，"),
            "the decomposed replacement must remain exact"
        )
    },
    CheckCase(name: "Whisper timed patch rejects NFC text for NFD token evidence") {
        let decomposedEvidence: [TimedToken] = [
            ("левый", 0.0, 0.2),
            (" общий", 0.2, 0.4),
            (" якорь", 0.4, 0.6),
            (" исправленный，", 0.6, 1.0),
            (" cafe", 1.1, 1.2),
            ("\u{0301}", 1.2, 1.3),
            (" правый", 1.3, 1.5),
            (" устойчивый", 1.5, 1.7),
            (" якорь", 1.7, 1.9),
        ]
        let precomposedText =
            "левый общий якорь исправленный， café правый устойчивый якорь"

        try expectEqual(
            bridgePatch(tokens: decomposedEvidence, bridgeText: precomposedText),
            nil
        )
    },
    CheckCase(name: "Whisper timed patch rejects a combining mark removed after whitespace") {
        let markedWhitespaceEvidence: [TimedToken] = [
            ("левый", 0.0, 0.2),
            (" общий", 0.2, 0.4),
            (" якорь", 0.4, 0.6),
            (" fixed, \u{0301}", 0.6, 0.9),
            ("transition", 1.1, 1.3),
            (" правый", 1.3, 1.5),
            (" устойчивый", 1.5, 1.7),
            (" якорь", 1.7, 1.9),
        ]
        let missingMarkText =
            "левый общий якорь fixed, transition правый устойчивый якорь"

        try expectEqual(
            bridgePatch(tokens: markedWhitespaceEvidence, bridgeText: missingMarkText),
            nil
        )
    },
    CheckCase(name: "Whisper timed patch rejects a combining mark changed after whitespace") {
        let acuteEvidence: [TimedToken] = [
            ("левый", 0.0, 0.2),
            (" общий", 0.2, 0.4),
            (" якорь", 0.4, 0.6),
            (" fixed, \u{0301}", 0.6, 0.9),
            ("transition", 1.1, 1.3),
            (" правый", 1.3, 1.5),
            (" устойчивый", 1.5, 1.7),
            (" якорь", 1.7, 1.9),
        ]
        let graveText =
            "левый общий якорь fixed, \u{0300}transition правый устойчивый якорь"

        try expectEqual(
            bridgePatch(tokens: acuteEvidence, bridgeText: graveText),
            nil
        )
    },
    CheckCase(name: "Whisper timed patch preserves an identical mark after whitespace") {
        let markedWhitespaceEvidence: [TimedToken] = [
            ("левый", 0.0, 0.2),
            (" общий", 0.2, 0.4),
            (" якорь", 0.4, 0.6),
            (" fixed, \u{0301}", 0.6, 0.9),
            ("transition", 1.1, 1.3),
            (" правый", 1.3, 1.5),
            (" устойчивый", 1.5, 1.7),
            (" якорь", 1.7, 1.9),
        ]

        guard let patch = bridgePatch(tokens: markedWhitespaceEvidence) else {
            throw CheckFailure(description: "identical mixed-grapheme evidence must map")
        }
        try expect(
            patch.previousText.hasSuffix(" fixed, \u{0301}"),
            "the complete marked grapheme must remain left"
        )
        try expect(patch.currentText.hasPrefix("transition "), "right text starts after the mark")
    },
    CheckCase(name: "Whisper timed patch maps an all-whitespace multi-scalar character") {
        let lineBreakEvidence: [TimedToken] = [
            ("левый", 0.0, 0.2),
            (" общий", 0.2, 0.4),
            (" якорь", 0.4, 0.6),
            (" исправленный，\r\n", 0.6, 0.9),
            ("переход", 1.1, 1.3),
            (" правый", 1.3, 1.5),
            (" устойчивый", 1.5, 1.7),
            (" якорь", 1.7, 1.9),
        ]

        guard let patch = bridgePatch(tokens: lineBreakEvidence) else {
            throw CheckFailure(description: "an all-whitespace scalar cluster must map")
        }
        try expect(
            patch.previousText.hasSuffix(" исправленный，\r\n"),
            "the complete multi-scalar whitespace character must remain left"
        )
        try expect(patch.currentText.hasPrefix("переход "), "right text starts after the line break")
    },
    CheckCase(name: "Whisper timed patch rejects missing left or right anchors") {
        try expectEqual(
            bridgePatch(previous: "KEEP совсем иной текст"),
            nil
        )
        try expectEqual(
            bridgePatch(current: "совсем иной текст KEEP"),
            nil
        )
    },
    CheckCase(name: "Whisper timed patch rejects incomplete token timestamps") {
        var missingStart = acceptedBridgeTokens()
        missingStart[3] = (missingStart[3].text, nil, missingStart[3].end)
        var missingEnd = acceptedBridgeTokens()
        missingEnd[4] = (missingEnd[4].text, missingEnd[4].start, nil)

        try expectEqual(bridgePatch(tokens: missingStart), nil)
        try expectEqual(bridgePatch(tokens: missingEnd), nil)
    },
    CheckCase(name: "Whisper timed patch rejects invalid and out-of-order timestamps") {
        var reversed = acceptedBridgeTokens()
        reversed[3] = (reversed[3].text, 1.2, 0.8)
        var overlapping = acceptedBridgeTokens()
        overlapping[4] = (overlapping[4].text, 1.1, 1.4)
        var nonfinite = acceptedBridgeTokens()
        nonfinite[4] = (nonfinite[4].text, .infinity, 1.4)
        var negative = acceptedBridgeTokens()
        negative[0] = (negative[0].text, -0.1, 0.2)

        try expectEqual(bridgePatch(tokens: reversed), nil)
        try expectEqual(bridgePatch(tokens: overlapping), nil)
        try expectEqual(bridgePatch(tokens: nonfinite), nil)
        try expectEqual(bridgePatch(tokens: negative), nil)
    },
    CheckCase(name: "Whisper timed patch accepts touching timestamp bounds") {
        var tokens = acceptedBridgeTokens()
        tokens[3] = (tokens[3].text, 0.6, 1.0)
        tokens[4] = (tokens[4].text, 1.0, 1.4)

        try expect(bridgePatch(tokens: tokens) != nil, "equal adjacent bounds are ordered")
    },
    CheckCase(name: "Whisper timed patch rejects a subword split across the cut") {
        let splitWord: [TimedToken] = [
            ("левый", 0.0, 0.2),
            (" общий", 0.2, 0.4),
            (" якорь", 0.4, 0.6),
            (" исправ", 0.6, 0.8),
            ("ленный，", 1.1, 1.3),
            (" переход", 1.3, 1.4),
            (" правый", 1.4, 1.6),
            (" устойчивый", 1.6, 1.8),
            (" якорь", 1.8, 2.0),
        ]

        try expectEqual(bridgePatch(tokens: splitWord), nil)
    },
    CheckCase(name: "Whisper timed patch keeps standalone punctuation on its timed side") {
        let punctuationOnLeft: [TimedToken] = [
            ("левый", 0.0, 0.2),
            (" общий", 0.2, 0.4),
            (" якорь", 0.4, 0.6),
            (" исправленный", 0.6, 0.8),
            (" ，", 0.8, 1.0),
            (" переход", 1.2, 1.4),
            (" правый", 1.4, 1.6),
            (" устойчивый", 1.6, 1.8),
            (" якорь", 1.8, 2.0),
        ]

        guard let patch = bridgePatch(tokens: punctuationOnLeft) else {
            throw CheckFailure(description: "a representable punctuation boundary must be accepted")
        }
        try expect(
            patch.previousText.hasSuffix(" исправленный ，"),
            "punctuation with a left midpoint must remain in the previous replacement"
        )
        try expect(patch.currentText.hasPrefix(" переход "), "right text begins after punctuation")
    },
    CheckCase(name: "Whisper timed patch keeps trailing token whitespace on the left") {
        let leftOwnedWhitespace: [TimedToken] = [
            ("левый", 0.0, 0.2),
            (" общий", 0.2, 0.4),
            (" якорь", 0.4, 0.6),
            (" исправленный， ", 0.6, 0.9),
            ("переход", 1.1, 1.3),
            (" правый", 1.3, 1.5),
            (" устойчивый", 1.5, 1.7),
            (" якорь", 1.7, 1.9),
        ]

        guard let patch = bridgePatch(tokens: leftOwnedWhitespace) else {
            throw CheckFailure(description: "an exact trailing-whitespace boundary must map")
        }
        try expect(
            patch.previousText.hasSuffix(" исправленный， "),
            "whitespace inside the left token must remain left"
        )
        try expect(patch.currentText.hasPrefix("переход "), "right text starts after the whitespace")
    },
    CheckCase(name: "Whisper timed patch keeps a left-timed whitespace token on the left") {
        let leftWhitespaceToken: [TimedToken] = [
            ("левый", 0.0, 0.2),
            (" общий", 0.2, 0.4),
            (" якорь", 0.4, 0.6),
            (" исправленный，", 0.6, 0.8),
            (" ", 0.8, 1.0),
            ("переход", 1.1, 1.3),
            (" правый", 1.3, 1.5),
            (" устойчивый", 1.5, 1.7),
            (" якорь", 1.7, 1.9),
        ]

        guard let patch = bridgePatch(tokens: leftWhitespaceToken) else {
            throw CheckFailure(description: "a whitespace-only timed boundary must map")
        }
        try expect(
            patch.previousText.hasSuffix(" исправленный， "),
            "a left-timed whitespace token must remain left"
        )
        try expect(patch.currentText.hasPrefix("переход "), "right text starts after the token")
    },
    CheckCase(name: "Whisper timed patch rejects cut times outside usable evidence") {
        try expectEqual(bridgePatch(cutTime: 0), nil)
        try expectEqual(bridgePatch(cutTime: 2), nil)
        try expectEqual(bridgePatch(cutTime: .nan), nil)
    },
    CheckCase(name: "Whisper timed patch rejects crossed bridge anchors") {
        let crossed: [TimedToken] = [
            ("правый", 0.0, 0.2),
            (" устойчивый", 0.2, 0.4),
            (" якорь", 0.4, 0.6),
            (" переход", 0.6, 1.2),
            (" левый", 1.2, 1.4),
            (" общий", 1.4, 1.6),
            (" якорь", 1.6, 1.8),
        ]

        try expectEqual(bridgePatch(tokens: crossed), nil)
    },
    CheckCase(name: "Whisper timed patch rejects ambiguous repeated anchor trigrams") {
        try expectEqual(
            bridgePatch(
                previous:
                    acceptedPreviousText + " левый общий якорь еще"
            ),
            nil
        )
        try expectEqual(
            bridgePatch(
                current:
                    acceptedCurrentText + " правый устойчивый якорь"
            ),
            nil
        )
        let duplicatedBridge =
            acceptedBridgeTokens()
            + acceptedBridgeTokens().map { token -> TimedToken in
                (
                    token.text,
                    token.start.map { $0 + 2 },
                    token.end.map { $0 + 2 }
                )
            }
        try expectEqual(bridgePatch(tokens: duplicatedBridge, cutTime: 2.1), nil)
    },
    CheckCase(name: "Whisper timed patch rejects empty left or right replacements") {
        let noLeft: [TimedToken] = [
            ("левый", 0.0, 0.2),
            (" общий", 0.2, 0.4),
            (" якорь", 0.4, 0.6),
            (" переход", 1.0, 1.2),
            (" правый", 1.2, 1.4),
            (" устойчивый", 1.4, 1.6),
            (" якорь", 1.6, 1.8),
        ]
        let noRight: [TimedToken] = [
            ("левый", 0.0, 0.2),
            (" общий", 0.2, 0.4),
            (" якорь", 0.4, 0.6),
            (" исправленный，", 0.6, 1.0),
            (" правый", 1.2, 1.4),
            (" устойчивый", 1.4, 1.6),
            (" якорь", 1.6, 1.8),
        ]

        try expectEqual(bridgePatch(tokens: noLeft), nil)
        try expectEqual(bridgePatch(tokens: noRight), nil)
    },
    CheckCase(name: "Whisper timed patch rejects Unicode punctuation loss") {
        let tokens = acceptedBridgeTokens().map { token -> TimedToken in
            (token.text.replacingOccurrences(of: "，", with: ""), token.start, token.end)
        }

        try expectEqual(bridgePatch(tokens: tokens), nil)
    },
    CheckCase(name: "Whisper timed patch rejects repeated trigrams in the patched boundary") {
        let repeated: [TimedToken] = [
            ("левый", 0.0, 0.2),
            (" общий", 0.2, 0.4),
            (" якорь", 0.4, 0.6),
            (" шум шум шум шум，", 0.6, 1.0),
            (" переход", 1.0, 1.4),
            (" правый", 1.4, 1.6),
            (" устойчивый", 1.6, 1.8),
            (" якорь", 1.8, 2.0),
        ]

        try expectEqual(bridgePatch(tokens: repeated), nil)
    },
]
