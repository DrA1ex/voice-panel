import Foundation
import VoicePanelCore

typealias WhisperBoundaryTranscriber =
    @Sendable (
        [Float],
        String,
        WhisperInferenceConfiguration,
        String,
        WhisperInferenceMetadataLevel
    ) async throws -> WhisperTranscriptionResult

struct WhisperProcessedSegmentRevision: Sendable {
    let segmentID: UUID
    let sequence: Int
    let text: String
}

enum WhisperProcessedChunkFailure: Equatable, Sendable {
    case baselineFailed(String)
    case cancelled
}

struct WhisperProcessedChunk: Sendable {
    let baseline: WhisperTranscriptionResult?
    let revisions: [WhisperProcessedSegmentRevision]
    let diagnostics: WhisperBoundaryRepairDiagnostics
    let failure: WhisperProcessedChunkFailure?
    let bridgeDuration: TimeInterval?

    init(
        baseline: WhisperTranscriptionResult?,
        revisions: [WhisperProcessedSegmentRevision],
        diagnostics: WhisperBoundaryRepairDiagnostics,
        failure: WhisperProcessedChunkFailure?,
        bridgeDuration: TimeInterval? = nil
    ) {
        self.baseline = baseline
        self.revisions = revisions
        self.diagnostics = diagnostics
        self.failure = failure
        self.bridgeDuration = bridgeDuration
    }

    var diagnosticMetadata: [String: String] {
        var metadata = [
            "accepted": String(diagnostics.accepted),
            "attempted": String(diagnostics.attempted),
            "baselineBoundaryWords": String(
                diagnostics.changedBoundaryWordCounts.baseline
            ),
            "inferenceMilliseconds": String(Int(diagnostics.inferenceDuration * 1_000)),
            "inferences": String(diagnostics.inferenceCount),
            "reason": diagnostics.reasonCode.rawValue,
            "replacementBoundaryWords": String(
                diagnostics.changedBoundaryWordCounts.replacement
            ),
            "strategy": diagnostics.strategy.rawValue,
        ]
        if let bridgeDuration {
            let boundedDuration =
                bridgeDuration.isFinite
                ? min(max(0, bridgeDuration), 7) : 0
            metadata["bridgeMilliseconds"] = String(Int(boundedDuration * 1_000))
        }
        return metadata
    }
}

actor WhisperBoundaryProcessor {
    private let configuration: WhisperInferenceConfiguration
    private let languageCode: String
    private let hallucinationGuardConfiguration: RecognitionHallucinationGuard.Configuration
    private let hallucinationGuard = RecognitionHallucinationGuard()
    private let monotonicNow: @Sendable () -> TimeInterval
    private let transcribe: WhisperBoundaryTranscriber

    private var state = WhisperBoundarySessionState()
    private var generation = 0

    init(
        configuration: WhisperInferenceConfiguration,
        languageCode: String,
        hallucinationGuardConfiguration: RecognitionHallucinationGuard.Configuration,
        monotonicNow: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        transcribe: @escaping WhisperBoundaryTranscriber
    ) {
        self.configuration = configuration
        self.languageCode = languageCode
        self.hallucinationGuardConfiguration = hallucinationGuardConfiguration
        self.monotonicNow = monotonicNow
        self.transcribe = transcribe
    }

    func process(chunk: AudioChunk, sequence: Int) async -> WhisperProcessedChunk {
        let expectedGeneration = generation
        let previous = state.contextualRetrySource
        let metadataLevel = baselineMetadataLevel
        let baselineStarted = monotonicNow()
        let rawBaseline: WhisperTranscriptionResult

        do {
            rawBaseline = try await transcribe(
                chunk.samples,
                languageCode,
                configuration,
                configuration.normalizedInitialPrompt,
                metadataLevel
            )
        } catch is CancellationError {
            if generation == expectedGeneration { state.recordCancellation() }
            return failedChunk(
                reason: .baselineCancelled,
                inferenceDuration: monotonicNow() - baselineStarted,
                failure: .cancelled
            )
        } catch {
            if generation == expectedGeneration { state.recordError() }
            return failedChunk(
                reason: .baselineFailed,
                inferenceDuration: monotonicNow() - baselineStarted,
                failure: .baselineFailed(error.localizedDescription)
            )
        }

        let baseline = hallucinationGuard.filteringLowSignalArtifacts(
            from: rawBaseline, chunk: chunk, configuration: hallucinationGuardConfiguration
        )
        let baselineRevision = WhisperProcessedSegmentRevision(
            segmentID: chunk.id,
            sequence: sequence,
            text: baseline.text
        )
        guard generation == expectedGeneration else {
            return baselineChunk(
                baseline: baseline,
                revision: baselineRevision,
                reason: .candidateCancelled
            )
        }
        guard !rawBaseline.text.isEmpty else {
            state.recordEmptyOutput()
            return WhisperProcessedChunk(
                baseline: baseline,
                revisions: [],
                diagnostics: diagnostics(
                    attempted: false,
                    accepted: false,
                    reason: .baselineEmpty,
                    inferenceCount: 1,
                    inferenceDuration: baseline.inferenceDuration
                ),
                failure: nil
            )
        }
        if baseline.text.isEmpty
            || hallucinationGuard.rejectionReason(
                for: baseline.text,
                chunk: chunk,
                configuration: hallucinationGuardConfiguration
            ) != nil
        {
            state.recordRejectedHallucination()
            return WhisperProcessedChunk(
                baseline: rawBaseline,
                revisions: [],
                diagnostics: diagnostics(
                    attempted: false,
                    accepted: false,
                    reason: .baselineRejectedHallucination,
                    inferenceCount: 1,
                    inferenceDuration: baseline.inferenceDuration
                ),
                failure: nil
            )
        }

        let baselineChunk = WhisperBoundaryAcceptedChunk(
            segmentID: chunk.id,
            sequence: sequence,
            result: baseline,
            boundaryReason: chunk.boundaryReason,
            audioDuration: chunk.duration
        )

        if configuration.boundaryStrategy == .boundaryBridge {
            return await processBoundaryBridge(
                baseline: baseline,
                baselineChunk: baselineChunk,
                baselineRevision: baselineRevision,
                previous: state.boundaryBridgeSource,
                chunk: chunk,
                expectedGeneration: expectedGeneration
            )
        }
        guard configuration.boundaryStrategy == .contextualRetry else {
            state.recordAccepted(baselineChunk)
            return self.baselineChunk(
                baseline: baseline,
                revision: baselineRevision,
                reason: .baselineOnly
            )
        }
        guard let previous, previous.boundaryReason == .maximumDuration else {
            state.recordAccepted(baselineChunk)
            return self.baselineChunk(
                baseline: baseline,
                revision: baselineRevision,
                reason: .previousBoundaryUnavailable
            )
        }
        let suspicion = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: previous.boundaryReason,
            previous: previous.result,
            current: baseline,
            currentAudioDuration: chunk.duration
        )
        guard !suspicion.isEmpty else {
            state.recordAccepted(baselineChunk)
            return self.baselineChunk(
                baseline: baseline,
                revision: baselineRevision,
                reason: .notSuspicious
            )
        }

        state.recordRepairAttempt()
        let retryPrompt = WhisperBoundaryPromptBuilder.prompt(
            staticPrompt: configuration.initialPrompt,
            previous: previous.result,
            current: baseline,
            previousAudioDuration: previous.audioDuration,
            overlapDuration: configuration.overlapDuration,
            mode: configuration.contextPromptMode
        )
        let retryStarted = Date()
        let candidate: WhisperTranscriptionResult
        do {
            candidate = try await transcribe(
                chunk.samples,
                languageCode,
                configuration,
                retryPrompt,
                metadataLevel
            )
        } catch is CancellationError {
            if Task.isCancelled || generation != expectedGeneration {
                if generation == expectedGeneration { state.recordCancellation() }
                return cancelledChunkAfterBaseline(
                    baseline: baseline,
                    inferenceDuration: baseline.inferenceDuration
                        + Date().timeIntervalSince(retryStarted)
                )
            }
            return rejectAlternative(
                baseline: baseline,
                baselineChunk: baselineChunk,
                revision: baselineRevision,
                reason: .candidateCancelled,
                inferenceDuration: baseline.inferenceDuration
                    + Date().timeIntervalSince(retryStarted),
                expectedGeneration: expectedGeneration
            )
        } catch {
            if Task.isCancelled || generation != expectedGeneration {
                if generation == expectedGeneration { state.recordCancellation() }
                return cancelledChunkAfterBaseline(
                    baseline: baseline,
                    inferenceDuration: baseline.inferenceDuration
                        + Date().timeIntervalSince(retryStarted)
                )
            }
            return rejectAlternative(
                baseline: baseline,
                baselineChunk: baselineChunk,
                revision: baselineRevision,
                reason: .candidateFailed,
                inferenceDuration: baseline.inferenceDuration
                    + Date().timeIntervalSince(retryStarted),
                expectedGeneration: expectedGeneration
            )
        }

        guard !Task.isCancelled, generation == expectedGeneration else {
            if generation == expectedGeneration { state.recordCancellation() }
            return cancelledChunkAfterBaseline(
                baseline: baseline,
                inferenceDuration: baseline.inferenceDuration + candidate.inferenceDuration
            )
        }
        guard !candidate.text.isEmpty else {
            return rejectAlternative(
                baseline: baseline,
                baselineChunk: baselineChunk,
                revision: baselineRevision,
                reason: .candidateEmpty,
                inferenceDuration: baseline.inferenceDuration + candidate.inferenceDuration,
                expectedGeneration: expectedGeneration
            )
        }
        if hallucinationGuard.rejectionReason(
            for: candidate,
            chunk: chunk,
            configuration: hallucinationGuardConfiguration
        ) != nil {
            return rejectAlternative(
                baseline: baseline,
                baselineChunk: baselineChunk,
                revision: baselineRevision,
                reason: .candidateRejectedHallucination,
                inferenceDuration: baseline.inferenceDuration + candidate.inferenceDuration,
                expectedGeneration: expectedGeneration
            )
        }

        let decision = WhisperBoundaryRepairPolicy.contextualPatch(
            previous: previous.result,
            baseline: baseline,
            candidate: candidate
        )
        switch decision {
        case .rejected(_, let reason):
            return rejectAlternative(
                baseline: baseline,
                baselineChunk: baselineChunk,
                revision: baselineRevision,
                reason: Self.reasonCode(for: reason),
                inferenceDuration: baseline.inferenceDuration + candidate.inferenceDuration,
                expectedGeneration: expectedGeneration
            )

        case .accepted(let patch):
            let repaired = WhisperTranscriptionResult(
                text: patch.text,
                segments: baseline.segments,
                detectedLanguage: baseline.detectedLanguage,
                inferenceDuration: baseline.inferenceDuration
            )
            let revisedChunk = state.contextualRevision(from: baselineChunk, result: repaired)
            state.recordAccepted(revisedChunk)
            return WhisperProcessedChunk(
                baseline: baseline,
                revisions: [
                    baselineRevision,
                    WhisperProcessedSegmentRevision(
                        segmentID: revisedChunk.segmentID,
                        sequence: revisedChunk.sequence,
                        text: revisedChunk.result.text
                    ),
                ],
                diagnostics: diagnostics(
                    attempted: true,
                    accepted: true,
                    reason: .accepted,
                    inferenceCount: 2,
                    inferenceDuration: baseline.inferenceDuration + candidate.inferenceDuration,
                    changedWordCounts: .init(
                        baseline: patch.baselinePrefixWordCount,
                        replacement: patch.candidatePrefixWordCount
                    )
                ),
                failure: nil
            )
        }
    }

    func reset() {
        generation += 1
        state.reset()
    }

    private var baselineMetadataLevel: WhisperInferenceMetadataLevel {
        if configuration.boundaryStrategy == .contextualRetry
            && configuration.contextPromptMode == .timestampAligned
        {
            return .tokenTimestamps
        }
        return hallucinationGuardConfiguration.isEnabled ? .segmentTimestamps : .segments
    }

    private func processBoundaryBridge(
        baseline: WhisperTranscriptionResult,
        baselineChunk: WhisperBoundaryAcceptedChunk,
        baselineRevision: WhisperProcessedSegmentRevision,
        previous: WhisperBoundaryBridgeSource?,
        chunk: AudioChunk,
        expectedGeneration: Int
    ) async -> WhisperProcessedChunk {
        guard let previous,
            previous.boundaryReason == .maximumDuration,
            previous.sampleRate == chunk.sampleRate,
            let bridge = WhisperBoundaryBridgeBuilder.make(
                previousSamples: previous.resampledSamples,
                currentSamples: chunk.samples,
                sampleRate: previous.sampleRate,
                overlapDuration: configuration.overlapDuration,
                sideDuration: 3.5
            )
        else {
            state.recordAccepted(
                baselineChunk,
                resampledSamples: chunk.samples,
                sampleRate: chunk.sampleRate
            )
            return self.baselineChunk(
                baseline: baseline,
                revision: baselineRevision,
                reason: .previousBoundaryUnavailable
            )
        }
        let suspicion = WhisperBoundaryRepairPolicy.assess(
            previousBoundaryReason: previous.boundaryReason,
            previous: previous.result,
            current: baseline,
            currentAudioDuration: chunk.duration
        )
        guard !suspicion.isEmpty else {
            state.recordAccepted(
                baselineChunk,
                resampledSamples: chunk.samples,
                sampleRate: chunk.sampleRate
            )
            return self.baselineChunk(
                baseline: baseline,
                revision: baselineRevision,
                reason: .notSuspicious
            )
        }

        state.recordRepairAttempt()
        let bridgeDuration = Double(bridge.samples.count) / previous.sampleRate
        let started = Date()
        let candidate: WhisperTranscriptionResult
        do {
            candidate = try await transcribe(
                bridge.samples,
                languageCode,
                configuration,
                configuration.normalizedInitialPrompt,
                .tokenTimestamps
            )
        } catch is CancellationError {
            if Task.isCancelled || generation != expectedGeneration {
                if generation == expectedGeneration { state.recordCancellation() }
                return cancelledChunkAfterBaseline(
                    baseline: baseline,
                    inferenceDuration: baseline.inferenceDuration
                        + Date().timeIntervalSince(started),
                    bridgeDuration: bridgeDuration
                )
            }
            state.recordCancellation()
            return rejectBoundaryBridge(
                baseline: baseline,
                revision: baselineRevision,
                reason: .candidateCancelled,
                inferenceDuration: baseline.inferenceDuration
                    + Date().timeIntervalSince(started),
                bridgeDuration: bridgeDuration
            )
        } catch {
            if Task.isCancelled || generation != expectedGeneration {
                if generation == expectedGeneration { state.recordCancellation() }
                return cancelledChunkAfterBaseline(
                    baseline: baseline,
                    inferenceDuration: baseline.inferenceDuration
                        + Date().timeIntervalSince(started),
                    bridgeDuration: bridgeDuration
                )
            }
            state.recordCandidateFailure()
            return rejectBoundaryBridge(
                baseline: baseline,
                revision: baselineRevision,
                reason: .candidateFailed,
                inferenceDuration: baseline.inferenceDuration
                    + Date().timeIntervalSince(started),
                bridgeDuration: bridgeDuration
            )
        }

        guard !Task.isCancelled, generation == expectedGeneration else {
            if generation == expectedGeneration { state.recordCancellation() }
            return cancelledChunkAfterBaseline(
                baseline: baseline,
                inferenceDuration: baseline.inferenceDuration + candidate.inferenceDuration,
                bridgeDuration: bridgeDuration
            )
        }
        guard !candidate.text.isEmpty else {
            return rejectBoundaryBridgeCandidate(
                baseline: baseline,
                baselineChunk: baselineChunk,
                revision: baselineRevision,
                chunk: chunk,
                reason: .candidateEmpty,
                inferenceDuration: baseline.inferenceDuration + candidate.inferenceDuration,
                bridgeDuration: bridgeDuration
            )
        }
        let candidateFilterChunk = AudioChunk(
            samples: bridge.samples,
            sampleRate: previous.sampleRate,
            boundaryReason: chunk.boundaryReason
        )
        if hallucinationGuard.rejectionReason(
            for: candidate,
            chunk: candidateFilterChunk,
            configuration: hallucinationGuardConfiguration
        ) != nil {
            return rejectBoundaryBridgeCandidate(
                baseline: baseline,
                baselineChunk: baselineChunk,
                revision: baselineRevision,
                chunk: chunk,
                reason: .candidateRejectedHallucination,
                inferenceDuration: baseline.inferenceDuration + candidate.inferenceDuration,
                bridgeDuration: bridgeDuration
            )
        }
        guard
            let patch = WhisperBoundaryRepairPolicy.bridgePatch(
                previous: previous.result,
                current: baseline,
                bridge: candidate,
                cutTime: bridge.cutTime
            )
        else {
            return rejectBoundaryBridgeCandidate(
                baseline: baseline,
                baselineChunk: baselineChunk,
                revision: baselineRevision,
                chunk: chunk,
                reason: .missingStableAnchor,
                inferenceDuration: baseline.inferenceDuration + candidate.inferenceDuration,
                bridgeDuration: bridgeDuration
            )
        }

        let revisedCurrentResult = WhisperTranscriptionResult(
            text: patch.currentText,
            segments: baseline.segments,
            detectedLanguage: baseline.detectedLanguage,
            inferenceDuration: baseline.inferenceDuration
        )
        let revisedCurrent = state.contextualRevision(
            from: baselineChunk,
            result: revisedCurrentResult
        )
        state.recordAccepted(
            revisedCurrent,
            resampledSamples: chunk.samples,
            sampleRate: chunk.sampleRate
        )
        return WhisperProcessedChunk(
            baseline: baseline,
            revisions: [
                WhisperProcessedSegmentRevision(
                    segmentID: previous.segmentID,
                    sequence: previous.sequence,
                    text: patch.previousText
                ),
                WhisperProcessedSegmentRevision(
                    segmentID: revisedCurrent.segmentID,
                    sequence: revisedCurrent.sequence,
                    text: revisedCurrent.result.text
                ),
            ],
            diagnostics: diagnostics(
                attempted: true,
                accepted: true,
                reason: .accepted,
                inferenceCount: 2,
                inferenceDuration: baseline.inferenceDuration + candidate.inferenceDuration,
                changedWordCounts: .init(
                    baseline: patch.removedBoundaryWordCount,
                    replacement: patch.replacementBoundaryWordCount
                )
            ),
            failure: nil,
            bridgeDuration: bridgeDuration
        )
    }

    private func rejectBoundaryBridgeCandidate(
        baseline: WhisperTranscriptionResult,
        baselineChunk: WhisperBoundaryAcceptedChunk,
        revision: WhisperProcessedSegmentRevision,
        chunk: AudioChunk,
        reason: WhisperBoundaryRepairReasonCode,
        inferenceDuration: TimeInterval,
        bridgeDuration: TimeInterval
    ) -> WhisperProcessedChunk {
        state.recordRepairRejection()
        state.recordAccepted(
            baselineChunk,
            resampledSamples: chunk.samples,
            sampleRate: chunk.sampleRate
        )
        return rejectBoundaryBridge(
            baseline: baseline,
            revision: revision,
            reason: reason,
            inferenceDuration: inferenceDuration,
            bridgeDuration: bridgeDuration
        )
    }

    private func rejectBoundaryBridge(
        baseline: WhisperTranscriptionResult,
        revision: WhisperProcessedSegmentRevision,
        reason: WhisperBoundaryRepairReasonCode,
        inferenceDuration: TimeInterval,
        bridgeDuration: TimeInterval
    ) -> WhisperProcessedChunk {
        WhisperProcessedChunk(
            baseline: baseline,
            revisions: [revision],
            diagnostics: diagnostics(
                attempted: true,
                accepted: false,
                reason: reason,
                inferenceCount: 2,
                inferenceDuration: inferenceDuration
            ),
            failure: nil,
            bridgeDuration: bridgeDuration
        )
    }

    private func rejectAlternative(
        baseline: WhisperTranscriptionResult,
        baselineChunk: WhisperBoundaryAcceptedChunk,
        revision: WhisperProcessedSegmentRevision,
        reason: WhisperBoundaryRepairReasonCode,
        inferenceDuration: TimeInterval,
        expectedGeneration: Int
    ) -> WhisperProcessedChunk {
        if generation == expectedGeneration {
            state.recordRepairRejection()
            state.recordAccepted(baselineChunk)
        }
        return self.baselineChunk(
            baseline: baseline,
            revision: revision,
            attempted: true,
            reason: reason,
            inferenceCount: 2,
            inferenceDuration: inferenceDuration
        )
    }

    private func baselineChunk(
        baseline: WhisperTranscriptionResult,
        revision: WhisperProcessedSegmentRevision,
        attempted: Bool = false,
        reason: WhisperBoundaryRepairReasonCode,
        inferenceCount: Int = 1,
        inferenceDuration: TimeInterval? = nil
    ) -> WhisperProcessedChunk {
        WhisperProcessedChunk(
            baseline: baseline,
            revisions: [revision],
            diagnostics: diagnostics(
                attempted: attempted,
                accepted: false,
                reason: reason,
                inferenceCount: inferenceCount,
                inferenceDuration: inferenceDuration ?? baseline.inferenceDuration
            ),
            failure: nil
        )
    }

    private func failedChunk(
        reason: WhisperBoundaryRepairReasonCode,
        inferenceDuration: TimeInterval,
        failure: WhisperProcessedChunkFailure
    ) -> WhisperProcessedChunk {
        WhisperProcessedChunk(
            baseline: nil,
            revisions: [],
            diagnostics: diagnostics(
                attempted: false,
                accepted: false,
                reason: reason,
                inferenceCount: 1,
                inferenceDuration: inferenceDuration
            ),
            failure: failure
        )
    }

    private func cancelledChunkAfterBaseline(
        baseline: WhisperTranscriptionResult,
        inferenceDuration: TimeInterval,
        bridgeDuration: TimeInterval? = nil
    ) -> WhisperProcessedChunk {
        WhisperProcessedChunk(
            baseline: baseline,
            revisions: [],
            diagnostics: diagnostics(
                attempted: true,
                accepted: false,
                reason: .candidateCancelled,
                inferenceCount: 2,
                inferenceDuration: inferenceDuration
            ),
            failure: .cancelled,
            bridgeDuration: bridgeDuration
        )
    }

    private func diagnostics(
        attempted: Bool,
        accepted: Bool,
        reason: WhisperBoundaryRepairReasonCode,
        inferenceCount: Int,
        inferenceDuration: TimeInterval,
        changedWordCounts: WhisperBoundaryChangedWordCounts = .init(
            baseline: 0,
            replacement: 0
        )
    ) -> WhisperBoundaryRepairDiagnostics {
        WhisperBoundaryRepairDiagnostics(
            strategy: configuration.boundaryStrategy,
            attempted: attempted,
            accepted: accepted,
            reasonCode: reason,
            inferenceCount: inferenceCount,
            inferenceDuration: inferenceDuration,
            changedBoundaryWordCounts: changedWordCounts
        )
    }

    private static func reasonCode(
        for reason: WhisperBoundaryRepairRejectionReason
    ) -> WhisperBoundaryRepairReasonCode {
        switch reason {
        case .missingStableAnchor: return .missingStableAnchor
        case .punctuationLoss: return .punctuationLoss
        case .lowerTokenProbability: return .lowerTokenProbability
        case .repeatedTrigram: return .repeatedTrigram
        case .insufficientImprovement: return .insufficientImprovement
        }
    }
}
