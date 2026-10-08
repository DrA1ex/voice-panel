import Foundation
import VoicePanelCore

struct WhisperBoundaryBenchmarkRawChunk: Codable, Equatable, Sendable {
    let sequence: Int
    let baselineText: String
    let candidateText: String?
}

struct WhisperBoundaryBenchmarkExplicitReport: Codable, Equatable, Sendable {
    let variantIdentifier: String
    let chunks: [WhisperBoundaryBenchmarkRawChunk]
}

struct WhisperBoundaryBenchmarkExecution: Sendable {
    let entry: WhisperBenchmarkMatrixEntry
    let transcript: String
    let pipelineSummary: RecognitionPipelineValidationSummary?
    let diagnostics: [WhisperBoundaryRepairDiagnostics]
    let processingDuration: TimeInterval
    let executedAudioDuration: TimeInterval
    let fallbackCount: Int
    let explicitReport: WhisperBoundaryBenchmarkExplicitReport

    var inferenceCount: Int {
        diagnostics.reduce(0) { $0 + $1.inferenceCount }
    }

    var repairAttemptCount: Int {
        diagnostics.reduce(0) { $0 + ($1.attempted ? 1 : 0) }
    }

    var acceptedRepairCount: Int {
        diagnostics.reduce(0) { $0 + ($1.accepted ? 1 : 0) }
    }
}

struct WhisperBoundaryBenchmarkExecutor {
    let vadConfiguration: VoiceActivityDetector.Configuration
    let segmenterConfiguration: AudioSegmenter.Configuration
    let detectionMode: VoiceActivityDetectionMode
    let inferenceConfiguration: WhisperInferenceConfiguration
    let languageCode: String
    let hallucinationGuardConfiguration: RecognitionHallucinationGuard.Configuration
    let neuralSpeechDetector: (@Sendable ([Float], Double) -> Bool?)?
    let transcribe: WhisperBoundaryTranscriber

    func execute(
        entry: WhisperBenchmarkMatrixEntry,
        samples sourceSamples: [Float]
    ) async throws -> WhisperBoundaryBenchmarkExecution {
        let startedAt = ProcessInfo.processInfo.systemUptime
        if entry.variant == .legacyContext {
            return try await executeLegacyContext(
                entry: entry,
                sourceSamples: sourceSamples,
                startedAt: startedAt
            )
        }

        let execution = await executeWithSharedProcessor(
            entry: entry,
            sourceSamples: sourceSamples
        )
        if entry.variant == .continuousFullAudio,
            execution.failed,
            WhisperFileImportPolicy.shouldFallback(after: .failed)
        {
            let fallbackEntry = WhisperBenchmarkMatrixEntry(
                variant: .standard,
                audioConfiguration: WhisperBenchmarkAudioConfiguration(
                    edgePadding: 0,
                    maximumChunkDurationOffset: 0
                )
            )
            let fallback = await executeWithSharedProcessor(
                entry: fallbackEntry,
                sourceSamples: sourceSamples
            )
            if fallback.cancelled { throw CancellationError() }
            if fallback.failed { throw RecognitionEngineError.inferenceFailed }
            return WhisperBoundaryBenchmarkExecution(
                entry: entry,
                transcript: fallback.transcript,
                pipelineSummary: fallback.pipelineSummary,
                diagnostics: execution.diagnostics + fallback.diagnostics,
                processingDuration: ProcessInfo.processInfo.systemUptime - startedAt,
                executedAudioDuration: execution.executedAudioDuration,
                fallbackCount: 1,
                explicitReport: WhisperBoundaryBenchmarkExplicitReport(
                    variantIdentifier: entry.variant.id,
                    chunks: execution.rawChunks + fallback.rawChunks
                )
            )
        }
        if execution.cancelled { throw CancellationError() }
        if execution.failed { throw RecognitionEngineError.inferenceFailed }

        return WhisperBoundaryBenchmarkExecution(
            entry: entry,
            transcript: execution.transcript,
            pipelineSummary: execution.pipelineSummary,
            diagnostics: execution.diagnostics,
            processingDuration: ProcessInfo.processInfo.systemUptime - startedAt,
            executedAudioDuration: execution.executedAudioDuration,
            fallbackCount: 0,
            explicitReport: WhisperBoundaryBenchmarkExplicitReport(
                variantIdentifier: entry.variant.id,
                chunks: execution.rawChunks
            )
        )
    }

    private func executeWithSharedProcessor(
        entry: WhisperBenchmarkMatrixEntry,
        sourceSamples: [Float]
    ) async -> ProcessorExecution {
        let prepared = prepareAudio(entry: entry, sourceSamples: sourceSamples)
        let configuration = inferenceConfiguration(for: entry.variant)
        let evidence = WhisperBoundaryBenchmarkEvidenceCollector()
        let processor = WhisperBoundaryProcessor(
            configuration: configuration,
            languageCode: languageCode,
            hallucinationGuardConfiguration: hallucinationGuardConfiguration,
            transcribe: { samples, language, configuration, prompt, metadata in
                let result = try await transcribe(
                    samples,
                    language,
                    configuration,
                    prompt,
                    metadata
                )
                await evidence.record(result.text)
                return result
            }
        )

        var revisions: [Int: String] = [:]
        var diagnostics: [WhisperBoundaryRepairDiagnostics] = []
        for (sequence, chunk) in prepared.chunks.enumerated() {
            if Task.isCancelled {
                await processor.reset()
                return ProcessorExecution.cancelled(
                    summary: prepared.summary,
                    executedAudioDuration: prepared.executedAudioDuration,
                    diagnostics: diagnostics,
                    rawChunks: await evidence.snapshot()
                )
            }
            await evidence.beginChunk(sequence)
            let output = await processor.process(chunk: chunk, sequence: sequence)
            diagnostics.append(output.diagnostics)
            for revision in output.revisions {
                revisions[revision.sequence] = revision.text
            }
            if output.failure == .cancelled {
                return ProcessorExecution.cancelled(
                    summary: prepared.summary,
                    executedAudioDuration: prepared.executedAudioDuration,
                    diagnostics: diagnostics,
                    rawChunks: await evidence.snapshot()
                )
            }
            if output.failure != nil {
                return ProcessorExecution.failed(
                    summary: prepared.summary,
                    executedAudioDuration: prepared.executedAudioDuration,
                    diagnostics: diagnostics,
                    rawChunks: await evidence.snapshot()
                )
            }
        }

        return ProcessorExecution(
            transcript: TranscriptTextMerger.merge(
                revisions.keys.sorted().compactMap { revisions[$0] }
            ),
            pipelineSummary: summary(
                prepared.summary,
                includingRejectionsFrom: diagnostics
            ),
            executedAudioDuration: prepared.executedAudioDuration,
            diagnostics: diagnostics,
            rawChunks: await evidence.snapshot(),
            failed: false,
            cancelled: false
        )
    }

    private func executeLegacyContext(
        entry: WhisperBenchmarkMatrixEntry,
        sourceSamples: [Float],
        startedAt: TimeInterval
    ) async throws -> WhisperBoundaryBenchmarkExecution {
        let prepared = prepareAudio(entry: entry, sourceSamples: sourceSamples)
        let configuration = inferenceConfiguration(for: .standard)
        var previous: (result: WhisperTranscriptionResult, chunk: AudioChunk)?
        var texts: [String] = []
        var diagnostics: [WhisperBoundaryRepairDiagnostics] = []
        var rawChunks: [WhisperBoundaryBenchmarkRawChunk] = []

        for (sequence, chunk) in prepared.chunks.enumerated() {
            try Task.checkCancellation()
            let usedContext = previous?.chunk.boundaryReason == .maximumDuration
            let prompt: String
            if let previous, usedContext {
                prompt = WhisperBoundaryPromptBuilder.prompt(
                    staticPrompt: inferenceConfiguration.initialPrompt,
                    previous: previous.result,
                    current: WhisperTranscriptionResult(
                        text: "",
                        segments: [],
                        detectedLanguage: "",
                        inferenceDuration: 0
                    ),
                    previousAudioDuration: previous.chunk.duration,
                    overlapDuration: inferenceConfiguration.overlapDuration,
                    mode: .legacyFixedWords
                )
            } else {
                prompt = inferenceConfiguration.normalizedInitialPrompt
            }
            let result = try await transcribe(
                chunk.samples,
                languageCode,
                configuration,
                prompt,
                .segments
            )
            rawChunks.append(
                WhisperBoundaryBenchmarkRawChunk(
                    sequence: sequence,
                    baselineText: result.text,
                    candidateText: nil
                )
            )
            let reasonCode: WhisperBoundaryRepairReasonCode
            if result.text.isEmpty {
                reasonCode = .baselineEmpty
                previous = nil
            } else if RecognitionHallucinationGuard().rejectionReason(
                for: result.text,
                chunk: chunk,
                configuration: hallucinationGuardConfiguration
            ) != nil {
                reasonCode = .baselineRejectedHallucination
                previous = nil
            } else {
                reasonCode = .baselineOnly
                texts.append(result.text)
                previous = (result, chunk)
            }
            diagnostics.append(
                WhisperBoundaryRepairDiagnostics(
                    strategy: .contextualRetry,
                    attempted: usedContext,
                    accepted: false,
                    reasonCode: reasonCode,
                    inferenceCount: 1,
                    inferenceDuration: result.inferenceDuration,
                    changedBoundaryWordCounts: .init(baseline: 0, replacement: 0)
                )
            )
        }

        return WhisperBoundaryBenchmarkExecution(
            entry: entry,
            transcript: TranscriptTextMerger.merge(texts),
            pipelineSummary: summary(
                prepared.summary,
                includingRejectionsFrom: diagnostics
            ),
            diagnostics: diagnostics,
            processingDuration: ProcessInfo.processInfo.systemUptime - startedAt,
            executedAudioDuration: prepared.executedAudioDuration,
            fallbackCount: 0,
            explicitReport: WhisperBoundaryBenchmarkExplicitReport(
                variantIdentifier: entry.variant.id,
                chunks: rawChunks
            )
        )
    }

    private func prepareAudio(
        entry: WhisperBenchmarkMatrixEntry,
        sourceSamples: [Float]
    ) -> (
        chunks: [AudioChunk],
        summary: RecognitionPipelineValidationSummary?,
        executedAudioDuration: TimeInterval
    ) {
        guard entry.variant != .continuousFullAudio else {
            return (
                [
                    AudioChunk(
                        samples: sourceSamples,
                        sampleRate: 16_000,
                        boundaryReason: .stopped
                    )
                ],
                nil,
                Double(sourceSamples.count) / 16_000
            )
        }

        let audioConfiguration =
            entry.audioConfiguration
            ?? WhisperBenchmarkAudioConfiguration(
                edgePadding: 0,
                maximumChunkDurationOffset: 0
            )
        let samples = audioConfiguration.paddedSamples(sourceSamples, sampleRate: 16_000)
        var adjustedSegmenterConfiguration = segmenterConfiguration
        adjustedSegmenterConfiguration.maximumChunkDuration =
            audioConfiguration.maximumChunkDuration(
                from: segmenterConfiguration.maximumChunkDuration
            )
        let segmented = RecognitionPipelineValidator.process(
            samples: samples,
            sampleRate: 16_000,
            vadConfiguration: vadConfiguration,
            segmenterConfiguration: adjustedSegmenterConfiguration,
            detectionMode: detectionMode,
            minimumAcceptedDuration: RecordingStopPolicy.defaultMinimumDuration,
            neuralSpeechDetector: neuralSpeechDetector
        )
        let result = WhisperFileImportPolicy.mergingShortForcedTail(
            in: segmented,
            segmenterConfiguration: adjustedSegmenterConfiguration
        )
        return (result.chunks, result.summary, result.summary.capturedDuration)
    }

    private func summary(
        _ pipelineSummary: RecognitionPipelineValidationSummary?,
        includingRejectionsFrom diagnostics: [WhisperBoundaryRepairDiagnostics]
    ) -> RecognitionPipelineValidationSummary? {
        let rejectionCount = diagnostics.filter {
            $0.reasonCode == .baselineRejectedHallucination
        }.count
        return pipelineSummary?.withRejectedResultCount(rejectionCount)
    }

    private func inferenceConfiguration(
        for variant: WhisperBenchmarkVariant
    ) -> WhisperInferenceConfiguration {
        let strategy: WhisperBoundaryStrategy
        let promptMode: WhisperContextPromptMode
        switch variant {
        case .standard, .legacyContext, .continuousFullAudio:
            strategy = .standard
            promptMode = inferenceConfiguration.contextPromptMode
        case .contextualRetry(let mode):
            strategy = .contextualRetry
            promptMode = mode
        case .boundaryBridge:
            strategy = .boundaryBridge
            promptMode = inferenceConfiguration.contextPromptMode
        }
        return WhisperInferenceConfiguration(
            numberOfThreads: inferenceConfiguration.numberOfThreads,
            usesCustomDecoding: inferenceConfiguration.usesCustomDecoding,
            decodingStrategy: inferenceConfiguration.decodingStrategy,
            greedyBestOf: inferenceConfiguration.greedyBestOf,
            beamSize: inferenceConfiguration.beamSize,
            initialPrompt: inferenceConfiguration.initialPrompt,
            boundaryStrategy: strategy,
            overlapDuration: inferenceConfiguration.overlapDuration,
            contextPromptMode: promptMode
        )
    }
}

private struct ProcessorExecution {
    let transcript: String
    let pipelineSummary: RecognitionPipelineValidationSummary?
    let executedAudioDuration: TimeInterval
    let diagnostics: [WhisperBoundaryRepairDiagnostics]
    let rawChunks: [WhisperBoundaryBenchmarkRawChunk]
    let failed: Bool
    let cancelled: Bool

    static func failed(
        summary: RecognitionPipelineValidationSummary?,
        executedAudioDuration: TimeInterval,
        diagnostics: [WhisperBoundaryRepairDiagnostics],
        rawChunks: [WhisperBoundaryBenchmarkRawChunk]
    ) -> Self {
        Self(
            transcript: "",
            pipelineSummary: summary?.withRejectedResultCount(
                diagnostics.filter { $0.reasonCode == .baselineRejectedHallucination }.count
            ),
            executedAudioDuration: executedAudioDuration,
            diagnostics: diagnostics,
            rawChunks: rawChunks,
            failed: true,
            cancelled: false
        )
    }

    static func cancelled(
        summary: RecognitionPipelineValidationSummary?,
        executedAudioDuration: TimeInterval,
        diagnostics: [WhisperBoundaryRepairDiagnostics],
        rawChunks: [WhisperBoundaryBenchmarkRawChunk]
    ) -> Self {
        Self(
            transcript: "",
            pipelineSummary: summary?.withRejectedResultCount(
                diagnostics.filter { $0.reasonCode == .baselineRejectedHallucination }.count
            ),
            executedAudioDuration: executedAudioDuration,
            diagnostics: diagnostics,
            rawChunks: rawChunks,
            failed: false,
            cancelled: true
        )
    }
}

private actor WhisperBoundaryBenchmarkEvidenceCollector {
    private var sequence = 0
    private var texts: [Int: [String]] = [:]

    func beginChunk(_ sequence: Int) {
        self.sequence = sequence
        texts[sequence] = []
    }

    func record(_ text: String) {
        texts[sequence, default: []].append(text)
    }

    func snapshot() -> [WhisperBoundaryBenchmarkRawChunk] {
        texts.keys.sorted().compactMap { sequence in
            guard let chunkTexts = texts[sequence], let baseline = chunkTexts.first else {
                return nil
            }
            return WhisperBoundaryBenchmarkRawChunk(
                sequence: sequence,
                baselineText: baseline,
                candidateText: chunkTexts.dropFirst().last
            )
        }
    }
}
