import AVFoundation
import Foundation

public enum SFSpeechRecognizerAuthorizationStatus { case notDetermined, authorized }

public final class SFSpeechAudioBufferRecognitionRequest {
    public var shouldReportPartialResults = false
    public var taskHint: SFSpeechRecognitionTaskHint = .dictation
    public var contextualStrings: [String] = []
    public var addsPunctuation = false
    public var requiresOnDeviceRecognition = false
    public private(set) var ended = false
    public private(set) var appendedBuffers = 0
    public init() {}
    public func append(_ buffer: AVAudioPCMBuffer) { appendedBuffers += 1 }
    public func endAudio() { ended = true }
}

public enum SFSpeechRecognitionTaskHint { case dictation }

public final class SFSpeechRecognitionTask {
    public private(set) var cancelled = false
    public func cancel() { cancelled = true }
}

public struct SFTranscription {
    public let formattedString: String
    public let segments: [SFTranscriptionSegment]
}

public struct SFTranscriptionSegment {
    public let substringRange: NSRange
    public let timestamp: TimeInterval
    public let duration: TimeInterval
}

/// Apple attaches metadata when it closes an utterance after a pause.
public final class SFSpeechRecognitionMetadata {}

public struct SFSpeechRecognitionResult {
    public let bestTranscription: SFTranscription
    public let isFinal: Bool
    public let speechRecognitionMetadata: SFSpeechRecognitionMetadata?
    public init(
        text: String, isFinal: Bool, segments: [SFTranscriptionSegment] = [], closesUtterance: Bool = false
    ) {
        bestTranscription = SFTranscription(formattedString: text, segments: segments)
        self.isFinal = isFinal
        speechRecognitionMetadata = closesUtterance ? SFSpeechRecognitionMetadata() : nil
    }
}

public enum SpeechStub {
    public static var requests: [SFSpeechAudioBufferRecognitionRequest] = []
    public static var callbacks: [(SFSpeechRecognitionResult?, Error?) -> Void] = []
    public static func reset() {
        requests = []
        callbacks = []
    }
    public static func emit(_ index: Int, text: String, final: Bool = false, closesUtterance: Bool = false) {
        callbacks[index](SFSpeechRecognitionResult(text: text, isFinal: final, closesUtterance: closesUtterance), nil)
    }
    public static func fail(_ index: Int) {
        callbacks[index](nil, NSError(domain: "SpeechStub", code: 1))
    }
    public static func emitTimed(
        _ index: Int, words: [(String, TimeInterval, TimeInterval)], final: Bool = false,
        closesUtterance: Bool = false
    ) {
        let text = words.map { $0.0 }.joined(separator: " ")
        var offset = 0
        let segments = words.map { word, timestamp, duration in
            let length = (word as NSString).length
            let segment = SFTranscriptionSegment(
                substringRange: NSRange(location: offset, length: length), timestamp: timestamp, duration: duration)
            offset += length + 1
            return segment
        }
        callbacks[index](
            SFSpeechRecognitionResult(
                text: text, isFinal: final, segments: segments, closesUtterance: closesUtterance), nil)
    }
}

public final class SFSpeechRecognizer {
    public var isAvailable = true
    public var supportsOnDeviceRecognition = true
    public init?(locale: Locale) {}
    public static func authorizationStatus() -> SFSpeechRecognizerAuthorizationStatus { .authorized }
    public static func requestAuthorization(_ callback: (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        callback(.authorized)
    }
    public func recognitionTask(
        with request: SFSpeechAudioBufferRecognitionRequest,
        resultHandler: @escaping (SFSpeechRecognitionResult?, Error?) -> Void
    ) -> SFSpeechRecognitionTask {
        SpeechStub.requests.append(request)
        SpeechStub.callbacks.append(resultHandler)
        return SFSpeechRecognitionTask()
    }
}
