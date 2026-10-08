import AVFoundation
import Foundation
import Speech
import VoicePanelCore

final class SystemSpeechRecognitionEngine: RecognitionEngine {
    private let onDeviceOnly: Bool
    private let addsPunctuation: Bool
    private let contextualPhrases: [String]

    init(
        onDeviceOnly: Bool = true,
        addsPunctuation: Bool = true,
        contextualPhrases: [String] = []
    ) {
        self.onDeviceOnly = onDeviceOnly
        self.addsPunctuation = addsPunctuation
        self.contextualPhrases = contextualPhrases
    }
    let displayName = "Apple Speech"
    let audioInputMode: RecognitionAudioInputMode = .continuousBuffers
    let finalizationTimeout: TimeInterval = 5
    let providesLiveDraft = true

    var onUpdate: ((RecognitionUpdate) -> Void)?
    var onFinished: (() -> Void)?
    var onMetrics: ((RecognitionPerformanceMetrics) -> Void)?
    var onChunkOutcome: ((RecognitionChunkOutcome) -> Void)?
    var onError: ((Error) -> Void)?

    private let lock = NSLock()

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var sessionGeneration = 0
    private var taskGeneration = 0
    private var nextSegmentSequence = 0
    private var currentSegmentID = UUID()
    private var currentSegmentSequence = 0
    private var lastHypothesis = ""
    private var draftSegmentSequence: Int?
    private var draftCommittedText = ""
    private var draftRestartAttempts = 0
    private var taskAudioRanges: [(request: Range<TimeInterval>, capture: Range<TimeInterval>)] = []
    private var taskAudioDuration: TimeInterval = 0
    private var committedDraftTokens: [TimedDraftToken] = []
    private var lastDraftTokens: [TimedDraftToken]?
    private var taskUtterances = SpeechUtteranceAccumulator()

    private var sessionActive = false
    private var sessionFinishing = false
    private var segmentFinishing = false
    private var isCancelled = false
    private var didNotifyFinished = false

    func requestAuthorization() async throws {
        let showsSystemPrompt = SFSpeechRecognizer.authorizationStatus() == .notDetermined
        if showsSystemPrompt { SystemPromptFocusCoordinator.willBegin() }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        if showsSystemPrompt { SystemPromptFocusCoordinator.didEnd() }
        guard status == .authorized else {
            throw RecognitionEngineError.authorizationDenied
        }
    }

    func start(localeIdentifier: String) async throws {
        try await startSession(localeIdentifier: localeIdentifier, chunkAlignedDraft: false)
    }

    func startDraft(localeIdentifier: String) async throws {
        try await startSession(localeIdentifier: localeIdentifier, chunkAlignedDraft: true)
    }

    private func startSession(localeIdentifier: String, chunkAlignedDraft: Bool) async throws {
        cancel()

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)), recognizer.isAvailable
        else {
            throw RecognitionEngineError.recognizerUnavailable(localeIdentifier)
        }

        if onDeviceOnly, #available(macOS 10.15, *) {
            guard recognizer.supportsOnDeviceRecognition else {
                throw RecognitionEngineError.onDeviceRecognitionUnavailable(localeIdentifier)
            }
        }

        let generation = lock.performLocked {
            sessionGeneration += 1
            self.recognizer = recognizer
            sessionActive = true
            sessionFinishing = false
            segmentFinishing = false
            isCancelled = false
            didNotifyFinished = false
            nextSegmentSequence = 0
            lastHypothesis = ""
            draftSegmentSequence = chunkAlignedDraft ? 0 : nil
            draftCommittedText = ""
            draftRestartAttempts = 0
            committedDraftTokens = []
            lastDraftTokens = nil
            return sessionGeneration
        }

        try startNextTask(sessionGeneration: generation)
    }

    /// Chunk delivery owns the draft timeline. Switch requests immediately;
    /// waiting for Apple's final callback would send new audio to an ended
    /// request and let back-to-back chunks collapse into a single boundary.
    func advanceDraftSegment(to sequence: Int) {
        let previous: (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?, Int, Int)? =
            lock.performLocked {
                guard sessionActive, !sessionFinishing, !isCancelled,
                    let currentSequence = draftSegmentSequence, sequence > currentSequence
                else { return nil }
                taskGeneration += 1  // Invalidate callbacks before releasing the lock.
                draftSegmentSequence = sequence
                draftCommittedText = ""
                committedDraftTokens = []
                lastDraftTokens = nil
                draftRestartAttempts = 0
                lastHypothesis = ""
                segmentFinishing = false
                return (request, task, sessionGeneration, taskGeneration)
            }
        guard let previous else { return }
        do {
            try startNextTask(sessionGeneration: previous.2, replacingTaskGeneration: previous.3)
        } catch {
            onError?(error)
        }
        previous.0?.endAudio()
        previous.1?.cancel()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let currentRequest = request
        let canAppend = sessionActive && !isCancelled
        lock.unlock()

        if canAppend {
            currentRequest?.append(buffer)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, captureTimeRange: Range<TimeInterval>) {
        lock.performLocked {
            guard sessionActive, !isCancelled, let request else { return }
            let duration = Double(buffer.frameLength) / buffer.format.sampleRate
            guard duration > 0 else { return }
            taskAudioRanges.append((taskAudioDuration..<(taskAudioDuration + duration), captureTimeRange))
            taskAudioDuration += duration
            request.append(buffer)
        }
    }

    func finishCurrentSegment() {
        lock.lock()
        guard sessionActive, !sessionFinishing, !segmentFinishing, !isCancelled else {
            lock.unlock()
            return
        }
        segmentFinishing = true
        let currentRequest = request
        lock.unlock()
        currentRequest?.endAudio()
    }

    func finish() {
        lock.lock()
        guard sessionActive, !isCancelled else {
            lock.unlock()
            return
        }

        sessionFinishing = true
        segmentFinishing = true
        let currentRequest = request
        let generation = sessionGeneration
        let token = taskGeneration
        let hasTask = currentRequest != nil || task != nil
        lock.unlock()

        if let currentRequest {
            currentRequest.endAudio()
        } else if !hasTask {
            finishWithoutActiveTask(sessionGeneration: generation, taskGeneration: token)
        }
    }

    func cancel() {
        lock.lock()
        sessionGeneration += 1
        sessionActive = false
        sessionFinishing = false
        segmentFinishing = false
        isCancelled = true
        didNotifyFinished = false
        let currentRequest = request
        let currentTask = task
        request = nil
        task = nil
        recognizer = nil
        lastHypothesis = ""
        draftSegmentSequence = nil
        draftCommittedText = ""
        draftRestartAttempts = 0
        committedDraftTokens = []
        lastDraftTokens = nil
        taskAudioRanges = []
        taskAudioDuration = 0
        lock.unlock()

        currentRequest?.endAudio()
        currentTask?.cancel()
    }

    private func startNextTask(
        sessionGeneration expectedSessionGeneration: Int,
        replacingTaskGeneration: Int? = nil
    ) throws {
        let nextRequest = SFSpeechAudioBufferRecognitionRequest()
        nextRequest.shouldReportPartialResults = true
        nextRequest.taskHint = .dictation
        nextRequest.contextualStrings = contextualPhrases
        if #available(macOS 13.0, *) {
            nextRequest.addsPunctuation = addsPunctuation
        }
        if onDeviceOnly, #available(macOS 10.15, *) {
            nextRequest.requiresOnDeviceRecognition = true
        }

        lock.lock()
        guard sessionActive,
            !sessionFinishing,
            !isCancelled,
            sessionGeneration == expectedSessionGeneration,
            replacingTaskGeneration == nil || taskGeneration == replacingTaskGeneration,
            let currentRecognizer = recognizer
        else {
            lock.unlock()
            return
        }

        taskGeneration += 1
        let expectedTaskGeneration = taskGeneration
        if let draftSegmentSequence {
            // Apple can finalize or restart independently of our audio cuts.
            // Such a restart must keep the current presentation segment.
            if currentSegmentSequence != draftSegmentSequence || nextSegmentSequence == 0 {
                currentSegmentID = UUID()
            }
            currentSegmentSequence = draftSegmentSequence
            nextSegmentSequence = draftSegmentSequence + 1
        } else {
            currentSegmentID = UUID()
            currentSegmentSequence = nextSegmentSequence
            nextSegmentSequence += 1
        }
        lastHypothesis = draftCommittedText
        taskAudioRanges.removeAll(keepingCapacity: true)
        taskAudioDuration = 0
        taskUtterances.reset()
        segmentFinishing = false
        request = nextRequest
        lock.unlock()

        let nextTask = currentRecognizer.recognitionTask(with: nextRequest) { [weak self] result, error in
            self?.handleRecognitionCallback(
                result: result,
                error: error,
                sessionGeneration: expectedSessionGeneration,
                taskGeneration: expectedTaskGeneration
            )
        }

        lock.lock()
        if sessionActive,
            sessionGeneration == expectedSessionGeneration,
            taskGeneration == expectedTaskGeneration,
            request === nextRequest
        {
            task = nextTask
            lock.unlock()
        } else {
            lock.unlock()
            nextTask.cancel()
        }
    }

    private func handleRecognitionCallback(
        result: SFSpeechRecognitionResult?,
        error: Error?,
        sessionGeneration expectedSessionGeneration: Int,
        taskGeneration expectedTaskGeneration: Int
    ) {
        var updateToSend: RecognitionUpdate?
        var shouldRestart = false
        var shouldNotifyFinished = false
        var errorToSend: Error?
        var draftRecoveryAttempt: Int?

        lock.lock()
        guard sessionActive,
            !isCancelled,
            sessionGeneration == expectedSessionGeneration,
            taskGeneration == expectedTaskGeneration
        else {
            lock.unlock()
            return
        }

        if let result {
            taskUtterances.observe(
                result.bestTranscription.formattedString,
                closesUtterance: result.speechRecognitionMetadata != nil
            )
            if draftSegmentSequence != nil, !taskAudioRanges.isEmpty {
                let formatted = result.bestTranscription.formattedString as NSString
                let segments = result.bestTranscription.segments
                let tokens = segments.enumerated().compactMap { index, segment -> TimedDraftToken? in
                    let midpoint = segment.timestamp + segment.duration / 2
                    guard segment.duration > 0, segment.duration.isFinite, segment.timestamp.isFinite,
                        let range = taskAudioRanges.first(where: { $0.request.contains(midpoint) })
                    else {
                        return nil
                    }
                    let start = index == 0 ? 0 : segment.substringRange.location
                    let end =
                        index + 1 < segments.count ? segments[index + 1].substringRange.location : formatted.length
                    guard start >= 0, end >= start, end <= formatted.length else { return nil }
                    return TimedDraftToken(
                        text: TranscriptTextNormalizer.normalize(
                            formatted.substring(with: NSRange(location: start, length: end - start))),
                        captureTime: range.capture.lowerBound + midpoint - range.request.lowerBound
                    )
                }
                if !result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let hasCompleteTiming =
                        tokens.count == segments.count && !tokens.isEmpty
                        && zip(tokens, tokens.dropFirst()).allSatisfy { $0.0.captureTime < $0.1.captureTime }
                    if hasCompleteTiming {
                        taskUtterances.replaceCurrentTokens(tokens)
                    } else if let latest = taskAudioRanges.last {
                        taskUtterances.replaceCurrentTokens(
                            DraftTokenTiming.observedTokens(
                                text: result.bestTranscription.formattedString,
                                previous: taskUtterances.currentTokens,
                                captureTime: latest.capture.upperBound.nextDown
                            ))
                    }
                    lastDraftTokens = committedDraftTokens + taskUtterances.tokens
                }
            }
            let hypothesis = TranscriptTextMerger.join(draftCommittedText, taskUtterances.text)
            lastHypothesis = hypothesis
            draftRestartAttempts = 0

            if result.isFinal {
                let kind: TranscriptSegmentUpdateKind = sessionFinishing ? .sessionFinal : .segmentFinal
                updateToSend = makeUpdate(
                    stableText: hypothesis,
                    partialText: "",
                    kind: kind
                )

                request = nil
                task = nil
                segmentFinishing = false

                if sessionFinishing {
                    sessionActive = false
                    shouldNotifyFinished = markFinishedNotificationLocked()
                } else {
                    if draftSegmentSequence != nil {
                        draftCommittedText = hypothesis
                        committedDraftTokens = lastDraftTokens ?? committedDraftTokens
                    }
                    shouldRestart = true
                }
            } else {
                updateToSend = makeUpdate(
                    stableText: hypothesis,
                    partialText: "",
                    kind: .partial
                )
            }
        }

        if result == nil, let error {
            if sessionFinishing || segmentFinishing {
                let kind: TranscriptSegmentUpdateKind = sessionFinishing ? .sessionFinal : .segmentFinal
                let fallbackText = TranscriptTextNormalizer.normalize(lastHypothesis)
                if !fallbackText.isEmpty {
                    updateToSend = makeUpdate(
                        stableText: fallbackText,
                        partialText: "",
                        kind: kind
                    )
                }

                request = nil
                task = nil
                segmentFinishing = false

                if sessionFinishing {
                    sessionActive = false
                    shouldNotifyFinished = markFinishedNotificationLocked()
                } else {
                    if draftSegmentSequence != nil {
                        draftCommittedText = fallbackText
                        committedDraftTokens = lastDraftTokens ?? committedDraftTokens
                    }
                    shouldRestart = true
                }
            } else if draftSegmentSequence != nil, draftRestartAttempts < 2 {
                draftRestartAttempts += 1
                draftRecoveryAttempt = draftRestartAttempts
                draftCommittedText = lastHypothesis
                committedDraftTokens = lastDraftTokens ?? committedDraftTokens
                request = nil
                task = nil
                shouldRestart = true
            } else {
                sessionActive = false
                request = nil
                task = nil
                errorToSend = error
            }
        }

        lock.unlock()

        if let draftRecoveryAttempt {
            DiagnosticLogger.shared.warning(
                "Apple draft request restarting",
                metadata: [
                    "attempt": String(draftRecoveryAttempt),
                    "error": error?.localizedDescription ?? "",
                ]
            )
        }

        if let updateToSend {
            onUpdate?(updateToSend)
        }

        if let errorToSend {
            onError?(errorToSend)
            return
        }

        if shouldRestart {
            do {
                try startNextTask(
                    sessionGeneration: expectedSessionGeneration,
                    replacingTaskGeneration: expectedTaskGeneration
                )
            } catch {
                onError?(error)
            }
        }

        if shouldNotifyFinished {
            onFinished?()
        }
    }

    private func finishWithoutActiveTask(
        sessionGeneration expectedSessionGeneration: Int,
        taskGeneration expectedTaskGeneration: Int
    ) {
        var updateToSend: RecognitionUpdate?
        var shouldNotifyFinished = false

        lock.lock()
        guard sessionActive,
            sessionGeneration == expectedSessionGeneration,
            taskGeneration == expectedTaskGeneration
        else {
            lock.unlock()
            return
        }

        let fallbackText = TranscriptTextNormalizer.normalize(lastHypothesis)
        if !fallbackText.isEmpty {
            updateToSend = makeUpdate(
                stableText: fallbackText,
                partialText: "",
                kind: .sessionFinal
            )
        }
        sessionActive = false
        shouldNotifyFinished = markFinishedNotificationLocked()
        lock.unlock()

        if let updateToSend {
            onUpdate?(updateToSend)
        }
        if shouldNotifyFinished {
            onFinished?()
        }
    }

    private func makeUpdate(
        stableText: String,
        partialText: String,
        kind: TranscriptSegmentUpdateKind
    ) -> RecognitionUpdate {
        RecognitionUpdate(
            segment: TranscriptSegmentUpdate(
                segmentID: currentSegmentID,
                sequence: currentSegmentSequence,
                stableText: stableText,
                partialText: partialText,
                kind: kind
            ),
            // Apple Speech revises its current hypothesis, but this bootstrap mode does
            // not represent a separate refinement pass. Keep it visually uniform.
            shouldDimPartialText: false,
            timedDraftTokens: lastDraftTokens
        )
    }

    private func markFinishedNotificationLocked() -> Bool {
        guard !didNotifyFinished else { return false }
        didNotifyFinished = true
        return true
    }
}

extension NSLock {
    fileprivate func performLocked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
