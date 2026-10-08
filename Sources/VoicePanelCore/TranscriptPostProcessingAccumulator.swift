import Foundation

public struct TranscriptPostProcessingAccumulator: Equatable, Sendable {
    private var acceptedSegments: [TranscriptPostProcessingSegment] = []

    public init() {}

    public mutating func append(
        text: String,
        boundaryMetadata: AudioChunkBoundaryMetadata
    ) {
        acceptedSegments.append(
            TranscriptPostProcessingSegment(
                text: text,
                boundaryMetadata: boundaryMetadata
            )
        )
    }

    public mutating func append(
        text: String,
        boundaryReason: AudioChunkBoundaryReason,
        trailingOverlapDuration: TimeInterval = 0
    ) {
        append(
            text: text,
            boundaryMetadata: AudioChunkBoundaryMetadata(
                reason: boundaryReason,
                trailingOverlapDuration: trailingOverlapDuration
            )
        )
    }

    public mutating func breakContinuity() {
        guard let last = acceptedSegments.last else { return }
        acceptedSegments[acceptedSegments.count - 1] = TranscriptPostProcessingSegment(
            text: last.text,
            boundaryMetadata: nil
        )
    }

    public var mergedText: String {
        TranscriptTextMerger.merge(acceptedSegments.map(\.text))
    }

    public func processedText(
        configuration: TranscriptPostProcessingConfiguration
    ) -> String {
        TranscriptPostProcessor.process(
            segments: acceptedSegments,
            configuration: configuration
        ).text
    }
}
