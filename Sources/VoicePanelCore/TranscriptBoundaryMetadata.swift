import Foundation

/// Keeps captured chunk boundaries attached to recognizer segments. Chunk IDs
/// are authoritative; sequence is a fallback for draft/final wrappers that use
/// a presentation ID while preserving the original chunk order.
public struct TranscriptBoundaryMetadata: Equatable, Sendable {
    private var metadataByID: [UUID: AudioChunkBoundaryMetadata] = [:]
    private var metadataBySequence: [Int: AudioChunkBoundaryMetadata] = [:]
    private var nextSequence = 0

    public init() {}

    public mutating func register(_ chunk: AudioChunk) {
        metadataByID[chunk.id] = chunk.boundaryMetadata
        metadataBySequence[nextSequence] = chunk.boundaryMetadata
        nextSequence += 1
    }

    public func boundaryMetadata(for segment: TranscriptSegment) -> AudioChunkBoundaryMetadata? {
        metadataByID[segment.id] ?? metadataBySequence[segment.sequence]
    }

    public func boundaryReason(for segment: TranscriptSegment) -> AudioChunkBoundaryReason? {
        boundaryMetadata(for: segment)?.reason
    }

    public mutating func reset() {
        metadataByID.removeAll(keepingCapacity: true)
        metadataBySequence.removeAll(keepingCapacity: true)
        nextSequence = 0
    }
}
