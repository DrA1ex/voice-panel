import Foundation
import VoicePanelCore

let recognitionValidationChecks: [CheckCase] = [
    CheckCase(name: "validation scorer ignores case and punctuation") {
        let score = try requireScore(
            reference: "VoicePanel, works well!",
            hypothesis: "voicepanel works well"
        )
        try expectEqual(score.wordEdits, 0)
        try expectApproximatelyEqual(score.wordErrorRate, 0, accuracy: 0.000_001)
        try expectEqual(score.characterEdits, 0)
    },
    CheckCase(name: "validation scorer reports substitutions and omissions") {
        let score = try requireScore(
            reference: "one two three four",
            hypothesis: "one too four"
        )
        try expectEqual(score.referenceWordCount, 4)
        try expectEqual(score.hypothesisWordCount, 3)
        try expectEqual(score.wordEdits, 2)
        try expectApproximatelyEqual(score.wordErrorRate, 0.5, accuracy: 0.000_001)
    },
    CheckCase(name: "validation scorer supports Cyrillic text") {
        let score = try requireScore(
            reference: "Проверка распознавания речи",
            hypothesis: "проверка распознавания речи"
        )
        try expectEqual(score.wordEdits, 0)
        try expectApproximatelyEqual(score.characterErrorRate, 0, accuracy: 0.000_001)
    },
    CheckCase(name: "validation scorer reports deterministic punctuation accuracy") {
        let punctuation = RecognitionPunctuationScorer.score(
            reference: "Привет, мир! Как дела?",
            hypothesis: "Привет мир. Как дела"
        )
        try expectEqual(punctuation.truePositives, 0)
        try expectEqual(punctuation.falsePositives, 1)
        try expectEqual(punctuation.falseNegatives, 3)
        try expectApproximatelyEqual(punctuation.precision, 0, accuracy: 0.000_001)
        try expectApproximatelyEqual(punctuation.recall, 0, accuracy: 0.000_001)
        try expectApproximatelyEqual(punctuation.f1, 0, accuracy: 0.000_001)
    },
    CheckCase(name: "punctuation scorer normalizes quotes ellipsis case and spacing") {
        let punctuation = RecognitionPunctuationScorer.score(
            reference: "Он сказал: “Да”… и ‘ушёл’.",
            hypothesis: "он сказал : \"да\"... И 'УШЁЛ'."
        )
        try expectEqual(punctuation.truePositives, 7)
        try expectEqual(punctuation.falsePositives, 0)
        try expectEqual(punctuation.falseNegatives, 0)
        try expectApproximatelyEqual(punctuation.precision, 1, accuracy: 0.000_001)
        try expectApproximatelyEqual(punctuation.recall, 1, accuracy: 0.000_001)
        try expectApproximatelyEqual(punctuation.f1, 1, accuracy: 0.000_001)
    },
    CheckCase(name: "punctuation scorer handles Unicode graphemes") {
        let punctuation = RecognitionPunctuationScorer.score(
            reference: "Cafe\u{301}… Что⁉",
            hypothesis: "CAFÉ... ЧТО⁉"
        )
        try expectEqual(punctuation.truePositives, 2)
        try expectEqual(punctuation.falsePositives, 0)
        try expectEqual(punctuation.falseNegatives, 0)
    },
    CheckCase(name: "punctuation scorer defines zero denominators") {
        let punctuation = RecognitionPunctuationScorer.score(
            reference: "No punctuation",
            hypothesis: "NO PUNCTUATION"
        )
        try expectEqual(punctuation.truePositives, 0)
        try expectEqual(punctuation.falsePositives, 0)
        try expectEqual(punctuation.falseNegatives, 0)
        try expectApproximatelyEqual(punctuation.precision, 0, accuracy: 0.000_001)
        try expectApproximatelyEqual(punctuation.recall, 0, accuracy: 0.000_001)
        try expectApproximatelyEqual(punctuation.f1, 0, accuracy: 0.000_001)
    },
    CheckCase(name: "punctuation scorer penalizes punctuation moved to another word boundary") {
        let punctuation = RecognitionPunctuationScorer.score(
            reference: "a, b.",
            hypothesis: "a b,."
        )
        try expectEqual(punctuation.truePositives, 1)
        try expectEqual(punctuation.falsePositives, 1)
        try expectEqual(punctuation.falseNegatives, 1)
        try expectApproximatelyEqual(punctuation.f1, 0.5, accuracy: 0.000_001)
    },
    CheckCase(name: "punctuation slots follow lexical insertions and deletions") {
        let insertion = RecognitionPunctuationScorer.score(
            reference: "a, b.",
            hypothesis: "a x, b."
        )
        try expectEqual(insertion.truePositives, 1)
        try expectEqual(insertion.falsePositives, 1)
        try expectEqual(insertion.falseNegatives, 1)

        let deletion = RecognitionPunctuationScorer.score(
            reference: "a x, b.",
            hypothesis: "a, b."
        )
        try expectEqual(deletion.truePositives, 1)
        try expectEqual(deletion.falsePositives, 1)
        try expectEqual(deletion.falseNegatives, 1)
    },
    CheckCase(name: "punctuation slots share lexical substitution columns") {
        let punctuation = RecognitionPunctuationScorer.score(
            reference: "a, b.",
            hypothesis: "a, changed."
        )
        try expectEqual(punctuation.truePositives, 2)
        try expectEqual(punctuation.falsePositives, 0)
        try expectEqual(punctuation.falseNegatives, 0)
    },
    CheckCase(name: "punctuation slots use deterministic repeated-word alignment") {
        let punctuation = RecognitionPunctuationScorer.score(
            reference: "a, b a.",
            hypothesis: "a a, b."
        )
        try expectEqual(punctuation.truePositives, 1)
        try expectEqual(punctuation.falsePositives, 1)
        try expectEqual(punctuation.falseNegatives, 1)
    },
    CheckCase(name: "validation report distinguishes each word edit category") {
        let report = makeValidationReport(
            reference: "alpha beta gamma delta epsilon zeta eta",
            hypothesis: "alpha changed gamma epsilon zeta eta extra"
        )
        let run = report.runs[0]
        try expectEqual(run.wordSubstitutions, 1)
        try expectEqual(run.wordInsertions, 1)
        try expectEqual(run.wordDeletions, 1)
        try expectEqual(run.accuracy?.wordEdits, 3)
    },
    CheckCase(name: "word edit backtrace resolves repeated-token ties deterministically") {
        let report = makeValidationReport(
            reference: "a b a",
            hypothesis: "a a b"
        )
        let run = report.runs[0]
        try expectEqual(run.wordSubstitutions, 2)
        try expectEqual(run.wordInsertions, 0)
        try expectEqual(run.wordDeletions, 0)
        try expectEqual(run.accuracy?.wordEdits, 2)
    },
    CheckCase(name: "validation run uses median inference duration") {
        let run = RecognitionValidationRun(
            target: sampleValidationTarget,
            sampleDuration: 10,
            processingDurations: [4, 2, 9, 3],
            transcript: "sample"
        )
        try expectApproximatelyEqual(run.processingDuration, 3.5, accuracy: 0.000_001)
        try expectApproximatelyEqual(run.minimumProcessingDuration, 2, accuracy: 0.000_001)
        try expectApproximatelyEqual(run.maximumProcessingDuration, 9, accuracy: 0.000_001)
        try expectApproximatelyEqual(run.realTimeFactor, 0.35, accuracy: 0.000_001)
        try expectEqual(run.repetitionCount, 4)
    },
    CheckCase(name: "validation report embeds scored runs") {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let run = RecognitionValidationRun(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            testedAt: timestamp,
            target: sampleValidationTarget,
            sampleDuration: 5,
            processingDurations: [1],
            transcript: "expected text"
        )
        let report = RecognitionValidationReport(
            generatedAt: timestamp,
            environment: RecognitionValidationEnvironment(
                hardware: "Mac",
                operatingSystem: "macOS",
                microphone: "Built-in",
                environmentProfile: "Balanced"
            ),
            referenceTranscript: "expected text",
            notes: "quiet room",
            runs: [run]
        )
        try expectEqual(report.schemaVersion, 2)
        try expectEqual(report.runs.count, 1)
        try expectEqual(report.runs[0].accuracy?.wordEdits, 0)
        try expectEqual(report.runs[0].punctuationAccuracy.truePositives, 0)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RecognitionValidationReport.self, from: data)
        try expectEqual(decoded, report)
    },
    CheckCase(name: "validation report decodes schema version one defaults") {
        let data = Data(schemaVersionOneFixture.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(RecognitionValidationReport.self, from: data)

        try expectEqual(report.schemaVersion, 1)
        try expectEqual(report.runs.count, 1)
        try expectEqual(report.runs[0].run.boundaryDiagnostics, [])
        try expectEqual(report.runs[0].wordSubstitutions, 0)
        try expectEqual(report.runs[0].wordInsertions, 0)
        try expectEqual(report.runs[0].wordDeletions, 0)
        try expectEqual(report.runs[0].punctuationAccuracy, .zero)
    },
    CheckCase(name: "punctuation decoding derives ratios from bounded counts") {
        let data = Data(
            #"""
            {
              "truePositives": 2,
              "falsePositives": -3,
              "falseNegatives": 4,
              "precision": 0.99,
              "recall": 0.99,
              "f1": 0.99
            }
            """#.utf8
        )
        let punctuation = try JSONDecoder().decode(
            RecognitionPunctuationAccuracy.self,
            from: data
        )

        try expectEqual(punctuation.truePositives, 2)
        try expectEqual(punctuation.falsePositives, 0)
        try expectEqual(punctuation.falseNegatives, 4)
        try expectApproximatelyEqual(punctuation.precision, 1, accuracy: 0.000_001)
        try expectApproximatelyEqual(punctuation.recall, 1.0 / 3.0, accuracy: 0.000_001)
        try expectApproximatelyEqual(punctuation.f1, 0.5, accuracy: 0.000_001)

        let partial = try JSONDecoder().decode(
            RecognitionPunctuationAccuracy.self,
            from: Data(#"{"falsePositives":2}"#.utf8)
        )
        try expectEqual(partial.truePositives, 0)
        try expectEqual(partial.falsePositives, 2)
        try expectEqual(partial.falseNegatives, 0)
        try expectApproximatelyEqual(partial.f1, 0, accuracy: 0.000_001)

        let oversizedData = Data(
            "{\"truePositives\":\(Int.max),\"falsePositives\":\(Int.max),\"falseNegatives\":\(Int.max)}".utf8
        )
        let oversized = try JSONDecoder().decode(
            RecognitionPunctuationAccuracy.self,
            from: oversizedData
        )
        try expectApproximatelyEqual(oversized.precision, 0.5, accuracy: 0.000_001)
        try expectApproximatelyEqual(oversized.recall, 0.5, accuracy: 0.000_001)
        try expectApproximatelyEqual(oversized.f1, 0.5, accuracy: 0.000_001)
    },
    CheckCase(name: "word edit breakdown decoding defaults and clamps fields") {
        let breakdown = try JSONDecoder().decode(
            RecognitionWordEditBreakdown.self,
            from: Data(#"{"substitutions":-1,"deletions":3}"#.utf8)
        )
        try expectEqual(breakdown.substitutions, 0)
        try expectEqual(breakdown.insertions, 0)
        try expectEqual(breakdown.deletions, 3)
        try expectEqual(breakdown.total, 3)
    },
    CheckCase(name: "decoded report word edit total saturates instead of overflowing") {
        let original = makeValidationReport(reference: "one two", hypothesis: "one too")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var root = try requireJSONObject(encoder.encode(original))
        guard var runs = root["runs"] as? [[String: Any]], !runs.isEmpty else {
            throw CheckFailure(description: "expected encoded validation report runs")
        }
        runs[0]["wordSubstitutions"] = Int.max
        runs[0]["wordInsertions"] = Int.max - 1
        runs[0]["wordDeletions"] = Int.max - 2
        root["runs"] = runs

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            RecognitionValidationReport.self,
            from: JSONSerialization.data(withJSONObject: root)
        )

        try expectEqual(decoded.runs[0].wordEditBreakdown.total, Int.max)
    },
    CheckCase(name: "transcript accuracy decoding rejects negative and invalid metrics") {
        let data = Data(
            #"""
            {
              "referenceWordCount": -1,
              "hypothesisWordCount": -2,
              "wordEdits": -3,
              "characterEdits": -4,
              "wordErrorRate": -0.5,
              "characterErrorRate": -1
            }
            """#.utf8
        )
        let accuracy = try JSONDecoder().decode(
            RecognitionTranscriptAccuracy.self,
            from: data
        )
        try expectEqual(accuracy.referenceWordCount, 0)
        try expectEqual(accuracy.hypothesisWordCount, 0)
        try expectEqual(accuracy.wordEdits, 0)
        try expectEqual(accuracy.characterEdits, 0)
        try expectApproximatelyEqual(accuracy.wordErrorRate, 0, accuracy: 0.000_001)
        try expectApproximatelyEqual(accuracy.characterErrorRate, 0, accuracy: 0.000_001)
    },
    CheckCase(name: "validation report decodes partial schema version two nested metrics") {
        let original = makeValidationReport(reference: "one two", hypothesis: "one too")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(original)
        var root = try requireJSONObject(encoded)
        guard var runs = root["runs"] as? [[String: Any]], !runs.isEmpty else {
            throw CheckFailure(description: "expected encoded validation report runs")
        }
        runs[0]["wordSubstitutions"] = -7
        runs[0].removeValue(forKey: "wordInsertions")
        runs[0]["wordDeletions"] = 2
        runs[0]["punctuationAccuracy"] = ["truePositives": 1]
        runs[0]["accuracy"] = ["wordEdits": 3]
        root["runs"] = runs
        let partialData = try JSONSerialization.data(withJSONObject: root)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RecognitionValidationReport.self, from: partialData)
        let reportRun = decoded.runs[0]
        try expectEqual(reportRun.wordSubstitutions, 0)
        try expectEqual(reportRun.wordInsertions, 0)
        try expectEqual(reportRun.wordDeletions, 2)
        try expectEqual(reportRun.punctuationAccuracy.truePositives, 1)
        try expectEqual(reportRun.punctuationAccuracy.falsePositives, 0)
        try expectEqual(reportRun.accuracy?.wordEdits, 3)
        try expectEqual(reportRun.accuracy?.referenceWordCount, 0)
        try expectEqual(reportRun.accuracy?.characterEdits, 0)
    },
    CheckCase(name: "validation schema version two round trips diagnostics and metrics") {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let diagnostics = WhisperBoundaryRepairDiagnostics(
            strategy: .contextualRetry,
            attempted: true,
            accepted: false,
            reasonCode: .missingStableAnchor,
            inferenceCount: 2,
            inferenceDuration: 1.5,
            changedBoundaryWordCounts: .init(baseline: 2, replacement: 0)
        )
        let run = RecognitionValidationRun(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            testedAt: timestamp,
            target: sampleValidationTarget,
            sampleDuration: 5,
            processingDurations: [1],
            transcript: "Привет мир.",
            boundaryDiagnostics: [diagnostics]
        )
        let report = RecognitionValidationReport(
            generatedAt: timestamp,
            environment: sampleValidationEnvironment,
            referenceTranscript: "Привет, мир!",
            notes: "fixture",
            runs: [run]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RecognitionValidationReport.self, from: data)

        try expectEqual(decoded, report)
        try expectEqual(decoded.runs[0].run.boundaryDiagnostics, [diagnostics])
        try expectEqual(decoded.runs[0].punctuationAccuracy.falsePositives, 1)
        try expectEqual(decoded.runs[0].punctuationAccuracy.falseNegatives, 2)
    },
    CheckCase(name: "validation target exports benchmark context settings") {
        let target = RecognitionValidationTarget(
            engine: "Whisper",
            model: "Large v3 Turbo",
            modelSize: "547 MB",
            compute: "Metal",
            profile: "Model only",
            language: "Auto",
            configuration: ["reusePreviousChunkContext": "enabled"]
        )
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(RecognitionValidationTarget.self, from: data)
        try expectEqual(
            decoded.configuration?["reusePreviousChunkContext"],
            "enabled"
        )
    },
]

private let sampleValidationTarget = RecognitionValidationTarget(
    engine: "Whisper",
    model: "Medium Q5",
    modelSize: "500 MB",
    compute: "Metal",
    profile: "Balanced",
    language: "Russian"
)

private let sampleValidationEnvironment = RecognitionValidationEnvironment(
    hardware: "Mac",
    operatingSystem: "macOS",
    microphone: "Built-in",
    environmentProfile: "Balanced"
)

private let schemaVersionOneFixture = #"""
    {
      "schemaVersion": 1,
      "generatedAt": "2023-11-14T22:13:20Z",
      "environment": {
        "hardware": "Mac",
        "operatingSystem": "macOS",
        "microphone": "Built-in",
        "environmentProfile": "Balanced"
      },
      "referenceTranscript": "expected text",
      "notes": "schema one fixture",
      "runs": [{
        "run": {
          "id": "11111111-2222-3333-4444-555555555555",
          "testedAt": "2023-11-14T22:13:20Z",
          "target": {
            "engine": "Whisper",
            "model": "Medium Q5",
            "modelSize": "500 MB",
            "compute": "Metal",
            "profile": "Balanced",
            "language": "Russian"
          },
          "sampleDuration": 5,
          "processingDurations": [1],
          "transcript": "expected text"
        },
        "accuracy": {
          "referenceWordCount": 2,
          "hypothesisWordCount": 2,
          "wordEdits": 0,
          "characterEdits": 0,
          "wordErrorRate": 0,
          "characterErrorRate": 0
        }
      }]
    }
    """#

private func makeValidationReport(
    reference: String,
    hypothesis: String
) -> RecognitionValidationReport {
    RecognitionValidationReport(
        environment: sampleValidationEnvironment,
        referenceTranscript: reference,
        notes: "",
        runs: [
            RecognitionValidationRun(
                target: sampleValidationTarget,
                sampleDuration: 1,
                processingDurations: [1],
                transcript: hypothesis
            )
        ]
    )
}

private func requireJSONObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CheckFailure(description: "expected encoded validation report object")
    }
    return object
}

private func requireScore(
    reference: String,
    hypothesis: String
) throws -> RecognitionTranscriptAccuracy {
    guard
        let score = RecognitionTranscriptScorer.score(
            reference: reference,
            hypothesis: hypothesis
        )
    else {
        throw CheckFailure(description: "expected a validation score")
    }
    return score
}
