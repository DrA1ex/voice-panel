import Foundation
import VoicePanelCore

let transcriptBoundaryMetadataChecks: [CheckCase] = [
    CheckCase(name: "Transcript boundary metadata follows a remapped live segment by sequence") {
        let forcedID = UUID()
        var metadata = TranscriptBoundaryMetadata()
        metadata.register(
            AudioChunk(
                id: forcedID,
                samples: [0.1],
                sampleRate: 16_000,
                boundaryReason: .maximumDuration
            )
        )

        let draftRemappedSegment = TranscriptSegment(
            id: UUID(),
            sequence: 0,
            finalText: "Продолжение фразы"
        )
        try expectEqual(
            metadata.boundaryReason(for: draftRemappedSegment),
            .maximumDuration
        )
    },
    CheckCase(name: "Transcript boundary metadata gives an exact chunk ID priority") {
        let firstID = UUID()
        let secondID = UUID()
        var metadata = TranscriptBoundaryMetadata()
        metadata.register(
            AudioChunk(
                id: firstID,
                samples: [0.1],
                sampleRate: 16_000,
                boundaryReason: .maximumDuration
            )
        )
        metadata.register(
            AudioChunk(
                id: secondID,
                samples: [0.1],
                sampleRate: 16_000,
                boundaryReason: .silence
            )
        )

        let reorderedSegment = TranscriptSegment(
            id: secondID,
            sequence: 0,
            finalText: "Новая фраза"
        )
        try expectEqual(metadata.boundaryReason(for: reorderedSegment), .silence)
    },
    CheckCase(name: "Transcript boundary metadata preserves actual overlap evidence") {
        let chunkID = UUID()
        var metadata = TranscriptBoundaryMetadata()
        metadata.register(
            AudioChunk(
                id: chunkID,
                samples: [0.1],
                sampleRate: 16_000,
                boundaryReason: .maximumDuration,
                trailingOverlapDuration: 0.4
            )
        )
        let segment = TranscriptSegment(id: chunkID, sequence: 9, finalText: "Текст")
        try expectEqual(
            metadata.boundaryMetadata(for: segment),
            AudioChunkBoundaryMetadata(
                reason: .maximumDuration,
                trailingOverlapDuration: 0.4
            )
        )
    },
]
