import Foundation
import VoicePanelCore

let transcriptCandidateEditFilterChecks: [CheckCase] = [
    CheckCase(name: "Safe edit filtering accepts punctuation and ordinary casing only") {
        let result = TranscriptCandidateEditFilter.apply(
            source: "потому что ну барьеры расставлены",
            candidate: "Потому что, ну, барьеры расставлены."
        )
        try expectEqual(result.text, "Потому что, ну, барьеры расставлены.")
        try expect(result.acceptedEditCount >= 3, "Expected case and punctuation edits to be accepted")
        try expectEqual(result.rejectedMeaningChangingEditCount, 0)
    },
    CheckCase(name: "Safe edit filtering rejects replacements of valid content words") {
        let result = TranscriptCandidateEditFilter.apply(
            source: "вот этот двойственный механизм",
            candidate: "Вот этот свойственный механизм."
        )
        try expectEqual(result.text, "Вот этот двойственный механизм.")
        try expectEqual(result.rejectedMeaningChangingEditCount, 1)
    },
    CheckCase(name: "Safe edit filtering rejects short semantic substitutions") {
        let result = TranscriptCandidateEditFilter.apply(
            source: "А вот получается как?",
            candidate: "А вот получается так?"
        )
        try expectEqual(result.text, "А вот получается как?")
        try expectEqual(result.rejectedMeaningChangingEditCount, 1)
    },
    CheckCase(name: "Safe edit filtering rejects content word deletion without discarding source") {
        let result = TranscriptCandidateEditFilter.apply(
            source: "система цель которой тебя защитить",
            candidate: "система которой тебя защитить"
        )
        try expectEqual(result.text, "система цель которой тебя защитить")
        try expectEqual(result.rejectedMeaningChangingEditCount, 1)
    },
    CheckCase(name: "Safe edit filtering accepts an explicitly validated spelling correction") {
        let pair = TranscriptSpellingReplacement(source: "сейча", replacement: "сейчас")
        let result = TranscriptCandidateEditFilter.apply(
            source: "сейчас сейча сейчас",
            candidate: "Сейчас сейчас сейчас.",
            configuration: .init(allowedSpellingReplacements: [pair])
        )
        try expectEqual(result.text, "Сейчас сейчас сейчас.")
        try expect(
            result.edits.contains { $0.kind == .spelling && $0.decision == .accepted },
            "Expected the validated spelling edit to be accepted"
        )
    },
    CheckCase(name: "Unvalidated close spelling replacement remains rejected") {
        let result = TranscriptCandidateEditFilter.apply(
            source: "вот этот двойственный механизм",
            candidate: "вот этот свойственный механизм"
        )
        try expectEqual(result.text, "вот этот двойственный механизм")
    },
    CheckCase(name: "Technical mixed-case tokens preserve their exact casing") {
        let result = TranscriptCandidateEditFilter.apply(
            source: "Запусти GigaAM модель",
            candidate: "Запусти Gigaam модель."
        )
        try expectEqual(result.text, "Запусти GigaAM модель")
    },
    CheckCase(name: "Russian typographic quotes are not downgraded to ASCII quotes") {
        let result = TranscriptCandidateEditFilter.apply(
            source: "Он сказал: «Сейчас будет плохо».",
            candidate: "Он сказал: \"Сейчас будет плохо\"."
        )
        try expectEqual(result.text, "Он сказал: «Сейчас будет плохо».")
    },
    CheckCase(name: "Protected URLs reject candidate punctuation corruption") {
        let result = TranscriptCandidateEditFilter.apply(
            source: "Открой https://example.com и проверь версию 1.8.0.",
            candidate: "Открой https: //example. com и проверь версию 1.9.0."
        )
        try expectEqual(result.text, "Открой https://example.com и проверь версию 1.8.0.")
        try expectEqual(result.rejectedMeaningChangingEditCount, 1)
    },
    CheckCase(name: "Question and exclamation modality cannot be introduced or removed") {
        let result = TranscriptCandidateEditFilter.apply(
            source: "Это работает.",
            candidate: "Это работает?"
        )
        try expectEqual(result.text, "Это работает.")
    },
    CheckCase(name: "Plausible spelling pairs include one-character truncation and transposition") {
        try expect(
            TranscriptCandidateEditFilter.isPlausibleSpellingPair(
                source: "сейча", replacement: "сейчас"
            ),
            "Expected one-character truncation to be plausible"
        )
        try expect(
            TranscriptCandidateEditFilter.isPlausibleSpellingPair(
                source: "фукнция", replacement: "функция"
            ),
            "Expected adjacent transposition to be plausible"
        )
        try expect(
            TranscriptCandidateEditFilter.isPlausibleSpellingPair(
                source: "двойственный", replacement: "свойственный"
            ),
            "Orthographic closeness alone must not imply acceptance"
        )
    },
]
