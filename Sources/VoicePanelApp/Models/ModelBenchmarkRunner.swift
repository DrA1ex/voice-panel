import AVFoundation
import CoreAudio
import Foundation
import VoicePanelCore

enum PerformanceTestMode: String, CaseIterable, Identifiable {
    case modelBenchmark
    case pipelineValidation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modelBenchmark: return "Model Benchmark"
        case .pipelineValidation: return "Pipeline Validation"
        }
    }

    var detail: String {
        switch self {
        case .modelBenchmark:
            return
                "Measures final-model inference on the reusable raw sample without VAD, phrase segmentation, or result filtering."
        case .pipelineValidation:
            return
                "Runs the reusable sample through the selected VAD, phrase boundaries, audio margins, minimum recording policy, final model, and result protection."
        }
    }
}

enum PerformancePipelineStage: Equatable, Sendable {
    case preparingSpeechDetection
    case analyzingAudio
    case loadingModel(String)
    case transcribingChunk(index: Int, total: Int, pass: Int, totalPasses: Int)
    case finalizing

    var title: String {
        switch self {
        case .preparingSpeechDetection:
            return "Preparing speech detection"
        case .analyzingAudio:
            return "Detecting speech and building chunks"
        case .loadingModel(let engine):
            return "Loading \(engine)"
        case .transcribingChunk(let index, let total, _, _):
            return "Recognizing chunk \(index) of \(total)"
        case .finalizing:
            return "Finalizing pipeline result"
        }
    }

    var detail: String {
        switch self {
        case .preparingSpeechDetection:
            return "The reusable VAD runtime is being prepared before the waveform can be analyzed."
        case .analyzingAudio:
            return
                "VoicePanel is classifying speech, pauses, and silence, then forming "
                + "the exact audio chunks sent to recognition."
        case .loadingModel(let engine):
            return
                "The pipeline visualization is ready. VoicePanel is now preparing "
                + "\(engine) to recognize the generated chunks."
        case .transcribingChunk(let index, let total, let pass, let totalPasses):
            let passSuffix = totalPasses > 1 ? " Pass \(pass) of \(totalPasses)." : ""
            return
                "Chunk \(index) of \(total) is being recognized; its text will appear "
                + "in the chunk inspector when ready.\(passSuffix)"
        case .finalizing:
            return "Recognition is complete and the benchmark result is being assembled."
        }
    }
}

private struct ModelBenchmarkPassResult {
    let transcript: String
    let pipelineSummary: RecognitionPipelineValidationSummary?
}

private struct ModelBenchmarkPreparedAudio: Sendable {
    let chunks: [AudioChunk]
    let summary: RecognitionPipelineValidationSummary?
    let visualization: PerformancePipelineVisualization?
    let analysisDuration: TimeInterval
}

struct WhisperBoundaryBenchmarkPresentation: Identifiable, Sendable {
    let execution: WhisperBoundaryBenchmarkExecution
    let run: RecognitionValidationRun

    var id: String { execution.entry.id }
}

struct PerformancePipelineVisualization: Sendable {
    typealias ChunkRecognitionState = WhisperBenchmarkChunkRecognitionState

    struct ChunkOverlay: Identifiable, Sendable {
        let id: UUID
        let startTime: TimeInterval
        let endTime: TimeInterval
        let speechStartTime: TimeInterval?
        let speechEndTime: TimeInterval?
        let boundaryReason: AudioChunkBoundaryReason
        let trailingOverlapDuration: TimeInterval
        let boundarySilenceDuration: TimeInterval?
        let recognitionState: ChunkRecognitionState

        init(
            id: UUID = UUID(),
            startTime: TimeInterval,
            endTime: TimeInterval,
            speechStartTime: TimeInterval?,
            speechEndTime: TimeInterval?,
            boundaryReason: AudioChunkBoundaryReason,
            trailingOverlapDuration: TimeInterval = 0,
            boundarySilenceDuration: TimeInterval?,
            recognitionState: ChunkRecognitionState = .pending
        ) {
            self.id = id
            self.startTime = startTime
            self.endTime = endTime
            self.speechStartTime = speechStartTime
            self.speechEndTime = speechEndTime
            self.boundaryReason = boundaryReason
            self.trailingOverlapDuration = trailingOverlapDuration
            self.boundarySilenceDuration = boundarySilenceDuration
            self.recognitionState = recognitionState
        }

        func withRecognitionState(_ recognitionState: ChunkRecognitionState) -> Self {
            Self(
                id: id,
                startTime: startTime,
                endTime: endTime,
                speechStartTime: speechStartTime,
                speechEndTime: speechEndTime,
                boundaryReason: boundaryReason,
                trailingOverlapDuration: trailingOverlapDuration,
                boundarySilenceDuration: boundarySilenceDuration,
                recognitionState: recognitionState
            )
        }
    }

    struct VADMarker: Identifiable, Sendable {
        enum Kind: Sendable {
            case speechStarted
            case speechEnded
        }

        let id = UUID()
        let time: TimeInterval
        let kind: Kind
    }

    struct VoiceActivitySpan: Identifiable, Sendable {
        enum Kind: Sendable {
            case speech
            case possiblePause
            case silence
        }

        let id = UUID()
        let startTime: TimeInterval
        let endTime: TimeInterval
        let kind: Kind
    }

    let duration: TimeInterval
    let waveformLevels: [Float]
    let speechSpans: [VoiceActivitySpan]
    let chunkOverlays: [ChunkOverlay]
    let vadMarkers: [VADMarker]
    let acceptedByRecordingPolicy: Bool
    let phraseBoundaryDuration: TimeInterval
    let maximumChunkDuration: TimeInterval
    let analysisDuration: TimeInterval

    func replacingChunkOverlays(_ chunkOverlays: [ChunkOverlay]) -> Self {
        Self(
            duration: duration,
            waveformLevels: waveformLevels,
            speechSpans: speechSpans,
            chunkOverlays: chunkOverlays,
            vadMarkers: vadMarkers,
            acceptedByRecordingPolicy: acceptedByRecordingPolicy,
            phraseBoundaryDuration: phraseBoundaryDuration,
            maximumChunkDuration: maximumChunkDuration,
            analysisDuration: analysisDuration
        )
    }
}

extension RecognitionValidationRun {
    var modelName: String { target.model }

    var speedDescription: String {
        guard processingDuration > 0 else { return "Instant" }
        let multiplier = sampleDuration / processingDuration
        if multiplier >= 1 {
            return String(format: "%.1f× faster than real time", multiplier)
        }
        return String(format: "%.1f× slower than real time", 1 / max(multiplier, 0.001))
    }
}

@MainActor
final class ModelBenchmarkRunner: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isRecordingSample = false
    @Published private(set) var isPlayingSample = false
    @Published private(set) var showsDeterminateProgress = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = "Record a sample up to 30 seconds to measure this Mac."
    @Published private(set) var result: RecognitionValidationRun?
    @Published private(set) var runs: [RecognitionValidationRun] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var inputWarning: String?
    @Published private(set) var recordedSampleDuration: TimeInterval = 0
    @Published private(set) var sampleDisplayName: String?
    @Published private(set) var sampleEnvironment: RecognitionValidationEnvironment?
    @Published private(set) var pipelineVisualization: PerformancePipelineVisualization?
    @Published private(set) var pipelineSummary: RecognitionPipelineValidationSummary?
    @Published private(set) var pipelineStage: PerformancePipelineStage?
    @Published private(set) var whisperComparisonResults: [WhisperBoundaryBenchmarkPresentation] = []

    private let capture = AudioCaptureService()
    private let accumulator = ModelBenchmarkAudioAccumulator()
    private let inputDeviceMonitor = AudioInputDeviceMonitor()
    private var recordedSamples: [Float] = []
    private var task: Task<Void, Never>?
    private var inputReconnectTask: Task<Void, Never>?
    private var inputRecoveryID = UUID()
    private var sampleRecordingSettings: AppSettings?
    private var runID = UUID()
    private var stopRecordingRequested = false
    private var samplePlayer: AVAudioPlayer?
    private var samplePlaybackTask: Task<Void, Never>?
    private var samplePlaybackID = UUID()
    private var pipelineVisualizations: [UUID: PerformancePipelineVisualization] = [:]
    private var cachedSileroRuntime: SileroVADRuntime?
    private var cachedSileroModelURL: URL?
    private var cachedSileroConfiguration: SileroVADRuntime.Configuration?

    var hasRecordedSample: Bool {
        !recordedSamples.isEmpty
    }

    init(monitorsAudioInputDevices: Bool = true) {
        guard monitorsAudioInputDevices else { return }
        inputDeviceMonitor.onChange = { [weak self] event in
            Task { @MainActor in
                self?.audioInputDeviceDidChange(event)
            }
        }
        inputDeviceMonitor.start()
    }

    func recordNewSample(
        settings: AppSettings,
        environment: RecognitionValidationEnvironment
    ) {
        guard !isRunning else { return }
        cancel()

        let selectedDeviceID = validatedInputSelection(settings: settings)
        let vadConfiguration = settings.makeVADConfiguration()
        sampleRecordingSettings = settings
        let currentRunID = UUID()
        runID = currentRunID
        stopRecordingRequested = false
        isRunning = true
        isRecordingSample = false
        showsDeterminateProgress = false
        progress = 0
        result = nil
        pipelineVisualization = nil
        pipelineSummary = nil
        pipelineStage = nil
        errorMessage = nil
        status = "Preparing microphone…"

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let samples = try await self.captureSample(
                    selectedDeviceID: selectedDeviceID,
                    vadConfiguration: vadConfiguration,
                    runID: currentRunID
                )
                guard self.runID == currentRunID else { throw CancellationError() }
                self.recordedSamples = samples
                self.recordedSampleDuration = Double(samples.count) / 16_000
                self.sampleDisplayName = "Microphone sample"
                self.sampleEnvironment = environment
                self.runs.removeAll()
                self.whisperComparisonResults.removeAll()
                self.pipelineVisualizations.removeAll()
                self.result = nil
                self.progress = 1
                self.status = "Recorded sample ready for testing."
                self.isRunning = false
                self.isRecordingSample = false
                self.showsDeterminateProgress = false
                self.task = nil
                self.sampleRecordingSettings = nil
                self.inputReconnectTask?.cancel()
                self.inputReconnectTask = nil
            } catch is CancellationError {
                if self.runID == currentRunID {
                    self.resetAfterCancellation()
                }
            } catch {
                if self.runID == currentRunID {
                    self.capture.stop(flushFinalChunk: false)
                    self.capture.onAudioBuffer = nil
                    self.accumulator.reset()
                    self.isRunning = false
                    self.isRecordingSample = false
                    self.showsDeterminateProgress = false
                    self.stopRecordingRequested = false
                    self.task = nil
                    self.progress = 0
                    self.pipelineStage = nil
                    self.status = "Sample recording could not be completed."
                    self.errorMessage = error.localizedDescription
                    self.sampleRecordingSettings = nil
                    self.inputReconnectTask?.cancel()
                    self.inputReconnectTask = nil
                }
            }
        }
    }

    func importSample(at url: URL) {
        guard !isRunning else { return }
        cancel()

        let currentRunID = UUID()
        runID = currentRunID
        isRunning = true
        showsDeterminateProgress = true
        progress = 0
        errorMessage = nil
        status = "Importing audio…"

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let decoded = try await AudioFileDecoder.decode(url: url) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.runID == currentRunID else { return }
                        self.progress = progress
                    }
                }
                try Task.checkCancellation()
                guard self.runID == currentRunID else { throw CancellationError() }

                // AudioFileDecoder's contract is one 16 kHz mono conversion. Keep this
                // decoded PCM immutable; every benchmark variation derives a fresh copy.
                self.recordedSamples = decoded.samples
                self.recordedSampleDuration = decoded.duration
                self.sampleDisplayName = url.lastPathComponent
                self.sampleEnvironment = nil
                self.runs.removeAll()
                self.whisperComparisonResults.removeAll()
                self.pipelineVisualizations.removeAll()
                self.result = nil
                self.pipelineVisualization = nil
                self.pipelineSummary = nil
                self.progress = 1
                self.status = "Imported audio ready for testing."
                self.isRunning = false
                self.showsDeterminateProgress = false
                self.task = nil
            } catch is CancellationError {
                if self.runID == currentRunID { self.resetAfterCancellation() }
            } catch {
                if self.runID == currentRunID {
                    self.isRunning = false
                    self.showsDeterminateProgress = false
                    self.progress = 0
                    self.status = "Audio import could not be completed."
                    self.errorMessage = error.localizedDescription
                    self.task = nil
                }
            }
        }
    }

    func runWhisperComparison(
        settings: AppSettings,
        target: RecognitionValidationTarget,
        edgePadding: TimeInterval,
        maximumChunkDurationOffset: TimeInterval,
        sileroVADModels: SileroVADModelManager,
        whisperRuntime: WhisperRuntimeManager
    ) {
        guard hasRecordedSample, !isRunning, settings.recognitionBackend == .whisper else { return }
        cancel()

        let samples = recordedSamples
        let currentRunID = UUID()
        let matrix = WhisperBenchmarkMatrix.make(
            edgePaddings: [edgePadding],
            maximumChunkDurationOffset: maximumChunkDurationOffset
        )
        let inferenceConfiguration = settings.whisperInferenceConfiguration
        let detectionMode = settings.effectiveVoiceActivityDetectionMode
        runID = currentRunID
        isRunning = true
        showsDeterminateProgress = true
        progress = 0
        result = nil
        pipelineVisualization = nil
        pipelineSummary = nil
        pipelineStage = nil
        whisperComparisonResults.removeAll()
        errorMessage = nil
        status = "Preparing Whisper comparison…"

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let sileroRuntime: SileroVADRuntime?
                if detectionMode == .energy {
                    sileroRuntime = nil
                } else {
                    sileroRuntime = try await self.prepareSileroRuntime(
                        models: sileroVADModels,
                        configuration: settings.sileroRuntimeConfiguration
                    )
                }
                let runtime = try await whisperRuntime.prepare(
                    settings.whisperModelID,
                    runtimeConfiguration: settings.whisperRuntimeConfiguration,
                    installIfNeeded: false
                )
                let executor = WhisperBoundaryBenchmarkExecutor(
                    vadConfiguration: settings.makeVADConfiguration(),
                    segmenterConfiguration: settings.makeFinalRecognitionSegmenterConfiguration(),
                    detectionMode: detectionMode,
                    inferenceConfiguration: inferenceConfiguration,
                    languageCode: settings.whisperLanguageCode,
                    hallucinationGuardConfiguration: settings.hallucinationGuardConfiguration,
                    neuralSpeechDetector: { frame, sampleRate in
                        sileroRuntime?.process(samples: frame, sampleRate: sampleRate)
                    },
                    transcribe: { samples, language, configuration, prompt, metadata in
                        try await runtime.transcribe(
                            samples: samples,
                            languageCode: language,
                            configuration: configuration,
                            initialPrompt: prompt,
                            metadataLevel: metadata
                        )
                    }
                )

                for (index, entry) in matrix.enumerated() {
                    try Task.checkCancellation()
                    guard self.runID == currentRunID else { throw CancellationError() }
                    self.status = "Running \(entry.variant.title)…"
                    sileroRuntime?.reset()
                    let execution = try await executor.execute(
                        entry: entry,
                        samples: samples
                    )
                    let run = RecognitionValidationRun(
                        target: Self.comparisonTarget(target, entry: entry),
                        sampleDuration: execution.executedAudioDuration,
                        processingDurations: [execution.processingDuration],
                        transcript: execution.transcript,
                        pipelineSummary: execution.pipelineSummary,
                        boundaryDiagnostics: execution.diagnostics
                    )
                    let presentation = WhisperBoundaryBenchmarkPresentation(
                        execution: execution,
                        run: run
                    )
                    self.whisperComparisonResults.append(presentation)
                    self.runs.append(run)
                    self.result = run
                    self.progress = Double(index + 1) / Double(max(1, matrix.count))
                }

                guard self.runID == currentRunID else { throw CancellationError() }
                self.status = "Whisper comparison complete"
                self.isRunning = false
                self.showsDeterminateProgress = false
                self.progress = 1
                self.task = nil
            } catch is CancellationError {
                if self.runID == currentRunID { self.resetAfterCancellation() }
            } catch {
                if self.runID == currentRunID {
                    self.isRunning = false
                    self.showsDeterminateProgress = false
                    self.progress = 0
                    self.status = "Whisper comparison could not be completed."
                    self.errorMessage = error.localizedDescription
                    self.task = nil
                }
            }
        }
    }

    func runCurrentSample(
        settings: AppSettings,
        target: RecognitionValidationTarget,
        repetitions: Int,
        mode: PerformanceTestMode,
        sileroVADModels: SileroVADModelManager,
        whisperRuntime: WhisperRuntimeManager,
        gigaAMRuntime: GigaAMRuntimeManager,
        localONNXRuntime: LocalONNXRuntimeManager,
        russianCorrectionRuntime: RussianTextCorrectionRuntimeManager
    ) {
        guard hasRecordedSample else { return }
        begin(
            settings: settings,
            target: target,
            repetitions: repetitions,
            mode: mode,
            sileroVADModels: sileroVADModels,
            whisperRuntime: whisperRuntime,
            gigaAMRuntime: gigaAMRuntime,
            localONNXRuntime: localONNXRuntime,
            russianCorrectionRuntime: russianCorrectionRuntime
        )
    }

    private func begin(
        settings: AppSettings,
        target: RecognitionValidationTarget,
        repetitions: Int,
        mode: PerformanceTestMode,
        sileroVADModels: SileroVADModelManager,
        whisperRuntime: WhisperRuntimeManager,
        gigaAMRuntime: GigaAMRuntimeManager,
        localONNXRuntime: LocalONNXRuntimeManager,
        russianCorrectionRuntime: RussianTextCorrectionRuntimeManager
    ) {
        guard !isRunning, settings.recognitionBackend != .appleSpeech else { return }
        cancel()

        let backend = settings.recognitionBackend
        let vadConfiguration = settings.makeVADConfiguration()
        let segmenterConfiguration = settings.makeFinalRecognitionSegmenterConfiguration()
        let detectionMode = settings.effectiveVoiceActivityDetectionMode
        let sileroConfiguration = settings.sileroRuntimeConfiguration
        let hallucinationGuardConfiguration = settings.hallucinationGuardConfiguration
        let transcriptPostProcessingConfiguration =
            settings.transcriptPostProcessingConfiguration
        let appliesRussianCorrection =
            mode == .pipelineValidation && settings.usesGigaAMRussianCorrection
        let whisperModel = settings.whisperModelID
        let whisperLanguageCode = settings.whisperLanguageCode
        let whisperRuntimeConfiguration = settings.whisperRuntimeConfiguration
        let selectedWhisperInferenceConfiguration = settings.whisperInferenceConfiguration
        let whisperInferenceConfiguration = WhisperInferenceConfiguration(
            numberOfThreads: selectedWhisperInferenceConfiguration.numberOfThreads,
            usesCustomDecoding: selectedWhisperInferenceConfiguration.usesCustomDecoding,
            decodingStrategy: selectedWhisperInferenceConfiguration.decodingStrategy,
            greedyBestOf: selectedWhisperInferenceConfiguration.greedyBestOf,
            beamSize: selectedWhisperInferenceConfiguration.beamSize,
            initialPrompt: selectedWhisperInferenceConfiguration.initialPrompt,
            boundaryStrategy: selectedWhisperInferenceConfiguration.boundaryStrategy,
            overlapDuration: selectedWhisperInferenceConfiguration.overlapDuration,
            contextPromptMode: selectedWhisperInferenceConfiguration.contextPromptMode
        )
        let gigaAMModel = settings.gigaAMModelID
        let gigaAMChunkPolicy = settings.makeGigaAMChunkPolicy()
        let gigaAMThreadCount = settings.gigaAMThreadCount
        let gigaAMProvider = settings.gigaAMExecutionProvider.runtimeValue
        let localONNXModel = settings.selectedLocalONNXModel
        let localONNXThreadCount = settings.localONNXThreadCount
        let localONNXProvider = settings.localONNXExecutionProvider.runtimeValue
        let rawMaximumChunkDuration: TimeInterval
        switch backend {
        case .appleSpeech, .whisper:
            rawMaximumChunkDuration = 30
        case .gigaAM:
            rawMaximumChunkDuration = max(1, min(20, settings.gigaAMMaximumChunkDuration))
        case .qwen3ASR, .parakeet:
            rawMaximumChunkDuration = max(1, min(20, settings.localONNXMaximumChunkDuration))
        }
        let requestedRepetitions = max(1, min(5, repetitions))
        let currentRunID = UUID()
        runID = currentRunID
        stopRecordingRequested = false
        isRunning = true
        isRecordingSample = false
        showsDeterminateProgress = false
        progress = 0
        result = nil
        pipelineVisualization = nil
        pipelineSummary = nil
        pipelineStage =
            mode == .pipelineValidation
            ? (detectionMode == .energy ? .analyzingAudio : .preparingSpeechDetection)
            : nil
        errorMessage = nil
        status = "Loading \(backend.title)…"

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let samples = try self.samplesForRun()
                let sileroRuntime: SileroVADRuntime?
                if mode == .pipelineValidation, detectionMode != .energy {
                    self.pipelineStage = .preparingSpeechDetection
                    self.status = "Preparing Silero VAD…"
                    sileroRuntime = try await self.prepareSileroRuntime(
                        models: sileroVADModels,
                        configuration: sileroConfiguration
                    )
                } else if mode == .pipelineValidation, backend == .whisper {
                    self.pipelineStage = .preparingSpeechDetection
                    self.status = "Preparing forced-chunk speech guard…"
                    do {
                        sileroRuntime = try await self.prepareSileroRuntime(
                            models: sileroVADModels,
                            configuration: sileroConfiguration
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        sileroRuntime = nil
                    }
                } else {
                    sileroRuntime = nil
                }

                if mode == .pipelineValidation {
                    self.pipelineStage = .analyzingAudio
                }
                self.status =
                    mode == .pipelineValidation ? "Analyzing VAD and chunk boundaries…" : "Preparing sample…"
                let prepared = await self.prepareAudio(
                    samples: samples,
                    mode: mode,
                    vadConfiguration: vadConfiguration,
                    segmenterConfiguration: segmenterConfiguration,
                    detectionMode: detectionMode,
                    sileroRuntime: sileroRuntime,
                    screensForcedWhisperChunks: backend == .whisper,
                    rawMaximumChunkDuration: rawMaximumChunkDuration
                )
                try Task.checkCancellation()
                guard self.runID == currentRunID else { throw CancellationError() }
                self.pipelineVisualization = prepared.visualization
                self.pipelineSummary = prepared.summary
                if mode == .pipelineValidation {
                    let analysisTime = Self.compactDurationTitle(prepared.analysisDuration)
                    if prepared.chunks.isEmpty {
                        self.pipelineStage = .finalizing
                        self.status = "VAD analysis completed in \(analysisTime); no chunks require recognition."
                        self.finish(
                            RecognitionValidationRun(
                                target: target,
                                sampleDuration: Double(samples.count) / 16_000,
                                processingDurations: Array(
                                    repeating: prepared.analysisDuration,
                                    count: requestedRepetitions
                                ),
                                transcript: "",
                                pipelineSummary: prepared.summary
                            ),
                            runID: currentRunID
                        )
                        return
                    }
                    self.pipelineStage = .loadingModel(backend.title)
                    self.status = "VAD analysis completed in \(analysisTime). Loading \(backend.title)…"
                }

                switch backend {
                case .appleSpeech:
                    throw CancellationError()

                case .whisper:
                    let model = whisperModel
                    let runtime = try await whisperRuntime.prepare(
                        model,
                        runtimeConfiguration: whisperRuntimeConfiguration,
                        installIfNeeded: false
                    )
                    let repeated = try await self.runRepeatedInference(
                        title: model.title,
                        repetitions: requestedRepetitions,
                        runID: currentRunID,
                        fixedAnalysisDuration: prepared.analysisDuration
                    ) { passIndex in
                        let processor = WhisperBoundaryProcessor(
                            configuration: whisperInferenceConfiguration,
                            languageCode: whisperLanguageCode,
                            hallucinationGuardConfiguration: mode == .pipelineValidation
                                ? hallucinationGuardConfiguration : .disabled,
                            transcribe: { samples, language, configuration, prompt, metadata in
                                try await runtime.transcribe(
                                    samples: samples,
                                    languageCode: language,
                                    configuration: configuration,
                                    initialPrompt: prompt,
                                    metadataLevel: metadata
                                )
                            }
                        )
                        return try await self.runPass(
                            prepared: prepared,
                            mode: mode,
                            hallucinationGuardConfiguration: hallucinationGuardConfiguration,
                            transcriptPostProcessingConfiguration:
                                transcriptPostProcessingConfiguration,
                            passIndex: passIndex,
                            repetitions: requestedRepetitions,
                            publishChunkRecognition: passIndex == 0
                        ) { chunk, chunkIndex, _, _ in
                            let resampled = WhisperAudioPreparation.resampledChunk(
                                chunk,
                                samples: LinearAudioResampler.resampleMono(
                                    samples: chunk.samples,
                                    from: chunk.sampleRate
                                ),
                                sampleRate: 16_000
                            )
                            let output = await processor.process(
                                chunk: resampled,
                                sequence: chunkIndex
                            )
                            if output.failure == .cancelled { throw CancellationError() }
                            guard output.failure == nil else {
                                throw RecognitionEngineError.inferenceFailed
                            }
                            return WhisperBenchmarkChunkClassification(processed: output)
                        }
                    }
                    self.finish(
                        RecognitionValidationRun(
                            target: target,
                            sampleDuration: Double(samples.count) / 16_000,
                            processingDurations: repeated.durations,
                            transcript: repeated.transcript,
                            pipelineSummary: repeated.pipelineSummary
                        ),
                        runID: currentRunID
                    )

                case .gigaAM:
                    let model = gigaAMModel
                    let runtime = try await gigaAMRuntime.prepare(
                        model,
                        installIfNeeded: false,
                        numberOfThreads: gigaAMThreadCount,
                        provider: gigaAMProvider
                    )
                    let repeated = try await self.runRepeatedInference(
                        title: model.title,
                        repetitions: requestedRepetitions,
                        runID: currentRunID,
                        fixedAnalysisDuration: prepared.analysisDuration
                    ) { passIndex in
                        let pass = try await self.runPass(
                            prepared: prepared,
                            mode: mode,
                            hallucinationGuardConfiguration: hallucinationGuardConfiguration,
                            transcriptPostProcessingConfiguration:
                                transcriptPostProcessingConfiguration,
                            passIndex: passIndex,
                            repetitions: requestedRepetitions,
                            publishChunkRecognition: passIndex == 0
                        ) { chunk, _, _, _ in
                            WhisperBenchmarkChunkClassification(
                                text: try await Task.detached(priority: .userInitiated) {
                                    let texts =
                                        try gigaAMChunkPolicy
                                        .chunksBoundedToInferenceLimit(chunk)
                                        .map { boundedChunk in
                                            try runtime.transcribe(
                                                samples: LinearAudioResampler.resampleMono(
                                                    samples: boundedChunk.samples,
                                                    from: boundedChunk.sampleRate
                                                )
                                            )
                                        }
                                    return TranscriptTextMerger.merge(texts)
                                }.value
                            )
                        }
                        return try await self.applyingRussianCorrection(
                            to: pass,
                            whenEnabled: appliesRussianCorrection,
                            numberOfThreads: gigaAMThreadCount,
                            runtimeManager: russianCorrectionRuntime
                        )
                    }
                    self.finish(
                        RecognitionValidationRun(
                            target: target,
                            sampleDuration: Double(samples.count) / 16_000,
                            processingDurations: repeated.durations,
                            transcript: repeated.transcript,
                            pipelineSummary: repeated.pipelineSummary
                        ),
                        runID: currentRunID
                    )

                case .qwen3ASR, .parakeet:
                    guard let model = localONNXModel else {
                        throw ModelBenchmarkError.modelUnavailable
                    }
                    let runtime = try await localONNXRuntime.prepare(
                        model,
                        installIfNeeded: false,
                        numberOfThreads: localONNXThreadCount,
                        provider: localONNXProvider
                    )
                    let repeated = try await self.runRepeatedInference(
                        title: model.title,
                        repetitions: requestedRepetitions,
                        runID: currentRunID,
                        fixedAnalysisDuration: prepared.analysisDuration
                    ) { passIndex in
                        try await self.runPass(
                            prepared: prepared,
                            mode: mode,
                            hallucinationGuardConfiguration: hallucinationGuardConfiguration,
                            transcriptPostProcessingConfiguration:
                                transcriptPostProcessingConfiguration,
                            passIndex: passIndex,
                            repetitions: requestedRepetitions,
                            publishChunkRecognition: passIndex == 0
                        ) { chunk, _, _, _ in
                            WhisperBenchmarkChunkClassification(
                                text: try await Task.detached(priority: .userInitiated) {
                                    try runtime.transcribe(
                                        samples: LinearAudioResampler.resampleMono(
                                            samples: chunk.samples,
                                            from: chunk.sampleRate
                                        )
                                    )
                                }.value
                            )
                        }
                    }
                    self.finish(
                        RecognitionValidationRun(
                            target: target,
                            sampleDuration: Double(samples.count) / 16_000,
                            processingDurations: repeated.durations,
                            transcript: repeated.transcript,
                            pipelineSummary: repeated.pipelineSummary
                        ),
                        runID: currentRunID
                    )
                }
            } catch is CancellationError {
                if self.runID == currentRunID {
                    self.resetAfterCancellation()
                }
            } catch {
                if self.runID == currentRunID {
                    self.capture.stop(flushFinalChunk: false)
                    self.capture.onAudioBuffer = nil
                    self.accumulator.reset()
                    self.isRunning = false
                    self.isRecordingSample = false
                    self.showsDeterminateProgress = false
                    self.stopRecordingRequested = false
                    self.task = nil
                    self.progress = 0
                    self.pipelineStage = nil
                    self.status =
                        mode == .pipelineValidation
                        ? "Pipeline validation could not be completed."
                        : "Benchmark could not be completed."
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func playRecordedSample() {
        guard hasRecordedSample, !isRunning else { return }
        stopSamplePlayback(updateStatus: false)
        do {
            let player = try AVAudioPlayer(
                data: ModelBenchmarkWaveEncoder.encode(
                    samples: recordedSamples,
                    sampleRate: 16_000
                )
            )
            player.prepareToPlay()
            player.play()
            samplePlayer = player
            isPlayingSample = true
            status = "Playing recorded sample…"
            errorMessage = nil

            let playbackID = UUID()
            let playbackDuration = player.duration
            samplePlaybackID = playbackID
            samplePlaybackTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(playbackDuration))
                guard let self, !Task.isCancelled, self.samplePlaybackID == playbackID else { return }
                self.stopSamplePlayback(updateStatus: true)
            }
        } catch {
            isPlayingSample = false
            errorMessage = "Could not play the recorded sample: \(error.localizedDescription)"
        }
    }

    func stopSamplePlayback() {
        stopSamplePlayback(updateStatus: true)
    }

    func exportRecordedSample(to url: URL) throws {
        guard hasRecordedSample else { throw ModelBenchmarkError.sampleMissing }
        try ModelBenchmarkWaveEncoder.encode(
            samples: recordedSamples,
            sampleRate: 16_000
        ).write(to: url, options: .atomic)
    }

    private func stopSamplePlayback(updateStatus: Bool) {
        samplePlaybackID = UUID()
        samplePlaybackTask?.cancel()
        samplePlaybackTask = nil
        samplePlayer?.stop()
        samplePlayer = nil
        let wasPlaying = isPlayingSample
        isPlayingSample = false
        if updateStatus, wasPlaying {
            status = "Recorded sample ready for testing."
        }
    }

    func stopRecording() {
        guard isRunning, isRecordingSample else { return }
        stopRecordingRequested = true
        status = "Finishing recorded sample…"
    }

    func cancel() {
        stopSamplePlayback(updateStatus: false)
        runID = UUID()
        stopRecordingRequested = false
        task?.cancel()
        task = nil
        inputReconnectTask?.cancel()
        inputReconnectTask = nil
        sampleRecordingSettings = nil
        capture.stop(flushFinalChunk: false)
        capture.onAudioBuffer = nil
        resetAfterCancellation()
    }

    func discardSample() {
        cancel()
        recordedSamples.removeAll(keepingCapacity: false)
        recordedSampleDuration = 0
        sampleDisplayName = nil
        result = nil
        pipelineVisualization = nil
        pipelineSummary = nil
        pipelineStage = nil
        pipelineVisualizations.removeAll()
        runs.removeAll()
        whisperComparisonResults.removeAll()
        sampleEnvironment = nil
        status = "Record a sample up to 30 seconds to measure this Mac."
    }

    func clearRuns() {
        guard !isRunning else { return }
        runs.removeAll()
        whisperComparisonResults.removeAll()
        pipelineVisualizations.removeAll()
        result = nil
        pipelineVisualization = nil
        pipelineSummary = nil
        pipelineStage = nil
        status =
            hasRecordedSample
            ? "Recorded sample ready for a new comparison."
            : "Record a sample up to 30 seconds to measure this Mac."
    }

    func makeReport(
        fallbackEnvironment: RecognitionValidationEnvironment,
        referenceTranscript: String,
        notes: String
    ) -> RecognitionValidationReport {
        RecognitionValidationReport(
            environment: sampleEnvironment ?? fallbackEnvironment,
            referenceTranscript: referenceTranscript,
            notes: notes,
            runs: runs
        )
    }

    func pipelineVisualization(for runID: UUID?) -> PerformancePipelineVisualization? {
        guard let runID else { return pipelineVisualization }
        return pipelineVisualizations[runID]
    }

    private func samplesForRun() throws -> [Float] {
        guard !recordedSamples.isEmpty else { throw ModelBenchmarkError.sampleMissing }
        return recordedSamples
    }

    nonisolated private static func comparisonTarget(
        _ target: RecognitionValidationTarget,
        entry: WhisperBenchmarkMatrixEntry
    ) -> RecognitionValidationTarget {
        var configuration = target.configuration ?? [:]
        configuration["whisperBenchmarkVariant"] = entry.variant.id
        if let audio = entry.audioConfiguration {
            configuration["whisperEdgePadding"] = String(audio.edgePadding)
            configuration["whisperMaximumChunkDurationOffset"] = String(
                audio.maximumChunkDurationOffset
            )
        }
        return RecognitionValidationTarget(
            engine: target.engine,
            model: target.model,
            modelSize: target.modelSize,
            compute: target.compute,
            profile: entry.variant.title,
            language: target.language,
            configuration: configuration
        )
    }

    private func validatedInputSelection(settings: AppSettings) -> UInt32 {
        let preferredDeviceID = AudioDeviceID(settings.selectedInputDeviceID)
        guard preferredDeviceID != 0,
            !AudioInputDeviceManager.isInputDeviceAvailable(preferredDeviceID)
        else { return settings.selectedInputDeviceID }

        settings.selectedInputDeviceID = 0
        inputWarning =
            "The selected microphone was disconnected. The sample recorder switched to the system default input."
        return 0
    }

    private func audioInputDeviceDidChange(_ event: AudioInputDeviceChangeEvent) {
        guard sampleRecordingSettings != nil else { return }
        let change: AudioInputTopologyChange
        switch event {
        case .defaultInputChanged:
            change = .defaultInputChanged
        case .deviceListChanged:
            change = .deviceListChanged
        }

        inputReconnectTask?.cancel()
        let expectedRunID = runID
        let recoveryID = UUID()
        inputRecoveryID = recoveryID
        inputReconnectTask = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performInputRecovery(
                change: change,
                expectedRunID: expectedRunID,
                recoveryID: recoveryID
            )
        }
    }

    private func performInputRecovery(
        change: AudioInputTopologyChange,
        expectedRunID: UUID,
        recoveryID: UUID
    ) async {
        defer { finishInputRecovery(id: recoveryID) }

        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled, runID == expectedRunID,
            let settings = sampleRecordingSettings
        else { return }

        let snapshot = AudioInputDeviceManager.snapshot()
        let preferredSelection = settings.selectedInputDeviceID
        let decision = makeInputRecoveryDecision(
            snapshot: snapshot,
            preferredSelection: preferredSelection,
            change: change
        )

        if decision.persistedSelection != preferredSelection {
            settings.selectedInputDeviceID = decision.persistedSelection
            inputWarning =
                "The selected microphone was disconnected. The sample recorder switched to the system default input."
        }

        if isRecordingSample, capture.hasActiveSession,
            decision.usesSystemFallback, decision.reconnectSelection == nil
        {
            capture.pauseCaptureForDeferredStop()
            status = "Microphone unavailable · captured sample preserved; waiting for input…"
            inputWarning =
                "No input device is currently available. Already captured sample audio is preserved."
            return
        }

        guard isRecordingSample, decision.shouldReconnect,
            let reconnectSelection = decision.reconnectSelection
        else { return }

        let previousResolvedDeviceID = capture.currentResolvedDeviceSelection
        let intendedResolvedDeviceID: AudioDeviceID? =
            reconnectSelection == 0 ? snapshot.defaultDeviceID : AudioDeviceID(reconnectSelection)
        var closeCurrentInputTail = previousResolvedDeviceID != intendedResolvedDeviceID
        let retryDelays: [Duration] = [.zero, .milliseconds(180), .milliseconds(420), .milliseconds(900)]
        var lastError: Error?

        for delay in retryDelays {
            if delay != .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, runID == expectedRunID, isRecordingSample else { return }

            do {
                _ = try capture.reconnect(
                    selectedDeviceID: AudioDeviceID(reconnectSelection),
                    closeCurrentInputTail: closeCurrentInputTail
                )
                status =
                    decision.usesSystemFallback
                    ? "Recording… system default input"
                    : "Recording… microphone connection restored"
                return
            } catch {
                lastError = error
                closeCurrentInputTail = false
            }
        }

        status = "Microphone unavailable · captured sample preserved; waiting for input…"
        inputWarning =
            lastError?.localizedDescription
            ?? "No input device is currently available. Already captured sample audio is preserved."
    }

    private func makeInputRecoveryDecision(
        snapshot: AudioInputDeviceSnapshot,
        preferredSelection: UInt32,
        change: AudioInputTopologyChange
    ) -> AudioInputRecoveryDecision {
        let availableDeviceIDs: Set<UInt32> = snapshot.availableDeviceIDs
        let defaultDeviceID: UInt32? = snapshot.defaultDeviceID
        let currentRequestedSelection: UInt32? = capture.currentDeviceSelection
        let currentResolvedDeviceID: UInt32? = capture.currentResolvedDeviceSelection
        let hasActiveSession: Bool = capture.hasActiveSession
        let isCapturing: Bool = capture.isCapturingAudio

        return AudioInputRecoveryPolicy.decision(
            preferredSelection: preferredSelection,
            availableDeviceIDs: availableDeviceIDs,
            defaultDeviceID: defaultDeviceID,
            currentRequestedSelection: currentRequestedSelection,
            currentResolvedDeviceID: currentResolvedDeviceID,
            hasActiveSession: hasActiveSession,
            isCapturing: isCapturing,
            change: change
        )
    }

    private func finishInputRecovery(id: UUID) {
        guard inputRecoveryID == id else { return }
        inputReconnectTask = nil
    }

    private func captureSample(
        selectedDeviceID: AudioDeviceID,
        vadConfiguration: VoiceActivityDetector.Configuration,
        runID currentRunID: UUID
    ) async throws -> [Float] {
        try await AudioCaptureService.requestMicrophonePermission()
        try Task.checkCancellation()

        accumulator.reset()
        capture.onAudioBuffer = { [accumulator] buffer in
            accumulator.append(buffer)
        }
        try capture.start(
            selectedDeviceID: selectedDeviceID,
            vadConfiguration: vadConfiguration,
            suppressSilenceInRecognizer: false
        )

        let maximumSampleDuration: TimeInterval = 30
        isRecordingSample = true
        showsDeterminateProgress = true
        progress = 0
        let startedAt = ContinuousClock.now
        defer {
            isRecordingSample = false
            showsDeterminateProgress = false
        }

        while true {
            try Task.checkCancellation()
            guard runID == currentRunID else { throw CancellationError() }
            if stopRecordingRequested { break }
            let elapsed = startedAt.duration(to: .now).timeInterval
            if elapsed >= maximumSampleDuration {
                progress = 1
                break
            }
            status = String(
                format: "Recording… %.1f s · stop when ready · %.1f s maximum",
                elapsed,
                maximumSampleDuration
            )
            progress = ModelBenchmarkProgress.recordingFraction(
                elapsed: elapsed,
                maximumDuration: maximumSampleDuration
            )
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        stopRecordingRequested = false
        status = "Preparing recorded sample…"
        progress = 0
        capture.stop(flushFinalChunk: false)
        capture.onAudioBuffer = nil
        let samples = accumulator.resampled(to: 16_000)
        accumulator.reset()
        guard samples.count >= 1_600 else {
            throw ModelBenchmarkError.sampleTooShort
        }
        return samples
    }

    private func prepareSileroRuntime(
        models: SileroVADModelManager,
        configuration: SileroVADRuntime.Configuration
    ) async throws -> SileroVADRuntime {
        let modelURL = try await models.ensureInstalled()
        if let cachedSileroRuntime,
            cachedSileroModelURL == modelURL,
            cachedSileroConfiguration == configuration
        {
            return cachedSileroRuntime
        }

        let runtime = try await Task.detached(priority: .userInitiated) {
            try SileroVADRuntime(
                modelURL: modelURL,
                configuration: configuration
            )
        }.value
        cachedSileroRuntime = runtime
        cachedSileroModelURL = modelURL
        cachedSileroConfiguration = configuration
        return runtime
    }

    private func runPass(
        prepared: ModelBenchmarkPreparedAudio,
        mode: PerformanceTestMode,
        hallucinationGuardConfiguration: RecognitionHallucinationGuard.Configuration,
        transcriptPostProcessingConfiguration: TranscriptPostProcessingConfiguration,
        passIndex: Int,
        repetitions: Int,
        publishChunkRecognition: Bool,
        transcribe: (
            AudioChunk,
            Int,
            String?,
            AudioChunkBoundaryReason?
        ) async throws -> WhisperBenchmarkChunkClassification
    ) async throws -> ModelBenchmarkPassResult {
        var accumulator = WhisperBenchmarkPassAccumulator()
        let chunkCount = prepared.chunks.count

        for (chunkIndex, chunk) in prepared.chunks.enumerated() {
            try Task.checkCancellation()
            if mode == .pipelineValidation {
                pipelineStage = .transcribingChunk(
                    index: chunkIndex + 1,
                    total: chunkCount,
                    pass: passIndex + 1,
                    totalPasses: repetitions
                )
                let passSuffix =
                    repetitions > 1 ? " · pass \(passIndex + 1) of \(repetitions)" : ""
                status =
                    "VAD ready · transcribing chunk \(chunkIndex + 1) of \(chunkCount)\(passSuffix)…"
                progress = pipelineProgress(
                    passIndex: passIndex,
                    repetitions: repetitions,
                    completedChunks: chunkIndex,
                    totalChunks: chunkCount
                )
            }

            let classified = try await transcribe(
                chunk,
                chunkIndex,
                accumulator.previousAcceptedText,
                accumulator.previousAcceptedBoundaryReason
            )
            let recognitionState = accumulator.consume(
                classified,
                chunk: chunk,
                appliesPresentationHallucinationGuard: mode == .pipelineValidation,
                hallucinationGuardConfiguration: hallucinationGuardConfiguration
            )

            if publishChunkRecognition {
                updateChunkRecognition(at: chunkIndex, state: recognitionState)
            }
            if mode == .pipelineValidation {
                progress = pipelineProgress(
                    passIndex: passIndex,
                    repetitions: repetitions,
                    completedChunks: chunkIndex + 1,
                    totalChunks: chunkCount
                )
            }
        }

        if mode == .pipelineValidation, passIndex == repetitions - 1 {
            pipelineStage = .finalizing
        }

        return ModelBenchmarkPassResult(
            transcript: mode == .pipelineValidation
                ? accumulator.transcript(
                    postProcessing: transcriptPostProcessingConfiguration
                )
                : accumulator.transcript,
            pipelineSummary: prepared.summary?.withRejectedResultCount(
                accumulator.rejectedResultCount
            )
        )
    }

    private func applyingRussianCorrection(
        to pass: ModelBenchmarkPassResult,
        whenEnabled isEnabled: Bool,
        numberOfThreads: Int,
        runtimeManager: RussianTextCorrectionRuntimeManager
    ) async throws -> ModelBenchmarkPassResult {
        guard isEnabled, !pass.transcript.isEmpty else { return pass }
        do {
            status = "Correcting Russian transcript…"
            let runtime = try await runtimeManager.prepare(
                installIfNeeded: true,
                numberOfThreads: max(1, min(4, numberOfThreads))
            )
            try Task.checkCancellation()
            let correction = try await runtime.correct(pass.transcript)
            return ModelBenchmarkPassResult(
                transcript: correction.text.isEmpty ? pass.transcript : correction.text,
                pipelineSummary: pass.pipelineSummary
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Match production finalization: optional correction fails open.
            return pass
        }
    }

    private func prepareAudio(
        samples: [Float],
        mode: PerformanceTestMode,
        vadConfiguration: VoiceActivityDetector.Configuration,
        segmenterConfiguration: AudioSegmenter.Configuration,
        detectionMode: VoiceActivityDetectionMode,
        sileroRuntime: SileroVADRuntime?,
        screensForcedWhisperChunks: Bool,
        rawMaximumChunkDuration: TimeInterval
    ) async -> ModelBenchmarkPreparedAudio {
        if mode == .modelBenchmark {
            return ModelBenchmarkPreparedAudio(
                chunks: makeIndependentRawBenchmarkChunks(
                    samples,
                    sampleRate: 16_000,
                    maximumChunkDuration: rawMaximumChunkDuration
                ),
                summary: nil,
                visualization: nil,
                analysisDuration: 0
            )
        }

        // RecognitionPipelineValidator.process remains the production chunking reference;
        // this trace adds synchronized visualization metadata without blocking MainActor.
        let traced = await Task.detached(priority: .userInitiated) {
            sileroRuntime?.reset()
            return Self.tracePipelineVisualization(
                samples: samples,
                sampleRate: 16_000,
                vadConfiguration: vadConfiguration,
                segmenterConfiguration: segmenterConfiguration,
                detectionMode: detectionMode,
                minimumAcceptedDuration: RecordingStopPolicy.defaultMinimumDuration,
                neuralSpeechDetector: { frame, sampleRate in
                    sileroRuntime?.process(samples: frame, sampleRate: sampleRate)
                },
                isolatedSpeechDetector: screensForcedWhisperChunks
                    ? { chunk in sileroRuntime?.detectsSpeech(in: chunk) }
                    : nil
            )
        }.value
        return ModelBenchmarkPreparedAudio(
            chunks: traced.chunks,
            summary: traced.summary,
            visualization: traced.visualization,
            analysisDuration: traced.visualization.analysisDuration
        )
    }

    private func makeIndependentRawBenchmarkChunks(
        _ samples: [Float],
        sampleRate: Double,
        maximumChunkDuration: TimeInterval
    ) -> [AudioChunk] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        let maximumSamples = max(1, Int((maximumChunkDuration * sampleRate).rounded()))
        var chunks: [AudioChunk] = []
        chunks.reserveCapacity(max(1, Int(ceil(Double(samples.count) / Double(maximumSamples)))))
        var offset = 0
        while offset < samples.count {
            let upperBound = min(samples.count, offset + maximumSamples)
            chunks.append(
                AudioChunk(
                    samples: Array(samples[offset..<upperBound]),
                    sampleRate: sampleRate,
                    boundaryReason: upperBound < samples.count ? .maximumDuration : .stopped
                )
            )
            offset = upperBound
        }
        return chunks
    }

    private func runRepeatedInference(
        title: String,
        repetitions: Int,
        runID currentRunID: UUID,
        fixedAnalysisDuration: TimeInterval,
        operation: (Int) async throws -> ModelBenchmarkPassResult
    ) async throws -> (
        durations: [TimeInterval],
        transcript: String,
        pipelineSummary: RecognitionPipelineValidationSummary?
    ) {
        var durations: [TimeInterval] = []
        durations.reserveCapacity(repetitions)
        var transcript = ""
        var pipelineSummary: RecognitionPipelineValidationSummary?
        showsDeterminateProgress = true
        progress = 0

        for index in 0..<repetitions {
            try Task.checkCancellation()
            guard runID == currentRunID else { throw CancellationError() }
            status =
                repetitions == 1
                ? "Running \(title)…"
                : "Running \(title)… pass \(index + 1) of \(repetitions)"
            let startedAt = ContinuousClock.now
            let pass = try await operation(index)
            durations.append(
                fixedAnalysisDuration + startedAt.duration(to: .now).timeInterval
            )
            if transcript.isEmpty || !pass.transcript.isEmpty {
                transcript = pass.transcript
            }
            if pipelineSummary == nil || pass.pipelineSummary?.rejectedResultCount ?? 0 > 0 {
                pipelineSummary = pass.pipelineSummary
            }
            progress = Double(index + 1) / Double(repetitions)
        }

        return (durations, transcript, pipelineSummary)
    }

    private func pipelineProgress(
        passIndex: Int,
        repetitions: Int,
        completedChunks: Int,
        totalChunks: Int
    ) -> Double {
        let safeRepetitions = max(1, repetitions)
        let chunkFraction =
            totalChunks > 0
            ? Double(min(max(completedChunks, 0), totalChunks)) / Double(totalChunks)
            : 1
        return min(
            1,
            max(0, (Double(passIndex) + chunkFraction) / Double(safeRepetitions))
        )
    }

    private func updateChunkRecognition(
        at index: Int,
        state: PerformancePipelineVisualization.ChunkRecognitionState
    ) {
        guard let visualization = pipelineVisualization,
            visualization.chunkOverlays.indices.contains(index)
        else {
            return
        }
        var overlays = visualization.chunkOverlays
        overlays[index] = overlays[index].withRecognitionState(state)
        pipelineVisualization = visualization.replacingChunkOverlays(overlays)
    }

    nonisolated private static func compactDurationTitle(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return "\(Int((max(0, duration) * 1_000).rounded())) ms"
        }
        return String(format: "%.2f s", duration)
    }

    nonisolated private static func tracePipelineVisualization(
        samples: [Float],
        sampleRate: Double,
        vadConfiguration: VoiceActivityDetector.Configuration,
        segmenterConfiguration: AudioSegmenter.Configuration,
        detectionMode: VoiceActivityDetectionMode,
        minimumAcceptedDuration: TimeInterval,
        frameDuration: TimeInterval = 0.032,
        neuralSpeechDetector: (([Float], Double) -> Bool?)? = nil,
        isolatedSpeechDetector: ((AudioChunk) -> Bool?)? = nil
    ) -> (
        chunks: [AudioChunk],
        summary: RecognitionPipelineValidationSummary,
        visualization: PerformancePipelineVisualization
    ) {
        let analysisStartedAt = ContinuousClock.now
        guard !samples.isEmpty, sampleRate > 0 else {
            let emptySummary = RecognitionPipelineValidationSummary(
                capturedDuration: 0,
                minimumAcceptedDuration: minimumAcceptedDuration,
                acceptedByRecordingPolicy: false,
                chunks: []
            )
            return (
                [],
                emptySummary,
                PerformancePipelineVisualization(
                    duration: 0,
                    waveformLevels: [],
                    speechSpans: [],
                    chunkOverlays: [],
                    vadMarkers: [],
                    acceptedByRecordingPolicy: false,
                    phraseBoundaryDuration: vadConfiguration.endOfSpeechSilenceDuration,
                    maximumChunkDuration: segmenterConfiguration.maximumChunkDuration,
                    analysisDuration: 0
                )
            )
        }

        var pipeline = RecognitionAudioChunkPipeline(
            vadConfiguration: vadConfiguration,
            segmenterConfiguration: segmenterConfiguration,
            minimumChunkDeliveryDuration: minimumAcceptedDuration,
            detectionMode: detectionMode
        )
        let frameSampleCount = max(1, Int((max(0.005, frameDuration) * sampleRate).rounded()))
        var emittedChunks: [AudioChunk] = []
        var chunkOverlays: [PerformancePipelineVisualization.ChunkOverlay] = []
        var vadMarkers: [PerformancePipelineVisualization.VADMarker] = []
        var spans: [PerformancePipelineVisualization.VoiceActivitySpan] = []
        var currentSpanKind: PerformancePipelineVisualization.VoiceActivitySpan.Kind?
        var currentSpanStart: TimeInterval = 0
        var offset = 0

        while offset < samples.count {
            let upperBound = min(samples.count, offset + frameSampleCount)
            let frame = Array(samples[offset..<upperBound])
            let rmsDB = Self.decibels(from: frame)
            let neuralSpeech = neuralSpeechDetector?(frame, sampleRate)
            let startTime = Double(offset) / sampleRate
            let endTime = Double(upperBound) / sampleRate
            if let result = pipeline.process(
                samples: frame,
                sampleRate: sampleRate,
                rmsDB: rmsDB,
                neuralSpeechDetected: neuralSpeech
            ) {
                let spanKind: PerformancePipelineVisualization.VoiceActivitySpan.Kind
                switch result.snapshot.state {
                case .speech:
                    spanKind = .speech
                case .possiblePause:
                    spanKind = .possiblePause
                case .silence:
                    spanKind = .silence
                }
                if currentSpanKind != spanKind {
                    if let currentSpanKind, startTime > currentSpanStart {
                        spans.append(
                            .init(
                                startTime: currentSpanStart,
                                endTime: startTime,
                                kind: currentSpanKind
                            )
                        )
                    }
                    currentSpanKind = spanKind
                    currentSpanStart = startTime
                }

                switch result.event {
                case .speechStarted:
                    vadMarkers.append(.init(time: endTime, kind: .speechStarted))
                case .speechEnded:
                    vadMarkers.append(.init(time: endTime, kind: .speechEnded))
                case .speechContinued, .possiblePause, .silence:
                    break
                }
                if !result.chunks.isEmpty {
                    let detectedBoundarySilenceDuration: TimeInterval?
                    if case .speechEnded(let silenceDuration) = result.event {
                        detectedBoundarySilenceDuration = silenceDuration
                    } else {
                        detectedBoundarySilenceDuration = nil
                    }
                    let trimmedTrailingSilence = max(
                        0,
                        (detectedBoundarySilenceDuration ?? 0)
                            - segmenterConfiguration.postRollDuration
                    )
                    let lastOverlap = result.chunks.last?.trailingOverlapDuration ?? 0
                    let finalChunkEnd = max(
                        0,
                        result.capturedDuration - result.pendingDuration + lastOverlap
                            - trimmedTrailingSilence
                    )
                    chunkOverlays.append(
                        contentsOf: Self.chunkOverlays(
                            for: result.chunks,
                            endingAt: finalChunkEnd,
                            boundarySilenceDuration: detectedBoundarySilenceDuration
                        )
                    )
                    emittedChunks.append(contentsOf: result.chunks)
                }
            }
            offset = upperBound
        }

        let stopResult = pipeline.stop(
            flushFinalChunk: true,
            forceChunkIfDurationAtLeast: minimumAcceptedDuration
        )
        emittedChunks.append(contentsOf: stopResult.finalChunks)
        let accepted =
            RecordingStopPolicy.action(
                for: stopResult.capturedDuration,
                minimumDuration: minimumAcceptedDuration
            ) == .flushAndFinalize
        if !accepted {
            emittedChunks.removeAll(keepingCapacity: false)
            chunkOverlays.removeAll(keepingCapacity: false)
        } else {
            chunkOverlays.append(
                contentsOf: Self.chunkOverlays(
                    for: stopResult.finalChunks,
                    endingAt: stopResult.capturedDuration,
                    boundarySilenceDuration: nil
                )
            )
        }

        if let currentSpanKind, stopResult.capturedDuration > currentSpanStart {
            spans.append(
                .init(
                    startTime: currentSpanStart,
                    endTime: stopResult.capturedDuration,
                    kind: currentSpanKind
                )
            )
        }

        let unscreenedSummary = RecognitionPipelineValidationSummary(
            capturedDuration: stopResult.capturedDuration,
            minimumAcceptedDuration: minimumAcceptedDuration,
            acceptedByRecordingPolicy: accepted,
            chunks: emittedChunks.map { chunk in
                RecognitionPipelineValidationChunk(
                    boundaryReason: chunk.boundaryReason,
                    duration: chunk.duration,
                    speechDuration: Self.speechDuration(of: chunk),
                    trailingOverlapDuration: chunk.trailingOverlapDuration
                )
            }
        )
        let mergedBeforeScreening = WhisperFileImportPolicy.mergingShortForcedTail(
            in: RecognitionPipelineValidator.Result(
                chunks: emittedChunks,
                summary: unscreenedSummary
            ),
            segmenterConfiguration: segmenterConfiguration
        )
        if mergedBeforeScreening.chunks.count != emittedChunks.count {
            chunkOverlays = Self.mergingShortForcedTailOverlays(
                chunkOverlays,
                chunks: mergedBeforeScreening.chunks
            )
        }

        let screening: WhisperFileChunkScreeningResult
        if let isolatedSpeechDetector {
            screening = WhisperFileImportPolicy.screeningForcedChunks(
                in: mergedBeforeScreening,
                detectsIsolatedSpeech: isolatedSpeechDetector
            )
        } else {
            screening = WhisperFileChunkScreeningResult(
                result: mergedBeforeScreening,
                excludedChunkIndices: []
            )
        }
        let excludedIndices = Set(screening.excludedChunkIndices)
        let excludedRanges = screening.excludedChunkIndices.compactMap { index in
            chunkOverlays.indices.contains(index)
                ? chunkOverlays[index].startTime..<chunkOverlays[index].endTime
                : nil
        }
        chunkOverlays = chunkOverlays.enumerated().compactMap { index, overlay in
            excludedIndices.contains(index) ? nil : overlay
        }
        let visualization = PerformancePipelineVisualization(
            duration: Double(samples.count) / sampleRate,
            waveformLevels: Self.downsampleWaveformLevels(
                samples: samples,
                sampleRate: sampleRate
            ),
            speechSpans: Self.markingExcludedSilence(
                in: spans,
                ranges: excludedRanges
            ),
            chunkOverlays: chunkOverlays,
            vadMarkers: vadMarkers,
            acceptedByRecordingPolicy: accepted,
            phraseBoundaryDuration: vadConfiguration.endOfSpeechSilenceDuration,
            maximumChunkDuration: segmenterConfiguration.maximumChunkDuration,
            analysisDuration: analysisStartedAt.duration(to: .now).timeInterval
        )
        return (screening.result.chunks, screening.result.summary, visualization)
    }

    nonisolated private static func chunkOverlays(
        for chunks: [AudioChunk],
        endingAt finalEndTime: TimeInterval,
        boundarySilenceDuration: TimeInterval?
    ) -> [PerformancePipelineVisualization.ChunkOverlay] {
        guard !chunks.isEmpty else { return [] }

        var reversed: [PerformancePipelineVisualization.ChunkOverlay] = []
        reversed.reserveCapacity(chunks.count)
        var endTime = max(0, finalEndTime)
        for (reverseIndex, chunk) in chunks.reversed().enumerated() {
            let startTime = max(0, endTime - chunk.duration)
            let speechStartTime: TimeInterval?
            let speechEndTime: TimeInterval?
            if let speechRange = chunk.speechRange, chunk.sampleRate > 0 {
                speechStartTime = startTime + Double(speechRange.lowerBound) / chunk.sampleRate
                speechEndTime = startTime + Double(speechRange.upperBound) / chunk.sampleRate
            } else {
                speechStartTime = nil
                speechEndTime = nil
            }
            let isLastChunk = reverseIndex == 0
            reversed.append(
                .init(
                    id: chunk.id,
                    startTime: startTime,
                    endTime: endTime,
                    speechStartTime: speechStartTime,
                    speechEndTime: speechEndTime,
                    boundaryReason: chunk.boundaryReason,
                    trailingOverlapDuration: chunk.trailingOverlapDuration,
                    boundarySilenceDuration: isLastChunk
                        && (chunk.boundaryReason == .silence
                            || chunk.boundaryReason == .longSilence)
                        ? boundarySilenceDuration : nil
                )
            )
            endTime = startTime + chunk.trailingOverlapDuration
        }
        return reversed.reversed()
    }

    nonisolated private static func mergingShortForcedTailOverlays(
        _ overlays: [PerformancePipelineVisualization.ChunkOverlay],
        chunks: [AudioChunk]
    ) -> [PerformancePipelineVisualization.ChunkOverlay] {
        guard overlays.count == chunks.count + 1,
            overlays.count >= 2,
            let previous = overlays.dropLast().last,
            let tail = overlays.last,
            previous.boundaryReason == .maximumDuration
                || previous.boundaryReason == .balancedPause,
            tail.boundaryReason != .maximumDuration,
            let mergedChunk = chunks.last
        else { return overlays }

        let mergedStart = min(previous.startTime, tail.startTime)
        let mergedEnd = max(previous.endTime, tail.endTime)
        let mergedSpeechStart = [previous.speechStartTime, tail.speechStartTime]
            .compactMap { $0 }.min()
        let mergedSpeechEnd = [previous.speechEndTime, tail.speechEndTime]
            .compactMap { $0 }.max()
        var result = Array(overlays.dropLast(2))
        result.append(
            .init(
                id: mergedChunk.id,
                startTime: mergedStart,
                endTime: mergedEnd,
                speechStartTime: mergedSpeechStart,
                speechEndTime: mergedSpeechEnd,
                boundaryReason: mergedChunk.boundaryReason,
                trailingOverlapDuration: mergedChunk.trailingOverlapDuration,
                boundarySilenceDuration: tail.boundarySilenceDuration
            )
        )
        return result
    }

    nonisolated private static func markingExcludedSilence(
        in spans: [PerformancePipelineVisualization.VoiceActivitySpan],
        ranges: [Range<TimeInterval>]
    ) -> [PerformancePipelineVisualization.VoiceActivitySpan] {
        guard !ranges.isEmpty else { return spans }
        let sortedRanges = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var result: [PerformancePipelineVisualization.VoiceActivitySpan] = []

        for span in spans {
            var cursor = span.startTime
            for range in sortedRanges {
                let lower = max(span.startTime, range.lowerBound)
                let upper = min(span.endTime, range.upperBound)
                guard lower < upper else { continue }
                if cursor < lower {
                    result.append(
                        .init(
                            startTime: cursor,
                            endTime: lower,
                            kind: span.kind
                        ))
                }
                result.append(
                    .init(
                        startTime: lower,
                        endTime: upper,
                        kind: .silence
                    ))
                cursor = max(cursor, upper)
            }
            if cursor < span.endTime {
                result.append(
                    .init(
                        startTime: cursor,
                        endTime: span.endTime,
                        kind: span.kind
                    ))
            }
        }
        return result
    }

    nonisolated private static func downsampleWaveformLevels(
        samples: [Float],
        sampleRate: Double,
        bucketCount: Int = 160
    ) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let count = max(24, min(bucketCount, samples.count))
        let bucketSize = max(1, samples.count / count)
        var levels: [Float] = []
        levels.reserveCapacity(count)
        var offset = 0
        while offset < samples.count {
            let upper = min(samples.count, offset + bucketSize)
            let slice = samples[offset..<upper]
            let peak = slice.reduce(Float(0)) { max($0, abs($1)) }
            levels.append(max(0.03, min(1, pow(peak, 0.7))))
            offset = upper
        }
        return levels
    }

    nonisolated private static func speechDuration(of chunk: AudioChunk) -> TimeInterval {
        guard chunk.sampleRate > 0 else { return 0 }
        if chunk.speechEvidenceAnalyzed {
            guard let range = chunk.speechRange else { return 0 }
            return Double(max(0, range.count)) / chunk.sampleRate
        }
        return chunk.duration
    }

    nonisolated private static func decibels(from samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -120 }
        let squareSum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = sqrt(squareSum / Float(samples.count))
        return 20 * log10(max(rms, 0.000_001))
    }

    private func finish(
        _ benchmarkResult: RecognitionValidationRun,
        runID currentRunID: UUID
    ) {
        guard runID == currentRunID else { return }
        if let pipelineVisualization {
            pipelineVisualizations[benchmarkResult.id] = pipelineVisualization
        }
        result = benchmarkResult
        pipelineSummary = benchmarkResult.pipelineSummary
        pipelineStage = nil
        runs.append(benchmarkResult)
        accumulator.reset()
        errorMessage = nil
        progress = 1
        status =
            benchmarkResult.pipelineSummary == nil
            ? "Model benchmark complete"
            : "Pipeline validation complete"
        isRunning = false
        isRecordingSample = false
        showsDeterminateProgress = false
        task = nil
    }

    private func resetAfterCancellation() {
        isRunning = false
        isRecordingSample = false
        showsDeterminateProgress = false
        stopRecordingRequested = false
        progress = 0
        pipelineStage = nil
        accumulator.reset()
        status =
            hasRecordedSample
            ? "Recorded sample ready for another model."
            : "Record a sample up to 30 seconds to measure this Mac."
        errorMessage = nil
    }
}

private enum ModelBenchmarkWaveEncoder {
    static func encode(samples: [Float], sampleRate: Int) -> Data {
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = Int(bitsPerSample / 8)
        let dataSize = samples.count * bytesPerSample
        let byteRate = UInt32(sampleRate * Int(channelCount) * bytesPerSample)
        let blockAlign = channelCount * UInt16(bytesPerSample)

        var data = Data()
        data.reserveCapacity(44 + dataSize)
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36 + dataSize))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channelCount)
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(UInt32(dataSize))

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            data.appendLittleEndian(Int16((clamped * Float(Int16.max)).rounded()))
        }
        return data
    }
}

extension Data {
    fileprivate mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}

private enum ModelBenchmarkError: LocalizedError {
    case sampleMissing
    case modelUnavailable
    case sampleTooShort

    var errorDescription: String? {
        switch self {
        case .sampleMissing:
            return "Record a microphone sample before running the model test."
        case .modelUnavailable:
            return "The selected local model is unavailable."
        case .sampleTooShort:
            return "No usable microphone audio was captured. Check the selected input and try again."
        }
    }
}

private final class ModelBenchmarkAudioAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator = LinearAudioSampleAccumulator()

    func reset() {
        lock.lock()
        accumulator.reset()
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: frameCount))
        lock.lock()
        accumulator.append(samples: samples, sampleRate: buffer.format.sampleRate)
        lock.unlock()
    }

    func resampled(to sampleRate: Double) -> [Float] {
        lock.lock()
        let snapshot = accumulator
        lock.unlock()
        return snapshot.resampled(to: sampleRate)
    }
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

#if DEBUG
    extension ModelBenchmarkRunner {
        func configurePreview(
            visualization: PerformancePipelineVisualization,
            summary: RecognitionPipelineValidationSummary,
            baseSettings: AppSettings
        ) {
            let olderSettings = AppSettings.makeIsolatedPerformanceCopy(of: baseSettings)
            olderSettings.recognitionProfile = .recommended
            olderSettings.whisperBoundaryStrategy = .standard
            olderSettings.voiceActivityDetectionMode = .energy
            olderSettings.voiceEndSilenceDuration = 0.85

            let latestSettings = AppSettings.makeIsolatedPerformanceCopy(of: baseSettings)
            latestSettings.beginCustomizingRecognitionProfile()
            latestSettings.whisperBoundaryStrategy = .contextualRetry
            latestSettings.voiceActivityDetectionMode = .hybrid
            latestSettings.voiceEndSilenceDuration = 0.70

            let olderSnapshot = olderSettings.encodedPerformanceConfigurationSnapshot() ?? ""
            let latestSnapshot = latestSettings.encodedPerformanceConfigurationSnapshot() ?? ""
            let olderRun = RecognitionValidationRun(
                testedAt: Date().addingTimeInterval(-420),
                target: RecognitionValidationTarget(
                    engine: "Whisper",
                    model: "Base Q5",
                    modelSize: "148 MB",
                    compute: "Metal",
                    profile: olderSettings.recognitionProfile.title,
                    language: "English",
                    configuration: [
                        "performanceTestMode": PerformanceTestMode.pipelineValidation.rawValue,
                        "performanceSetupSnapshot": olderSnapshot,
                        "pipeline.strategy": "Phrase segmentation",
                        "whisper.reusePreviousChunkContext": "false",
                    ]
                ),
                sampleDuration: visualization.duration,
                processingDurations: [0.78, 0.74, 0.76],
                transcript: "The benchmark shows the exact text recognized for every generated chunk.",
                pipelineSummary: summary
            )
            let latestRun = RecognitionValidationRun(
                testedAt: Date().addingTimeInterval(-90),
                target: RecognitionValidationTarget(
                    engine: "Whisper",
                    model: "Base Q5",
                    modelSize: "148 MB",
                    compute: "Metal",
                    profile: latestSettings.recognitionProfile.title,
                    language: "English",
                    configuration: [
                        "performanceTestMode": PerformanceTestMode.pipelineValidation.rawValue,
                        "performanceSetupSnapshot": latestSnapshot,
                        "pipeline.strategy": "Phrase segmentation",
                        "whisper.reusePreviousChunkContext": "true",
                        "vad.mode": "Hybrid",
                    ]
                ),
                sampleDuration: visualization.duration,
                processingDurations: [0.62, 0.60, 0.64],
                transcript: "The benchmark now shows the exact text recognized for every generated chunk.",
                pipelineSummary: summary
            )

            recordedSamples = Array(repeating: 0.08, count: 1_600)
            recordedSampleDuration = visualization.duration
            sampleEnvironment = RecognitionValidationEnvironment(
                hardware: "MacBook Pro · Apple Silicon",
                operatingSystem: "macOS Preview",
                microphone: "Studio Display Microphone",
                environmentProfile: "Balanced"
            )
            result = latestRun
            runs = [olderRun, latestRun]
            pipelineVisualization = visualization
            pipelineSummary = summary
            pipelineVisualizations = [
                olderRun.id: visualization,
                latestRun.id: visualization,
            ]
            status = "Pipeline validation complete"
            isRunning = false
            isRecordingSample = false
            showsDeterminateProgress = false
            progress = 1
        }
    }
#endif
