import Foundation

public struct CompactAudioImportPresentation: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case preparing
        case listening
        case stopping
        case finalizing
        case result
        case failed
        case other
    }

    public enum Content: Equatable, Sendable {
        case recording
        case processing
        case result
        case failure
    }

    public enum Element: Equatable, Sendable {
        case indeterminateIndicator
        case determinateIndicator(Double)
        case fallbackDescription(String)
    }

    public enum RecordingLayout: Equatable, Sendable {
        case standardRecording
        case dedicatedImportProgress
    }

    public let content: Content
    public let elements: [Element]
    public let recordingLayout: RecordingLayout

    public static func resolve(
        phase: Phase,
        isImportingAudioFile: Bool,
        progress: AudioImportProgress?,
        preparationProgress: Double?
    ) -> CompactAudioImportPresentation {
        let content: Content
        switch phase {
        case .stopping, .finalizing:
            content = .processing
        case .result:
            content = .result
        case .failed:
            content = .failure
        case .preparing, .listening, .other:
            content = .recording
        }

        guard isImportingAudioFile,
            phase == .preparing || phase == .stopping || phase == .finalizing,
            let progress
        else {
            return CompactAudioImportPresentation(
                content: content,
                elements: [],
                recordingLayout: .standardRecording
            )
        }

        let fraction =
            progress.stage == .converting
            ? preparationProgress : progress.fractionCompleted
        var elements: [Element] =
            fraction.map { [.determinateIndicator($0)] }
            ?? [.indeterminateIndicator]
        let fallbackDescription = progress.fallbackDescription
        if let fallbackDescription {
            elements.append(.fallbackDescription(fallbackDescription))
        }
        let recordingLayout: RecordingLayout =
            content == .recording && fallbackDescription != nil
            ? .dedicatedImportProgress : .standardRecording
        return CompactAudioImportPresentation(
            content: content,
            elements: elements,
            recordingLayout: recordingLayout
        )
    }
}
