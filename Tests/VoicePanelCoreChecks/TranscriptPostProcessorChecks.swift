import Foundation
import VoicePanelCore

let transcriptPostProcessorChecks: [CheckCase] = [
    CheckCase(name: "Final cleanup replaces an overlapped boundary with the continuing punctuation") {
        let result = TranscriptPostProcessor.process(
            segments: [
                .init(
                    text: "Это было хорошо.",
                    boundaryReason: .maximumDuration,
                    trailingOverlapDuration: 0.3
                ),
                .init(text: "Хорошо, но можно лучше.", boundaryReason: .stopped),
            ],
            configuration: .init(isEnabled: true, languageCode: "ru-RU")
        )
        try expectEqual(result.text, "Это было хорошо, но можно лучше.")
        try expectEqual(result.stitchedBoundaryCount, 1)
    },
    CheckCase(name: "Final cleanup removes a multiword overlap with one small recognition typo") {
        let result = TranscriptPostProcessor.process(
            segments: [
                .init(
                    text: "Надо сейчас проверить эту функцию",
                    boundaryReason: .maximumDuration,
                    trailingOverlapDuration: 0.4
                ),
                .init(
                    text: "проверить эту фукнцию и запустить тесты",
                    boundaryReason: .stopped
                ),
            ],
            configuration: .init(isEnabled: true, languageCode: "ru-RU")
        )
        try expectEqual(result.text, "Надо сейчас проверить эту функцию и запустить тесты")
    },
    CheckCase(name: "Final cleanup keeps an intentionally repeated one-word segment") {
        let result = TranscriptPostProcessor.process(
            segments: ["Да.", "Да."],
            configuration: .init(isEnabled: true, languageCode: "ru-RU")
        )
        try expectEqual(result.text, "Да. Да.")
        try expectEqual(result.removedSegmentCount, 0)
    },
    CheckCase(name: "Final cleanup preserves an intentional ellipsis") {
        let result = TranscriptPostProcessor.process(
            segments: ["Я думаю...", "Надо проверить ещё раз."],
            configuration: .init(isEnabled: true, languageCode: "ru-RU")
        )
        try expectEqual(result.text, "Я думаю... Надо проверить ещё раз.")
    },
    CheckCase(name: "Final cleanup keeps intentional repeated lowercase words") {
        let result = TranscriptPostProcessor.process(
            segments: ["Это очень", "очень важно"],
            configuration: .init(isEnabled: true, languageCode: "ru-RU")
        )
        try expectEqual(result.text, "Это очень очень важно")
        try expectEqual(result.stitchedBoundaryCount, 0)
    },
    CheckCase(name: "Forced cleanup removes an exact one-word audio overlap") {
        let result = TranscriptPostProcessor.process(
            segments: [
                .init(
                    text: "Нам стоит обратно",
                    boundaryReason: .maximumDuration,
                    trailingOverlapDuration: 0.3
                ),
                .init(text: "обратно вернуть результат", boundaryReason: .stopped),
            ],
            configuration: .init(isEnabled: true, languageCode: "ru-RU")
        )
        try expectEqual(result.text, "Нам стоит обратно вернуть результат")
        try expectEqual(result.stitchedBoundaryCount, 1)
    },
    CheckCase(name: "Final cleanup marks a dangling terminal comma as incomplete speech") {
        let result = TranscriptPostProcessor.process(
            segments: ["Мы ещё не закончили,"],
            configuration: .init(isEnabled: true, languageCode: "ru-RU")
        )
        try expect(result.text.hasSuffix("…"), "dangling terminal comma was retained")
        try expect(!result.text.hasSuffix(","), "transcript still ends with a comma")
    },
    CheckCase(name: "Final cleanup removes a one-word overlap only with boundary evidence") {
        let result = TranscriptPostProcessor.process(
            segments: [
                .init(
                    text: "Это действительно важно.",
                    boundaryReason: .maximumDuration,
                    trailingOverlapDuration: 0.3
                ),
                .init(
                    text: "Важно, потому что данные сохраняются.",
                    boundaryReason: .stopped
                ),
            ],
            configuration: .init(isEnabled: true, languageCode: "ru-RU")
        )
        try expectEqual(result.text, "Это действительно важно, потому что данные сохраняются.")
    },
    CheckCase(name: "Mixed Russian cleanup preserves a legitimate English phrase by default") {
        let result = TranscriptPostProcessor.process(
            segments: ["Это основной текст.", "Thank you.", "Продолжаем работу."],
            configuration: .init(isEnabled: true, languageCode: "ru-RU")
        )
        try expectEqual(result.text, "Это основной текст. Thank you. Продолжаем работу.")
        try expectEqual(result.removedSegmentCount, 0)
    },
    CheckCase(name: "Language-mismatch hallucination filtering remains an explicit opt-in") {
        let result = TranscriptPostProcessor.process(
            segments: ["Это основной текст.", "Thank you.", "Продолжаем работу."],
            configuration: .init(
                isEnabled: true,
                languageCode: "ru-RU",
                removesLanguageMismatchedHallucinations: true
            )
        )
        try expectEqual(result.text, "Это основной текст. Продолжаем работу.")
        try expectEqual(result.removedSegmentCount, 1)
    },
    CheckCase(name: "English cleanup preserves a legitimate English phrase") {
        let result = TranscriptPostProcessor.process(
            segments: ["Thank you."],
            configuration: .init(isEnabled: true, languageCode: "en-US")
        )
        try expectEqual(result.text, "Thank you.")
    },
    CheckCase(name: "Disabled final cleanup preserves the existing merger behavior") {
        let result = TranscriptPostProcessor.process(
            segments: ["Это было хорошо.", "Хорошо, но можно лучше."],
            configuration: .init(isEnabled: false, languageCode: "ru-RU")
        )
        try expectEqual(result.text, "Это было хорошо. Хорошо, но можно лучше.")
        try expectEqual(result.stitchedBoundaryCount, 0)
    },
    CheckCase(name: "Forced continuation lowercases a false chunk sentence start") {
        let result = TranscriptPostProcessor.process(
            segments: [
                .init(text: "Мы продолжаем эту мысль", boundaryReason: .maximumDuration),
                .init(text: "Потому что она ещё не закончилась", boundaryReason: .stopped),
            ],
            configuration: .init(isEnabled: true, languageCode: "ru-RU")
        )
        try expectEqual(
            result.text,
            "Мы продолжаем эту мысль потому что она ещё не закончилась"
        )
        try expectEqual(result.stitchedBoundaryCount, 1)
    },
    CheckCase(name: "Forced continuation lowercases after boundary punctuation") {
        for continuation in ["— Потому что мысль продолжается", "«Потому что мысль продолжается"] {
            let result = TranscriptPostProcessor.process(
                segments: [
                    .init(text: "Мы ещё не закончили", boundaryReason: .maximumDuration),
                    .init(text: continuation, boundaryReason: .stopped),
                ],
                configuration: .init(isEnabled: true, languageCode: "ru-RU")
            )
            try expect(
                !result.text.contains("Потому"),
                "forced continuation kept a false uppercase start after punctuation"
            )
        }
    },
    CheckCase(name: "Natural pause repairs ordinary boundary capitalization") {
        let continued = TranscriptPostProcessor.process(
            segments: [
                .init(text: "Ожидания были такие что", boundaryReason: .silence),
                .init(text: "Мы не должны размазывать ответственность", boundaryReason: .stopped),
            ],
            configuration: .init(isEnabled: true, languageCode: "ru-RU")
        )
        try expectEqual(
            continued.text,
            "Ожидания были такие что мы не должны размазывать ответственность"
        )
        try expectEqual(continued.stitchedBoundaryCount, 1)

        let newSentence = TranscriptPostProcessor.process(
            segments: [
                .init(text: "Мы закончили первую мысль.", boundaryReason: .silence),
                .init(text: "теперь начинается следующая", boundaryReason: .stopped),
            ],
            configuration: .init(isEnabled: true, languageCode: "ru-RU")
        )
        try expectEqual(
            newSentence.text,
            "Мы закончили первую мысль. Теперь начинается следующая"
        )
        try expectEqual(newSentence.stitchedBoundaryCount, 1)
    },
    CheckCase(name: "Natural pause preserves protected boundary casing") {
        for continuation in [
            "API возвращает ответ",
            "VoicePanel продолжает распознавание",
            "https://example.com готов",
        ] {
            let result = TranscriptPostProcessor.process(
                segments: [
                    .init(text: "Мы используем сервис", boundaryReason: .silence),
                    .init(text: continuation, boundaryReason: .stopped),
                ],
                configuration: .init(isEnabled: true, languageCode: "ru-RU")
            )
            try expect(result.text.contains(continuation), "protected casing was changed")
        }
    },
    CheckCase(name: "Forced continuation preserves acronyms and internal casing") {
        for continuation in ["VoicePanel продолжает распознавание", "API возвращает ответ"] {
            let result = TranscriptPostProcessor.process(
                segments: [
                    .init(text: "Мы используем модель", boundaryReason: .maximumDuration),
                    .init(text: continuation, boundaryReason: .stopped),
                ],
                configuration: .init(isEnabled: true, languageCode: "ru-RU")
            )
            try expect(result.text.contains(continuation), "technical casing was changed")
        }
    },
    CheckCase(name: "Removed duplicate keeps the following forced boundary metadata") {
        let result = TranscriptPostProcessor.process(
            segments: [
                .init(
                    text: "Повторяем этот фрагмент",
                    boundaryReason: .maximumDuration,
                    trailingOverlapDuration: 0.3
                ),
                .init(text: "Повторяем этот фрагмент", boundaryReason: .maximumDuration),
                .init(text: "Чтобы продолжить мысль", boundaryReason: .stopped),
            ],
            configuration: .init(isEnabled: true, languageCode: "ru-RU")
        )
        try expectEqual(result.text, "Повторяем этот фрагмент чтобы продолжить мысль")
    },
    CheckCase(name: "Pause-balanced cleanup never removes repeated boundary words") {
        let result = TranscriptPostProcessor.process(
            segments: [
                .init(text: "Это очень важно", boundaryReason: .balancedPause),
                .init(text: "важно проверить ещё раз", boundaryReason: .stopped),
            ],
            configuration: .init(isEnabled: true, languageCode: "ru-RU")
        )
        try expectEqual(result.text, "Это очень важно важно проверить ещё раз")
        try expectEqual(result.stitchedBoundaryCount, 0)
    },
    CheckCase(name: "A zero-overlap hard cut never removes a repeated word") {
        let result = TranscriptPostProcessor.process(
            segments: [
                .init(text: "Нужно снова", boundaryReason: .maximumDuration),
                .init(text: "снова попробовать", boundaryReason: .stopped),
            ],
            configuration: .init(isEnabled: true, languageCode: "ru-RU")
        )
        try expectEqual(result.text, "Нужно снова снова попробовать")
    },
    CheckCase(name: "Pause-balanced cleanup changes only ordinary boundary case") {
        let lowercased = TranscriptPostProcessor.process(
            segments: [
                .init(text: "Мы продолжаем мысль", boundaryReason: .balancedPause),
                .init(text: "Потому что она важна", boundaryReason: .stopped),
            ],
            configuration: .init(isEnabled: true, languageCode: "ru-RU")
        )
        try expectEqual(lowercased.text, "Мы продолжаем мысль потому что она важна")

        let uppercased = TranscriptPostProcessor.process(
            segments: [
                .init(text: "Мы закончили.", boundaryReason: .balancedPause),
                .init(text: "теперь следующий вопрос", boundaryReason: .stopped),
            ],
            configuration: .init(isEnabled: true, languageCode: "ru-RU")
        )
        try expectEqual(uppercased.text, "Мы закончили. Теперь следующий вопрос")

        let protected = TranscriptPostProcessor.process(
            segments: [
                .init(text: "Используем интерфейс", boundaryReason: .balancedPause),
                .init(text: "API и VoicePanel", boundaryReason: .stopped),
            ],
            configuration: .init(isEnabled: true, languageCode: "ru-RU")
        )
        try expectEqual(protected.text, "Используем интерфейс API и VoicePanel")

        let url = TranscriptPostProcessor.process(
            segments: [
                .init(text: "Адрес записан.", boundaryReason: .balancedPause),
                .init(text: "https://example.com готов", boundaryReason: .stopped),
            ],
            configuration: .init(isEnabled: true, languageCode: "ru-RU")
        )
        try expectEqual(url.text, "Адрес записан. https://example.com готов")
    },
]
