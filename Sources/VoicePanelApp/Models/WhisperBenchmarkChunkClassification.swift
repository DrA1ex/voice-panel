import VoicePanelCore

enum WhisperBenchmarkChunkRecognitionState: Equatable, Sendable {
    case pending
    case accepted(String)
    case empty
    case rejected(text: String, reason: String)
}

struct WhisperBenchmarkChunkClassification: Sendable {
    let text: String
    let rejectionReason: WhisperBoundaryRepairReasonCode?

    init(
        text: String,
        rejectionReason: WhisperBoundaryRepairReasonCode? = nil
    ) {
        self.text = text
        self.rejectionReason = rejectionReason
    }

    init(processed: WhisperProcessedChunk) {
        if processed.diagnostics.reasonCode == .baselineRejectedHallucination {
            text = processed.baseline?.text ?? ""
            rejectionReason = .baselineRejectedHallucination
        } else {
            text = processed.revisions.last?.text ?? ""
            rejectionReason = nil
        }
    }
}

struct WhisperBenchmarkPassAccumulator {
    private(set) var previousAcceptedText: String?
    private(set) var previousAcceptedBoundaryReason: AudioChunkBoundaryReason?
    private(set) var rejectedResultCount = 0
    private var transcriptAccumulator = TranscriptPostProcessingAccumulator()

    var transcript: String {
        transcriptAccumulator.mergedText
    }

    func transcript(
        postProcessing configuration: TranscriptPostProcessingConfiguration
    ) -> String {
        transcriptAccumulator.processedText(configuration: configuration)
    }

    mutating func consume(
        _ classified: WhisperBenchmarkChunkClassification,
        chunk: AudioChunk,
        appliesPresentationHallucinationGuard: Bool,
        hallucinationGuardConfiguration: RecognitionHallucinationGuard.Configuration
    ) -> WhisperBenchmarkChunkRecognitionState {
        let text = classified.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rejectionReason = classified.rejectionReason {
            clearContinuity()
            rejectedResultCount += 1
            return .rejected(text: text, reason: rejectionReason.rawValue)
        }
        if text.isEmpty {
            clearContinuity()
            return .empty
        }
        if appliesPresentationHallucinationGuard,
            let rejectionReason = RecognitionHallucinationGuard().rejectionReason(
                for: text,
                chunk: chunk,
                configuration: hallucinationGuardConfiguration
            )
        {
            clearContinuity()
            rejectedResultCount += 1
            return .rejected(text: text, reason: rejectionReason)
        }

        transcriptAccumulator.append(text: text, boundaryMetadata: chunk.boundaryMetadata)
        previousAcceptedText = text
        previousAcceptedBoundaryReason = chunk.boundaryReason
        return .accepted(text)
    }

    private mutating func clearContinuity() {
        transcriptAccumulator.breakContinuity()
        previousAcceptedText = nil
        previousAcceptedBoundaryReason = nil
    }
}
