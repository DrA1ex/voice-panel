import AVFoundation
import Foundation
import VoicePanelCore

struct RecognitionUpdate {
    let segment: TranscriptSegmentUpdate
    let shouldDimPartialText: Bool
    var timedDraftTokens: [TimedDraftToken]? = nil
}

enum RecognitionChunkOutcome {
    case completed(UUID)
    case failed(UUID, message: String)
    case cancelled(UUID)
}

enum RecognitionFinalTextPolicy: Equatable {
    case allRecognizedSegments
    case finalizedSegmentsOnly
}

enum RecognitionAudioInputMode: Equatable {
    case continuousBuffers
    case vadChunks
    case continuousBuffersAndVADChunks
}

struct RecognitionPerformanceMetrics: Equatable {
    let engineName: String
    let queueDepth: Int
    let chunkDuration: TimeInterval
    let processingDuration: TimeInterval

    var realTimeFactor: Double {
        guard chunkDuration > 0 else { return 0 }
        return processingDuration / chunkDuration
    }
}

protocol RecognitionEngine: AnyObject {
    var displayName: String { get }
    var audioInputMode: RecognitionAudioInputMode { get }
    var finalizationTimeout: TimeInterval { get }
    var providesLiveDraft: Bool { get }
    var finalTextPolicy: RecognitionFinalTextPolicy { get }
    var onUpdate: ((RecognitionUpdate) -> Void)? { get set }
    var onFinished: (() -> Void)? { get set }
    var onMetrics: ((RecognitionPerformanceMetrics) -> Void)? { get set }
    var onChunkOutcome: ((RecognitionChunkOutcome) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    func requestAuthorization() async throws
    func start(localeIdentifier: String) async throws
    func append(_ buffer: AVAudioPCMBuffer)
    func append(_ buffer: AVAudioPCMBuffer, captureTimeRange: Range<TimeInterval>)
    func append(_ chunk: AudioChunk)
    func finishCurrentSegment()
    func finish()
    func cancel()
}

extension RecognitionEngine {
    var providesLiveDraft: Bool { false }
    var finalTextPolicy: RecognitionFinalTextPolicy { .allRecognizedSegments }
    func finishCurrentSegment() {}
    func append(_ buffer: AVAudioPCMBuffer) {}
    func append(_ buffer: AVAudioPCMBuffer, captureTimeRange: Range<TimeInterval>) { append(buffer) }
    func append(_ chunk: AudioChunk) {}
}

enum RecognitionEngineError: LocalizedError {
    case authorizationDenied
    case recognizerUnavailable(String)
    case onDeviceRecognitionUnavailable(String)
    case failedToStart
    case modelCouldNotBeLoaded(String)
    case inferenceFailed
    case gigaAMInferenceFailed
    case gigaAMInputTooLong(actualDuration: TimeInterval, maximumDuration: TimeInterval)
    case localONNXInferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return
                "Speech Recognition access is off. Enable VoicePanel in System Settings → "
                + "Privacy & Security → Speech Recognition."
        case .recognizerUnavailable(let locale):
            return "Speech recognition is unavailable for locale \(locale)."
        case .onDeviceRecognitionUnavailable(let locale):
            return
                "On-device Apple speech recognition is unavailable for \(locale). Install the required macOS language assets or choose another locale."
        case .failedToStart:
            return "The speech recognition session could not be started."
        case .modelCouldNotBeLoaded(let path):
            return "The local recognition model could not be loaded from \(path)."
        case .inferenceFailed:
            return "Whisper could not process the current audio chunk."
        case .gigaAMInferenceFailed:
            return "GigaAM could not process the current audio chunk."
        case .gigaAMInputTooLong(let actualDuration, let maximumDuration):
            return String(
                format: "GigaAM input is %.3f seconds; the application safety limit is %.0f seconds.",
                actualDuration,
                maximumDuration
            )
        case .localONNXInferenceFailed(let model):
            return "\(model) could not process the current audio chunk."
        }
    }
}
