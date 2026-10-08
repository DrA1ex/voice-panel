import Foundation

public struct RecognitionValidationTarget: Codable, Equatable, Sendable {
    public let engine: String
    public let model: String
    public let modelSize: String
    public let compute: String
    public let profile: String
    public let language: String
    public let configuration: [String: String]?

    public init(
        engine: String,
        model: String,
        modelSize: String,
        compute: String,
        profile: String,
        language: String,
        configuration: [String: String]? = nil
    ) {
        self.engine = engine
        self.model = model
        self.modelSize = modelSize
        self.compute = compute
        self.profile = profile
        self.language = language
        self.configuration = configuration
    }
}

public struct RecognitionValidationEnvironment: Codable, Equatable, Sendable {
    public let hardware: String
    public let operatingSystem: String
    public let microphone: String
    public let environmentProfile: String

    public init(
        hardware: String,
        operatingSystem: String,
        microphone: String,
        environmentProfile: String
    ) {
        self.hardware = hardware
        self.operatingSystem = operatingSystem
        self.microphone = microphone
        self.environmentProfile = environmentProfile
    }
}

public struct RecognitionValidationRun: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let testedAt: Date
    public let target: RecognitionValidationTarget
    public let sampleDuration: TimeInterval
    public let processingDurations: [TimeInterval]
    public let transcript: String
    public let pipelineSummary: RecognitionPipelineValidationSummary?
    public let boundaryDiagnostics: [WhisperBoundaryRepairDiagnostics]

    public init(
        id: UUID = UUID(),
        testedAt: Date = Date(),
        target: RecognitionValidationTarget,
        sampleDuration: TimeInterval,
        processingDurations: [TimeInterval],
        transcript: String,
        pipelineSummary: RecognitionPipelineValidationSummary? = nil,
        boundaryDiagnostics: [WhisperBoundaryRepairDiagnostics] = []
    ) {
        self.id = id
        self.testedAt = testedAt
        self.target = target
        self.sampleDuration = sampleDuration
        self.processingDurations = processingDurations
        self.transcript = transcript
        self.pipelineSummary = pipelineSummary
        self.boundaryDiagnostics = boundaryDiagnostics
    }

    public var processingDuration: TimeInterval {
        Self.median(processingDurations)
    }

    public var minimumProcessingDuration: TimeInterval {
        processingDurations.min() ?? 0
    }

    public var maximumProcessingDuration: TimeInterval {
        processingDurations.max() ?? 0
    }

    public var repetitionCount: Int {
        processingDurations.count
    }

    public var realTimeFactor: Double {
        guard sampleDuration > 0 else { return 0 }
        return processingDuration / sampleDuration
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case testedAt
        case target
        case sampleDuration
        case processingDurations
        case transcript
        case pipelineSummary
        case boundaryDiagnostics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        testedAt = try container.decode(Date.self, forKey: .testedAt)
        target = try container.decode(RecognitionValidationTarget.self, forKey: .target)
        sampleDuration = try container.decode(TimeInterval.self, forKey: .sampleDuration)
        processingDurations = try container.decode(
            [TimeInterval].self,
            forKey: .processingDurations
        )
        transcript = try container.decode(String.self, forKey: .transcript)
        pipelineSummary = try container.decodeIfPresent(
            RecognitionPipelineValidationSummary.self,
            forKey: .pipelineSummary
        )
        boundaryDiagnostics =
            try container.decodeIfPresent(
                [WhisperBoundaryRepairDiagnostics].self,
                forKey: .boundaryDiagnostics
            ) ?? []
    }
}

public struct RecognitionTranscriptAccuracy: Codable, Equatable, Sendable {
    public let referenceWordCount: Int
    public let hypothesisWordCount: Int
    public let wordEdits: Int
    public let characterEdits: Int
    public let wordErrorRate: Double
    public let characterErrorRate: Double

    public init(
        referenceWordCount: Int,
        hypothesisWordCount: Int,
        wordEdits: Int,
        characterEdits: Int,
        wordErrorRate: Double,
        characterErrorRate: Double
    ) {
        self.referenceWordCount = max(0, referenceWordCount)
        self.hypothesisWordCount = max(0, hypothesisWordCount)
        self.wordEdits = max(0, wordEdits)
        self.characterEdits = max(0, characterEdits)
        self.wordErrorRate = wordErrorRate.isFinite ? max(0, wordErrorRate) : 0
        self.characterErrorRate =
            characterErrorRate.isFinite ? max(0, characterErrorRate) : 0
    }

    private enum CodingKeys: String, CodingKey {
        case referenceWordCount
        case hypothesisWordCount
        case wordEdits
        case characterEdits
        case wordErrorRate
        case characterErrorRate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            referenceWordCount: try container.decodeIfPresent(
                Int.self,
                forKey: .referenceWordCount
            ) ?? 0,
            hypothesisWordCount: try container.decodeIfPresent(
                Int.self,
                forKey: .hypothesisWordCount
            ) ?? 0,
            wordEdits: try container.decodeIfPresent(Int.self, forKey: .wordEdits) ?? 0,
            characterEdits: try container.decodeIfPresent(
                Int.self,
                forKey: .characterEdits
            ) ?? 0,
            wordErrorRate: try container.decodeIfPresent(
                Double.self,
                forKey: .wordErrorRate
            ) ?? 0,
            characterErrorRate: try container.decodeIfPresent(
                Double.self,
                forKey: .characterErrorRate
            ) ?? 0
        )
    }
}

public struct RecognitionPunctuationAccuracy: Codable, Equatable, Sendable {
    public static let zero = RecognitionPunctuationAccuracy(
        truePositives: 0,
        falsePositives: 0,
        falseNegatives: 0
    )

    public let truePositives: Int
    public let falsePositives: Int
    public let falseNegatives: Int
    public let precision: Double
    public let recall: Double
    public let f1: Double

    public init(
        truePositives: Int,
        falsePositives: Int,
        falseNegatives: Int
    ) {
        self.truePositives = max(0, truePositives)
        self.falsePositives = max(0, falsePositives)
        self.falseNegatives = max(0, falseNegatives)

        let precisionDenominator = Double(self.truePositives) + Double(self.falsePositives)
        let recallDenominator = Double(self.truePositives) + Double(self.falseNegatives)
        precision =
            precisionDenominator > 0
            ? Double(self.truePositives) / precisionDenominator : 0
        recall =
            recallDenominator > 0
            ? Double(self.truePositives) / recallDenominator : 0
        f1 =
            precision + recall > 0
            ? 2 * precision * recall / (precision + recall) : 0
    }

    private enum CodingKeys: String, CodingKey {
        case truePositives
        case falsePositives
        case falseNegatives
        case precision
        case recall
        case f1
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            truePositives: try container.decodeIfPresent(
                Int.self,
                forKey: .truePositives
            ) ?? 0,
            falsePositives: try container.decodeIfPresent(
                Int.self,
                forKey: .falsePositives
            ) ?? 0,
            falseNegatives: try container.decodeIfPresent(
                Int.self,
                forKey: .falseNegatives
            ) ?? 0
        )
    }

    public var truePositiveCount: Int { truePositives }
    public var falsePositiveCount: Int { falsePositives }
    public var falseNegativeCount: Int { falseNegatives }
    public var f1Score: Double { f1 }
}

public struct RecognitionWordEditBreakdown: Codable, Equatable, Sendable {
    public static let zero = RecognitionWordEditBreakdown(
        substitutions: 0,
        insertions: 0,
        deletions: 0
    )

    public let substitutions: Int
    public let insertions: Int
    public let deletions: Int

    public init(substitutions: Int, insertions: Int, deletions: Int) {
        self.substitutions = max(0, substitutions)
        self.insertions = max(0, insertions)
        self.deletions = max(0, deletions)
    }

    public var total: Int {
        let partial = substitutions.addingReportingOverflow(insertions)
        guard !partial.overflow else { return .max }
        let complete = partial.partialValue.addingReportingOverflow(deletions)
        return complete.overflow ? .max : complete.partialValue
    }

    private enum CodingKeys: String, CodingKey {
        case substitutions
        case insertions
        case deletions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            substitutions: try container.decodeIfPresent(Int.self, forKey: .substitutions) ?? 0,
            insertions: try container.decodeIfPresent(Int.self, forKey: .insertions) ?? 0,
            deletions: try container.decodeIfPresent(Int.self, forKey: .deletions) ?? 0
        )
    }
}

private enum RecognitionWordAlignmentStep: Equatable {
    case match
    case substitution
    case insertion
    case deletion
}

private func recognitionWordAlignment<T: Equatable>(
    _ reference: [T],
    _ hypothesis: [T]
) -> [RecognitionWordAlignmentStep] {
    var distances = Array(
        repeating: Array(repeating: 0, count: hypothesis.count + 1),
        count: reference.count + 1
    )
    for referenceIndex in 0...reference.count {
        distances[referenceIndex][0] = referenceIndex
    }
    for hypothesisIndex in 0...hypothesis.count {
        distances[0][hypothesisIndex] = hypothesisIndex
    }

    if !reference.isEmpty, !hypothesis.isEmpty {
        for referenceIndex in 1...reference.count {
            for hypothesisIndex in 1...hypothesis.count {
                let substitutionCost =
                    reference[referenceIndex - 1] == hypothesis[hypothesisIndex - 1] ? 0 : 1
                distances[referenceIndex][hypothesisIndex] = min(
                    distances[referenceIndex][hypothesisIndex - 1] + 1,
                    distances[referenceIndex - 1][hypothesisIndex] + 1,
                    distances[referenceIndex - 1][hypothesisIndex - 1] + substitutionCost
                )
            }
        }
    }

    var reversedSteps: [RecognitionWordAlignmentStep] = []
    var referenceIndex = reference.count
    var hypothesisIndex = hypothesis.count
    while referenceIndex > 0 || hypothesisIndex > 0 {
        if referenceIndex > 0, hypothesisIndex > 0,
            reference[referenceIndex - 1] == hypothesis[hypothesisIndex - 1],
            distances[referenceIndex][hypothesisIndex]
                == distances[referenceIndex - 1][hypothesisIndex - 1]
        {
            reversedSteps.append(.match)
            referenceIndex -= 1
            hypothesisIndex -= 1
        } else if referenceIndex > 0, hypothesisIndex > 0,
            distances[referenceIndex][hypothesisIndex]
                == distances[referenceIndex - 1][hypothesisIndex - 1] + 1
        {
            reversedSteps.append(.substitution)
            referenceIndex -= 1
            hypothesisIndex -= 1
        } else if referenceIndex > 0,
            distances[referenceIndex][hypothesisIndex]
                == distances[referenceIndex - 1][hypothesisIndex] + 1
        {
            reversedSteps.append(.deletion)
            referenceIndex -= 1
        } else {
            reversedSteps.append(.insertion)
            hypothesisIndex -= 1
        }
    }
    return reversedSteps.reversed()
}

public enum RecognitionPunctuationScorer {
    private struct PunctuationEvent: Equatable {
        let boundary: Int
        let token: String
    }

    private struct TokenizedText {
        let words: [String]
        let punctuation: [PunctuationEvent]
    }

    public static func score(
        reference: String,
        hypothesis: String
    ) -> RecognitionPunctuationAccuracy {
        let tokenizedReference = tokenize(reference)
        let tokenizedHypothesis = tokenize(hypothesis)
        let alignment = recognitionWordAlignment(
            tokenizedReference.words,
            tokenizedHypothesis.words
        )
        let (referenceSlots, hypothesisSlots) = boundarySlots(for: alignment)
        let referenceTokens = tokenizedReference.punctuation.map {
            PunctuationEvent(boundary: referenceSlots[$0.boundary], token: $0.token)
        }
        let hypothesisTokens = tokenizedHypothesis.punctuation.map {
            PunctuationEvent(boundary: hypothesisSlots[$0.boundary], token: $0.token)
        }
        let truePositives = longestCommonSubsequenceLength(
            referenceTokens,
            hypothesisTokens
        )
        return RecognitionPunctuationAccuracy(
            truePositives: truePositives,
            falsePositives: hypothesisTokens.count - truePositives,
            falseNegatives: referenceTokens.count - truePositives
        )
    }

    private static func tokenize(_ text: String) -> TokenizedText {
        var words: [String] = []
        var punctuation: [PunctuationEvent] = []
        var currentWord = ""
        var index = text.startIndex

        func finishWord() {
            guard !currentWord.isEmpty else { return }
            words.append(currentWord)
            currentWord = ""
        }

        while index < text.endIndex {
            if text[index...].hasPrefix("...") {
                finishWord()
                punctuation.append(PunctuationEvent(boundary: words.count, token: "…"))
                index = text.index(index, offsetBy: 3)
                continue
            }

            let character = text[index]
            if character.unicodeScalars.contains(where: {
                CharacterSet.alphanumerics.contains($0)
            }) {
                currentWord.append(contentsOf: String(character).lowercased())
            } else {
                finishWord()
                if let token = canonicalPunctuationToken(for: character) {
                    punctuation.append(PunctuationEvent(boundary: words.count, token: token))
                }
            }
            index = text.index(after: index)
        }
        finishWord()

        return TokenizedText(words: words, punctuation: punctuation)
    }

    private static func canonicalPunctuationToken(for character: Character) -> String? {
        switch character {
        case "…": return "…"
        case "‘", "’", "‚", "‛": return "'"
        case "“", "”", "„", "‟": return "\""
        default:
            return character.unicodeScalars.contains(where: {
                CharacterSet.punctuationCharacters.contains($0)
            }) ? String(character) : nil
        }
    }

    private static func boundarySlots(
        for alignment: [RecognitionWordAlignmentStep]
    ) -> ([Int], [Int]) {
        let referenceWordCount = alignment.reduce(into: 0) { count, step in
            if step != .insertion { count += 1 }
        }
        let hypothesisWordCount = alignment.reduce(into: 0) { count, step in
            if step != .deletion { count += 1 }
        }
        var referenceSlots = Array(repeating: 0, count: referenceWordCount + 1)
        var hypothesisSlots = Array(repeating: 0, count: hypothesisWordCount + 1)
        var referenceIndex = 0
        var hypothesisIndex = 0

        for (slotIndex, step) in alignment.enumerated() {
            let slot = slotIndex + 1
            if step != .insertion {
                referenceIndex += 1
                referenceSlots[referenceIndex] = slot
            }
            if step != .deletion {
                hypothesisIndex += 1
                hypothesisSlots[hypothesisIndex] = slot
            }
        }
        return (referenceSlots, hypothesisSlots)
    }

    private static func longestCommonSubsequenceLength<T: Equatable>(
        _ lhs: [T],
        _ rhs: [T]
    ) -> Int {
        var previous = Array(repeating: 0, count: rhs.count + 1)
        for leftValue in lhs {
            var current = Array(repeating: 0, count: rhs.count + 1)
            for (rightIndex, rightValue) in rhs.enumerated() {
                current[rightIndex + 1] =
                    leftValue == rightValue
                    ? previous[rightIndex] + 1
                    : max(current[rightIndex], previous[rightIndex + 1])
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

public enum RecognitionTranscriptScorer {
    public static func score(
        reference: String,
        hypothesis: String
    ) -> RecognitionTranscriptAccuracy? {
        let normalizedReference = normalizedText(reference)
        guard !normalizedReference.isEmpty else { return nil }
        let normalizedHypothesis = normalizedText(hypothesis)
        let referenceWords = normalizedReference.split(separator: " ").map(String.init)
        let hypothesisWords = normalizedHypothesis.split(separator: " ").map(String.init)
        let wordEditBreakdown = editBreakdown(referenceWords, hypothesisWords)
        let wordEdits = wordEditBreakdown.total
        let referenceCharacters = Array(normalizedReference)
        let hypothesisCharacters = Array(normalizedHypothesis)
        let characterEdits = editDistance(referenceCharacters, hypothesisCharacters)

        return RecognitionTranscriptAccuracy(
            referenceWordCount: referenceWords.count,
            hypothesisWordCount: hypothesisWords.count,
            wordEdits: wordEdits,
            characterEdits: characterEdits,
            wordErrorRate: Double(wordEdits) / Double(max(1, referenceWords.count)),
            characterErrorRate: Double(characterEdits)
                / Double(max(1, referenceCharacters.count))
        )
    }

    public static func normalizedText(_ text: String) -> String {
        var result = ""
        var needsSeparator = false

        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if needsSeparator, !result.isEmpty {
                    result.append(" ")
                }
                result.unicodeScalars.append(scalar)
                needsSeparator = false
            } else if !result.isEmpty {
                needsSeparator = true
            }
        }

        return result
    }

    public static func wordEditBreakdown(
        reference: String,
        hypothesis: String
    ) -> RecognitionWordEditBreakdown {
        let normalizedReference = normalizedText(reference)
        guard !normalizedReference.isEmpty else { return .zero }
        let normalizedHypothesis = normalizedText(hypothesis)
        return editBreakdown(
            normalizedReference.split(separator: " ").map(String.init),
            normalizedHypothesis.split(separator: " ").map(String.init)
        )
    }

    private static func editBreakdown<T: Equatable>(
        _ lhs: [T],
        _ rhs: [T]
    ) -> RecognitionWordEditBreakdown {
        var substitutions = 0
        var insertions = 0
        var deletions = 0
        for step in recognitionWordAlignment(lhs, rhs) {
            switch step {
            case .match: break
            case .substitution: substitutions += 1
            case .insertion: insertions += 1
            case .deletion: deletions += 1
            }
        }

        return RecognitionWordEditBreakdown(
            substitutions: substitutions,
            insertions: insertions,
            deletions: deletions
        )
    }

    private static func editDistance<T: Equatable>(_ lhs: [T], _ rhs: [T]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        for (leftIndex, leftValue) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, rightValue) in rhs.enumerated() {
                let substitutionCost = leftValue == rightValue ? 0 : 1
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + substitutionCost
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

public struct RecognitionValidationReportRun: Codable, Equatable, Sendable {
    public let run: RecognitionValidationRun
    public let accuracy: RecognitionTranscriptAccuracy?
    public let punctuationAccuracy: RecognitionPunctuationAccuracy
    public let wordSubstitutions: Int
    public let wordInsertions: Int
    public let wordDeletions: Int

    public init(
        run: RecognitionValidationRun,
        accuracy: RecognitionTranscriptAccuracy?,
        punctuationAccuracy: RecognitionPunctuationAccuracy = .zero,
        wordSubstitutions: Int = 0,
        wordInsertions: Int = 0,
        wordDeletions: Int = 0
    ) {
        self.run = run
        self.accuracy = accuracy
        self.punctuationAccuracy = punctuationAccuracy
        self.wordSubstitutions = max(0, wordSubstitutions)
        self.wordInsertions = max(0, wordInsertions)
        self.wordDeletions = max(0, wordDeletions)
    }

    public var wordEditBreakdown: RecognitionWordEditBreakdown {
        RecognitionWordEditBreakdown(
            substitutions: wordSubstitutions,
            insertions: wordInsertions,
            deletions: wordDeletions
        )
    }

    private enum CodingKeys: String, CodingKey {
        case run
        case accuracy
        case punctuationAccuracy
        case wordSubstitutions
        case wordInsertions
        case wordDeletions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedBreakdown = RecognitionWordEditBreakdown(
            substitutions: try container.decodeIfPresent(
                Int.self,
                forKey: .wordSubstitutions
            ) ?? 0,
            insertions: try container.decodeIfPresent(Int.self, forKey: .wordInsertions) ?? 0,
            deletions: try container.decodeIfPresent(Int.self, forKey: .wordDeletions) ?? 0
        )
        self.init(
            run: try container.decode(RecognitionValidationRun.self, forKey: .run),
            accuracy: try container.decodeIfPresent(
                RecognitionTranscriptAccuracy.self,
                forKey: .accuracy
            ),
            punctuationAccuracy: try container.decodeIfPresent(
                RecognitionPunctuationAccuracy.self,
                forKey: .punctuationAccuracy
            ) ?? .zero,
            wordSubstitutions: decodedBreakdown.substitutions,
            wordInsertions: decodedBreakdown.insertions,
            wordDeletions: decodedBreakdown.deletions
        )
    }
}

public struct RecognitionValidationReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let environment: RecognitionValidationEnvironment
    public let referenceTranscript: String
    public let notes: String
    public let runs: [RecognitionValidationReportRun]

    public init(
        generatedAt: Date = Date(),
        environment: RecognitionValidationEnvironment,
        referenceTranscript: String,
        notes: String,
        runs: [RecognitionValidationRun]
    ) {
        schemaVersion = 2
        self.generatedAt = generatedAt
        self.environment = environment
        self.referenceTranscript = referenceTranscript
        self.notes = notes
        self.runs = runs.map { run in
            let wordEditBreakdown = RecognitionTranscriptScorer.wordEditBreakdown(
                reference: referenceTranscript,
                hypothesis: run.transcript
            )
            return RecognitionValidationReportRun(
                run: run,
                accuracy: RecognitionTranscriptScorer.score(
                    reference: referenceTranscript,
                    hypothesis: run.transcript
                ),
                punctuationAccuracy: RecognitionPunctuationScorer.score(
                    reference: referenceTranscript,
                    hypothesis: run.transcript
                ),
                wordSubstitutions: wordEditBreakdown.substitutions,
                wordInsertions: wordEditBreakdown.insertions,
                wordDeletions: wordEditBreakdown.deletions
            )
        }
    }
}
