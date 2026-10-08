import Combine
import Foundation
import VoicePanelCore

struct TranscriptPresentationRun: Equatable {
    let text: String
    let isDraft: Bool
    let shouldDim: Bool
}

struct TranscriptPresentation: Equatable {
    let stableText: String
    let partialText: String
    let combinedText: String
    let compactText: String
    let multilineText: String
    let runs: [TranscriptPresentationRun]

    init(session: TranscriptSession = TranscriptSession(), dimmedDraftSegmentIDs: Set<UUID> = []) {
        stableText = session.stableText
        partialText = session.partialText
        // Preserve every pending draft in timeline order, including drafts
        // between finalized chunks. Apply the same overlap rules as the session.
        var combinedText = ""
        var runs: [TranscriptPresentationRun] = []
        for segment in session.segments where !TranscriptTextMerger.isEffectivelyEmpty(segment.displayText) {
            let merged =
                segment.allowsLeadingOverlap
                ? TranscriptTextMerger.merge(combinedText, segment.displayText)
                : TranscriptTextMerger.join(combinedText, segment.displayText)
            let appended = String(merged.dropFirst(combinedText.count))
            if !appended.isEmpty {
                runs.append(
                    TranscriptPresentationRun(
                        text: appended, isDraft: !segment.isFinal,
                        shouldDim: !segment.isFinal && dimmedDraftSegmentIDs.contains(segment.id)
                    )
                )
            }
            combinedText = merged
        }
        self.runs = runs
        self.combinedText = combinedText
        compactText = TranscriptTextNormalizer.singleLinePreview(combinedText)
        multilineText = TranscriptTextNormalizer.normalize(String(combinedText.suffix(1_200)))
    }
}

@MainActor
final class AppState: ObservableObject {
    enum Phase: String {
        case idle
        case preparing
        case monitoring
        case listening
        case stopping
        case finalizing
        case result
        case failed
        case cancelled

        var isRecordingRelated: Bool {
            switch self {
            case .preparing, .listening, .stopping, .finalizing:
                return true
            default:
                return false
            }
        }
    }

    enum CompletionPresentation: String {
        case none
        case success
        case copied
        case interactive
        case noSpeech
        case tooShort
        case partialIssue
    }

    @Published var phase: Phase = .idle
    @Published var completionPresentation: CompletionPresentation = .none
    private(set) var transcriptSession = TranscriptSession()
    @Published private(set) var transcriptPresentation = TranscriptPresentation()
    @Published var editableText = ""
    @Published var statusMessage = "Ready"
    @Published private(set) var preparationProgress: Double?
    @Published private(set) var isWaitingForRecognizer = false
    @Published private(set) var isImportingAudioFile = false
    @Published private(set) var audioImportProgress: AudioImportProgress?
    @Published var audioLevels = Array(repeating: Float(0), count: 56)
    @Published private(set) var audioLevelCount = 0
    @Published var currentLevelDB: Float = -90
    @Published var currentNormalizedLevel: Float = 0
    @Published var peakLevelDB: Float = -90
    @Published var noiseFloorDB: Float = -58
    @Published var thresholdDB: Float = -46
    @Published var voiceActivityState: VoiceActivityState = .silence
    @Published var emittedChunkCount = 0
    @Published var lastError: String?
    @Published var inputDeviceWarning: String?
    @Published var shouldDimPartialText = false
    @Published var activeEngineName = "Apple Speech"
    @Published var hasLiveDraftText = false
    var recognitionUsesAudioChunks = false
    @Published var recognitionQueueDepth = 0
    @Published var lastChunkProcessingDuration: TimeInterval = 0
    @Published var lastChunkDuration: TimeInterval = 0
    @Published var realTimeFactor: Double = 0
    @Published var recordingDuration: TimeInterval = 0
    @Published private(set) var activePendingFeedbackVoicedDuration: TimeInterval = 0
    @Published private(set) var frozenPendingFeedbackItemCount = 0
    @Published private(set) var frozenPendingFeedbackExtent: Double = 0
    @Published private(set) var pendingFeedbackItemExtent: Double = 0
    @Published private(set) var pendingRecognitionWork = RecognitionPendingWork()
    @Published private(set) var recordingControlSource: RecordingControlSource?

    private var lastPendingFeedbackCaptureDuration: TimeInterval = 0
    private var pendingFeedbackItemsByChunkID: [UUID: Int] = [:]
    private var pendingFeedbackExtentsByChunkID: [UUID: Double] = [:]
    private var resolvedPendingFeedbackChunkIDs: Set<UUID> = []
    private var transcriptBoundaryMetadata = TranscriptBoundaryMetadata()
    private var dimmedDraftSegmentIDs: Set<UUID> = []

    var stableText: String {
        transcriptPresentation.stableText
    }

    var partialText: String {
        transcriptPresentation.partialText
    }

    var combinedTranscript: String {
        phase == .result ? editableText : transcriptPresentation.combinedText
    }

    var compactTranscriptText: String {
        phase == .result
            ? TranscriptTextNormalizer.singleLinePreview(editableText)
            : transcriptPresentation.compactText
    }

    var canStartRecording: Bool {
        switch phase {
        case .idle, .result, .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    func resetForNewSession(source: RecordingControlSource? = nil) {
        transcriptSession.reset()
        dimmedDraftSegmentIDs.removeAll(keepingCapacity: true)
        transcriptPresentation = TranscriptPresentation()
        recordingControlSource = source
        editableText = ""
        emittedChunkCount = 0
        transcriptBoundaryMetadata.reset()
        lastError = nil
        shouldDimPartialText = false
        completionPresentation = .none
        statusMessage = "Preparing…"
        preparationProgress = nil
        isWaitingForRecognizer = false
        isImportingAudioFile = false
        audioImportProgress = nil
        audioLevels = Array(repeating: 0, count: audioLevels.count)
        audioLevelCount = 0
        currentNormalizedLevel = 0
        recognitionQueueDepth = 0
        lastChunkProcessingDuration = 0
        lastChunkDuration = 0
        realTimeFactor = 0
        hasLiveDraftText = false
        recognitionUsesAudioChunks = false
        recordingDuration = 0
        activePendingFeedbackVoicedDuration = 0
        frozenPendingFeedbackItemCount = 0
        frozenPendingFeedbackExtent = 0
        pendingFeedbackItemExtent = 0
        lastPendingFeedbackCaptureDuration = 0
        pendingFeedbackItemsByChunkID.removeAll(keepingCapacity: true)
        pendingFeedbackExtentsByChunkID.removeAll(keepingCapacity: true)
        resolvedPendingFeedbackChunkIDs.removeAll(keepingCapacity: true)
        pendingRecognitionWork.reset()
    }

    func updatePreparation(
        status: String,
        progress: Double? = nil,
        waitingForRecognizer: Bool = true,
        importingAudioFile: Bool = false
    ) {
        statusMessage = status
        preparationProgress = progress.map { min(max($0, 0), 1) }
        isWaitingForRecognizer = waitingForRecognizer
        isImportingAudioFile = importingAudioFile
    }

    func clearPreparation() {
        preparationProgress = nil
        isWaitingForRecognizer = false
        isImportingAudioFile = false
    }

    func updateAudioImportProgress(_ progress: AudioImportProgress?) {
        audioImportProgress = progress
    }

    func clearRecordingContext() {
        recordingControlSource = nil
    }

    func latchHotKeyRecording() {
        guard recordingControlSource == .hotKeyHold else { return }
        recordingControlSource = .hotKeyLatched
    }

    func discardTranscriptContent() {
        transcriptSession.reset()
        dimmedDraftSegmentIDs.removeAll(keepingCapacity: true)
        transcriptPresentation = TranscriptPresentation()
        editableText = ""
        shouldDimPartialText = false
        hasLiveDraftText = false
        audioImportProgress = nil
    }

    func applyRecognitionUpdate(_ update: RecognitionUpdate) {
        applyRecognitionUpdates([update])
    }

    func applyRecognitionUpdates(_ updates: [RecognitionUpdate]) {
        guard !updates.isEmpty else { return }
        var nextSession = transcriptSession
        var resetsActiveFeedback = false
        var includesSessionFinal = false

        for update in updates {
            nextSession.apply(update.segment)
            // A final callback affects only its own segment's styling. Older
            // finals must not make unrelated live drafts look finalized.
            if update.segment.kind == .partial, update.shouldDimPartialText {
                dimmedDraftSegmentIDs.insert(update.segment.segmentID)
            } else {
                dimmedDraftSegmentIDs.remove(update.segment.segmentID)
            }
            if !recognitionUsesAudioChunks, update.segment.kind != .partial {
                resetsActiveFeedback = true
            }
            if update.segment.kind == .sessionFinal {
                includesSessionFinal = true
            }
        }

        transcriptSession = nextSession
        transcriptPresentation = TranscriptPresentation(
            session: nextSession, dimmedDraftSegmentIDs: dimmedDraftSegmentIDs
        )
        shouldDimPartialText = transcriptPresentation.runs.contains(where: \.shouldDim)

        // Chunk pipelines acknowledge audio only through queue/outcome events.
        // Drafts and older chunk results must never clear the current live tail.
        if resetsActiveFeedback {
            activePendingFeedbackVoicedDuration = 0
            refreshPendingFeedbackItemExtent()
        }

        if includesSessionFinal {
            editableText = nextSession.combinedText
        }
    }

    func updateCaptureProgress(
        recordingDuration: TimeInterval,
        pendingAudioDuration: TimeInterval
    ) {
        self.recordingDuration = max(0, recordingDuration)
        pendingRecognitionWork.updateCurrentAudioDuration(pendingAudioDuration)
    }

    func queueRecognitionChunk(_ chunk: AudioChunk) {
        transcriptBoundaryMetadata.register(chunk)
        if resolvedPendingFeedbackChunkIDs.remove(chunk.id) != nil {
            activePendingFeedbackVoicedDuration = 0
            refreshPendingFeedbackItemExtent()
            pendingRecognitionWork.queueChunk(id: chunk.id, duration: chunk.duration)
            return
        }
        let frozenCount = max(
            1,
            PendingFeedbackPolicy.itemCount(
                forVoicedDuration: activePendingFeedbackVoicedDuration
            )
        )
        let frozenExtent = max(
            1,
            PendingFeedbackPolicy.itemExtent(
                forVoicedDuration: activePendingFeedbackVoicedDuration
            )
        )
        // Every queued final chunk keeps at least one visible operation marker.
        // A fast recognizer may still resolve it before main-thread registration,
        // so nil remains reserved for that completion-before-registration order.
        pendingFeedbackItemsByChunkID[chunk.id] = frozenCount
        pendingFeedbackExtentsByChunkID[chunk.id] = frozenExtent
        activePendingFeedbackVoicedDuration = 0
        refreshFrozenPendingFeedback()
        pendingRecognitionWork.queueChunk(id: chunk.id, duration: chunk.duration)
    }

    func boundaryReason(forTranscriptSegment segment: TranscriptSegment) -> AudioChunkBoundaryReason? {
        transcriptBoundaryMetadata.boundaryReason(for: segment)
    }

    func boundaryMetadata(
        forTranscriptSegment segment: TranscriptSegment
    ) -> AudioChunkBoundaryMetadata? {
        transcriptBoundaryMetadata.boundaryMetadata(for: segment)
    }

    func resolveRecognitionChunk(id: UUID, failed: Bool) {
        if pendingFeedbackItemsByChunkID.removeValue(forKey: id) == nil {
            resolvedPendingFeedbackChunkIDs.insert(id)
        }
        pendingFeedbackExtentsByChunkID.removeValue(forKey: id)
        refreshFrozenPendingFeedback()
        if failed {
            pendingRecognitionWork.failChunk(id: id)
        } else {
            pendingRecognitionWork.completeChunk(id: id)
        }
    }

    @discardableResult
    func recoverRecognitionChunkFailure(id: UUID) -> Bool {
        pendingRecognitionWork.recoverFailedChunk(id: id)
    }

    func finishAudioCapture() {
        pendingRecognitionWork.finishCapture()
        lastPendingFeedbackCaptureDuration = 0
        currentNormalizedLevel = 0
        voiceActivityState = .silence
    }

    private func clearPendingFeedback() {
        activePendingFeedbackVoicedDuration = 0
        frozenPendingFeedbackItemCount = 0
        frozenPendingFeedbackExtent = 0
        pendingFeedbackItemExtent = 0
        lastPendingFeedbackCaptureDuration = 0
        pendingFeedbackItemsByChunkID.removeAll(keepingCapacity: true)
        pendingFeedbackExtentsByChunkID.removeAll(keepingCapacity: true)
        resolvedPendingFeedbackChunkIDs.removeAll(keepingCapacity: true)
    }

    func finishRecognitionEngine() {
        pendingRecognitionWork.finishEngine()
        clearPendingFeedback()
        recognitionQueueDepth = 0
    }

    var pendingPlaceholderCount: Int {
        pendingRecognitionWork.placeholderCount()
    }

    func pendingFeedbackPresentation(maximumItemCount: Int) -> PendingFeedbackPresentation {
        PendingFeedbackPolicy.presentation(
            isRecording: phase.isRecordingRelated,
            voiceActivityState: voiceActivityState,
            activeVoicedDuration: activePendingFeedbackVoicedDuration,
            frozenItemCount: frozenPendingFeedbackItemCount,
            maximumItemCount: maximumItemCount
        )
    }

    func applyRecognitionMetrics(_ metrics: RecognitionPerformanceMetrics) {
        activeEngineName = metrics.engineName
        recognitionQueueDepth = metrics.queueDepth
        lastChunkProcessingDuration = metrics.processingDuration
        lastChunkDuration = metrics.chunkDuration
        realTimeFactor = metrics.realTimeFactor
    }

    func appendAudioLevel(_ normalizedLevel: Float, peakDB: Float) {
        let clampedLevel = min(max(normalizedLevel, 0), 1)
        if audioLevelCount < audioLevels.count {
            audioLevels[audioLevelCount] = clampedLevel
            audioLevelCount += 1
        } else {
            audioLevels.removeFirst()
            audioLevels.append(clampedLevel)
        }
        currentNormalizedLevel = clampedLevel
        peakLevelDB = max(peakLevelDB * 0.94, peakDB)
    }

    func updatePendingFeedbackVoiceActivity(
        recordingDuration: TimeInterval,
        voiceActivityState: VoiceActivityState
    ) {
        let duration = max(0, recordingDuration)
        let delta =
            duration >= lastPendingFeedbackCaptureDuration
            ? duration - lastPendingFeedbackCaptureDuration
            : 0
        lastPendingFeedbackCaptureDuration = duration
        guard voiceActivityState == .speech else { return }
        activePendingFeedbackVoicedDuration += delta
        refreshPendingFeedbackItemExtent()
    }

    private func refreshFrozenPendingFeedback() {
        frozenPendingFeedbackItemCount = pendingFeedbackItemsByChunkID.values.reduce(0, +)
        frozenPendingFeedbackExtent = pendingFeedbackExtentsByChunkID.values.reduce(0, +)
        refreshPendingFeedbackItemExtent()
    }

    private func refreshPendingFeedbackItemExtent() {
        pendingFeedbackItemExtent =
            frozenPendingFeedbackExtent
            + PendingFeedbackPolicy.itemExtent(
                forVoicedDuration: activePendingFeedbackVoicedDuration
            )
    }

    func endAudioActivity() {
        finishAudioCapture()
        clearPendingFeedback()
    }

    func finalizeResult(
        finalizedSegmentsOnly: Bool = false,
        processedText: String? = nil
    ) {
        clearPreparation()
        audioImportProgress = nil
        let sourceText =
            processedText
            ?? (finalizedSegmentsOnly
                ? transcriptSession.finalizedText
                : transcriptSession.combinedText)
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        editableText = text
        shouldDimPartialText = false
        phase = .result
        if pendingRecognitionWork.failedChunkCount > 0 {
            completionPresentation = .partialIssue
            statusMessage = "Completed with an issue"
        } else {
            completionPresentation = text.isEmpty ? .noSpeech : .success
            statusMessage = text.isEmpty ? "No speech recognized" : "Transcript ready"
        }
    }

    func fail(_ message: String) {
        clearPreparation()
        audioImportProgress = nil
        lastError = message
        completionPresentation = .none
        statusMessage = message
        phase = .failed
    }
}

#if DEBUG
    extension AppState {
        func configurePreview(
            phase: Phase,
            stableText: String = "",
            partialText: String = "",
            editableText: String? = nil,
            statusMessage: String? = nil,
            completionPresentation: CompletionPresentation = .none,
            preparationProgress: Double? = nil,
            isWaitingForRecognizer: Bool = false,
            isImportingAudioFile: Bool = false,
            voiceActivityState: VoiceActivityState = .silence,
            currentLevelDB: Float = -46,
            currentNormalizedLevel: Float = 0.36,
            thresholdDB: Float = -44,
            noiseFloorDB: Float = -58,
            emittedChunkCount: Int = 0,
            recordingDuration: TimeInterval = 0,
            pendingFeedbackItemCount: Int = 0,
            pendingFeedbackExtent: Double = 0,
            error: String? = nil
        ) {
            self.phase = phase
            var previewSession = TranscriptSession()
            previewSession.apply(
                TranscriptSegmentUpdate(
                    segmentID: UUID(), sequence: 0, stableText: stableText,
                    partialText: "", kind: .segmentFinal
                )
            )
            previewSession.apply(
                TranscriptSegmentUpdate(
                    segmentID: UUID(), sequence: 1, stableText: "",
                    partialText: partialText, kind: .partial
                )
            )
            self.transcriptPresentation = TranscriptPresentation(session: previewSession)
            self.editableText = editableText ?? self.transcriptPresentation.combinedText
            self.statusMessage = statusMessage ?? phase.rawValue.capitalized
            self.completionPresentation = completionPresentation
            self.preparationProgress = preparationProgress
            self.isWaitingForRecognizer = isWaitingForRecognizer
            self.isImportingAudioFile = isImportingAudioFile
            self.voiceActivityState = voiceActivityState
            self.currentLevelDB = currentLevelDB
            self.currentNormalizedLevel = currentNormalizedLevel
            self.thresholdDB = thresholdDB
            self.noiseFloorDB = noiseFloorDB
            self.emittedChunkCount = emittedChunkCount
            self.recordingDuration = recordingDuration
            self.frozenPendingFeedbackItemCount = pendingFeedbackItemCount
            self.frozenPendingFeedbackExtent = pendingFeedbackExtent
            self.pendingFeedbackItemExtent = pendingFeedbackExtent
            self.lastError = error

            let levels: [Float] = [
                0.08, 0.12, 0.18, 0.30, 0.52, 0.76, 0.44, 0.62,
                0.84, 0.55, 0.32, 0.20, 0.38, 0.72, 0.91, 0.64,
            ]
            audioLevels = Array(repeating: 0.06, count: max(56, audioLevels.count))
            for index in audioLevels.indices {
                audioLevels[index] = levels[index % levels.count]
            }
            audioLevelCount = audioLevels.count
        }
    }
#endif
