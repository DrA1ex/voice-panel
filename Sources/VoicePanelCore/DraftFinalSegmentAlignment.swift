import Foundation

/// Keeps draft and final recognition output attached to the same transcript segment.
/// Chunk order is the authoritative timeline because both the live draft and the
/// refinement engine receive the same captured audio in that order.
public struct DraftFinalSegmentAlignment: Equatable, Sendable {
    private var chunkIDsBySequence: [Int: UUID] = [:]
    private var presentationIDsBySequence: [Int: UUID] = [:]
    private var sequencesByChunkID: [UUID: Int] = [:]
    private var finalizedSequences: Set<Int> = []
    private var nextChunkSequence = 0
    private var trailingOverlapBySequence: [Int: TimeInterval] = [:]

    public init() {}

    @discardableResult
    public mutating func registerChunk(id: UUID, trailingOverlapDuration: TimeInterval = 0) -> Int {
        let sequence = nextChunkSequence
        nextChunkSequence += 1
        chunkIDsBySequence[sequence] = id
        sequencesByChunkID[id] = sequence
        trailingOverlapBySequence[sequence] = trailingOverlapDuration
        if presentationIDsBySequence[sequence] == nil {
            presentationIDsBySequence[sequence] = id
        }
        return sequence
    }

    public mutating func segmentIDForDraft(sequence: Int) -> UUID {
        if let presentationID = presentationIDsBySequence[sequence] {
            return presentationID
        }
        let presentationID = chunkIDsBySequence[sequence] ?? UUID()
        presentationIDsBySequence[sequence] = presentationID
        return presentationID
    }

    public mutating func segmentIDForFinal(
        sequence: Int,
        engineSegmentID: UUID
    ) -> UUID {
        let segmentID =
            presentationIDsBySequence[sequence]
            ?? chunkIDsBySequence[sequence]
            ?? engineSegmentID
        presentationIDsBySequence[sequence] = segmentID
        finalizedSequences.insert(sequence)
        return segmentID
    }

    public func sequence(forChunkID chunkID: UUID) -> Int? {
        sequencesByChunkID[chunkID]
    }

    public mutating func finalizeEmptyChunk(id chunkID: UUID) -> (sequence: Int, segmentID: UUID)? {
        guard let sequence = sequence(forChunkID: chunkID),
            !finalizedSequences.contains(sequence)
        else { return nil }
        let segmentID = presentationIDsBySequence[sequence] ?? chunkID
        presentationIDsBySequence[sequence] = segmentID
        finalizedSequences.insert(sequence)
        return (sequence, segmentID)
    }

    public func isFinalized(sequence: Int) -> Bool {
        finalizedSequences.contains(sequence)
    }

    public func allowsLeadingOverlap(sequence: Int) -> Bool {
        (trailingOverlapBySequence[sequence - 1] ?? 0) > 0
    }

    public var nextSessionSequence: Int {
        max(
            nextChunkSequence,
            max(
                (chunkIDsBySequence.keys.max() ?? -1) + 1,
                (presentationIDsBySequence.keys.max() ?? -1) + 1
            )
        )
    }

    public mutating func reset() {
        trailingOverlapBySequence.removeAll(keepingCapacity: true)
        chunkIDsBySequence.removeAll(keepingCapacity: true)
        presentationIDsBySequence.removeAll(keepingCapacity: true)
        sequencesByChunkID.removeAll(keepingCapacity: true)
        finalizedSequences.removeAll(keepingCapacity: true)
        nextChunkSequence = 0
    }
}
