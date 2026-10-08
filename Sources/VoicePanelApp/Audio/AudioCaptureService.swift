import AVFoundation
import AudioToolbox
import Foundation
import VoicePanelCore

struct AudioCaptureMetrics {
    let rmsDB: Float
    let peakDB: Float
    let normalizedLevel: Float
    let vadSnapshot: VoiceActivitySnapshot
    let recordingDuration: TimeInterval
    let pendingAudioDuration: TimeInterval
}

typealias AudioCaptureStopResult = RecognitionAudioChunkPipeline.StopResult

struct AudioCapturePreparationActivationResult: Sendable {
    let capturedDuration: TimeInterval
    let includedDuration: TimeInterval
    let discardedDuration: TimeInterval
    let wasTruncated: Bool
}

enum AudioCaptureError: LocalizedError {
    case microphonePermissionDenied
    case noInputChannels
    case unsupportedBufferFormat
    case noDeferredCapture
    case noDefaultInputDevice
    case noAudioReceived
    case inputDeviceUnavailable(AudioDeviceID)
    case failedToSelectInput(OSStatus)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission was not granted."
        case .noInputChannels:
            return "The selected input device has no available channels."
        case .unsupportedBufferFormat:
            return "The selected input format is not supported by VoicePanel."
        case .noDeferredCapture:
            return "The microphone session is no longer available to resume."
        case .noAudioReceived:
            return "The microphone did not deliver audio. Check the input device and try again."
        case .noDefaultInputDevice:
            return "No system input device is currently available."
        case .inputDeviceUnavailable(let deviceID):
            return "The selected input device is no longer available (device \(deviceID))."
        case .failedToSelectInput(let status):
            return "The selected input device could not be activated (Core Audio error \(status))."
        }
    }
}

final class AudioCaptureService: @unchecked Sendable {
    private struct Callbacks {
        var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
        var onTimedAudioBuffer: ((AVAudioPCMBuffer, Range<TimeInterval>) -> Void)?
        var onCapturedSamples: (([Float], Double) -> Void)?
        var onMetrics: ((AudioCaptureMetrics) -> Void)?
        var onChunk: ((AudioChunk) -> Void)?
    }

    private let callbacksLock = NSLock()
    private var callbacks = Callbacks()

    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { callbacksLock.performLocked { callbacks.onAudioBuffer } }
        set { callbacksLock.performLocked { callbacks.onAudioBuffer = newValue } }
    }

    var onTimedAudioBuffer: ((AVAudioPCMBuffer, Range<TimeInterval>) -> Void)? {
        get { callbacksLock.performLocked { callbacks.onTimedAudioBuffer } }
        set { callbacksLock.performLocked { callbacks.onTimedAudioBuffer = newValue } }
    }

    var onCapturedSamples: (([Float], Double) -> Void)? {
        get { callbacksLock.performLocked { callbacks.onCapturedSamples } }
        set { callbacksLock.performLocked { callbacks.onCapturedSamples = newValue } }
    }

    var onMetrics: ((AudioCaptureMetrics) -> Void)? {
        get { callbacksLock.performLocked { callbacks.onMetrics } }
        set { callbacksLock.performLocked { callbacks.onMetrics = newValue } }
    }

    var onChunk: ((AudioChunk) -> Void)? {
        get { callbacksLock.performLocked { callbacks.onChunk } }
        set { callbacksLock.performLocked { callbacks.onChunk = newValue } }
    }

    private var engine: AVAudioEngine?
    private var chunkPipeline = RecognitionAudioChunkPipeline()
    private var transmissionPolicy = RecognitionAudioTransmissionPolicy()
    private var pendingRecognitionBuffers:
        [(buffer: AVAudioPCMBuffer, duration: TimeInterval, captureTimeRange: Range<TimeInterval>)] = []
    private var pendingRecognitionBufferHead = 0
    private var pendingRecognitionDuration: TimeInterval = 0
    private let recognitionPreRollDuration: TimeInterval = 0.30
    private enum CaptureMode: Equatable {
        case inactive
        case preparation
        case activating
        case active
    }

    private var captureMode: CaptureMode = .inactive
    private var preparationBuffers: [(buffer: AVAudioPCMBuffer, duration: TimeInterval)] = []
    private var preparationBufferHead = 0
    private var preparationBufferedDuration: TimeInterval = 0
    private var preparationCapturedDuration: TimeInterval = 0
    private var preparationBufferWasTruncated = false
    private var preparationVADConfiguration = VoiceActivityDetector.Configuration.balanced
    private let maximumPreparationBufferDuration: TimeInterval = 30
    private var running = false
    private var liveness = AudioCaptureLiveness()
    private var receivedSessionAudio = false
    private var sessionActive = false
    private var activeRequestedDeviceSelection: AudioDeviceID?
    private var activeResolvedDeviceSelection: AudioDeviceID?
    private var sileroVAD: SileroVADRuntime?
    private let processingLock = NSLock()
    private let callbackCondition = NSCondition()
    private var acceptsAudioCallbacks = false
    private var activeAudioCallbacks = 0

    var currentCapturedDuration: TimeInterval {
        processingLock.performLocked {
            switch captureMode {
            case .inactive:
                return 0
            case .preparation:
                return preparationCapturedDuration
            case .activating:
                return chunkPipeline.capturedDuration + preparationBufferedDuration
            case .active:
                return chunkPipeline.capturedDuration
            }
        }
    }

    var hasActiveSession: Bool {
        processingLock.performLocked { sessionActive }
    }

    var isCapturingAudio: Bool {
        processingLock.performLocked { running }
    }

    // Retained through stop so callers can distinguish a broken microphone
    // from valid preparation audio deliberately excluded by the user's policy.
    var hasReceivedSessionAudio: Bool {
        processingLock.performLocked { receivedSessionAudio }
    }

    var captureLiveness: AudioCaptureLiveness.Status {
        processingLock.performLocked {
            liveness.status(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    var currentDeviceSelection: AudioDeviceID? {
        processingLock.performLocked { activeRequestedDeviceSelection }
    }

    var currentResolvedDeviceSelection: AudioDeviceID? {
        processingLock.performLocked { activeResolvedDeviceSelection }
    }

    static func requestMicrophonePermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            SystemPromptFocusCoordinator.willBegin()
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            SystemPromptFocusCoordinator.didEnd()
            guard granted else { throw AudioCaptureError.microphonePermissionDenied }
        default:
            throw AudioCaptureError.microphonePermissionDenied
        }
    }

    func start(
        selectedDeviceID: AudioDeviceID,
        vadConfiguration: VoiceActivityDetector.Configuration,
        segmenterConfiguration: AudioSegmenter.Configuration = .init(),
        detectionMode: VoiceActivityDetectionMode = .energy,
        sileroVAD: SileroVADRuntime? = nil,
        suppressSilenceInRecognizer: Bool = false,
        minimumChunkDeliveryDuration: TimeInterval = 0
    ) throws {
        _ = stop(flushFinalChunk: false)

        processingLock.performLocked {
            receivedSessionAudio = false
            configureActivePipelineLocked(
                vadConfiguration: vadConfiguration,
                segmenterConfiguration: segmenterConfiguration,
                detectionMode: detectionMode,
                sileroVAD: sileroVAD,
                suppressSilenceInRecognizer: suppressSilenceInRecognizer,
                minimumChunkDeliveryDuration: minimumChunkDeliveryDuration
            )
            captureMode = .active
            resetPreparationBuffersLocked()
        }

        do {
            try startAudioEngine(selectedDeviceID: selectedDeviceID)
            processingLock.performLocked { sessionActive = true }
        } catch {
            processingLock.performLocked {
                sessionActive = false
                activeRequestedDeviceSelection = nil
                activeResolvedDeviceSelection = nil
            }
            throw error
        }
    }

    /// Opens the selected microphone immediately while recognition models and
    /// VAD runtimes are still becoming ready. Buffers stay private to this
    /// service until activatePreparedCapture() installs the final pipeline.
    func startPreparationCapture(
        selectedDeviceID: AudioDeviceID,
        vadConfiguration: VoiceActivityDetector.Configuration
    ) throws {
        _ = stop(flushFinalChunk: false)

        processingLock.performLocked {
            receivedSessionAudio = false
            resetCaptureBuffersLocked()
            resetPreparationBuffersLocked()
            preparationVADConfiguration = vadConfiguration
            captureMode = .preparation
        }

        do {
            try startAudioEngine(selectedDeviceID: selectedDeviceID)
            processingLock.performLocked { sessionActive = true }
        } catch {
            processingLock.performLocked {
                captureMode = .inactive
                sessionActive = false
                activeRequestedDeviceSelection = nil
                activeResolvedDeviceSelection = nil
                resetPreparationBuffersLocked()
            }
            throw error
        }
    }

    /// Installs the real VAD/chunking pipeline without restarting AVAudioEngine,
    /// then drains every preparation buffer in order before live processing.
    func activatePreparedCapture(
        vadConfiguration: VoiceActivityDetector.Configuration,
        segmenterConfiguration: AudioSegmenter.Configuration = .init(),
        detectionMode: VoiceActivityDetectionMode = .energy,
        sileroVAD: SileroVADRuntime? = nil,
        suppressSilenceInRecognizer: Bool = false,
        minimumChunkDeliveryDuration: TimeInterval = 0,
        includeExtendedPreparationAudio: Bool
    ) -> AudioCapturePreparationActivationResult {
        beginPipelineDrain()
        defer { endAudioCallback() }

        let activation = processingLock.performLocked {
            () -> (
                initialBuffers: [(buffer: AVAudioPCMBuffer, duration: TimeInterval)],
                result: AudioCapturePreparationActivationResult
            ) in
            guard captureMode == .preparation else {
                return (
                    [],
                    AudioCapturePreparationActivationResult(
                        capturedDuration: 0,
                        includedDuration: 0,
                        discardedDuration: 0,
                        wasTruncated: false
                    )
                )
            }

            configureActivePipelineLocked(
                vadConfiguration: vadConfiguration,
                segmenterConfiguration: segmenterConfiguration,
                detectionMode: detectionMode,
                sileroVAD: sileroVAD,
                suppressSilenceInRecognizer: suppressSilenceInRecognizer,
                minimumChunkDeliveryDuration: minimumChunkDeliveryDuration
            )

            let capturedDuration = preparationCapturedDuration
            let includePreparationAudio =
                RecordingPreparationAudioPolicy.decision(
                    capturedDuration: capturedDuration,
                    includeWhenPreparationIsLong: includeExtendedPreparationAudio
                ) == .include
            let bufferedDuration = preparationBufferedDuration
            let initialBuffers =
                includePreparationAudio
                ? Array(preparationBuffers[preparationBufferHead...])
                : []
            let includedDuration = includePreparationAudio ? bufferedDuration : 0
            let discardedDuration = max(0, capturedDuration - includedDuration)
            let wasTruncated = preparationBufferWasTruncated

            preparationBuffers.removeAll(keepingCapacity: true)
            preparationBufferHead = 0
            preparationBufferedDuration = 0
            preparationCapturedDuration = 0
            preparationBufferWasTruncated = false
            captureMode = .activating

            return (
                initialBuffers,
                AudioCapturePreparationActivationResult(
                    capturedDuration: capturedDuration,
                    includedDuration: includedDuration,
                    discardedDuration: discardedDuration,
                    wasTruncated: wasTruncated
                )
            )
        }

        var buffers = activation.initialBuffers
        while true {
            for pending in buffers {
                processActiveBuffer(pending.buffer)
            }

            buffers = processingLock.performLocked {
                guard captureMode == .activating else { return [] }
                guard preparationBufferHead < preparationBuffers.count else {
                    captureMode = .active
                    return []
                }
                let next = Array(preparationBuffers[preparationBufferHead...])
                preparationBuffers.removeAll(keepingCapacity: true)
                preparationBufferHead = 0
                preparationBufferedDuration = 0
                return next
            }
            if buffers.isEmpty {
                break
            }
        }

        return activation.result
    }

    /// Stops adding microphone samples after a push-to-talk release while
    /// preserving buffered and already activated pipeline state. Activation can
    /// complete on a worker while the coordinator still presents preparation,
    /// so this deliberately accepts every non-inactive capture mode.
    func pauseCaptureForDeferredStop() {
        let shouldPause = processingLock.performLocked {
            sessionActive && captureMode != .inactive && running
        }
        if shouldPause {
            suspendAudioEnginePreservingPipeline()
        }
    }

    @discardableResult
    func resumeCaptureAfterDeferredStop(selectedDeviceID: AudioDeviceID) throws -> Bool {
        let state = processingLock.performLocked {
            (
                canResume: sessionActive && captureMode != .inactive && !running,
                alreadyRunning: sessionActive && captureMode != .inactive && running
            )
        }
        if state.alreadyRunning { return true }
        guard state.canResume else { return false }
        try startAudioEngine(selectedDeviceID: selectedDeviceID)
        return true
    }

    /// Moves an active recording to another input while preserving every
    /// sample already accepted by the previous audio tap. If opening the new
    /// device fails, the session remains suspended and can be retried or
    /// finalized normally.
    @discardableResult
    func reconnect(
        selectedDeviceID: AudioDeviceID,
        closeCurrentInputTail: Bool
    ) throws -> AudioDeviceID {
        guard hasActiveSession else {
            throw AudioCaptureError.noDeferredCapture
        }
        let mode = processingLock.performLocked { captureMode }
        suspendAudioEnginePreservingPipeline()
        if closeCurrentInputTail, mode == .active {
            flushPendingRecognitionBuffers()

            let boundaryChunks = processingLock.performLocked {
                chunkPipeline.inputChanged()
            }
            let chunkHandler = callbacksSnapshot().onChunk
            for chunk in boundaryChunks {
                chunkHandler?(chunk)
            }
        }

        return try startAudioEngine(selectedDeviceID: selectedDeviceID)
    }

    @discardableResult
    func stop(
        flushFinalChunk: Bool = true,
        forceChunkIfDurationAtLeast minimumDuration: TimeInterval? = nil
    ) -> AudioCaptureStopResult {
        suspendAudioEnginePreservingPipeline()

        let stopped = processingLock.performLocked {
            let result = chunkPipeline.stop(
                flushFinalChunk: flushFinalChunk,
                forceChunkIfDurationAtLeast: minimumDuration
            )
            resetCaptureBuffersLocked()
            resetPreparationBuffersLocked()
            sileroVAD?.reset()
            sileroVAD = nil
            captureMode = .inactive
            sessionActive = false
            activeRequestedDeviceSelection = nil
            activeResolvedDeviceSelection = nil
            return result
        }

        return stopped
    }

    func updateVADConfiguration(
        _ configuration: VoiceActivityDetector.Configuration,
        detectionMode: VoiceActivityDetectionMode
    ) {
        processingLock.performLocked {
            chunkPipeline.updateVADConfiguration(configuration)
            chunkPipeline.updateDetectionMode(detectionMode)
        }
    }

    private func beginAudioCallback() -> Bool {
        callbackCondition.performLocked {
            guard acceptsAudioCallbacks else { return false }
            activeAudioCallbacks += 1
            return true
        }
    }

    private func endAudioCallback() {
        callbackCondition.lock()
        activeAudioCallbacks = max(0, activeAudioCallbacks - 1)
        if activeAudioCallbacks == 0 {
            callbackCondition.broadcast()
        }
        callbackCondition.unlock()
    }

    private func beginPipelineDrain() {
        callbackCondition.performLocked {
            activeAudioCallbacks += 1
        }
    }

    @discardableResult
    private func startAudioEngine(selectedDeviceID: AudioDeviceID) throws -> AudioDeviceID {
        let resolvedDeviceID = try AudioInputDeviceManager.resolveInputDeviceID(selectedDeviceID)
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        try selectInputDevice(resolvedDeviceID, on: inputNode)

        let format = try selectedInputFormat(on: inputNode)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, self.beginAudioCallback() else { return }
            defer { self.endAudioCallback() }
            self.consume(buffer)
        }

        engine.prepare()
        processingLock.performLocked {
            liveness.start(at: ProcessInfo.processInfo.systemUptime)
        }
        callbackCondition.performLocked { acceptsAudioCallbacks = true }
        do {
            try engine.start()
            self.engine = engine
            processingLock.performLocked {
                running = true
                activeRequestedDeviceSelection = selectedDeviceID
                activeResolvedDeviceSelection = resolvedDeviceID
            }
            return resolvedDeviceID
        } catch {
            callbackCondition.performLocked { acceptsAudioCallbacks = false }
            processingLock.performLocked {
                running = false
                liveness.suspend()
            }
            inputNode.removeTap(onBus: 0)
            self.engine = nil
            throw error
        }
    }

    private func suspendAudioEnginePreservingPipeline() {
        callbackCondition.performLocked { acceptsAudioCallbacks = false }

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        self.engine = nil

        // Do not set `running` to false before this drain. A callback that
        // already passed beginAudioCallback() owns accepted audio and must be
        // allowed to finish consume() before a device handoff or engine.finish().
        callbackCondition.lock()
        while activeAudioCallbacks > 0 {
            callbackCondition.wait()
        }
        callbackCondition.unlock()

        processingLock.performLocked {
            running = false
            liveness.suspend()
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, buffer.format.sampleRate > 0 else { return }
        processingLock.performLocked {
            receivedSessionAudio = true
            liveness.receivedBuffer(at: ProcessInfo.processInfo.systemUptime)
        }

        let channel = channels[0]
        var samples = Array(repeating: Float(0), count: frameCount)
        var squareSum: Float = 0
        var peak: Float = 0

        for index in 0..<frameCount {
            let sample = channel[index]
            samples[index] = sample
            squareSum += sample * sample
            peak = max(peak, abs(sample))
        }

        let rms = sqrt(squareSum / Float(frameCount))
        let rmsDB = Self.decibels(fromLinear: rms)
        let peakDB = Self.decibels(fromLinear: peak)
        let duration = Double(frameCount) / buffer.format.sampleRate
        callbacksSnapshot().onCapturedSamples?(samples, buffer.format.sampleRate)

        let mode = processingLock.performLocked { captureMode }
        if mode == .preparation || mode == .activating,
            let copiedBuffer = copyBuffer(buffer)
        {
            let preparationMetrics = processingLock.performLocked {
                () -> AudioCaptureMetrics? in
                guard captureMode == .preparation || captureMode == .activating else {
                    return nil
                }
                preparationBuffers.append((copiedBuffer, duration))
                preparationBufferedDuration += duration
                if captureMode == .preparation {
                    preparationCapturedDuration += duration
                    trimPreparationBuffersLocked()
                }

                let configuration = preparationVADConfiguration
                let noiseFloor = configuration.initialNoiseFloorDB
                let normalized = min(max((rmsDB + 60) / 60, 0), 1)
                return AudioCaptureMetrics(
                    rmsDB: rmsDB,
                    peakDB: peakDB,
                    normalizedLevel: normalized,
                    vadSnapshot: VoiceActivitySnapshot(
                        state: .silence,
                        rmsDB: rmsDB,
                        noiseFloorDB: noiseFloor,
                        thresholdDB: configuration.threshold(for: noiseFloor)
                    ),
                    recordingDuration: captureMode == .preparation
                        ? preparationCapturedDuration
                        : chunkPipeline.capturedDuration + preparationBufferedDuration,
                    pendingAudioDuration: preparationBufferedDuration
                )
            }
            if let preparationMetrics {
                callbacksSnapshot().onMetrics?(preparationMetrics)
                return
            }
        }

        processActiveBuffer(
            buffer,
            samples: samples,
            rmsDB: rmsDB,
            peakDB: peakDB,
            duration: duration
        )
    }

    private func processActiveBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let channel = channels[0]
        var samples = Array(repeating: Float(0), count: frameCount)
        var squareSum: Float = 0
        var peak: Float = 0
        for index in 0..<frameCount {
            let sample = channel[index]
            samples[index] = sample
            squareSum += sample * sample
            peak = max(peak, abs(sample))
        }
        let rms = sqrt(squareSum / Float(frameCount))
        processActiveBuffer(
            buffer,
            samples: samples,
            rmsDB: Self.decibels(fromLinear: rms),
            peakDB: Self.decibels(fromLinear: peak),
            duration: Double(frameCount) / buffer.format.sampleRate
        )
    }

    private func processActiveBuffer(
        _ buffer: AVAudioPCMBuffer,
        samples: [Float],
        rmsDB: Float,
        peakDB: Float,
        duration: TimeInterval
    ) {

        let neuralVAD = processingLock.performLocked { sileroVAD }
        let neuralSpeechDetected = neuralVAD?.process(
            samples: samples,
            sampleRate: buffer.format.sampleRate
        )
        let processed = processingLock.performLocked {
            () -> RecognitionAudioChunkPipeline.ProcessResult? in
            guard captureMode == .active || captureMode == .activating else { return nil }
            return chunkPipeline.process(
                samples: samples,
                sampleRate: buffer.format.sampleRate,
                rmsDB: rmsDB,
                neuralSpeechDetected: neuralSpeechDetected
            )
        }

        guard let processed else { return }
        routeBufferToRecognizer(
            buffer, event: processed.event, duration: duration,
            captureTimeRange: (processed.capturedDuration - duration)..<processed.capturedDuration
        )

        let normalized = min(max((rmsDB + 60) / 60, 0), 1)
        let callbackSnapshot = callbacksSnapshot()
        callbackSnapshot.onMetrics?(
            AudioCaptureMetrics(
                rmsDB: rmsDB,
                peakDB: peakDB,
                normalizedLevel: normalized,
                vadSnapshot: processed.snapshot,
                recordingDuration: processed.capturedDuration,
                pendingAudioDuration: processed.pendingDuration
            ))
        for chunk in processed.chunks {
            callbackSnapshot.onChunk?(chunk)
        }
    }

    private func configureActivePipelineLocked(
        vadConfiguration: VoiceActivityDetector.Configuration,
        segmenterConfiguration: AudioSegmenter.Configuration,
        detectionMode: VoiceActivityDetectionMode,
        sileroVAD: SileroVADRuntime?,
        suppressSilenceInRecognizer: Bool,
        minimumChunkDeliveryDuration: TimeInterval
    ) {
        chunkPipeline = RecognitionAudioChunkPipeline(
            vadConfiguration: vadConfiguration,
            segmenterConfiguration: segmenterConfiguration,
            minimumChunkDeliveryDuration: minimumChunkDeliveryDuration,
            detectionMode: detectionMode
        )
        self.sileroVAD = sileroVAD
        transmissionPolicy = RecognitionAudioTransmissionPolicy(
            suppressDetectedSilence: suppressSilenceInRecognizer
        )
        pendingRecognitionBuffers.removeAll(keepingCapacity: true)
        pendingRecognitionBufferHead = 0
        pendingRecognitionDuration = 0
    }

    private func resetCaptureBuffersLocked() {
        pendingRecognitionBuffers.removeAll(keepingCapacity: true)
        pendingRecognitionBufferHead = 0
        pendingRecognitionDuration = 0
    }

    private func resetPreparationBuffersLocked() {
        preparationBuffers.removeAll(keepingCapacity: true)
        preparationBufferHead = 0
        preparationBufferedDuration = 0
        preparationCapturedDuration = 0
        preparationBufferWasTruncated = false
    }

    private func trimPreparationBuffersLocked() {
        while preparationBufferedDuration > maximumPreparationBufferDuration,
            preparationBufferHead < preparationBuffers.count
        {
            let removed = preparationBuffers[preparationBufferHead]
            preparationBufferHead += 1
            preparationBufferedDuration = max(
                0,
                preparationBufferedDuration - removed.duration
            )
            preparationBufferWasTruncated = true
        }
        compactPreparationBuffersLockedIfNeeded()
    }

    private func compactPreparationBuffersLockedIfNeeded() {
        guard preparationBufferHead >= 256,
            preparationBufferHead * 2 >= preparationBuffers.count
        else { return }
        preparationBuffers.removeFirst(preparationBufferHead)
        preparationBufferHead = 0
    }

    private func flushPendingRecognitionBuffers() {
        let snapshot = callbacksSnapshot()
        guard snapshot.onAudioBuffer != nil || snapshot.onTimedAudioBuffer != nil else {
            resetCaptureBuffersLocked()
            return
        }
        for index in pendingRecognitionBufferHead..<pendingRecognitionBuffers.count {
            let pending = pendingRecognitionBuffers[index]
            transmit(pending.buffer, captureTimeRange: pending.captureTimeRange, callbacks: snapshot)
        }
        resetCaptureBuffersLocked()
    }

    private func routeBufferToRecognizer(
        _ buffer: AVAudioPCMBuffer,
        event: VoiceActivityEvent,
        duration: TimeInterval,
        captureTimeRange: Range<TimeInterval>
    ) {
        let snapshot = callbacksSnapshot()
        guard snapshot.onAudioBuffer != nil || snapshot.onTimedAudioBuffer != nil else { return }

        switch transmissionPolicy.disposition(for: event) {
        case .transmit:
            transmit(buffer, captureTimeRange: captureTimeRange, callbacks: snapshot)

        case .bufferForPreRoll:
            guard let copiedBuffer = copyBuffer(buffer) else { return }
            pendingRecognitionBuffers.append((copiedBuffer, duration, captureTimeRange))
            pendingRecognitionDuration += duration
            trimPendingRecognitionBuffers()

        case .flushBufferedAndTransmit:
            for index in pendingRecognitionBufferHead..<pendingRecognitionBuffers.count {
                let pending = pendingRecognitionBuffers[index]
                transmit(pending.buffer, captureTimeRange: pending.captureTimeRange, callbacks: snapshot)
            }
            resetCaptureBuffersLocked()
            transmit(buffer, captureTimeRange: captureTimeRange, callbacks: snapshot)
        }
    }

    private func transmit(
        _ buffer: AVAudioPCMBuffer, captureTimeRange: Range<TimeInterval>, callbacks: Callbacks
    ) {
        if let timed = callbacks.onTimedAudioBuffer {
            timed(buffer, captureTimeRange)
        } else {
            callbacks.onAudioBuffer?(buffer)
        }
    }

    private func trimPendingRecognitionBuffers() {
        while pendingRecognitionDuration > recognitionPreRollDuration,
            pendingRecognitionBufferHead < pendingRecognitionBuffers.count
        {
            let removed = pendingRecognitionBuffers[pendingRecognitionBufferHead]
            pendingRecognitionBufferHead += 1
            pendingRecognitionDuration = max(0, pendingRecognitionDuration - removed.duration)
        }
        if pendingRecognitionBufferHead >= 32,
            pendingRecognitionBufferHead * 2 >= pendingRecognitionBuffers.count
        {
            pendingRecognitionBuffers.removeFirst(pendingRecognitionBufferHead)
            pendingRecognitionBufferHead = 0
        }
    }

    private func callbacksSnapshot() -> Callbacks {
        callbacksLock.performLocked { callbacks }
    }

    private func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard
            let copy = AVAudioPCMBuffer(
                pcmFormat: source.format,
                frameCapacity: source.frameLength
            )
        else {
            return nil
        }
        copy.frameLength = source.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in 0..<sourceBuffers.count {
            guard let sourceData = sourceBuffers[index].mData,
                let destinationData = destinationBuffers[index].mData
            else {
                continue
            }
            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            memcpy(destinationData, sourceData, byteCount)
        }
        return copy
    }

    private func selectInputDevice(_ deviceID: AudioDeviceID, on inputNode: AVAudioInputNode) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw AudioCaptureError.failedToSelectInput(kAudio_ParamError)
        }
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioCaptureError.failedToSelectInput(status)
        }
    }

    private func selectedInputFormat(on inputNode: AVAudioInputNode) throws -> AVAudioFormat {
        guard let audioUnit = inputNode.audioUnit else {
            throw AudioCaptureError.unsupportedBufferFormat
        }

        // outputFormat(forBus:) may still describe the previous output route while
        // AUHAL is switching devices. The hardware side of AUHAL input element 1 is
        // updated synchronously by kAudioOutputUnitProperty_CurrentDevice, so use it
        // as the source of truth for the tap's sample rate and channel count.
        var hardwareFormat = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &hardwareFormat,
            &dataSize
        )
        guard status == noErr,
            hardwareFormat.mSampleRate > 0,
            hardwareFormat.mChannelsPerFrame > 0,
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: hardwareFormat.mSampleRate,
                channels: AVAudioChannelCount(hardwareFormat.mChannelsPerFrame),
                interleaved: false
            )
        else {
            throw AudioCaptureError.unsupportedBufferFormat
        }
        return format
    }

    private static func decibels(fromLinear value: Float) -> Float {
        20 * log10(max(value, 0.000_001))
    }
}

extension NSLock {
    fileprivate func performLocked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

extension NSCondition {
    fileprivate func performLocked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
