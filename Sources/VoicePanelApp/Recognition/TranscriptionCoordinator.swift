import AppKit
import Combine
import CoreAudio
import VoicePanelCore

private final class LatestCaptureMetricsMailbox: @unchecked Sendable {
    struct PendingMetrics {
        let operationID: UUID
        let metrics: AudioCaptureMetrics
    }

    private let lock = NSLock()
    private var pending: PendingMetrics?

    func submit(_ metrics: AudioCaptureMetrics, operationID: UUID) {
        lock.performMetricsMailboxLocked {
            pending = PendingMetrics(operationID: operationID, metrics: metrics)
        }
    }

    func takeLatest() -> PendingMetrics? {
        lock.performMetricsMailboxLocked {
            defer { pending = nil }
            return pending
        }
    }
}

extension NSLock {
    fileprivate func performMetricsMailboxLocked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

@MainActor
final class TranscriptionCoordinator {
    let state: AppState
    let settings: AppSettings

    var onShowCompactPanel: (() -> Void)?
    var onHideCompactPanel: (() -> Void)?
    var onShowFullTranscript: (() -> Void)?
    var onHideFullTranscript: (() -> Void)?

    private let audioCapture: AudioCaptureService
    private let history: HistoryModel
    private let whisperModels: WhisperModelManager
    private let whisperRuntime: WhisperRuntimeManager
    private let whisperDraftRuntime: WhisperRuntimeManager
    private let gigaAMModels: GigaAMModelManager
    private let gigaAMRuntime: GigaAMRuntimeManager
    private let gigaAMDraftRuntime: GigaAMRuntimeManager
    private let localONNXModels: LocalONNXModelManager
    private let localONNXRuntime: LocalONNXRuntimeManager
    private let sileroVADModels: SileroVADModelManager
    private let russianCorrectionModels: RussianCorrectionModelManager
    private let russianCorrectionRuntime: RussianTextCorrectionRuntimeManager
    private let inputDeviceMonitor = AudioInputDeviceMonitor()
    private let diagnostics = DiagnosticLogger.shared
    private let captureMetricsMailbox = LatestCaptureMetricsMailbox()
    private let debugAudioRecordingStore = DebugAudioRecordingStore()
    private var debugAudioRecordingSessionID: UUID?
    private var recognitionEngine: RecognitionEngine?

    private var startTask: Task<Void, Never>?
    private var inputReconnectTask: Task<Void, Never>?
    private var inputRecoveryID = UUID()
    private var cancellables = Set<AnyCancellable>()
    private var lastHistoryCheckpointText = ""
    private var lastHistoryCheckpointAt = Date.distantPast
    private var hotKeyReleaseStopTask: Task<Void, Never>?
    private var finalizationTimeoutTask: Task<Void, Never>?
    private var finalizationCompletionTask: Task<Void, Never>?
    private var transcriptPostProcessingTask: Task<Void, Never>?
    private var operationID = UUID()
    private var finalizedOperationID: UUID?
    private var recordingInitiator: RecordingControlSource?
    private var recordingStartedAt: Date?
    private var currentHistoryRecordID: UUID?
    private var importedAudioDuration: TimeInterval?
    private var importedChunkWaiters: [UUID: CheckedContinuation<RecognitionChunkOutcome, Never>] = [:]
    private var importFallbackDescription: String?
    private var pendingRecognitionUpdates: [RecognitionUpdate] = []
    private var recognitionUpdateFlushTask: Task<Void, Never>?
    private var stopAfterPreparation = false
    private var currentEngineName = "Apple Speech"
    private var engineDidFinish = false
    private var finalizationStartedAt: Date?
    private let minimumAcceptedRecordingDuration = RecordingStopPolicy.defaultMinimumDuration
    private let minimumFinalizationFeedbackDuration: TimeInterval = 0.35

    var canToggleRecordingFromMenu: Bool {
        recordingInitiator?.requiresManualStop == true
            && (state.phase == .preparing || state.phase == .listening)
    }

    init(
        state: AppState,
        settings: AppSettings,
        history: HistoryModel,
        whisperModels: WhisperModelManager,
        whisperRuntime: WhisperRuntimeManager,
        whisperDraftRuntime: WhisperRuntimeManager,
        gigaAMModels: GigaAMModelManager,
        gigaAMRuntime: GigaAMRuntimeManager,
        gigaAMDraftRuntime: GigaAMRuntimeManager,
        localONNXModels: LocalONNXModelManager,
        localONNXRuntime: LocalONNXRuntimeManager,
        sileroVADModels: SileroVADModelManager,
        russianCorrectionModels: RussianCorrectionModelManager,
        russianCorrectionRuntime: RussianTextCorrectionRuntimeManager,
        audioCapture: AudioCaptureService = AudioCaptureService(),
        monitorsAudioInputDevices: Bool = true
    ) {
        self.state = state
        self.settings = settings
        self.history = history
        self.whisperModels = whisperModels
        self.whisperRuntime = whisperRuntime
        self.whisperDraftRuntime = whisperDraftRuntime
        self.gigaAMModels = gigaAMModels
        self.gigaAMRuntime = gigaAMRuntime
        self.gigaAMDraftRuntime = gigaAMDraftRuntime
        self.localONNXModels = localONNXModels
        self.localONNXRuntime = localONNXRuntime
        self.sileroVADModels = sileroVADModels
        self.russianCorrectionModels = russianCorrectionModels
        self.russianCorrectionRuntime = russianCorrectionRuntime
        self.audioCapture = audioCapture
        if monitorsAudioInputDevices {
            inputDeviceMonitor.onChange = { [weak self] event in
                Task { @MainActor in self?.audioInputDeviceDidChange(event) }
            }
            inputDeviceMonitor.start()
        }
        // This must run independently of display refreshes: a hidden panel or
        // an empty metrics mailbox must not disable stalled-input recovery.
        Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.checkAudioCaptureLiveness() }
            .store(in: &cancellables)
        observeRuntimePreparation()
    }

    func startHotKeyRecording() {
        if state.phase == .monitoring { stopMonitoring() }
        if stopAfterPreparation,
            recordingInitiator == .hotKeyHold,
            state.phase == .preparing
        {
            do {
                guard
                    try audioCapture.resumeCaptureAfterDeferredStop(
                        selectedDeviceID: validatedInputSelection()
                    )
                else { throw AudioCaptureError.noDeferredCapture }
                stopAfterPreparation = false
                state.statusMessage = "Recording · preparing recognizer"
                diagnostics.info("Deferred preparation stop cancelled by a new hot-key press")
            } catch {
                diagnostics.error(
                    "Could not resume preparation capture",
                    metadata: ["error": error.localizedDescription]
                )
                cancelCurrentSession()
                state.fail(error.localizedDescription)
            }
            return
        }
        if hotKeyReleaseStopTask != nil,
            recordingInitiator == .hotKeyHold,
            state.phase == .preparing || state.phase == .listening
        {
            hotKeyReleaseStopTask?.cancel()
            hotKeyReleaseStopTask = nil
            state.statusMessage =
                state.phase == .preparing
                ? "Preparing · hold hot key to record"
                : "Hold hot key to record · \(recognitionEngine?.displayName ?? currentEngineName)"
            diagnostics.info("Scheduled hot-key release stop cancelled by a new press")
            return
        }
        applyRecordingDecision(for: .hotKeyPressed)
    }

    func stopHotKeyRecording() {
        let delay = HotKeyReleaseTailPolicy.scheduledDuration(
            isEnabled: settings.hotKeyReleaseTailEnabled,
            configuredDuration: settings.hotKeyReleaseTailDuration,
            phase: recordingControlPhase,
            source: recordingInitiator
        )
        guard delay > 0 else {
            applyRecordingDecision(for: .hotKeyReleased)
            return
        }

        hotKeyReleaseStopTask?.cancel()
        let expectedOperationID = operationID
        state.statusMessage = "Capturing the end of the phrase…"
        diagnostics.info(
            "Hot-key release tail scheduled",
            metadata: ["delaySeconds": String(format: "%.3f", delay)]
        )
        hotKeyReleaseStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self,
                !Task.isCancelled,
                self.operationID == expectedOperationID
            else { return }
            self.hotKeyReleaseStopTask = nil
            self.applyRecordingDecision(for: .hotKeyReleased)
        }
    }

    func latchHotKeyRecording() {
        hotKeyReleaseStopTask?.cancel()
        hotKeyReleaseStopTask = nil
        if stopAfterPreparation,
            recordingInitiator == .hotKeyHold,
            state.phase == .preparing
        {
            do {
                guard
                    try audioCapture.resumeCaptureAfterDeferredStop(
                        selectedDeviceID: validatedInputSelection()
                    )
                else { throw AudioCaptureError.noDeferredCapture }
            } catch {
                diagnostics.error(
                    "Could not resume capture before latching",
                    metadata: ["error": error.localizedDescription]
                )
                cancelCurrentSession()
                state.fail(error.localizedDescription)
                return
            }
        }
        stopAfterPreparation = false
        applyRecordingDecision(for: .latchHotKey)
    }

    func toggleMenuRecording() {
        if state.phase == .monitoring { stopMonitoring() }
        applyRecordingDecision(for: .menuToggle)
    }

    private func applyRecordingDecision(for event: RecordingControlEvent) {
        switch RecordingControlPolicy.decide(
            event: event,
            phase: recordingControlPhase,
            activeSource: recordingInitiator
        ) {
        case .start(let source): startRecording(initiator: source)
        case .stop: stopRecording()
        case .cancelPreparation: cancelCurrentSession()
        case .finishPreparationThenStop:
            guard audioCapture.hasActiveSession else {
                diagnostics.info("Hot key released before microphone capture started")
                cancelCurrentSession(showFeedback: false)
                break
            }
            stopAfterPreparation = true
            audioCapture.pauseCaptureForDeferredStop()
            state.statusMessage = "Finishing captured audio when the recognizer is ready…"
            diagnostics.info("Hot-key release deferred until preparation finishes")
        case .latchHotKey:
            stopAfterPreparation = false
            recordingInitiator = .hotKeyLatched
            state.latchHotKeyRecording()
            state.statusMessage =
                state.phase == .preparing
                ? "Preparing · release the hot key"
                : "Recording · press Stop when finished"
            diagnostics.info("Hot-key recording latched for manual stop")
        case .none: break
        }
    }

    private var recordingControlPhase: RecordingControlPhase {
        switch state.phase {
        case .idle, .result, .failed, .cancelled, .monitoring: return .idle
        case .preparing: return .preparing
        case .listening: return .listening
        case .stopping, .finalizing: return .finalizing
        }
    }

    func startRecording(initiator: RecordingControlSource = .menu) {
        guard state.canStartRecording else { return }

        persistEditedResultIfNeeded()
        inputReconnectTask?.cancel()
        inputReconnectTask = nil
        hotKeyReleaseStopTask?.cancel()
        hotKeyReleaseStopTask = nil
        finalizationTimeoutTask?.cancel()
        finalizationTimeoutTask = nil
        finalizationCompletionTask?.cancel()
        finalizationCompletionTask = nil
        transcriptPostProcessingTask?.cancel()
        transcriptPostProcessingTask = nil
        finalizationStartedAt = nil
        operationID = UUID()
        finalizedOperationID = nil
        recordingInitiator = initiator
        stopAfterPreparation = false
        recordingStartedAt = nil
        currentHistoryRecordID = nil
        lastHistoryCheckpointText = ""
        lastHistoryCheckpointAt = .distantPast
        importedAudioDuration = nil
        importFallbackDescription = nil
        cancelImportedChunkWaiters()
        cancelRecognitionUpdateFlush(discardPending: true)
        engineDidFinish = false
        diagnostics.info(
            "Recording preparation started",
            metadata: [
                "backend": settings.recognitionBackend.rawValue,
                "initiator": String(describing: initiator),
                "microphoneActive": "false",
            ]
        )

        let currentOperationID = operationID
        state.resetForNewSession(source: initiator)
        state.inputDeviceWarning = nil
        state.phase = .preparing
        state.activeEngineName = settings.recognitionBackend.title
        state.updatePreparation(
            status: initialRecordingPreparationStatus,
            waitingForRecognizer: true
        )

        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await AudioCaptureService.requestMicrophonePermission()
                try Task.checkCancellation()
                guard self.operationID == currentOperationID else { return }

                self.beginDebugAudioRecordingIfEnabled(sessionID: currentOperationID)
                let vadConfiguration = self.settings.makeVADConfiguration()
                self.configureAudioCallbacks(sendToRecognizer: false, engine: nil)
                self.state.currentLevelDB = -90
                self.state.noiseFloorDB = vadConfiguration.initialNoiseFloorDB
                self.state.thresholdDB = vadConfiguration.threshold(
                    for: vadConfiguration.initialNoiseFloorDB
                )
                self.state.voiceActivityState = .silence
                try self.audioCapture.startPreparationCapture(
                    selectedDeviceID: self.validatedInputSelection(),
                    vadConfiguration: vadConfiguration
                )
                self.recordingStartedAt = Date()
                self.onShowCompactPanel?()
                self.state.updatePreparation(
                    status: "Recording · preparing recognizer…",
                    waitingForRecognizer: true
                )
                self.diagnostics.info(
                    "Audio capture started before recognition engine",
                    metadata: [
                        "backend": self.settings.recognitionBackend.rawValue,
                        "inputDevice": String(self.settings.selectedInputDeviceID),
                    ]
                )

                let engine = try await self.makeRecognitionEngine()
                try Task.checkCancellation()
                guard self.operationID == currentOperationID else {
                    engine.cancel()
                    return
                }

                self.recognitionEngine = engine
                self.currentEngineName = engine.displayName
                self.state.activeEngineName = engine.displayName
                self.configureRecognitionCallbacks(for: engine)
                self.diagnostics.info(
                    "Recognition engine prepared while microphone capture continued",
                    metadata: [
                        "engine": engine.displayName,
                        "inputMode": String(describing: engine.audioInputMode),
                    ]
                )

                try await engine.requestAuthorization()
                try Task.checkCancellation()
                self.state.hasLiveDraftText = engine.providesLiveDraft
                self.state.recognitionUsesAudioChunks = engine.audioInputMode != .continuousBuffers
                try await engine.start(localeIdentifier: self.settings.activeLanguageIdentifier)
                try Task.checkCancellation()
                guard self.operationID == currentOperationID else {
                    engine.cancel()
                    return
                }

                self.state.updatePreparation(
                    status: "Preparing voice detection…",
                    waitingForRecognizer: true
                )
                let sileroVAD = try await self.prepareVoiceActivityRuntime()
                try Task.checkCancellation()
                guard self.operationID == currentOperationID else {
                    engine.cancel()
                    return
                }

                self.configureAudioCallbacks(sendToRecognizer: true, engine: engine)
                let segmenterConfiguration = self.segmenterConfiguration()
                let detectionMode = self.settings.effectiveVoiceActivityDetectionMode
                let suppressSilence =
                    (engine.audioInputMode == .continuousBuffers
                        || engine.audioInputMode == .continuousBuffersAndVADChunks)
                    && self.settings.suppressDetectedSilence
                let minimumChunkDeliveryDuration =
                    engine.audioInputMode == .continuousBuffers
                    ? 0
                    : self.minimumAcceptedRecordingDuration
                let includeExtendedPreparationAudio =
                    self.settings.includeAudioCapturedWhilePreparing
                let audioCapture = self.audioCapture
                let activation = await Task.detached(priority: .userInitiated) {
                    audioCapture.activatePreparedCapture(
                        vadConfiguration: vadConfiguration,
                        segmenterConfiguration: segmenterConfiguration,
                        detectionMode: detectionMode,
                        sileroVAD: sileroVAD,
                        suppressSilenceInRecognizer: suppressSilence,
                        minimumChunkDeliveryDuration: minimumChunkDeliveryDuration,
                        includeExtendedPreparationAudio: includeExtendedPreparationAudio
                    )
                }.value

                guard self.operationID == currentOperationID else {
                    _ = self.audioCapture.stop(flushFinalChunk: false)
                    engine.cancel()
                    return
                }

                self.state.clearPreparation()
                self.state.phase = .listening
                self.diagnostics.info(
                    "Prepared audio activated for recognition",
                    metadata: [
                        "engine": engine.displayName,
                        "capturedSeconds": String(format: "%.3f", activation.capturedDuration),
                        "includedSeconds": String(format: "%.3f", activation.includedDuration),
                        "discardedSeconds": String(format: "%.3f", activation.discardedDuration),
                        "bufferTruncated": String(activation.wasTruncated),
                    ]
                )
                self.state.statusMessage =
                    initiator == .hotKeyHold
                    ? "Hold hot key to record · \(engine.displayName)"
                    : "Listening · \(engine.displayName)"
                if !self.audioCapture.isCapturingAudio, !self.stopAfterPreparation {
                    self.state.statusMessage =
                        "Microphone unavailable · recording preserved; waiting for input…"
                }
                if self.settings.showFullTranscriptAutomatically {
                    self.onShowFullTranscript?()
                }
                if self.stopAfterPreparation {
                    self.stopAfterPreparation = false
                    self.stopRecording()
                }
            } catch is CancellationError {
                self.endDebugAudioRecording(sessionID: currentOperationID)
                return
            } catch {
                _ = self.audioCapture.stop(flushFinalChunk: false)
                self.endDebugAudioRecording()
                self.recognitionEngine?.cancel()
                self.recognitionEngine = nil
                self.stopAfterPreparation = false
                self.diagnostics.error(
                    "Recording preparation failed",
                    metadata: ["error": error.localizedDescription]
                )
                self.onShowCompactPanel?()
                self.state.fail(error.localizedDescription)
            }
        }
    }

    func transcribeAudioFile(at url: URL) {
        guard state.canStartRecording else { return }

        persistEditedResultIfNeeded()
        hotKeyReleaseStopTask?.cancel()
        hotKeyReleaseStopTask = nil
        finalizationTimeoutTask?.cancel()
        finalizationTimeoutTask = nil
        finalizationCompletionTask?.cancel()
        finalizationCompletionTask = nil
        transcriptPostProcessingTask?.cancel()
        transcriptPostProcessingTask = nil
        finalizationStartedAt = nil
        operationID = UUID()
        finalizedOperationID = nil
        recordingInitiator = .menu
        recordingStartedAt = Date()
        currentHistoryRecordID = nil
        importedAudioDuration = nil
        importFallbackDescription = nil
        cancelImportedChunkWaiters()
        cancelRecognitionUpdateFlush(discardPending: true)
        engineDidFinish = false

        let currentOperationID = operationID
        let importRoute = WhisperFileImportPolicy.route(
            isWhisper: settings.recognitionBackend == .whisper,
            mode: settings.whisperFileTranscriptionMode
        )
        let displayName = url.lastPathComponent
        state.resetForNewSession(source: .menu)
        state.phase = .preparing
        state.activeEngineName = settings.recognitionBackend.title
        state.updatePreparation(
            status: "Waiting for the recognizer before importing \(displayName)…",
            waitingForRecognizer: false,
            importingAudioFile: true
        )
        state.updateAudioImportProgress(AudioImportProgress(stage: .preparing))
        onShowCompactPanel?()
        diagnostics.info(
            "Audio file transcription preparation started",
            metadata: [
                "backend": settings.recognitionBackend.rawValue,
                "file": displayName,
            ]
        )

        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            let accessedSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if accessedSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let outcome = try await WhisperFileImportExecutor.execute(
                    route: importRoute,
                    prepareEngine: { boundaryStrategyOverride in
                        let engine = try await self.prepareImportedRecognitionEngine(
                            boundaryStrategyOverride: boundaryStrategyOverride
                        )
                        try Task.checkCancellation()
                        guard self.operationID == currentOperationID else {
                            engine.cancel()
                            throw CancellationError()
                        }
                        return engine
                    },
                    decode: {
                        try await self.decodeImportedAudio(
                            at: url,
                            displayName: displayName,
                            operationID: currentOperationID
                        )
                    },
                    transcribeContinuous: { engine, decoded in
                        try await self.transcribeContinuousImportedAudio(
                            decoded,
                            with: engine,
                            displayName: displayName,
                            operationID: currentOperationID
                        )
                    },
                    transcribeSegmented: { engine, decoded, isFallback in
                        try await self.transcribeSegmentedImportedAudio(
                            decoded,
                            with: engine,
                            displayName: displayName,
                            operationID: currentOperationID,
                            isFallback: isFallback
                        )
                    },
                    cancelEngine: { engine in
                        engine.cancel()
                        if self.recognitionEngine === engine {
                            self.recognitionEngine = nil
                        }
                    },
                    beginFallback: { reason in
                        self.beginImportedAudioFallback(reason)
                    }
                )
                guard outcome == .completed else { throw CancellationError() }
            } catch is CancellationError {
                return
            } catch {
                self.cancelImportedChunkWaiters()
                self.recognitionEngine?.cancel()
                self.recognitionEngine = nil
                self.diagnostics.error(
                    "Audio file transcription failed",
                    metadata: [
                        "file": displayName,
                        "error": error.localizedDescription,
                    ]
                )
                self.state.fail(error.localizedDescription)
            }
        }
    }

    private func prepareImportedRecognitionEngine(
        boundaryStrategyOverride: WhisperBoundaryStrategy?
    ) async throws -> RecognitionEngine {
        let engine = try await makeRecognitionEngine(
            includeDraft: false,
            boundaryStrategyOverride: boundaryStrategyOverride
        )
        do {
            recognitionEngine = engine
            currentEngineName = engine.displayName
            state.activeEngineName = engine.displayName
            configureRecognitionCallbacks(for: engine)
            try await engine.requestAuthorization()
            try Task.checkCancellation()
            state.hasLiveDraftText = engine.providesLiveDraft
            state.recognitionUsesAudioChunks = engine.audioInputMode != .continuousBuffers
            try await engine.start(localeIdentifier: settings.activeLanguageIdentifier)
            try Task.checkCancellation()
            return engine
        } catch {
            engine.cancel()
            if recognitionEngine === engine { recognitionEngine = nil }
            throw error
        }
    }

    private func decodeImportedAudio(
        at url: URL,
        displayName: String,
        operationID expectedOperationID: UUID
    ) async throws -> DecodedAudioFile {
        state.updatePreparation(
            status: "Converting \(displayName)…",
            progress: 0,
            waitingForRecognizer: false,
            importingAudioFile: true
        )
        let decoded = try await AudioFileDecoder.decode(url: url) { [weak self] progress in
            Task { @MainActor in
                guard let self,
                    self.operationID == expectedOperationID,
                    self.state.phase == .preparing
                else { return }
                self.state.updatePreparation(
                    status: "Converting \(displayName)… \(Int(progress * 100))%",
                    progress: progress,
                    waitingForRecognizer: false,
                    importingAudioFile: true
                )
                self.state.updateAudioImportProgress(
                    AudioImportProgress(
                        stage: .converting,
                        fallbackDescription: self.importFallbackDescription
                    )
                )
            }
        }
        try Task.checkCancellation()
        guard operationID == expectedOperationID else { throw CancellationError() }
        importedAudioDuration = decoded.duration
        return decoded
    }

    private func transcribeContinuousImportedAudio(
        _ decoded: DecodedAudioFile,
        with engine: RecognitionEngine,
        displayName: String,
        operationID expectedOperationID: UUID
    ) async throws -> WhisperContinuousAttemptOutcome {
        try Task.checkCancellation()
        guard operationID == expectedOperationID else { throw CancellationError() }
        let chunks = WhisperFileImportPolicy.continuousChunks(
            samples: decoded.samples,
            sampleRate: decoded.sampleRate
        )
        guard chunks.count == 1, let chunk = chunks.first else {
            throw AudioFileDecoderError.emptyAudio
        }

        beginImportedAudioTranscription()
        let startedAt = Date()
        publishImportedAudioProgress(
            currentChunk: 1,
            completedChunks: 0,
            totalChunks: 1,
            completedAudioDuration: 0,
            totalAudioDuration: chunk.duration,
            startedAt: startedAt
        )
        state.emittedChunkCount += 1
        state.queueRecognitionChunk(chunk)
        let outcome = await appendImportedChunkAndWait(chunk, to: engine)
        try Task.checkCancellation()
        guard operationID == expectedOperationID else { throw CancellationError() }

        let resolution = WhisperFileImportOutcomeInterpreter.continuousResolution(
            after: outcome,
            recoverFailure: { id in
                state.recoverRecognitionChunkFailure(id: id)
            }
        )

        switch resolution.outcome {
        case .completed:
            publishImportedAudioProgress(
                currentChunk: 1,
                completedChunks: 1,
                totalChunks: 1,
                completedAudioDuration: chunk.duration,
                totalAudioDuration: chunk.duration,
                startedAt: startedAt
            )
            finalizeImportedAudio(
                decoded,
                chunks: chunks,
                with: engine,
                displayName: displayName
            )
            return .completed
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        }
    }

    private func transcribeSegmentedImportedAudio(
        _ decoded: DecodedAudioFile,
        with engine: RecognitionEngine,
        displayName: String,
        operationID expectedOperationID: UUID,
        isFallback: Bool
    ) async throws {
        setPreparationStatus("Preparing voice detection for imported audio…")
        let screensForcedWhisperChunks = settings.recognitionBackend == .whisper
        let requiresNeuralVAD = settings.effectiveVoiceActivityDetectionMode != .energy
        let sileroVAD: SileroVADRuntime?
        if screensForcedWhisperChunks, !requiresNeuralVAD {
            sileroVAD = try? await prepareVoiceActivityRuntime(force: true)
        } else {
            sileroVAD = try await prepareVoiceActivityRuntime()
        }
        try Task.checkCancellation()
        guard operationID == expectedOperationID else { throw CancellationError() }

        state.updatePreparation(
            status: "Detecting speech and splitting audio…",
            waitingForRecognizer: false,
            importingAudioFile: true
        )
        state.updateAudioImportProgress(
            AudioImportProgress(
                stage: .analyzing,
                fallbackDescription: importFallbackDescription
            )
        )
        sileroVAD?.reset()
        let vadConfiguration = settings.makeVADConfiguration()
        let segmenterConfiguration = segmenterConfiguration()
        let detectionMode = settings.effectiveVoiceActivityDetectionMode
        let pipeline = await Task.detached(priority: .userInitiated) {
            let segmented = RecognitionPipelineValidator.process(
                samples: decoded.samples,
                sampleRate: decoded.sampleRate,
                vadConfiguration: vadConfiguration,
                segmenterConfiguration: segmenterConfiguration,
                detectionMode: detectionMode,
                minimumAcceptedDuration: 0.10,
                neuralSpeechDetector: { frame, sampleRate in
                    sileroVAD?.process(samples: frame, sampleRate: sampleRate)
                }
            )
            let merged = WhisperFileImportPolicy.mergingShortForcedTail(
                in: segmented,
                segmenterConfiguration: segmenterConfiguration
            )
            guard screensForcedWhisperChunks, let sileroVAD else { return merged }
            return WhisperFileImportPolicy.screeningForcedChunks(
                in: merged,
                detectsIsolatedSpeech: { sileroVAD.detectsSpeech(in: $0) }
            ).result
        }.value
        try Task.checkCancellation()
        guard operationID == expectedOperationID else { throw CancellationError() }
        guard pipeline.summary.detectedSpeech, !pipeline.chunks.isEmpty else {
            throw AudioFileDecoderError.noSpeechDetected
        }

        beginImportedAudioTranscription()
        let chunks = pipeline.chunks
        let totalChunkDuration = chunks.reduce(0) { $0 + $1.duration }
        let transcriptionStartedAt = Date()
        var completedChunks = 0
        var completedAudioDuration: TimeInterval = 0

        publishImportedAudioProgress(
            currentChunk: 1,
            completedChunks: 0,
            totalChunks: chunks.count,
            completedAudioDuration: 0,
            totalAudioDuration: totalChunkDuration,
            startedAt: transcriptionStartedAt
        )

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            guard operationID == expectedOperationID else { throw CancellationError() }
            publishImportedAudioProgress(
                currentChunk: index + 1,
                completedChunks: completedChunks,
                totalChunks: chunks.count,
                completedAudioDuration: completedAudioDuration,
                totalAudioDuration: totalChunkDuration,
                startedAt: transcriptionStartedAt
            )
            state.emittedChunkCount += 1

            let outcome: RecognitionChunkOutcome?
            switch engine.audioInputMode {
            case .continuousBuffers:
                guard let buffer = chunk.makePCMBuffer() else {
                    throw AudioFileDecoderError.unsupportedFormat
                }
                engine.append(buffer)
                outcome = nil

            case .continuousBuffersAndVADChunks:
                guard let buffer = chunk.makePCMBuffer() else {
                    throw AudioFileDecoderError.unsupportedFormat
                }
                state.queueRecognitionChunk(chunk)
                engine.append(buffer)
                outcome = await appendImportedChunkAndWait(chunk, to: engine)

            case .vadChunks:
                state.queueRecognitionChunk(chunk)
                outcome = await appendImportedChunkAndWait(chunk, to: engine)
            }

            if case .cancelled? = outcome { throw CancellationError() }
            if let fallbackError = WhisperFileImportOutcomeInterpreter.segmentedFallbackError(
                after: outcome,
                isFallback: isFallback
            ) {
                throw fallbackError
            }
            completedChunks += 1
            completedAudioDuration += chunk.duration
            publishImportedAudioProgress(
                currentChunk: min(index + 2, chunks.count),
                completedChunks: completedChunks,
                totalChunks: chunks.count,
                completedAudioDuration: completedAudioDuration,
                totalAudioDuration: totalChunkDuration,
                startedAt: transcriptionStartedAt
            )
        }

        try Task.checkCancellation()
        guard operationID == expectedOperationID else { throw CancellationError() }
        finalizeImportedAudio(
            decoded,
            chunks: chunks,
            with: engine,
            displayName: displayName
        )
    }

    private func beginImportedAudioTranscription() {
        state.updatePreparation(
            status: "Transcribing imported audio…",
            waitingForRecognizer: false,
            importingAudioFile: true
        )
        state.phase = .finalizing
        state.finishAudioCapture()
        finalizationStartedAt = Date()
        engineDidFinish = false
    }

    private func finalizeImportedAudio(
        _ decoded: DecodedAudioFile,
        chunks: [AudioChunk],
        with engine: RecognitionEngine,
        displayName: String
    ) {
        let completedDuration = chunks.reduce(0) { $0 + $1.duration }
        state.statusMessage = "Assembling imported transcript…"
        state.updateAudioImportProgress(
            AudioImportProgress(
                stage: .finalizing,
                currentChunk: chunks.count,
                completedChunks: chunks.count,
                totalChunks: chunks.count,
                completedAudioDuration: completedDuration,
                totalAudioDuration: completedDuration,
                elapsedProcessingDuration: Date().timeIntervalSince(
                    finalizationStartedAt ?? Date()
                ),
                fallbackDescription: importFallbackDescription
            )
        )
        engine.finish()
        scheduleFinalizationTimeout(for: engine)
        diagnostics.info(
            "Audio file queued for transcription",
            metadata: [
                "file": displayName,
                "duration": String(format: "%.3f", decoded.duration),
                "chunks": String(chunks.count),
            ]
        )
    }

    private func beginImportedAudioFallback(_ reason: WhisperFileImportFallbackReason) {
        importFallbackDescription = WhisperFileImportPolicy.fallbackDescription(for: reason)
        state.phase = .preparing
        state.lastError = nil
        state.updateAudioImportProgress(
            AudioImportProgress(
                stage: .preparing,
                fallbackDescription: importFallbackDescription
            )
        )
        setPreparationStatus("Preparing Profile VAD fallback…")
    }

    private func appendImportedChunkAndWait(
        _ chunk: AudioChunk,
        to engine: RecognitionEngine
    ) async -> RecognitionChunkOutcome {
        await withCheckedContinuation { continuation in
            importedChunkWaiters[chunk.id] = continuation
            engine.append(chunk)
        }
    }

    private func publishImportedAudioProgress(
        currentChunk: Int,
        completedChunks: Int,
        totalChunks: Int,
        completedAudioDuration: TimeInterval,
        totalAudioDuration: TimeInterval,
        startedAt: Date
    ) {
        let elapsed = max(0, Date().timeIntervalSince(startedAt))
        let remaining = AudioImportProgress.estimateRemainingDuration(
            elapsedProcessingDuration: elapsed,
            completedAudioDuration: completedAudioDuration,
            totalAudioDuration: totalAudioDuration
        )
        let progress = AudioImportProgress(
            stage: .transcribing,
            currentChunk: currentChunk,
            completedChunks: completedChunks,
            totalChunks: totalChunks,
            completedAudioDuration: completedAudioDuration,
            totalAudioDuration: totalAudioDuration,
            elapsedProcessingDuration: elapsed,
            estimatedRemainingDuration: remaining,
            fallbackDescription: importFallbackDescription
        )
        state.updateAudioImportProgress(progress)
        state.statusMessage = importedAudioProgressStatus(progress)
    }

    private func importedAudioProgressStatus(_ progress: AudioImportProgress) -> String {
        guard progress.totalChunks > 0 else { return "Transcribing imported audio…" }
        let chunk = min(max(progress.currentChunk, 1), progress.totalChunks)
        var status = "Chunk \(chunk) of \(progress.totalChunks)"
        if let remaining = progress.estimatedRemainingDuration {
            status += " · about \(Self.compactDuration(remaining)) remaining"
        } else if progress.completedChunks == 0 {
            status += " · estimating remaining time…"
        }
        return status
    }

    private static func compactDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        if seconds < 60 { return "\(max(1, seconds)) sec" }
        let minutes = seconds / 60
        if minutes < 60 {
            let remainder = seconds % 60
            return remainder >= 30 ? "\(minutes + 1) min" : "\(minutes) min"
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    private func resolveImportedChunkWaiter(_ outcome: RecognitionChunkOutcome, id: UUID) {
        importedChunkWaiters.removeValue(forKey: id)?.resume(returning: outcome)
    }

    private func cancelImportedChunkWaiters() {
        let waiters = importedChunkWaiters
        importedChunkWaiters.removeAll(keepingCapacity: true)
        for (id, waiter) in waiters {
            waiter.resume(returning: .cancelled(id))
        }
    }

    private var initialRecordingPreparationStatus: String {
        switch settings.recognitionBackend {
        case .appleSpeech:
            return "Preparing Apple Speech…"
        case .whisper:
            return whisperModels.isInstalled(settings.whisperModelID)
                ? "Waiting for \(settings.whisperModelID.title) to load…"
                : "Waiting for \(settings.whisperModelID.title) to download…"
        case .gigaAM:
            return gigaAMModels.isInstalled(settings.gigaAMModelID)
                ? "Waiting for \(settings.gigaAMModelID.title) to load…"
                : "Waiting for \(settings.gigaAMModelID.title) to download…"
        case .qwen3ASR, .parakeet:
            guard let model = settings.selectedLocalONNXModel else {
                return "Waiting for the selected local model…"
            }
            return localONNXModels.isInstalled(model)
                ? "Waiting for \(model.title) to load…"
                : "Waiting for \(model.title) to download…"
        }
    }

    private struct PreparationDisplay {
        let status: String
        let progress: Double?
    }

    private func observeRuntimePreparation() {
        whisperRuntime.$state
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshRuntimePreparationStatus() }
            }
            .store(in: &cancellables)
        whisperDraftRuntime.$state
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshRuntimePreparationStatus() }
            }
            .store(in: &cancellables)
        gigaAMRuntime.$state
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshRuntimePreparationStatus() }
            }
            .store(in: &cancellables)
        gigaAMDraftRuntime.$state
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshRuntimePreparationStatus() }
            }
            .store(in: &cancellables)
        localONNXRuntime.$state
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshRuntimePreparationStatus() }
            }
            .store(in: &cancellables)
    }

    private func refreshRuntimePreparationStatus() {
        guard state.phase == .preparing else { return }
        let display: PreparationDisplay?
        switch settings.recognitionBackend {
        case .appleSpeech:
            display = nil
        case .whisper:
            display =
                whisperPreparationDisplay(whisperRuntime.state, role: nil)
                ?? whisperPreparationDisplay(whisperDraftRuntime.state, role: "draft")
        case .gigaAM:
            display =
                gigaAMPreparationDisplay(gigaAMRuntime.state, role: nil)
                ?? gigaAMPreparationDisplay(gigaAMDraftRuntime.state, role: "draft")
        case .qwen3ASR, .parakeet:
            display = localONNXPreparationDisplay(localONNXRuntime.state)
        }
        guard let display else { return }
        setPreparationStatus(display.status, progress: display.progress)
    }

    private func setPreparationStatus(_ status: String, progress: Double? = nil) {
        state.updatePreparation(
            status: status,
            progress: progress,
            waitingForRecognizer: !state.isImportingAudioFile,
            importingAudioFile: state.isImportingAudioFile
        )
    }

    private func whisperPreparationDisplay(
        _ loadState: WhisperRuntimeLoadState,
        role: String?
    ) -> PreparationDisplay? {
        let prefix = role.map { "\($0.capitalized) " } ?? ""
        switch loadState {
        case .inactive, .ready:
            return nil
        case .notInstalled(let model):
            return PreparationDisplay(
                status: "Waiting to download \(prefix.lowercased())\(model.title)…",
                progress: nil
            )
        case .downloading(let model, let progress):
            return PreparationDisplay(
                status: "Downloading \(prefix.lowercased())\(model.title)… \(Int(progress * 100))%",
                progress: progress
            )
        case .verifying(let model):
            return PreparationDisplay(
                status: "Verifying \(prefix.lowercased())\(model.title)…",
                progress: 0.92
            )
        case .loading(let model, let progress):
            return PreparationDisplay(
                status: "Loading \(prefix.lowercased())\(model.title) into memory… \(Int(progress * 100))%",
                progress: progress
            )
        case .failed(let model, let message):
            return PreparationDisplay(
                status: "Could not prepare \(prefix.lowercased())\(model.title): \(message)",
                progress: nil
            )
        }
    }

    private func gigaAMPreparationDisplay(
        _ loadState: GigaAMRuntimeLoadState,
        role: String?
    ) -> PreparationDisplay? {
        let prefix = role.map { "\($0) " } ?? ""
        switch loadState {
        case .inactive, .ready:
            return nil
        case .notInstalled(let model):
            return PreparationDisplay(
                status: "Waiting to download \(prefix)\(model.title)…",
                progress: nil
            )
        case .downloading(let model, let progress):
            return PreparationDisplay(
                status: "Downloading \(prefix)\(model.title)… \(Int(progress * 100))%",
                progress: progress
            )
        case .verifying(let model, let progress):
            return PreparationDisplay(
                status: "Verifying \(prefix)\(model.title)… \(Int(progress * 100))%",
                progress: progress
            )
        case .loading(let model, let progress):
            return PreparationDisplay(
                status: "Loading \(prefix)\(model.title) into memory… \(Int(progress * 100))%",
                progress: progress
            )
        case .failed(let model, let message):
            return PreparationDisplay(
                status: "Could not prepare \(prefix)\(model.title): \(message)",
                progress: nil
            )
        }
    }

    private func localONNXPreparationDisplay(
        _ loadState: LocalONNXRuntimeLoadState
    ) -> PreparationDisplay? {
        switch loadState {
        case .inactive, .ready:
            return nil
        case .notInstalled(let model):
            return PreparationDisplay(
                status: "Waiting to download \(model.title)…",
                progress: nil
            )
        case .downloading(let model, let progress):
            return PreparationDisplay(
                status: "Downloading \(model.title)… \(Int(progress * 100))%",
                progress: progress
            )
        case .verifying(let model, let progress):
            return PreparationDisplay(
                status: "Verifying \(model.title)… \(Int(progress * 100))%",
                progress: progress
            )
        case .loading(let model, let progress):
            return PreparationDisplay(
                status: "Loading \(model.title) into memory… \(Int(progress * 100))%",
                progress: progress
            )
        case .failed(let model, let message):
            return PreparationDisplay(
                status: "Could not prepare \(model.title): \(message)",
                progress: nil
            )
        }
    }

    private func makeRecognitionEngine(
        includeDraft: Bool = true,
        boundaryStrategyOverride: WhisperBoundaryStrategy? = nil
    ) async throws -> RecognitionEngine {
        switch settings.recognitionBackend {
        case .appleSpeech:
            return makeAppleSpeechEngine()

        case .whisper:
            let finalModel = settings.whisperModelID
            let inferenceConfiguration = whisperInferenceConfiguration(
                boundaryStrategyOverride: boundaryStrategyOverride
            )
            setPreparationStatus(
                whisperModels.isInstalled(finalModel)
                    ? "Waiting for \(finalModel.title) to load…"
                    : "Waiting for \(finalModel.title) to download…"
            )
            let finalRuntime = try await whisperRuntime.prepare(
                finalModel,
                runtimeConfiguration: settings.whisperRuntimeConfiguration,
                installIfNeeded: true
            )
            let finalEngine = WhisperRecognitionEngine(
                model: finalModel,
                runtime: finalRuntime,
                inferenceConfiguration: inferenceConfiguration,
                hallucinationGuardConfiguration: settings.hallucinationGuardConfiguration
            )
            guard includeDraft else { return finalEngine }

            switch settings.effectiveWhisperDraftSource {
            case .none:
                diagnostics.info(
                    "Recognition path selected",
                    metadata: [
                        "backend": "whisper",
                        "draft": "none",
                        "textAuthority": "final-model-only",
                    ]
                )
                return finalEngine

            case .appleSpeech:
                return AppleDraftRefinementRecognitionEngine(
                    displayName: "Apple Draft → Whisper · \(finalModel.title)",
                    draftLocaleIdentifier: settings.appleSpeechLanguageIdentifier,
                    draft: makeAppleSpeechEngine(),
                    finalEngine: finalEngine
                )

            case .localWhisper:
                let draftModel = settings.whisperDraftModelID
                setPreparationStatus(
                    whisperModels.isInstalled(draftModel)
                        ? "Waiting for \(draftModel.title) draft to load…"
                        : "Waiting for \(draftModel.title) draft to download…"
                )
                let draftRuntime = try await whisperDraftRuntime.prepare(
                    draftModel,
                    runtimeConfiguration: settings.whisperRuntimeConfiguration,
                    installIfNeeded: true
                )
                let draftEngine = WhisperRecognitionEngine(
                    model: draftModel,
                    runtime: draftRuntime,
                    inferenceConfiguration: inferenceConfiguration
                )
                return ChunkDraftRefinementRecognitionEngine(
                    displayName: "\(draftModel.title) Draft → \(finalModel.title)",
                    draftLocaleIdentifier: settings.whisperLanguageCode,
                    finalLocaleIdentifier: settings.whisperLanguageCode,
                    draftEngine: draftEngine,
                    finalEngine: finalEngine
                )
            }

        case .gigaAM:
            let finalModel = settings.gigaAMModelID
            setPreparationStatus(
                gigaAMModels.isInstalled(finalModel)
                    ? "Waiting for \(finalModel.title) to load…"
                    : "Waiting for \(finalModel.title) to download…"
            )
            let finalRuntime = try await gigaAMRuntime.prepare(
                finalModel,
                installIfNeeded: true,
                numberOfThreads: settings.gigaAMThreadCount,
                provider: settings.gigaAMExecutionProvider.runtimeValue
            )
            let finalEngine = GigaAMRecognitionEngine(
                model: finalModel,
                runtime: finalRuntime,
                policy: settings.makeGigaAMChunkPolicy(),
                hallucinationGuardConfiguration: settings.hallucinationGuardConfiguration
            )
            guard includeDraft else { return finalEngine }

            switch settings.effectiveGigaAMDraftSource {
            case .none:
                return finalEngine

            case .appleSpeech:
                return AppleDraftRefinementRecognitionEngine(
                    displayName: "Apple Draft → GigaAM · \(finalModel.title)",
                    draftLocaleIdentifier: "ru-RU",
                    draft: makeAppleSpeechEngine(),
                    finalEngine: finalEngine
                )

            case .localGigaAM:
                let draftModel = settings.gigaAMDraftModelID
                setPreparationStatus(
                    gigaAMModels.isInstalled(draftModel)
                        ? "Waiting for \(draftModel.title) draft to load…"
                        : "Waiting for \(draftModel.title) draft to download…"
                )
                let draftRuntime = try await gigaAMDraftRuntime.prepare(
                    draftModel,
                    installIfNeeded: true,
                    numberOfThreads: settings.gigaAMThreadCount,
                    provider: settings.gigaAMExecutionProvider.runtimeValue
                )
                let draftEngine = GigaAMRecognitionEngine(
                    model: draftModel,
                    runtime: draftRuntime,
                    policy: settings.makeGigaAMChunkPolicy()
                )
                return ChunkDraftRefinementRecognitionEngine(
                    displayName: "\(draftModel.title) Draft → \(finalModel.title)",
                    draftLocaleIdentifier: "ru-RU",
                    finalLocaleIdentifier: "ru-RU",
                    draftEngine: draftEngine,
                    finalEngine: finalEngine
                )
            }
        case .qwen3ASR, .parakeet:
            guard let model = settings.selectedLocalONNXModel else {
                throw RecognitionEngineError.modelCouldNotBeLoaded(
                    settings.recognitionBackend.title
                )
            }
            setPreparationStatus(
                localONNXModels.isInstalled(model)
                    ? "Waiting for \(model.title) to load…"
                    : "Waiting for \(model.title) to download…"
            )
            let runtime = try await localONNXRuntime.prepare(
                model,
                installIfNeeded: true,
                numberOfThreads: settings.localONNXThreadCount,
                provider: settings.localONNXExecutionProvider.runtimeValue
            )
            let finalEngine = LocalONNXRecognitionEngine(
                model: model,
                runtime: runtime,
                policy: settings.makeLocalONNXChunkPolicy(),
                hallucinationGuardConfiguration: settings.hallucinationGuardConfiguration
            )
            guard includeDraft else { return finalEngine }

            switch settings.effectiveLocalONNXDraftSource {
            case .none:
                return finalEngine
            case .appleSpeech:
                return AppleDraftRefinementRecognitionEngine(
                    displayName: "Apple Draft → \(model.shortTitle)",
                    draftLocaleIdentifier: settings.appleSpeechLanguageIdentifier,
                    draft: makeAppleSpeechEngine(),
                    finalEngine: finalEngine
                )
            }
        }
    }

    private func whisperInferenceConfiguration(
        boundaryStrategyOverride: WhisperBoundaryStrategy?
    ) -> WhisperInferenceConfiguration {
        let configured = settings.whisperInferenceConfiguration
        return WhisperInferenceConfiguration(
            numberOfThreads: configured.numberOfThreads,
            usesCustomDecoding: configured.usesCustomDecoding,
            decodingStrategy: configured.decodingStrategy,
            greedyBestOf: configured.greedyBestOf,
            beamSize: configured.beamSize,
            initialPrompt: configured.initialPrompt,
            boundaryStrategy: boundaryStrategyOverride ?? configured.boundaryStrategy,
            overlapDuration: configured.overlapDuration,
            contextPromptMode: configured.contextPromptMode
        )
    }

    private func makeAppleSpeechEngine() -> SystemSpeechRecognitionEngine {
        SystemSpeechRecognitionEngine(
            onDeviceOnly: settings.appleSpeechOnDeviceOnly,
            addsPunctuation: settings.appleSpeechAddsPunctuation,
            contextualPhrases: settings.appleSpeechVocabularyTerms
        )
    }

    private func segmenterConfiguration() -> AudioSegmenter.Configuration {
        settings.makeRecognitionSegmenterConfiguration()
    }

    private func prepareVoiceActivityRuntime(
        force: Bool = false
    ) async throws -> SileroVADRuntime? {
        guard force || settings.effectiveVoiceActivityDetectionMode != .energy else { return nil }
        if !sileroVADModels.isInstalled {
            setPreparationStatus("Downloading Silero voice detection…")
        }
        let modelURL = try await sileroVADModels.ensureInstalled()
        return try SileroVADRuntime(
            modelURL: modelURL,
            configuration: settings.sileroRuntimeConfiguration
        )
    }

    private func logAudioCaptureStopped(_ stopResult: AudioCaptureStopResult) {
        diagnostics.info(
            "Audio capture stopped",
            metadata: [
                "capturedSeconds": String(format: "%.3f", stopResult.capturedDuration),
                "deliveredChunks": String(stopResult.emittedChunkCount),
                "finalChunks": String(stopResult.finalChunks.count),
            ]
        )
    }

    private func setFinalizationStatus() {
        switch settings.recognitionBackend {
        case .appleSpeech: state.statusMessage = "Completing the last phrase…"
        case .whisper: state.statusMessage = "Processing remaining Whisper chunks…"
        case .gigaAM: state.statusMessage = "Refining the final Russian transcript with GigaAM…"
        case .qwen3ASR: state.statusMessage = "Refining the final transcript with Qwen3-ASR…"
        case .parakeet: state.statusMessage = "Processing remaining Parakeet chunks…"
        }
    }

    func stopRecording() {
        inputReconnectTask?.cancel()
        inputReconnectTask = nil
        hotKeyReleaseStopTask?.cancel()
        hotKeyReleaseStopTask = nil
        guard state.phase == .listening, let engine = recognitionEngine else { return }

        let capturedDuration = audioCapture.currentCapturedDuration
        guard
            RecordingStopPolicy.action(
                for: capturedDuration,
                minimumDuration: minimumAcceptedRecordingDuration
            ) == .flushAndFinalize
        else {
            discardTooShortRecording(engine: engine)
            return
        }

        state.phase = .stopping
        state.statusMessage = "Stopping recording…"
        state.finishAudioCapture()
        let stopResult = audioCapture.stop(
            flushFinalChunk: true,
            forceChunkIfDurationAtLeast: minimumAcceptedRecordingDuration
        )
        endDebugAudioRecording()
        logAudioCaptureStopped(stopResult)
        let acceptsFinalChunks =
            engine.audioInputMode == .vadChunks
            || engine.audioInputMode == .continuousBuffersAndVADChunks

        if acceptsFinalChunks, stopResult.emittedChunkCount == 0 {
            engine.cancel()
            recognitionEngine = nil
            diagnostics.error(
                "Accepted recording produced no recognition chunks",
                metadata: [
                    "capturedSeconds": String(format: "%.3f", stopResult.capturedDuration),
                    "engine": engine.displayName,
                ]
            )
            state.fail("Recorded audio could not be queued for recognition. Please try again.")
            return
        }

        RecognitionStopHandoff.perform(
            finalChunks: stopResult.finalChunks,
            acceptsChunks: acceptsFinalChunks,
            append: { chunk in
                state.emittedChunkCount += 1
                state.queueRecognitionChunk(chunk)
                diagnostics.info(
                    "Final audio chunk queued",
                    metadata: [
                        "chunk": chunk.id.uuidString,
                        "duration": String(format: "%.3f", chunk.duration),
                        "boundary": chunk.boundaryReason.rawValue,
                        "overlapSeconds": String(
                            format: "%.3f",
                            chunk.trailingOverlapDuration
                        ),
                    ]
                )
                engine.append(chunk)
            },
            prepareToFinish: {
                state.phase = .finalizing
                finalizationStartedAt = Date()
                setFinalizationStatus()
                // State and pending work must be visible before finish(). Some
                // engines complete synchronously when their queue is empty.
                diagnostics.info(
                    "Recognition finish requested",
                    metadata: ["pendingChunks": String(state.pendingRecognitionWork.chunkCount)]
                )
            },
            finish: {
                engine.finish()
            }
        )

        scheduleFinalizationTimeout(for: engine)
    }

    private func scheduleFinalizationTimeout(for engine: RecognitionEngine) {
        let operationAtStop = operationID
        let timeout = engine.finalizationTimeout
        finalizationTimeoutTask?.cancel()
        finalizationTimeoutTask = Task { [weak self, weak engine] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled,
                let self,
                let engine,
                self.recognitionEngine === engine,
                self.operationID == operationAtStop,
                self.state.phase == .finalizing
            else { return }
            guard RecognitionFinalizationPolicy.action(for: .timeout) == .fail else { return }
            engine.cancel()
            self.diagnostics.error(
                "Recognition finalization timed out",
                metadata: ["pendingChunks": String(self.state.pendingRecognitionWork.chunkCount)]
            )
            self.persistCurrentTranscriptCheckpoint(reason: "recognition timeout", force: true)
            self.state.fail(
                "Recognition did not finish all queued audio in time. The partial transcript was preserved.")
        }
    }

    private func discardTooShortRecording(engine: RecognitionEngine?) {
        let stopResult = audioCapture.stop(flushFinalChunk: false)
        endDebugAudioRecording()
        let heldDuration = Date().timeIntervalSince(recordingStartedAt ?? Date())
        if !audioCapture.hasReceivedSessionAudio, heldDuration >= minimumAcceptedRecordingDuration {
            startTask?.cancel()
            engine?.cancel()
            recognitionEngine = nil
            engineDidFinish = false
            stopAfterPreparation = false
            diagnostics.error(
                "Recording ended without microphone audio",
                metadata: ["heldSeconds": String(format: "%.3f", heldDuration)]
            )
            onShowCompactPanel?()
            state.fail(AudioCaptureError.noAudioReceived.localizedDescription)
            return
        }
        diagnostics.info(
            "Audio capture discarded as an accidental tap",
            metadata: [
                "capturedSeconds": String(format: "%.3f", stopResult.capturedDuration),
                "heldSeconds": String(
                    format: "%.3f",
                    Date().timeIntervalSince(recordingStartedAt ?? Date())
                ),
                "minimumSeconds": String(format: "%.3f", minimumAcceptedRecordingDuration),
            ]
        )
        if engine == nil {
            startTask?.cancel()
        }
        engine?.cancel()
        recognitionEngine = nil
        engineDidFinish = false
        state.resetForNewSession()
        state.phase = .result
        state.completionPresentation = .tooShort
        state.statusMessage = "Recording too short"

        let discardedOperation = operationID
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard let self,
                self.operationID == discardedOperation,
                self.state.phase == .result,
                self.state.completionPresentation == .tooShort
            else { return }
            self.onHideCompactPanel?()
            self.onHideFullTranscript?()
            self.state.phase = .idle
            self.state.completionPresentation = .none
            self.state.statusMessage = "Ready"
            self.recordingInitiator = nil
        }
    }

    func cancelCurrentSession(showFeedback: Bool = true) {
        inputReconnectTask?.cancel()
        inputReconnectTask = nil
        operationID = UUID()
        stopAfterPreparation = false
        hotKeyReleaseStopTask?.cancel()
        hotKeyReleaseStopTask = nil
        startTask?.cancel()
        finalizationTimeoutTask?.cancel()
        finalizationTimeoutTask = nil
        finalizationCompletionTask?.cancel()
        finalizationCompletionTask = nil
        transcriptPostProcessingTask?.cancel()
        transcriptPostProcessingTask = nil
        finalizationStartedAt = nil
        startTask = nil
        _ = audioCapture.stop(flushFinalChunk: false)
        endDebugAudioRecording()
        recognitionEngine?.cancel()
        recognitionEngine = nil
        engineDidFinish = false
        recordingInitiator = nil
        recordingStartedAt = nil
        currentHistoryRecordID = nil
        importedAudioDuration = nil
        cancelImportedChunkWaiters()
        cancelRecognitionUpdateFlush(discardPending: true)
        state.hasLiveDraftText = false
        state.clearRecordingContext()
        state.discardTranscriptContent()
        guard showFeedback else {
            onHideCompactPanel?()
            onHideFullTranscript?()
            state.phase = .idle
            state.statusMessage = "Ready"
            return
        }

        state.phase = .cancelled
        state.statusMessage = "Cancelled"

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.state.phase == .cancelled else { return }
            self.state.phase = .idle
            self.state.statusMessage = "Ready"
        }
    }

    func startMonitoring() {
        guard state.phase == .idle || state.phase == .result || state.phase == .failed else { return }
        persistEditedResultIfNeeded()
        operationID = UUID()
        let currentOperationID = operationID
        state.phase = .preparing
        state.statusMessage = "Opening microphone…"

        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await AudioCaptureService.requestMicrophonePermission()
                try Task.checkCancellation()
                guard self.operationID == currentOperationID else { return }

                self.configureAudioCallbacks(sendToRecognizer: false, engine: nil)
                let vadConfiguration = self.settings.makeVADConfiguration()
                self.state.currentLevelDB = -90
                self.state.noiseFloorDB = vadConfiguration.initialNoiseFloorDB
                self.state.thresholdDB = vadConfiguration.threshold(
                    for: vadConfiguration.initialNoiseFloorDB
                )
                self.state.voiceActivityState = .silence
                let sileroVAD = try await self.prepareVoiceActivityRuntime()
                try self.audioCapture.start(
                    selectedDeviceID: self.validatedInputSelection(),
                    vadConfiguration: vadConfiguration,
                    segmenterConfiguration: self.segmenterConfiguration(),
                    detectionMode: self.settings.effectiveVoiceActivityDetectionMode,
                    sileroVAD: sileroVAD,
                    suppressSilenceInRecognizer: false
                )
                self.state.phase = .monitoring
                self.state.statusMessage = "Input test"
            } catch is CancellationError {
                return
            } catch {
                _ = self.audioCapture.stop(flushFinalChunk: false)
                self.state.fail(error.localizedDescription)
            }
        }
    }

    func stopMonitoring() {
        guard state.phase == .monitoring || state.phase == .preparing else { return }
        inputReconnectTask?.cancel()
        inputReconnectTask = nil
        operationID = UUID()
        hotKeyReleaseStopTask?.cancel()
        hotKeyReleaseStopTask = nil
        startTask?.cancel()
        startTask = nil
        _ = audioCapture.stop(flushFinalChunk: false)
        state.phase = .idle
        state.statusMessage = "Ready"
    }

    func updateVADConfiguration() {
        let configuration = settings.makeVADConfiguration()
        audioCapture.updateVADConfiguration(
            configuration,
            detectionMode: settings.effectiveVoiceActivityDetectionMode
        )
        let displayedNoiseFloor =
            state.noiseFloorDB.isFinite
                && state.noiseFloorDB >= configuration.minimumNoiseObservationDB
            ? state.noiseFloorDB
            : configuration.initialNoiseFloorDB
        state.noiseFloorDB = displayedNoiseFloor
        state.thresholdDB = configuration.threshold(for: displayedNoiseFloor)
    }

    func selectedInputDeviceDidChange() {
        let selectedDeviceID = AudioDeviceID(settings.selectedInputDeviceID)
        if selectedDeviceID != 0, AudioInputDeviceManager.isInputDeviceAvailable(selectedDeviceID) {
            state.inputDeviceWarning = nil
        }
        guard audioCapture.hasActiveSession else { return }
        scheduleInputRecovery(
            change: .deviceListChanged,
            reason: "user selection changed",
            forceReconnect: true
        )
    }

    private func audioInputDeviceDidChange(_ event: AudioInputDeviceChangeEvent) {
        switch event {
        case .defaultInputChanged(let defaultDeviceID):
            scheduleInputRecovery(
                change: .defaultInputChanged,
                reason: "system default changed to \(defaultDeviceID.map(String.init) ?? "none")",
                forceReconnect: false
            )
        case .deviceListChanged:
            scheduleInputRecovery(
                change: .deviceListChanged,
                reason: "input device topology changed",
                forceReconnect: false
            )
        }
    }

    private func validatedInputSelection() -> AudioDeviceID {
        let preferredDeviceID = AudioDeviceID(settings.selectedInputDeviceID)
        guard preferredDeviceID != 0,
            !AudioInputDeviceManager.isInputDeviceAvailable(preferredDeviceID)
        else { return preferredDeviceID }

        settings.selectedInputDeviceID = 0
        state.inputDeviceWarning =
            "The selected microphone was disconnected. VoicePanel switched to the system default input."
        diagnostics.warning(
            "Unavailable input preference repaired",
            metadata: ["missingDevice": String(preferredDeviceID)]
        )
        return 0
    }

    private func checkAudioCaptureLiveness() {
        guard audioCapture.hasActiveSession,
            !stopAfterPreparation,
            inputReconnectTask == nil,
            state.phase == .preparing || state.phase == .listening || state.phase == .monitoring,
            audioCapture.captureLiveness == .stalled
        else { return }

        state.inputDeviceWarning = "Microphone audio stopped arriving. Reconnecting…"
        diagnostics.warning(
            "Audio input stopped delivering buffers",
            metadata: [
                "requestedDevice": audioCapture.currentDeviceSelection.map(String.init) ?? "none",
                "resolvedDevice": audioCapture.currentResolvedDeviceSelection.map(String.init) ?? "none",
                "capturedSeconds": String(format: "%.3f", audioCapture.currentCapturedDuration),
            ]
        )
        scheduleInputRecovery(
            change: .deviceListChanged,
            reason: "audio buffer timeout",
            forceReconnect: true
        )
    }

    private func scheduleInputRecovery(
        change: AudioInputTopologyChange,
        reason: String,
        forceReconnect: Bool
    ) {
        inputReconnectTask?.cancel()
        let expectedOperationID = operationID
        let recoveryID = UUID()
        inputRecoveryID = recoveryID
        inputReconnectTask = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performInputRecovery(
                change: change,
                reason: reason,
                forceReconnect: forceReconnect,
                expectedOperationID: expectedOperationID,
                recoveryID: recoveryID
            )
        }
    }

    private func performInputRecovery(
        change: AudioInputTopologyChange,
        reason: String,
        forceReconnect: Bool,
        expectedOperationID: UUID,
        recoveryID: UUID
    ) async {
        defer { finishInputRecovery(id: recoveryID) }

        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled, !stopAfterPreparation else { return }

        let snapshot = AudioInputDeviceManager.snapshot()
        let preferredSelection = settings.selectedInputDeviceID
        var decision = makeInputRecoveryDecision(
            snapshot: snapshot,
            preferredSelection: preferredSelection,
            change: change
        )

        if decision.persistedSelection != preferredSelection {
            settings.selectedInputDeviceID = decision.persistedSelection
            state.inputDeviceWarning =
                "The selected microphone was disconnected. VoicePanel switched to the system default input."
            if state.phase == .idle || state.phase == .result || state.phase == .failed {
                state.statusMessage = "Microphone disconnected · using system default"
            }
            diagnostics.warning(
                "Selected audio input disappeared",
                metadata: [
                    "missingDevice": String(preferredSelection),
                    "fallbackDefault": snapshot.defaultDeviceID.map(String.init) ?? "none",
                ]
            )
        }

        guard operationID == expectedOperationID || !audioCapture.hasActiveSession else { return }

        if forceReconnect, audioCapture.hasActiveSession, decision.reconnectSelection != nil {
            decision = AudioInputRecoveryDecision(
                persistedSelection: decision.persistedSelection,
                reconnectSelection: decision.reconnectSelection,
                usesSystemFallback: decision.usesSystemFallback,
                shouldReconnect: true
            )
        }

        guard decision.shouldReconnect, let reconnectSelection = decision.reconnectSelection else {
            if audioCapture.hasActiveSession, decision.persistedSelection == 0, snapshot.defaultDeviceID == nil {
                audioCapture.pauseCaptureForDeferredStop()
                persistCurrentTranscriptCheckpoint(reason: "input unavailable")
                state.inputDeviceWarning = "No microphone is available. Connect an input device to continue."
                state.statusMessage = "Microphone unavailable · recording preserved"
            }
            return
        }

        guard
            state.phase == .preparing
                || state.phase == .listening
                || state.phase == .monitoring,
            audioCapture.hasActiveSession
        else { return }

        persistCurrentTranscriptCheckpoint(reason: "audio input handoff")
        let previousResolvedDeviceID = audioCapture.currentResolvedDeviceSelection
        let intendedResolvedDeviceID: AudioDeviceID? =
            reconnectSelection == 0
            ? snapshot.defaultDeviceID
            : AudioDeviceID(reconnectSelection)
        var closeCurrentInputTail = previousResolvedDeviceID != intendedResolvedDeviceID
        let retryDelays: [Duration] = [.zero, .milliseconds(180), .milliseconds(420), .milliseconds(900)]
        var lastError: Error?

        for (attempt, delay) in retryDelays.enumerated() {
            if delay != .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, !stopAfterPreparation, operationID == expectedOperationID,
                state.phase == .preparing
                    || state.phase == .listening
                    || state.phase == .monitoring
            else { return }

            let currentSnapshot = AudioInputDeviceManager.snapshot()
            let targetSelection: AudioDeviceID
            if reconnectSelection == 0 {
                guard currentSnapshot.defaultDeviceID != nil else {
                    lastError = AudioCaptureError.noDefaultInputDevice
                    continue
                }
                targetSelection = 0
            } else {
                guard currentSnapshot.availableDeviceIDs.contains(reconnectSelection) else {
                    lastError = AudioCaptureError.inputDeviceUnavailable(AudioDeviceID(reconnectSelection))
                    continue
                }
                targetSelection = AudioDeviceID(reconnectSelection)
            }

            state.statusMessage =
                decision.usesSystemFallback
                ? "Selected microphone disconnected · switching to system input…"
                : "Refreshing microphone connection…"
            diagnostics.info(
                "Audio input handoff started",
                metadata: [
                    "reason": reason,
                    "attempt": String(attempt + 1),
                    "targetSelection": String(targetSelection),
                    "capturedSeconds": String(
                        format: "%.3f",
                        audioCapture.currentCapturedDuration
                    ),
                ]
            )

            do {
                let resolvedDeviceID = try audioCapture.reconnect(
                    selectedDeviceID: targetSelection,
                    closeCurrentInputTail: closeCurrentInputTail
                )
                // Core Audio can report a successful start without delivering
                // any input. Only complete the handoff after a real PCM buffer.
                closeCurrentInputTail = false
                try await waitForInputBuffer(expectedOperationID: expectedOperationID)
                if !decision.usesSystemFallback {
                    state.inputDeviceWarning = nil
                }
                restoreStatusAfterInputReconnect(usingFallback: decision.usesSystemFallback)
                diagnostics.info(
                    "Audio input handoff completed",
                    metadata: [
                        "requestedDevice": String(targetSelection),
                        "resolvedDevice": String(resolvedDeviceID),
                        "capturedSeconds": String(
                            format: "%.3f",
                            audioCapture.currentCapturedDuration
                        ),
                    ]
                )
                return
            } catch is CancellationError {
                return
            } catch {
                lastError = error
                closeCurrentInputTail = false
                diagnostics.warning(
                    "Audio input handoff attempt failed",
                    metadata: [
                        "attempt": String(attempt + 1),
                        "targetSelection": String(targetSelection),
                        "error": error.localizedDescription,
                    ]
                )
            }
        }

        audioCapture.pauseCaptureForDeferredStop()
        state.inputDeviceWarning =
            "The microphone is not delivering audio. Check its connection or select another input."
        persistCurrentTranscriptCheckpoint(reason: "audio input handoff suspended")
        state.statusMessage = "Microphone unavailable · recording preserved; waiting for input…"
        diagnostics.warning(
            "Audio input handoff suspended",
            metadata: [
                "error": lastError?.localizedDescription ?? "No input device is available",
                "capturedSeconds": String(
                    format: "%.3f",
                    audioCapture.currentCapturedDuration
                ),
            ]
        )
    }

    private func waitForInputBuffer(expectedOperationID: UUID) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        while true {
            try Task.checkCancellation()
            guard operationID == expectedOperationID, !stopAfterPreparation,
                audioCapture.hasActiveSession,
                state.phase == .preparing || state.phase == .listening || state.phase == .monitoring
            else { throw CancellationError() }
            if audioCapture.captureLiveness == .receiving { return }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw AudioCaptureError.noAudioReceived
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func makeInputRecoveryDecision(
        snapshot: AudioInputDeviceSnapshot,
        preferredSelection: UInt32,
        change: AudioInputTopologyChange
    ) -> AudioInputRecoveryDecision {
        let availableDeviceIDs: Set<UInt32> = snapshot.availableDeviceIDs
        let defaultDeviceID: UInt32? = snapshot.defaultDeviceID
        let currentRequestedSelection: UInt32? = audioCapture.currentDeviceSelection
        let currentResolvedDeviceID: UInt32? = audioCapture.currentResolvedDeviceSelection
        let hasActiveSession: Bool = audioCapture.hasActiveSession
        let isCapturing: Bool = audioCapture.isCapturingAudio

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

    private func restoreStatusAfterInputReconnect(usingFallback: Bool) {
        switch state.phase {
        case .monitoring:
            state.statusMessage = usingFallback ? "Input test · system fallback" : "Input test"
        case .preparing:
            state.statusMessage =
                usingFallback
                ? "Recording · system fallback · preparing recognizer…"
                : "Recording · preparing recognizer…"
        case .listening:
            let prefix = usingFallback ? "Recording · system fallback" : "Recording"
            state.statusMessage =
                recordingInitiator == .hotKeyHold
                ? "\(prefix) · hold hot key"
                : "\(prefix) · press Stop when finished"
        default:
            break
        }
    }

    func copyResultToPasteboard() {
        guard state.phase == .result || state.phase == .failed else {
            switch state.phase {
            case .stopping, .finalizing:
                state.statusMessage = "Finishing transcript before copying…"
            default:
                break
            }
            return
        }
        let text = currentResultText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        state.statusMessage = "Copied"
    }

    func copyFromTranscriptWindow() {
        if state.phase == .result || state.phase == .failed { copyAndDismissResult() } else { copyResultToPasteboard() }
    }

    func copyAndDismissResult() {
        persistEditedResultIfNeeded()
        copyResultToPasteboard()
        dismissResult()
    }

    func copyResultWithFeedback() {
        persistEditedResultIfNeeded()
        let text = currentResultText
        guard !text.isEmpty else { return }
        copyResultToPasteboard()
        state.completionPresentation = .copied
    }

    func dismissResult() {
        persistEditedResultIfNeeded()
        if state.phase == .result || state.phase == .failed {
            state.phase = .idle
            state.completionPresentation = .none
            state.statusMessage = "Ready"
        }
        onHideCompactPanel?()
        onHideFullTranscript?()
        recordingInitiator = nil
        state.clearRecordingContext()
        recognitionEngine = nil
        engineDidFinish = false
        currentHistoryRecordID = nil
        importedAudioDuration = nil
        cancelImportedChunkWaiters()
        cancelRecognitionUpdateFlush(discardPending: true)
        state.discardTranscriptContent()
    }

    func closeFullTranscript() {
        if state.phase == .result || state.phase == .failed { dismissResult() } else { onHideFullTranscript?() }
    }

    private var currentResultText: String {
        if state.phase == .result {
            return state.editableText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let source: String
        if recognitionEngine?.finalTextPolicy == .finalizedSegmentsOnly {
            source = state.transcriptSession.finalizedText
        } else {
            source = state.transcriptSession.combinedText
        }
        return source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func finalizeCurrentResult() {
        guard state.phase == .finalizing, finalizedOperationID != operationID else { return }
        finalizationTimeoutTask?.cancel()
        finalizationTimeoutTask = nil
        finalizationCompletionTask?.cancel()
        finalizationCompletionTask = nil
        finalizationStartedAt = nil
        finalizedOperationID = operationID

        let finalizationOperationID = operationID
        let finalizedSegmentsOnly = recognitionEngine?.finalTextPolicy == .finalizedSegmentsOnly
        let segments = state.transcriptSession.segments.compactMap {
            segment -> TranscriptPostProcessingSegment? in
            let text: String?
            if finalizedSegmentsOnly {
                text = segment.finalText
            } else {
                text = segment.displayText
            }
            guard let text else { return nil }
            return TranscriptPostProcessingSegment(
                text: text,
                boundaryMetadata: state.boundaryMetadata(forTranscriptSegment: segment)
            )
        }
        let cleanupConfiguration = settings.transcriptPostProcessingConfiguration
        let shouldRunRussianCorrection = settings.usesGigaAMRussianCorrection
        state.statusMessage =
            cleanupConfiguration.isEnabled
            ? "Cleaning up transcript…"
            : "Preparing transcript…"

        transcriptPostProcessingTask?.cancel()
        transcriptPostProcessingTask = Task { [weak self] in
            guard let self else { return }

            let cleanup = TranscriptPostProcessor.process(
                segments: segments,
                configuration: cleanupConfiguration
            )
            var finalText = cleanup.text
            var correctionApplied = false
            var correctionFailure: String?

            if shouldRunRussianCorrection, !finalText.isEmpty, !Task.isCancelled {
                self.state.statusMessage =
                    self.russianCorrectionModels.isInstalled(.sageFREDT5Int8)
                    ? "Correcting Russian text…"
                    : "Downloading Russian correction model…"
                do {
                    let runtime = try await self.russianCorrectionRuntime.prepare(
                        installIfNeeded: true,
                        numberOfThreads: max(1, min(4, self.settings.gigaAMThreadCount))
                    )
                    try Task.checkCancellation()
                    let correction = try await runtime.correct(finalText)
                    if !correction.text.isEmpty {
                        correctionApplied = correction.didChange
                        finalText = correction.text
                    }
                    self.diagnostics.info(
                        "Russian transcript edit filtering completed",
                        metadata: [
                            "proposedEdits": String(correction.proposedEditCount),
                            "acceptedEdits": String(correction.acceptedEditCount),
                            "rejectedEdits": String(correction.rejectedEditCount),
                            "rejectedMeaningChanges": String(
                                correction.rejectedMeaningChangingEditCount
                            ),
                        ]
                    )
                } catch is CancellationError {
                    guard !Task.isCancelled,
                        self.operationID == finalizationOperationID,
                        self.state.phase == .finalizing
                    else { return }
                    correctionFailure = "Russian correction preparation was cancelled."
                    self.diagnostics.warning(
                        "Russian transcript correction was cancelled; using the cleaned ASR result"
                    )
                } catch {
                    correctionFailure = error.localizedDescription
                    self.diagnostics.warning(
                        "Russian transcript correction failed; using the cleaned ASR result",
                        metadata: ["error": error.localizedDescription]
                    )
                }
            }

            guard !Task.isCancelled,
                self.operationID == finalizationOperationID,
                self.state.phase == .finalizing
            else { return }

            self.transcriptPostProcessingTask = nil
            self.state.finalizeResult(
                finalizedSegmentsOnly: finalizedSegmentsOnly,
                processedText: finalText
            )
            var metadata = [
                "characters": String(self.currentResultText.count),
                "finalizedOnly": String(finalizedSegmentsOnly),
                "failedChunks": String(self.state.pendingRecognitionWork.failedChunkCount),
                "segments": String(self.state.transcriptSession.segments.count),
                "cleanupEnabled": String(cleanupConfiguration.isEnabled),
                "removedSegments": String(cleanup.removedSegmentCount),
                "stitchedBoundaries": String(cleanup.stitchedBoundaryCount),
                "russianCorrectionEnabled": String(shouldRunRussianCorrection),
                "russianCorrectionApplied": String(correctionApplied),
            ]
            if let correctionFailure { metadata["russianCorrectionFailure"] = correctionFailure }
            self.diagnostics.info("Recognition finalization completed", metadata: metadata)
            self.persistFinalResult()
            self.presentCompletedResult()
        }
    }

    private func presentCompletedResult() {
        let completionOperation = operationID
        let hasText = !currentResultText.isEmpty
        let hasChunkFailures = state.pendingRecognitionWork.failedChunkCount > 0
        if importedAudioDuration != nil {
            switch WhisperFileImportPolicy.terminalPresentation(
                hasText: hasText,
                failedChunkCount: state.pendingRecognitionWork.failedChunkCount
            ) {
            case .partialIssue:
                state.completionPresentation = .partialIssue
                state.statusMessage = "Completed with an issue"
            case .interactive:
                state.completionPresentation = .interactive
                state.statusMessage = "Imported transcript ready"
                onHideCompactPanel?()
                onShowFullTranscript?()
            case .noSpeech:
                state.completionPresentation = .interactive
                state.statusMessage = "No speech recognized"
                onHideCompactPanel?()
                onShowFullTranscript?()
            }
            return
        }
        if hasChunkFailures {
            state.completionPresentation = .partialIssue
            state.statusMessage = "Completed with an issue"
            return
        }
        state.completionPresentation = hasText ? .success : .noSpeech

        switch recordingInitiator {
        case .hotKeyHold:
            if hasText {
                // The success presentation means the transcript is ready for use.
                // Keep the following delays purely visual; the pasteboard must
                // already contain this result when the green state appears.
                copyResultToPasteboard()
            }
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(480))
                guard self.operationID == completionOperation, self.state.phase == .result else { return }

                if hasText {
                    self.state.completionPresentation = .copied
                    self.state.statusMessage = "Copied"
                    try? await Task.sleep(for: .milliseconds(650))
                } else {
                    try? await Task.sleep(for: .milliseconds(550))
                }

                guard self.operationID == completionOperation, self.state.phase == .result else { return }
                switch self.settings.hotKeyCompletionBehavior {
                case .copyAndClose:
                    self.onHideCompactPanel?()
                    self.onHideFullTranscript?()
                    self.state.phase = .idle
                    self.state.completionPresentation = .none
                    self.state.statusMessage = "Ready"
                    self.recordingInitiator = nil
                    self.state.clearRecordingContext()
                    self.recognitionEngine = nil
                    self.currentHistoryRecordID = nil
                    self.state.discardTranscriptContent()
                case .copyAndOpenEditor:
                    self.state.completionPresentation = .interactive
                    self.state.statusMessage = hasText ? "Ready to edit" : "No speech recognized"
                    self.onHideCompactPanel?()
                    self.onShowFullTranscript?()
                }
            }

        case .hotKeyLatched, .menu:
            switch settings.menuCompletionBehavior {
            case .compactResult:
                state.completionPresentation = hasText ? .interactive : .noSpeech
                state.statusMessage = hasText ? "Transcript ready" : "No speech recognized"
            case .openEditor:
                state.completionPresentation = .interactive
                state.statusMessage = hasText ? "Ready to edit" : "No speech recognized"
                onHideCompactPanel?()
                onShowFullTranscript?()
            }

        case nil:
            state.completionPresentation = .interactive
        }
    }

    private func persistFinalResult() {
        persistCurrentTranscriptCheckpoint(reason: "final result", force: true)
    }

    private func persistCurrentTranscriptCheckpoint(
        reason: String,
        force: Bool = false
    ) {
        guard settings.historyStorageMode == .encrypted else { return }
        flushRecognitionUpdates()
        let text = currentResultText
        guard !text.isEmpty else { return }

        let now = Date()
        guard
            force
                || text != lastHistoryCheckpointText
                || now.timeIntervalSince(lastHistoryCheckpointAt) >= 2
        else { return }

        let startedAt = recordingStartedAt ?? now
        let id = currentHistoryRecordID ?? UUID()
        let existingPinned = history.records.first(where: { $0.id == id })?.isPinned ?? false
        let capturedDuration = max(
            state.recordingDuration,
            audioCapture.currentCapturedDuration
        )
        let record = TranscriptHistoryRecord(
            id: id,
            createdAt: startedAt,
            updatedAt: now,
            text: text,
            duration: importedAudioDuration
                ?? max(capturedDuration, now.timeIntervalSince(startedAt)),
            languageIdentifier: settings.activeLanguageIdentifier,
            engineName: currentEngineName,
            isPinned: existingPinned
        )
        currentHistoryRecordID = id
        guard history.upsert(record) else {
            diagnostics.error(
                "Transcript recovery checkpoint failed",
                metadata: [
                    "reason": reason,
                    "characters": String(text.count),
                    "historyUnlocked": String(history.isUnlocked),
                    "error": history.lastError ?? "Unknown history write error",
                ]
            )
            return
        }
        lastHistoryCheckpointText = text
        lastHistoryCheckpointAt = now
        diagnostics.info(
            "Transcript recovery checkpoint saved",
            metadata: [
                "reason": reason,
                "characters": String(text.count),
                "historyUnlocked": String(history.isUnlocked),
            ]
        )
    }

    private func persistEditedResultIfNeeded() {
        guard let currentHistoryRecordID, state.phase == .result else { return }
        history.updateText(id: currentHistoryRecordID, text: state.editableText)
    }

    private func enqueueRecognitionUpdate(_ update: RecognitionUpdate) {
        pendingRecognitionUpdates.append(update)
        if update.segment.kind == .sessionFinal {
            flushRecognitionUpdates()
            return
        }
        guard recognitionUpdateFlushTask == nil else { return }
        let delay = importedAudioDuration == nil ? 0.08 : 0.30
        recognitionUpdateFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.recognitionUpdateFlushTask = nil
            self.flushRecognitionUpdates()
        }
    }

    private func flushRecognitionUpdates() {
        recognitionUpdateFlushTask?.cancel()
        recognitionUpdateFlushTask = nil
        guard !pendingRecognitionUpdates.isEmpty else { return }
        let updates = pendingRecognitionUpdates
        pendingRecognitionUpdates.removeAll(keepingCapacity: true)
        state.applyRecognitionUpdates(updates)
    }

    private func cancelRecognitionUpdateFlush(discardPending: Bool) {
        recognitionUpdateFlushTask?.cancel()
        recognitionUpdateFlushTask = nil
        if discardPending {
            pendingRecognitionUpdates.removeAll(keepingCapacity: true)
        } else {
            flushRecognitionUpdates()
        }
    }

    private func configureRecognitionCallbacks(for engine: RecognitionEngine) {
        engine.onUpdate = { [weak self, weak engine] update in
            DispatchQueue.main.async {
                guard let self, let engine, self.recognitionEngine === engine else { return }
                self.enqueueRecognitionUpdate(update)
            }
        }
        engine.onFinished = { [weak self, weak engine] in
            DispatchQueue.main.async {
                guard let self, let engine, self.recognitionEngine === engine,
                    self.state.phase == .finalizing,
                    RecognitionFinalizationPolicy.action(for: .engineFinished) == .complete
                else { return }
                self.flushRecognitionUpdates()
                self.engineDidFinish = true
                self.diagnostics.info("Recognition engine finished")
                self.state.finishRecognitionEngine()
                self.completeRecognitionIfReady()
            }
        }
        engine.onMetrics = { [weak self, weak engine] metrics in
            DispatchQueue.main.async {
                guard let self, let engine, self.recognitionEngine === engine else { return }
                self.state.applyRecognitionMetrics(metrics)
                if self.state.phase == .listening, metrics.queueDepth > 0 {
                    self.state.statusMessage = "Listening · \(metrics.engineName) · queue \(metrics.queueDepth)"
                } else if self.state.phase == .finalizing, self.importedAudioDuration == nil {
                    self.state.statusMessage =
                        metrics.queueDepth > 0
                        ? "Processing remaining \(metrics.engineName) chunks… queue \(metrics.queueDepth)"
                        : "Completing transcript…"
                }
            }
        }
        engine.onChunkOutcome = { [weak self, weak engine] outcome in
            DispatchQueue.main.async {
                guard let self, let engine, self.recognitionEngine === engine else { return }
                self.flushRecognitionUpdates()
                let chunkID: UUID
                switch outcome {
                case .completed(let id):
                    chunkID = id
                    self.diagnostics.info("Recognition chunk completed", metadata: ["chunk": id.uuidString])
                    self.state.resolveRecognitionChunk(id: id, failed: false)
                case .failed(let id, let message):
                    chunkID = id
                    self.diagnostics.error(
                        "Recognition chunk failed",
                        metadata: ["chunk": id.uuidString, "error": message]
                    )
                    self.state.resolveRecognitionChunk(id: id, failed: true)
                    self.state.lastError = message
                    self.state.statusMessage = "A chunk failed; continuing with the remaining audio…"
                case .cancelled(let id):
                    chunkID = id
                    self.state.resolveRecognitionChunk(id: id, failed: true)
                }
                self.resolveImportedChunkWaiter(outcome, id: chunkID)
                self.persistCurrentTranscriptCheckpoint(reason: "recognition chunk completed")
                self.completeRecognitionIfReady()
            }
        }
        engine.onError = { [weak self, weak engine] error in
            DispatchQueue.main.async {
                guard let self, let engine, self.recognitionEngine === engine else { return }
                self.flushRecognitionUpdates()
                self.diagnostics.error(
                    "Recognition engine error",
                    metadata: ["engine": engine.displayName, "error": error.localizedDescription]
                )
                self.cancelImportedChunkWaiters()
                self.persistCurrentTranscriptCheckpoint(reason: "recognition engine error", force: true)
                if self.importedAudioDuration != nil {
                    self.startTask?.cancel()
                    engine.cancel()
                    self.recognitionEngine = nil
                    self.state.fail(error.localizedDescription)
                } else if self.state.phase == .finalizing {
                    self.state.lastError = error.localizedDescription
                    self.state.statusMessage = "A chunk failed; finishing the remaining recognition queue…"
                } else {
                    _ = self.audioCapture.stop(flushFinalChunk: false)
                    engine.cancel()
                    self.state.fail(error.localizedDescription)
                }
            }
        }
    }

    private func completeRecognitionIfReady() {
        guard state.phase == .finalizing,
            engineDidFinish,
            state.pendingRecognitionWork.chunkCount == 0
        else { return }

        let elapsed = Date().timeIntervalSince(finalizationStartedAt ?? Date())
        let remainingDelay = FinalizationFeedbackPolicy.remainingDelay(
            elapsed: elapsed,
            minimumVisibleDuration: minimumFinalizationFeedbackDuration
        )
        guard remainingDelay > 0 else {
            finalizationCompletionTask?.cancel()
            finalizationCompletionTask = nil
            finalizeCurrentResult()
            return
        }
        guard finalizationCompletionTask == nil else { return }

        let completionOperation = operationID
        finalizationCompletionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remainingDelay))
            guard let self,
                !Task.isCancelled,
                self.operationID == completionOperation,
                self.state.phase == .finalizing,
                self.engineDidFinish,
                self.state.pendingRecognitionWork.chunkCount == 0
            else { return }
            self.finalizationCompletionTask = nil
            self.finalizeCurrentResult()
        }
    }

    private func configureAudioCallbacks(sendToRecognizer: Bool, engine: RecognitionEngine?) {
        if sendToRecognizer, let engine,
            engine.audioInputMode == .continuousBuffers || engine.audioInputMode == .continuousBuffersAndVADChunks
        {
            audioCapture.onAudioBuffer = nil
            audioCapture.onTimedAudioBuffer = { [weak engine] buffer, range in
                engine?.append(buffer, captureTimeRange: range)
            }
        } else {
            audioCapture.onAudioBuffer = nil
            audioCapture.onTimedAudioBuffer = nil
        }

        let callbackOperationID = operationID
        let captureMetricsMailbox = captureMetricsMailbox
        audioCapture.onMetrics = { [captureMetricsMailbox] metrics in
            captureMetricsMailbox.submit(metrics, operationID: callbackOperationID)
        }

        audioCapture.onChunk = { [weak self, weak engine] chunk in
            let shouldSend =
                sendToRecognizer
                && (engine?.audioInputMode == .vadChunks
                    || engine?.audioInputMode == .continuousBuffersAndVADChunks)
            if shouldSend {
                // append() must happen inside the audio callback. stop() drains
                // this callback before finish(), which guarantees the tail is
                // accepted without ever blocking the callback on the main actor.
                engine?.append(chunk)
            }
            DispatchQueue.main.async { [weak self, weak engine] in
                guard let self, self.operationID == callbackOperationID else { return }
                self.handleCapturedChunk(
                    chunk,
                    queuedForRecognition: shouldSend,
                    engine: engine
                )
            }
        }
    }

    private func beginDebugAudioRecordingIfEnabled(sessionID: UUID) {
        guard settings.debugAudioRecordingEnabled else {
            audioCapture.onCapturedSamples = nil
            debugAudioRecordingSessionID = nil
            return
        }
        debugAudioRecordingSessionID = sessionID
        debugAudioRecordingStore.start(sessionID: sessionID)
        audioCapture.onCapturedSamples = { [debugAudioRecordingStore] samples, sampleRate in
            debugAudioRecordingStore.append(
                sessionID: sessionID,
                samples: samples,
                sampleRate: sampleRate
            )
        }
    }

    private func endDebugAudioRecording() {
        guard let sessionID = debugAudioRecordingSessionID else {
            audioCapture.onCapturedSamples = nil
            return
        }
        endDebugAudioRecording(sessionID: sessionID)
    }

    private func endDebugAudioRecording(sessionID: UUID) {
        guard debugAudioRecordingSessionID == sessionID else { return }
        audioCapture.onCapturedSamples = nil
        debugAudioRecordingSessionID = nil
        debugAudioRecordingStore.finish(sessionID: sessionID)
    }

    func flushCaptureMetricsForDisplay() {
        guard let pending = captureMetricsMailbox.takeLatest(),
            pending.operationID == operationID,
            state.phase == .preparing
                || state.phase == .listening
                || state.phase == .monitoring
        else { return }
        applyCaptureMetrics(pending.metrics)
    }

    private func applyCaptureMetrics(_ metrics: AudioCaptureMetrics) {
        state.currentLevelDB = metrics.rmsDB
        state.noiseFloorDB = metrics.vadSnapshot.noiseFloorDB
        state.thresholdDB = metrics.vadSnapshot.thresholdDB
        state.voiceActivityState = metrics.vadSnapshot.state
        state.updatePendingFeedbackVoiceActivity(
            recordingDuration: metrics.recordingDuration,
            voiceActivityState: metrics.vadSnapshot.state
        )
        state.updateCaptureProgress(
            recordingDuration: metrics.recordingDuration,
            pendingAudioDuration: metrics.pendingAudioDuration
        )
        state.appendAudioLevel(metrics.normalizedLevel, peakDB: metrics.peakDB)
    }

    private func handleCapturedChunk(
        _ chunk: AudioChunk,
        queuedForRecognition: Bool,
        engine: RecognitionEngine?
    ) {
        guard
            state.phase == .listening
                || state.phase == .stopping
                || state.phase == .finalizing
        else { return }

        state.emittedChunkCount += 1
        diagnostics.info(
            "Audio chunk emitted",
            metadata: [
                "chunk": chunk.id.uuidString,
                "duration": String(format: "%.3f", chunk.duration),
                "boundary": chunk.boundaryReason.rawValue,
                "overlapSeconds": String(format: "%.3f", chunk.trailingOverlapDuration),
            ]
        )
        guard queuedForRecognition else { return }
        guard
            let engine,
            recognitionEngine === engine,
            !engineDidFinish
        else { return }

        state.queueRecognitionChunk(chunk)
    }
}
