import Foundation
import VoicePanelCore

let draftFinalSegmentAlignmentChecks: [CheckCase] = [
    CheckCase(name: "Draft and final output share the emitted chunk ID") {
        var alignment = DraftFinalSegmentAlignment()
        let chunkID = UUID()
        let sequence = alignment.registerChunk(id: chunkID)
        try expectEqual(sequence, 0)
        try expectEqual(alignment.segmentIDForDraft(sequence: sequence), chunkID)
        try expectEqual(
            alignment.segmentIDForFinal(sequence: sequence, engineSegmentID: UUID()),
            chunkID
        )
        try expectEqual(alignment.isFinalized(sequence: sequence), true)
    },

    CheckCase(name: "Draft output arriving before a chunk gets a stable fallback ID") {
        var alignment = DraftFinalSegmentAlignment()
        let first = alignment.segmentIDForDraft(sequence: 0)
        let second = alignment.segmentIDForDraft(sequence: 0)
        try expectEqual(first, second)
    },

    CheckCase(name: "Final output replaces a draft that arrived before its audio chunk") {
        var alignment = DraftFinalSegmentAlignment()
        let provisionalPresentationID = alignment.segmentIDForDraft(sequence: 0)
        let chunkID = UUID()
        try expectEqual(alignment.registerChunk(id: chunkID), 0)
        try expectEqual(alignment.sequence(forChunkID: chunkID), 0)
        try expectEqual(
            alignment.segmentIDForFinal(sequence: 0, engineSegmentID: chunkID),
            provisionalPresentationID
        )
        try expect(provisionalPresentationID != chunkID, "presentation and transport IDs stay distinct")
    },

    CheckCase(name: "Draft alignment can clear a chunk that produced no final text") {
        var alignment = DraftFinalSegmentAlignment()
        let chunkID = UUID()
        let sequence = alignment.registerChunk(id: chunkID)
        _ = alignment.segmentIDForDraft(sequence: sequence)
        let cleared = alignment.finalizeEmptyChunk(id: chunkID)
        try expectEqual(cleared?.sequence, sequence)
        try expectEqual(cleared?.segmentID, chunkID)
        try expect(alignment.isFinalized(sequence: sequence), "empty final must clear draft")
    },

    CheckCase(name: "An empty final clears a draft that arrived before its chunk") {
        var alignment = DraftFinalSegmentAlignment()
        let provisionalPresentationID = alignment.segmentIDForDraft(sequence: 0)
        let chunkID = UUID()
        _ = alignment.registerChunk(id: chunkID)
        let cleared = alignment.finalizeEmptyChunk(id: chunkID)
        try expectEqual(cleared?.segmentID, provisionalPresentationID)
    },

    CheckCase(name: "Alignment reset starts a fresh timeline") {
        var alignment = DraftFinalSegmentAlignment()
        _ = alignment.registerChunk(id: UUID())
        alignment.reset()
        try expectEqual(alignment.registerChunk(id: UUID()), 0)
        try expectEqual(alignment.nextSessionSequence, 1)
    },
]
