import VoicePanelCore

let transcriptPostProcessingAccumulatorChecks: [CheckCase] = [
    CheckCase(name: "Pipeline transcript keeps forced boundary metadata for final cleanup") {
        var accumulator = TranscriptPostProcessingAccumulator()
        accumulator.append(
            text: "Нам стоит вернуть эту возможность",
            boundaryReason: .maximumDuration
        )
        accumulator.append(
            text: "Потому что задача ещё не закончена",
            boundaryReason: .stopped
        )

        try expectEqual(
            accumulator.processedText(
                configuration: .init(isEnabled: true, languageCode: "ru-RU")
            ),
            "Нам стоит вернуть эту возможность потому что задача ещё не закончена"
        )
    },
    CheckCase(name: "Rejected pipeline chunk breaks forced continuation cleanup") {
        var accumulator = TranscriptPostProcessingAccumulator()
        accumulator.append(text: "Первая мысль оборвалась", boundaryReason: .maximumDuration)
        accumulator.breakContinuity()
        accumulator.append(text: "Новая мысль", boundaryReason: .stopped)

        try expectEqual(
            accumulator.processedText(
                configuration: .init(isEnabled: true, languageCode: "ru-RU")
            ),
            "Первая мысль оборвалась Новая мысль"
        )
    },
]
