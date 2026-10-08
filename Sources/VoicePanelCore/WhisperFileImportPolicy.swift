import Foundation

public enum WhisperFileImportRoute: Equatable, Sendable {
    case profileVAD
    case continuousFullAudio
}

public enum WhisperContinuousAttemptOutcome: Equatable, Sendable {
    case completed
    case failed
    case cancelled
}

public enum WhisperFileImportTerminalPresentation: Equatable, Sendable {
    case interactive
    case noSpeech
    case partialIssue
}

public enum WhisperFileImportFallbackReason: String, Equatable, Sendable {
    case preparationFailed
    case recognitionFailed
}

public struct WhisperFileChunkScreeningResult: Sendable {
    public let result: RecognitionPipelineValidator.Result
    public let excludedChunkIndices: [Int]

    public init(
        result: RecognitionPipelineValidator.Result,
        excludedChunkIndices: [Int]
    ) {
        self.result = result
        self.excludedChunkIndices = excludedChunkIndices
    }
}

public enum WhisperFileImportPolicy {
    private static let maximumShortForcedTailDuration: TimeInterval = 1.25
    private static let forcedTailHeadroomDuration: TimeInterval = 2
    private static let maximumWhisperChunkDuration: TimeInterval = 30

    public static func route(
        isWhisper: Bool,
        mode: WhisperFileTranscriptionMode
    ) -> WhisperFileImportRoute {
        guard isWhisper, mode == .continuousFullAudio else { return .profileVAD }
        return .continuousFullAudio
    }

    public static func shouldFallback(after outcome: WhisperContinuousAttemptOutcome) -> Bool {
        outcome == .failed
    }

    public static func fallbackDescription(for reason: WhisperFileImportFallbackReason) -> String {
        switch reason {
        case .preparationFailed:
            return "Continuous Full Audio was unavailable. Retrying once with Profile VAD and Standard boundaries."
        case .recognitionFailed:
            return "Continuous Full Audio failed. Retrying once with Profile VAD and Standard boundaries."
        }
    }

    public static func continuousChunks(
        samples: [Float],
        sampleRate: Double
    ) -> [AudioChunk] {
        [
            AudioChunk(
                samples: samples,
                sampleRate: sampleRate,
                boundaryReason: .stopped
            )
        ]
    }

    public static func mergingShortForcedTail(
        in result: RecognitionPipelineValidator.Result,
        segmenterConfiguration: AudioSegmenter.Configuration
    ) -> RecognitionPipelineValidator.Result {
        let profileMaximum =
            segmenterConfiguration.maximumChunkDuration.isFinite
            ? max(0, segmenterConfiguration.maximumChunkDuration) : 0
        let chunks = mergeShortForcedTails(
            result.chunks,
            overlapDuration: segmenterConfiguration.overlapDuration,
            maximumMergedDuration: min(
                maximumWhisperChunkDuration,
                profileMaximum + forcedTailHeadroomDuration
            )
        )
        guard chunks.count != result.chunks.count else { return result }

        return RecognitionPipelineValidator.Result(
            chunks: chunks,
            summary: RecognitionPipelineValidationSummary(
                capturedDuration: result.summary.capturedDuration,
                minimumAcceptedDuration: result.summary.minimumAcceptedDuration,
                acceptedByRecordingPolicy: result.summary.acceptedByRecordingPolicy,
                chunks: chunks.map { validationSummary(for: $0) },
                rejectedResultCount: result.summary.rejectedResultCount
            )
        )
    }

    /// Rechecks only long forced chunks in isolation. Resetting the neural VAD
    /// prevents speech state from leaking across a hard boundary and admitting
    /// an entire low-level non-speech chunk. Missing evidence always fails open.
    public static func screeningForcedChunks(
        in result: RecognitionPipelineValidator.Result,
        detectsIsolatedSpeech: (AudioChunk) -> Bool?
    ) -> WhisperFileChunkScreeningResult {
        var chunks: [AudioChunk] = []
        var excludedIndices: [Int] = []
        chunks.reserveCapacity(result.chunks.count)

        for (index, chunk) in result.chunks.enumerated() {
            let shouldCheck =
                chunk.boundaryReason == .maximumDuration
                && chunk.speechEvidenceAnalyzed
                && chunk.duration >= 1
            if shouldCheck, detectsIsolatedSpeech(chunk) == false {
                excludedIndices.append(index)
            } else {
                chunks.append(chunk)
            }
        }

        guard !excludedIndices.isEmpty else {
            return WhisperFileChunkScreeningResult(
                result: result,
                excludedChunkIndices: []
            )
        }
        return WhisperFileChunkScreeningResult(
            result: RecognitionPipelineValidator.Result(
                chunks: chunks,
                summary: RecognitionPipelineValidationSummary(
                    capturedDuration: result.summary.capturedDuration,
                    minimumAcceptedDuration: result.summary.minimumAcceptedDuration,
                    acceptedByRecordingPolicy: result.summary.acceptedByRecordingPolicy,
                    chunks: chunks.map(validationSummary(for:)),
                    rejectedResultCount: result.summary.rejectedResultCount
                )
            ),
            excludedChunkIndices: excludedIndices
        )
    }

    public static func terminalPresentation(
        hasText: Bool,
        failedChunkCount: Int
    ) -> WhisperFileImportTerminalPresentation {
        guard failedChunkCount <= 0 else { return .partialIssue }
        return hasText ? .interactive : .noSpeech
    }

    private static func mergeShortForcedTails(
        _ chunks: [AudioChunk],
        overlapDuration: TimeInterval,
        maximumMergedDuration: TimeInterval
    ) -> [AudioChunk] {
        guard chunks.count > 1, maximumMergedDuration > 0 else { return chunks }

        var mergedChunks: [AudioChunk] = []
        mergedChunks.reserveCapacity(chunks.count)
        for chunk in chunks {
            guard let previous = mergedChunks.last,
                let merged = merge(
                    previous,
                    with: chunk,
                    overlapDuration: overlapDuration,
                    maximumMergedDuration: maximumMergedDuration
                )
            else {
                mergedChunks.append(chunk)
                continue
            }
            mergedChunks[mergedChunks.count - 1] = merged
        }
        return mergedChunks
    }

    private static func merge(
        _ previous: AudioChunk,
        with tail: AudioChunk,
        overlapDuration: TimeInterval,
        maximumMergedDuration: TimeInterval
    ) -> AudioChunk? {
        guard
            previous.boundaryReason == .maximumDuration
                || previous.boundaryReason == .balancedPause,
            tail.boundaryReason != .maximumDuration,
            previous.sampleRate.isFinite,
            previous.sampleRate > 0,
            previous.sampleRate == tail.sampleRate,
            tail.duration <= maximumShortForcedTailDuration
        else { return nil }

        let overlapCount: Int
        if previous.boundaryReason == .balancedPause,
            previous.trailingOverlapDuration == 0
        {
            overlapCount = 0
        } else {
            let maximumOverlapCount = min(
                tail.samples.count,
                previous.samples.count,
                sampleCount(duration: overlapDuration, sampleRate: previous.sampleRate)
            )
            let minimumOverlapCount = min(
                maximumOverlapCount,
                max(1, sampleCount(duration: 0.01, sampleRate: previous.sampleRate))
            )
            guard
                let matchedOverlapCount = stride(
                    from: maximumOverlapCount,
                    through: minimumOverlapCount,
                    by: -1
                ).first(where: { count in
                    previous.samples.suffix(count).elementsEqual(
                        tail.samples.prefix(count)
                    )
                })
            else { return nil }
            overlapCount = matchedOverlapCount
        }

        let appendedSamples = tail.samples.dropFirst(overlapCount)
        let mergedCount = previous.samples.count + appendedSamples.count
        guard
            mergedCount
                <= sampleCount(
                    duration: maximumMergedDuration,
                    sampleRate: previous.sampleRate
                )
        else { return nil }

        var samples = previous.samples
        samples.reserveCapacity(mergedCount)
        samples.append(contentsOf: appendedSamples)
        let evidenceAnalyzed =
            previous.speechEvidenceAnalyzed && tail.speechEvidenceAnalyzed
        return AudioChunk(
            id: previous.id,
            samples: samples,
            sampleRate: previous.sampleRate,
            boundaryReason: tail.boundaryReason,
            trailingOverlapDuration: tail.trailingOverlapDuration,
            speechRange: evidenceAnalyzed
                ? mergedSpeechRange(
                    previous: previous,
                    tail: tail,
                    overlapCount: overlapCount,
                    mergedCount: mergedCount
                ) : nil,
            speechEvidenceAnalyzed: evidenceAnalyzed
        )
    }

    private static func mergedSpeechRange(
        previous: AudioChunk,
        tail: AudioChunk,
        overlapCount: Int,
        mergedCount: Int
    ) -> Range<Int>? {
        var lower = previous.speechRange?.lowerBound
        var upper = previous.speechRange?.upperBound
        if let tailRange = tail.speechRange {
            let shiftedLower = min(
                mergedCount,
                max(0, previous.samples.count + tailRange.lowerBound - overlapCount)
            )
            let shiftedUpper = min(
                mergedCount,
                max(shiftedLower, previous.samples.count + tailRange.upperBound - overlapCount)
            )
            if shiftedLower < shiftedUpper {
                lower = min(lower ?? shiftedLower, shiftedLower)
                upper = max(upper ?? shiftedUpper, shiftedUpper)
            }
        }
        guard let lower, let upper, lower < upper else { return nil }
        return lower..<upper
    }

    private static func validationSummary(
        for chunk: AudioChunk
    ) -> RecognitionPipelineValidationChunk {
        let speechDuration: TimeInterval
        if chunk.speechEvidenceAnalyzed {
            speechDuration = Double(chunk.speechRange?.count ?? 0) / chunk.sampleRate
        } else {
            speechDuration = chunk.duration
        }
        return RecognitionPipelineValidationChunk(
            boundaryReason: chunk.boundaryReason,
            duration: chunk.duration,
            speechDuration: speechDuration,
            trailingOverlapDuration: chunk.trailingOverlapDuration
        )
    }

    private static func sampleCount(duration: TimeInterval, sampleRate: Double) -> Int {
        guard duration.isFinite, duration >= 0,
            sampleRate.isFinite, sampleRate > 0
        else { return 0 }
        let count = (duration * sampleRate).rounded()
        guard count.isFinite, count < Double(Int.max) else { return Int.max }
        return max(0, Int(count))
    }
}
