import Foundation
import VoicePanelCore

private func repairResult(
    _ text: String,
    tokenProbabilities: [Double] = [0.9],
    tokenTexts: [String]? = nil,
    noSpeechProbability: Double = 0
) -> WhisperTranscriptionResult {
    let texts =
        tokenTexts
        ?? tokenProbabilities.indices.map { index in
            index == 0 ? text : " evidence\(index)"
        }
    let tokens = zip(texts, tokenProbabilities).map { tokenText, probability in
        WhisperTokenEvidence(
            text: tokenText,
            startTime: nil,
            endTime: nil,
            probability: probability
        )
    }
    return WhisperTranscriptionResult(
        text: text,
        segments: [
            WhisperSegmentEvidence(
                text: text,
                startTime: 0,
                endTime: 2,
                noSpeechProbability: noSpeechProbability,
                tokens: tokens
            )
        ],
        detectedLanguage: "ru",
        inferenceDuration: 0
    )
}

private func rejectedReason(
    _ decision: WhisperBoundaryRepairDecision
) -> WhisperBoundaryRepairRejectionReason? {
    guard case .rejected(_, let reason) = decision else { return nil }
    return reason
}

let whisperBoundaryRepairPolicyChecks: [CheckCase] = [
    CheckCase(name: "Whisper natural-silence boundaries never request repair") {
        let reasons = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: .silence,
            previous: repairResult("раз два три"),
            current: repairResult(
                "раз два три",
                tokenProbabilities: [],
                noSpeechProbability: 0.99
            ),
            currentAudioDuration: 3
        )

        try expectEqual(reasons, [])
    },
    CheckCase(name: "Whisper forced repeated trigrams are suspicious") {
        let reasons = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: .maximumDuration,
            previous: repairResult("начало раз два три"),
            current: repairResult("раз два три продолжение"),
            currentAudioDuration: 2
        )

        try expect(
            reasons.contains(.repeatedTrigram),
            "a phrase repeated across a forced join must trigger repair assessment"
        )
    },
    CheckCase(name: "Whisper forced joins without a two-word anchor are suspicious") {
        let reasons = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: .maximumDuration,
            previous: repairResult("один два три четыре"),
            current: repairResult("пять шесть семь восемь"),
            currentAudioDuration: 2
        )

        try expect(
            reasons.contains(.missingOverlapAnchor),
            "a forced join without two aligned words must trigger repair assessment"
        )
    },
    CheckCase(name: "Whisper forced short results require more than one second of audio") {
        let shortAtThreshold = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: .maximumDuration,
            previous: repairResult("один два"),
            current: repairResult("один два"),
            currentAudioDuration: 1
        )
        let shortAboveThreshold = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: .maximumDuration,
            previous: repairResult("один два"),
            current: repairResult("один два"),
            currentAudioDuration: 1.001
        )

        try expect(
            !shortAtThreshold.contains(.shortCurrentText),
            "one second of audio is not above the short-result threshold"
        )
        try expect(
            shortAboveThreshold.contains(.shortCurrentText),
            "more than one second with fewer than three words must be suspicious"
        )
    },
    CheckCase(name: "Whisper confidence and no-speech suspicion thresholds are exclusive") {
        let atThresholds = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: .maximumDuration,
            previous: repairResult("один два три"),
            current: repairResult(
                "один два три дальше",
                tokenProbabilities: [0.45],
                noSpeechProbability: 0.60
            ),
            currentAudioDuration: 2
        )
        let outsideThresholds = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: .maximumDuration,
            previous: repairResult("один два три"),
            current: repairResult(
                "один два три дальше",
                tokenProbabilities: [0.449],
                noSpeechProbability: 0.601
            ),
            currentAudioDuration: 2
        )

        try expect(!atThresholds.contains(.lowTokenProbability), "0.45 must remain accepted")
        try expect(!atThresholds.contains(.highNoSpeechProbability), "0.60 must remain accepted")
        try expect(outsideThresholds.contains(.lowTokenProbability), "less than 0.45 is weak")
        try expect(outsideThresholds.contains(.highNoSpeechProbability), "more than 0.60 is high")
    },
    CheckCase(name: "Whisper boundary confidence excludes special and non-finite tokens") {
        let reasons = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: .maximumDuration,
            previous: repairResult("один два три"),
            current: repairResult(
                "один два три дальше",
                tokenProbabilities: [0, .nan, .infinity, 0.9, 0.8, 0.7],
                tokenTexts: [
                    "<|startoftranscript|>",
                    "<|0.00|>",
                    "<|endoftext|>",
                    " один",
                    " два",
                    " три",
                ],
                noSpeechProbability: .nan
            ),
            currentAudioDuration: 2
        )

        try expect(
            !reasons.contains(.lowTokenProbability),
            "Whisper special tokens and non-finite values must not dilute lexical confidence"
        )
        try expect(
            !reasons.contains(.highNoSpeechProbability),
            "non-finite no-speech evidence must not trigger a repair"
        )
    },
    CheckCase(name: "Whisper missing lexical confidence is deterministically weak") {
        let reasons = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: .maximumDuration,
            previous: repairResult("один два три"),
            current: repairResult("один два три дальше", tokenProbabilities: []),
            currentAudioDuration: 2
        )

        try expect(
            reasons.contains(.lowTokenProbability),
            "missing lexical probability evidence must use the documented zero score"
        )
    },
    CheckCase(name: "Whisper contextual patches reject multilingual punctuation loss") {
        let baselineText = "получается дальше、 со знаками общий якорь здесь。 хвост"
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("ввод получается дальше"),
            baseline: repairResult(baselineText, tokenProbabilities: [0.8]),
            candidate: repairResult(
                "получается дальше без знаков общий якорь здесь。 хвост",
                tokenProbabilities: [0.9]
            )
        )

        try expectEqual(rejectedReason(decision), .punctuationLoss)
        try expectEqual(decision.text, baselineText)
    },
    CheckCase(name: "Whisper contextual patches replace only text before a stable anchor") {
        let baselineText = "ошибка общий якорь здесь. неизменный хвост 你好。"
        let candidateText = "один два исправление общий якорь здесь иначе"
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("слева один два"),
            baseline: repairResult(baselineText, tokenProbabilities: [0.8]),
            candidate: repairResult(candidateText, tokenProbabilities: [0.8])
        )

        guard case .accepted(let patch) = decision else {
            throw CheckFailure(description: "a better aligned candidate must be accepted")
        }
        try expectEqual(
            patch.text,
            "один два исправление общий якорь здесь. неизменный хвост 你好。"
        )
        try expectEqual(patch.baselinePrefixWordCount, 1)
        try expectEqual(patch.candidatePrefixWordCount, 3)
    },
    CheckCase(name: "Whisper accepted patches preserve the baseline suffix byte for byte") {
        let baselineSuffix = "общий якорь здесь…  ¿Qué?  你好。"
        let baselineText = "ошибка " + baselineSuffix
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("слева один два"),
            baseline: repairResult(baselineText, tokenProbabilities: [0.8]),
            candidate: repairResult(
                "один два исправление общий якорь здесь другой хвост",
                tokenProbabilities: [0.8]
            )
        )

        guard case .accepted(let patch) = decision else {
            throw CheckFailure(description: "a better aligned candidate must be accepted")
        }
        let resultBytes = Array(patch.text.utf8)
        let suffixBytes = Array(baselineSuffix.utf8)
        try expect(
            resultBytes.suffix(suffixBytes.count).elementsEqual(suffixBytes),
            "the accepted result must reuse the original baseline suffix bytes"
        )
    },
    CheckCase(name: "Whisper contextual patches retain baseline without a stable anchor") {
        let baselineText = "исходный текст остается полностью"
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("слева один два"),
            baseline: repairResult(baselineText),
            candidate: repairResult("один два совершенно иная версия")
        )

        try expectEqual(rejectedReason(decision), .missingStableAnchor)
        try expectEqual(decision.text, baselineText)
    },
    CheckCase(name: "Whisper contextual patches reject candidate trigram repetition") {
        let baselineText = "ошибка общий якорь здесь. хвост"
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("слева один два"),
            baseline: repairResult(baselineText, tokenProbabilities: [0.8]),
            candidate: repairResult(
                "один два шум шум шум шум общий якорь здесь. хвост",
                tokenProbabilities: [0.9]
            )
        )

        try expectEqual(rejectedReason(decision), .repeatedTrigram)
        try expectEqual(decision.text, baselineText)
    },
    CheckCase(name: "Whisper contextual patches require explicit score improvement") {
        let baselineText = "старая версия общий якорь здесь. хвост"
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("несвязанный левый контекст"),
            baseline: repairResult(baselineText, tokenProbabilities: [0.5]),
            candidate: repairResult(
                "новая версия общий якорь здесь. хвост",
                tokenProbabilities: [0.99]
            )
        )

        try expectEqual(rejectedReason(decision), .insufficientImprovement)
        try expectEqual(decision.text, baselineText)
    },
    CheckCase(name: "Whisper contextual confidence ignores special-token probabilities") {
        let baselineText = "ошибка общий якорь здесь. хвост"
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("слева один два"),
            baseline: repairResult(
                baselineText,
                tokenProbabilities: [0.8, 0.8],
                tokenTexts: [" ошибка", " общий"]
            ),
            candidate: repairResult(
                "один два исправление общий якорь здесь. хвост",
                tokenProbabilities: [0, 0, 0.8, 0.8],
                tokenTexts: [
                    "<|startoftranscript|>",
                    "<|endoftext|>",
                    " один",
                    " два",
                ]
            )
        )

        guard case .accepted = decision else {
            throw CheckFailure(
                description: "special-token probabilities must not cause a false confidence rejection"
            )
        }
    },
    CheckCase(name: "Whisper contextual patches reject repetition created by the final splice") {
        let baselineText = "ошибка общий якорь здесь потом один два новый"
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("слева один два"),
            baseline: repairResult(baselineText),
            candidate: repairResult("один два новый общий якорь здесь конец")
        )

        try expectEqual(rejectedReason(decision), .repeatedTrigram)
        try expectEqual(decision.text, baselineText)
    },
    CheckCase(name: "Whisper stable anchors must be unique in the baseline window") {
        let baselineText =
            "ошибка альфа бета гамма база один альфа бета гамма база два"
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("слева один два"),
            baseline: repairResult(baselineText),
            candidate: repairResult("один два новый альфа бета гамма кандидат")
        )

        try expectEqual(rejectedReason(decision), .missingStableAnchor)
        try expectEqual(decision.text, baselineText)
    },
    CheckCase(name: "Whisper stable anchors must be unique in the candidate window") {
        let baselineText = "ошибка альфа бета гамма база"
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("слева один два"),
            baseline: repairResult(baselineText),
            candidate: repairResult(
                "один два альфа бета гамма кандидат альфа бета гамма конец"
            )
        )

        try expectEqual(rejectedReason(decision), .missingStableAnchor)
        try expectEqual(decision.text, baselineText)
    },
    CheckCase(name: "Whisper stable anchor selection uses the earliest unique match") {
        let baselineText =
            "ошибка альфа бета гамма база один альфа бета гамма база два "
            + "ранний общий якорь хвост поздний общий маркер конец"
        let candidatePrefix =
            "один два новый альфа бета гамма кандидат один "
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("слева один два"),
            baseline: repairResult(baselineText),
            candidate: repairResult(
                candidatePrefix
                    + "ранний общий якорь кандидат два поздний общий маркер"
            )
        )

        guard case .accepted(let patch) = decision else {
            throw CheckFailure(description: "the first unique stable anchor must be accepted")
        }
        try expectEqual(
            patch.text,
            candidatePrefix
                + "ранний общий якорь хвост поздний общий маркер конец"
        )
    },
    CheckCase(name: "Whisper join scores use overlap and repetition coefficients exactly") {
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("слева один два"),
            baseline: repairResult(
                "шум шум шум шум ошибка общий якорь здесь. хвост",
                tokenProbabilities: [0.8]
            ),
            candidate: repairResult(
                "один два новый общий якорь здесь. хвост",
                tokenProbabilities: [0.8]
            )
        )

        guard case .accepted(let patch) = decision else {
            throw CheckFailure(description: "the better scored boundary must be accepted")
        }
        try expectApproximatelyEqual(patch.baselineScore, -2.2, accuracy: 0.000_001)
        try expectApproximatelyEqual(patch.candidateScore, 4.8, accuracy: 0.000_001)
    },
    CheckCase(name: "Whisper contextual score accepts an exact 0.5 improvement") {
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("несвязанный левый контекст"),
            baseline: repairResult(
                "старая версия общий якорь здесь. хвост",
                tokenProbabilities: [0.4]
            ),
            candidate: repairResult(
                "новая версия общий якорь здесь. хвост",
                tokenProbabilities: [0.9]
            )
        )

        guard case .accepted(let patch) = decision else {
            throw CheckFailure(description: "an exact 0.5 score gain must be accepted")
        }
        try expectApproximatelyEqual(
            patch.candidateScore - patch.baselineScore,
            0.5,
            accuracy: 0.000_001
        )
    },
    CheckCase(name: "Whisper contextual score rejects an improvement below 0.5") {
        let baselineText = "старая версия общий якорь здесь. хвост"
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("несвязанный левый контекст"),
            baseline: repairResult(baselineText, tokenProbabilities: [0.4]),
            candidate: repairResult(
                "новая версия общий якорь здесь. хвост",
                tokenProbabilities: [0.899]
            )
        )

        try expectEqual(rejectedReason(decision), .insufficientImprovement)
        try expectEqual(decision.text, baselineText)
    },
    CheckCase(name: "Whisper contextual confidence accepts an exact 0.05 decrease") {
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("слева один два"),
            baseline: repairResult(
                "ошибка общий якорь здесь. хвост",
                tokenProbabilities: [0.9]
            ),
            candidate: repairResult(
                "один два новый общий якорь здесь. хвост",
                tokenProbabilities: [0.85]
            )
        )

        guard case .accepted = decision else {
            throw CheckFailure(description: "an exact 0.05 confidence decrease must be allowed")
        }
    },
    CheckCase(name: "Whisper lower-confidence rejection retains the exact baseline") {
        let baselineText = "ошибка общий якорь здесь. хвост"
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("слева один два"),
            baseline: repairResult(baselineText, tokenProbabilities: [0.9]),
            candidate: repairResult(
                "один два новый общий якорь здесь. хвост",
                tokenProbabilities: [0.849]
            )
        )

        try expectEqual(rejectedReason(decision), .lowerTokenProbability)
        try expectEqual(decision.text, baselineText)
    },
    CheckCase(name: "Whisper lexical confidence handles multilingual and malformed tokens") {
        let lexicalTokens = [" 你", " слово", " и\u{306}"]
        let configuration = WhisperBoundaryRepairConfiguration(
            minimumTokenProbability: 0.79
        )
        for lexicalToken in lexicalTokens {
            let reasons = WhisperBoundaryRepairPolicy.assess(
                previousBoundaryReason: .maximumDuration,
                previous: repairResult("один два три"),
                current: repairResult(
                    "один два три дальше",
                    tokenProbabilities: [0.8, 0, 0, -1, 2],
                    tokenTexts: [
                        lexicalToken,
                        " \u{301}",
                        " 、",
                        " вне",
                        " диапазона",
                    ]
                ),
                currentAudioDuration: 2,
                configuration: configuration
            )

            try expect(
                !reasons.contains(.lowTokenProbability),
                "\(lexicalToken) must count while combining, punctuation, and out-of-domain evidence does not"
            )
        }
    },
    CheckCase(name: "Whisper contextual anchors remain inside twenty-four boundary words") {
        let baselinePrefix = (1...24).map { "база\($0)" }.joined(separator: " ")
        let candidatePrefix = (1...24).map { "кандидат\($0)" }.joined(separator: " ")
        let baselineText = baselinePrefix + " общий якорь здесь хвост"
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("слева кандидат1 кандидат2"),
            baseline: repairResult(baselineText),
            candidate: repairResult(candidatePrefix + " общий якорь здесь конец")
        )

        try expectEqual(rejectedReason(decision), .missingStableAnchor)
        try expectEqual(decision.text, baselineText)
    },
    CheckCase(name: "Whisper repair configuration normalizes invalid public values") {
        let clamped = WhisperBoundaryRepairConfiguration(
            boundaryWordLimit: .max,
            minimumAnchorWords: 1,
            repeatedNGramLength: 99,
            minimumTokenProbability: -1,
            maximumNoSpeechProbability: 2,
            maximumPunctuationLoss: .max
        )
        let nonFinite = WhisperBoundaryRepairConfiguration(
            minimumTokenProbability: .nan,
            maximumNoSpeechProbability: .infinity
        )

        try expectEqual(clamped.boundaryWordLimit, 24)
        try expectEqual(clamped.minimumAnchorWords, 3)
        try expectEqual(clamped.repeatedNGramLength, 3)
        try expectEqual(clamped.minimumTokenProbability, 0)
        try expectEqual(clamped.maximumNoSpeechProbability, 1)
        try expectEqual(clamped.maximumPunctuationLoss, 24)
        try expectEqual(nonFinite.minimumTokenProbability, 0.45)
        try expectEqual(nonFinite.maximumNoSpeechProbability, 0.60)
    },
    CheckCase(name: "Whisper repair use normalizes mutated non-finite thresholds") {
        var configuration = WhisperBoundaryRepairConfiguration()
        configuration.minimumTokenProbability = .nan
        configuration.maximumNoSpeechProbability = .nan
        let reasons = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: .maximumDuration,
            previous: repairResult("один два три"),
            current: repairResult(
                "один два три дальше",
                tokenProbabilities: [0.44],
                noSpeechProbability: 0.61
            ),
            currentAudioDuration: 2,
            configuration: configuration
        )

        try expect(reasons.contains(.lowTokenProbability), "NaN must restore the 0.45 default")
        try expect(reasons.contains(.highNoSpeechProbability), "NaN must restore the 0.60 default")
    },
    CheckCase(name: "Whisper repair use preserves the three-word stable anchor minimum") {
        var configuration = WhisperBoundaryRepairConfiguration()
        configuration.minimumAnchorWords = 1
        let baselineText = "ошибка единственный хвост база"
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("слева один два"),
            baseline: repairResult(baselineText),
            candidate: repairResult("один два новый единственный конец"),
            configuration: configuration
        )

        try expectEqual(rejectedReason(decision), .missingStableAnchor)
        try expectEqual(decision.text, baselineText)
    },
    CheckCase(name: "Whisper repair use preserves trigram repetition semantics") {
        var configuration = WhisperBoundaryRepairConfiguration()
        configuration.repeatedNGramLength = 1
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("слева один два"),
            baseline: repairResult("ошибка общий якорь здесь. хвост"),
            candidate: repairResult(
                "один два шум шум новый общий якорь здесь. хвост"
            ),
            configuration: configuration
        )

        guard case .accepted = decision else {
            throw CheckFailure(description: "a repeated word is not a repeated trigram")
        }
    },
    CheckCase(name: "Whisper repair use keeps mutated windows hard bounded") {
        var configuration = WhisperBoundaryRepairConfiguration()
        configuration.boundaryWordLimit = .max
        let baselinePrefix = (1...24).map { "база\($0)" }.joined(separator: " ")
        let candidatePrefix = (1...24).map { "кандидат\($0)" }.joined(separator: " ")
        let baselineText = baselinePrefix + " общий якорь здесь хвост"
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("слева кандидат1 кандидат2"),
            baseline: repairResult(baselineText),
            candidate: repairResult(candidatePrefix + " общий якорь здесь конец"),
            configuration: configuration
        )

        try expectEqual(rejectedReason(decision), .missingStableAnchor)
        try expectEqual(decision.text, baselineText)
    },
    CheckCase(name: "Whisper weak confidence treats a rounded exact threshold as equal") {
        let reasons = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: .maximumDuration,
            previous: repairResult("один два три"),
            current: repairResult(
                "один два три дальше",
                tokenProbabilities: [0.2, 0.7]
            ),
            currentAudioDuration: 2
        )

        try expect(
            !reasons.contains(.lowTokenProbability),
            "the mathematical mean (0.2 + 0.7) / 2 is exactly 0.45"
        )
    },
    CheckCase(name: "Whisper weak confidence stays strict outside comparison tolerance") {
        let below = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: .maximumDuration,
            previous: repairResult("один два три"),
            current: repairResult(
                "один два три дальше",
                tokenProbabilities: [0.2, 0.7 - 8e-15]
            ),
            currentAudioDuration: 2
        )
        let above = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: .maximumDuration,
            previous: repairResult("один два три"),
            current: repairResult(
                "один два три дальше",
                tokenProbabilities: [0.2, 0.7 + 8e-15]
            ),
            currentAudioDuration: 2
        )

        try expect(below.contains(.lowTokenProbability), "a mean below tolerance must be weak")
        try expect(!above.contains(.lowTokenProbability), "a mean above threshold is not weak")
    },
    CheckCase(name: "Whisper no-speech treats a rounded exact threshold as equal") {
        let reasons = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: .maximumDuration,
            previous: repairResult("один два три"),
            current: repairResult(
                "один два три дальше",
                noSpeechProbability: 0.2 + 0.4
            ),
            currentAudioDuration: 2
        )

        try expect(
            !reasons.contains(.highNoSpeechProbability),
            "the mathematical no-speech value 0.2 + 0.4 is exactly 0.60"
        )
    },
    CheckCase(name: "Whisper no-speech stays strict outside comparison tolerance") {
        let below = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: .maximumDuration,
            previous: repairResult("один два три"),
            current: repairResult(
                "один два три дальше",
                noSpeechProbability: 0.60 - 4e-15
            ),
            currentAudioDuration: 2
        )
        let above = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: .maximumDuration,
            previous: repairResult("один два три"),
            current: repairResult(
                "один два три дальше",
                noSpeechProbability: 0.60 + 4e-15
            ),
            currentAudioDuration: 2
        )

        try expect(!below.contains(.highNoSpeechProbability), "a lower value is not high")
        try expect(above.contains(.highNoSpeechProbability), "a value above tolerance is high")
    },
    CheckCase(name: "Whisper score accepts a rounded mathematical 0.5 gain") {
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("несвязанный левый контекст"),
            baseline: repairResult(
                "старая версия общий якорь здесь хвост",
                tokenProbabilities: [0.2]
            ),
            candidate: repairResult(
                "новая версия общий якорь здесь хвост",
                tokenProbabilities: [0.7]
            )
        )

        guard case .accepted = decision else {
            throw CheckFailure(description: "the mathematical score gain 0.7 - 0.2 is 0.5")
        }
    },
    CheckCase(name: "Whisper score gain stays strict outside comparison tolerance") {
        let baselineText = "старая версия общий якорь здесь хвост"
        let below = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("несвязанный левый контекст"),
            baseline: repairResult(baselineText, tokenProbabilities: [0.2]),
            candidate: repairResult(
                "новая версия общий якорь здесь хвост",
                tokenProbabilities: [0.7 - 4e-15]
            )
        )
        let above = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("несвязанный левый контекст"),
            baseline: repairResult(baselineText, tokenProbabilities: [0.2]),
            candidate: repairResult(
                "новая версия общий якорь здесь хвост",
                tokenProbabilities: [0.7 + 4e-15]
            )
        )

        try expectEqual(rejectedReason(below), .insufficientImprovement)
        try expectEqual(below.text, baselineText)
        guard case .accepted = above else {
            throw CheckFailure(description: "a score gain above 0.5 must be accepted")
        }
    },
    CheckCase(name: "Whisper confidence accepts a rounded mathematical 0.05 decrease") {
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("слева один два"),
            baseline: repairResult(
                "ошибка общий якорь здесь хвост",
                tokenProbabilities: [0.17]
            ),
            candidate: repairResult(
                "один два новый общий якорь здесь хвост",
                tokenProbabilities: [0.12]
            )
        )

        guard case .accepted = decision else {
            throw CheckFailure(description: "the mathematical confidence drop 0.17 - 0.12 is 0.05")
        }
    },
    CheckCase(name: "Whisper confidence drop stays strict outside comparison tolerance") {
        let baselineText = "ошибка общий якорь здесь хвост"
        let allowed = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("слева один два"),
            baseline: repairResult(baselineText, tokenProbabilities: [0.17]),
            candidate: repairResult(
                "один два новый общий якорь здесь хвост",
                tokenProbabilities: [0.12 + 4e-15]
            )
        )
        let rejected = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult("слева один два"),
            baseline: repairResult(baselineText, tokenProbabilities: [0.17]),
            candidate: repairResult(
                "один два новый общий якорь здесь хвост",
                tokenProbabilities: [0.12 - 4e-15]
            )
        )

        guard case .accepted = allowed else {
            throw CheckFailure(description: "a confidence drop below 0.05 must be allowed")
        }
        try expectEqual(rejectedReason(rejected), .lowerTokenProbability)
        try expectEqual(rejected.text, baselineText)
    },
    CheckCase(name: "Whisper short-audio duration stays strict outside comparison tolerance") {
        let belowTolerance = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: .maximumDuration,
            previous: repairResult("один два"),
            current: repairResult("один два"),
            currentAudioDuration: 1 - 4e-15
        )
        let withinTolerance = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: .maximumDuration,
            previous: repairResult("один два"),
            current: repairResult("один два"),
            currentAudioDuration: 1 + 5e-16
        )
        let aboveTolerance = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: .maximumDuration,
            previous: repairResult("один два"),
            current: repairResult("один два"),
            currentAudioDuration: 1 + 4e-15
        )

        try expect(
            !belowTolerance.contains(.shortCurrentText),
            "duration genuinely below one second must not be suspicious"
        )
        try expect(
            !withinTolerance.contains(.shortCurrentText),
            "duration rounding at one second must remain at the threshold"
        )
        try expect(
            aboveTolerance.contains(.shortCurrentText),
            "duration genuinely above tolerance must remain suspicious"
        )
    },
    CheckCase(name: "Whisper score delta avoids cancellation at twelve-word overlap") {
        let overlap = (1...12).map { "слово\($0)" }.joined(separator: " ")
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult(overlap),
            baseline: repairResult(overlap + " исходный хвост", tokenProbabilities: [0.077]),
            candidate: repairResult(overlap + " другой хвост", tokenProbabilities: [0.577])
        )

        guard case .accepted(let patch) = decision else {
            throw CheckFailure(
                description: "a mathematical 0.5 confidence gain must survive a score base of 24"
            )
        }
        try expectApproximatelyEqual(patch.baselineScore, 24.077, accuracy: 0.000_000_000_001)
        try expectApproximatelyEqual(patch.candidateScore, 24.577, accuracy: 0.000_000_000_001)
    },
    CheckCase(name: "Whisper score delta rejects a high-base gain outside tolerance") {
        let overlap = (1...12).map { "слово\($0)" }.joined(separator: " ")
        let baselineText = overlap + " исходный хвост"
        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: repairResult(overlap),
            baseline: repairResult(baselineText, tokenProbabilities: [0.002]),
            candidate: repairResult(
                overlap + " другой хвост",
                tokenProbabilities: [0.502 - 2e-15]
            )
        )

        try expectEqual(rejectedReason(decision), .insufficientImprovement)
        try expectEqual(decision.text, baselineText)
    },
]
