import Foundation
import VoicePanelCore

let recognitionPendingWorkChecks: [CheckCase] = [
    CheckCase(name: "Pending duration moves from live audio to a queued chunk") {
        var work = RecognitionPendingWork()
        let id = UUID()
        work.updateCurrentAudioDuration(4)
        try expectEqual(work.placeholderCount(), 4)

        work.queueChunk(id: id, duration: 4)
        work.finishCapture()
        try expectApproximatelyEqual(work.totalDuration, 4, accuracy: 0.001)
        try expectEqual(work.placeholderCount(), 4)

        work.completeChunk(id: id)
        try expectEqual(work.hasWork, false)
        try expectEqual(work.placeholderCount(), 0)
    },

    CheckCase(name: "Failed chunks are removed and counted") {
        var work = RecognitionPendingWork()
        let id = UUID()
        work.queueChunk(id: id, duration: 6)
        work.failChunk(id: id)
        try expectEqual(work.chunkCount, 0)
        try expectEqual(work.failedChunkCount, 1)
    },

    CheckCase(name: "a recovered failed attempt no longer marks terminal work partial") {
        var work = RecognitionPendingWork()
        let continuousID = UUID()
        work.queueChunk(id: continuousID, duration: 30)
        work.failChunk(id: continuousID)

        try expectEqual(work.recoverFailedChunk(id: continuousID), true)
        try expectEqual(work.failedChunkCount, 0)
        try expectEqual(work.recoverFailedChunk(id: continuousID), false)
        try expectEqual(work.failedChunkCount, 0)
    },

    CheckCase(name: "recovering Continuous does not hide a genuine fallback failure") {
        var work = RecognitionPendingWork()
        let continuousID = UUID()
        let fallbackID = UUID()
        work.queueChunk(id: continuousID, duration: 30)
        work.failChunk(id: continuousID)
        _ = work.recoverFailedChunk(id: continuousID)
        work.queueChunk(id: fallbackID, duration: 12)
        work.failChunk(id: fallbackID)

        try expectEqual(work.failedChunkCount, 1)
    },

    CheckCase(name: "Chunk completion may arrive before UI registration") {
        var work = RecognitionPendingWork()
        let id = UUID()
        work.completeChunk(id: id)
        work.queueChunk(id: id, duration: 3)
        try expectEqual(work.hasWork, false)
    },

    CheckCase(name: "Chunk failure may arrive before UI registration") {
        var work = RecognitionPendingWork()
        let id = UUID()
        work.failChunk(id: id)
        work.queueChunk(id: id, duration: 3)
        try expectEqual(work.chunkCount, 0)
        try expectEqual(work.failedChunkCount, 1)
    },
    CheckCase(name: "Pending shimmer uses a one-second cadence") {
        var work = RecognitionPendingWork()
        work.updateCurrentAudioDuration(0.9)
        try expectEqual(work.placeholderCount(), 0)
        work.updateCurrentAudioDuration(1)
        try expectEqual(work.placeholderCount(), 1)
    },
    CheckCase(name: "Pending placeholders grow at one word per second") {
        var work = RecognitionPendingWork()
        work.updateCurrentAudioDuration(10)
        try expectEqual(work.placeholderCount(), 10)
    },

    CheckCase(name: "Engine completion clears stale pending chunk bookkeeping") {
        var work = RecognitionPendingWork()
        work.updateCurrentAudioDuration(4)
        work.queueChunk(id: UUID(), duration: 4)
        work.finishEngine()
        try expectEqual(work.hasWork, false)
        try expectEqual(work.chunkCount, 0)
    },
]
