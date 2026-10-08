import VoicePanelCore

let transcriptTextNormalizerChecks: [CheckCase] = [
    CheckCase(name: "Normalizer removes spaces before punctuation") {
        try expectEqual(
            TranscriptTextNormalizer.normalize("Привет , мир . Как дела ?"),
            "Привет, мир. Как дела?"
        )
    },

    CheckCase(name: "Normalizer fixes bracket spacing and repeated whitespace") {
        try expectEqual(
            TranscriptTextNormalizer.normalize("Это   ( тест )  !"),
            "Это (тест)!"
        )
    },

    CheckCase(name: "Segment merge does not insert a space before punctuation") {
        try expectEqual(TranscriptTextMerger.merge("Привет", "."), "Привет.")
    },

    CheckCase(name: "Normalizer preserves explicit line breaks") {
        try expectEqual(
            TranscriptTextNormalizer.normalize("Первая строка  \n  Вторая строка ."),
            "Первая строка\nВторая строка."
        )
    },

    CheckCase(name: "Return symbols become actual line breaks") {
        try expectEqual(TranscriptTextNormalizer.normalize("Первая↵Вторая"), "Первая\nВторая")
        try expectEqual(TranscriptTextMerger.merge("Первая", "↵"), "Первая\n")
        try expectEqual(TranscriptTextMerger.merge("Первая\n", "Вторая"), "Первая\nВторая")
    },

    CheckCase(name: "Multi-line preview starts completed sentences on new lines") {
        try expectEqual(
            TranscriptTextNormalizer.sentenceLines(
                "First sentence. Second sentence! Is this the third? Yes… It is."
            ),
            "First sentence.\nSecond sentence!\nIs this the third?\nYes…\nIt is."
        )
    },

    CheckCase(name: "Compact preview keeps the newest words after a long recording") {
        let text = String(repeating: "Старая фраза. ", count: 10_000) + "Последние слова."
        let preview = TranscriptTextNormalizer.singleLinePreview(text)
        try expect(preview.count <= 1_200, "The preview must remain bounded")
        try expect(preview.hasSuffix("Последние слова."), "The latest words must remain visible")
    },

    CheckCase(name: "Compact preview flattens all speech-engine line separators") {
        let preview = TranscriptTextNormalizer.singleLinePreview(
            "Один\r\nдва\rтри\u{2028}четыре\u{2029}пять↵шесть⏎семь\u{000B}восемь\u{000C}девять"
        )
        try expectEqual(preview, "Один два три четыре пять шесть семь восемь девять")
        try expect(!preview.contains(where: { $0.isNewline }), "The viewport must receive a single line")
    },

    CheckCase(name: "Compact preview remains bounded across repeated line breaks") {
        let preview = TranscriptTextNormalizer.singleLinePreview(
            String(repeating: "Я\n", count: 1_000) + "Конец", maximumCharacters: 64
        )
        try expect(preview.count <= 64, "The preview must respect the limit")
        try expect(preview.hasSuffix("Конец"), "The preview must preserve the latest words")
    },

    CheckCase(name: "Compact preview preserves Unicode characters at the tail boundary") {
        try expectEqual(
            TranscriptTextNormalizer.singleLinePreview("Начало 👨‍👩‍👧‍👦 👍🏽 Я", maximumCharacters: 5),
            "👨‍👩‍👧‍👦 👍🏽 Я"
        )
        try expectEqual(TranscriptTextNormalizer.singleLinePreview("Текст", maximumCharacters: 0), "")
    },

]
