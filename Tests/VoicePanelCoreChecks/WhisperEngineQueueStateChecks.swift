import VoicePanelCore

let whisperEngineQueueStateChecks: [CheckCase] = [
    CheckCase(name: "Whisper engine pending queue drains FIFO before finalization") {
        var queue = WhisperEnginePendingQueue<Int>()
        try expect(queue.append(10), "active queue rejected first chunk")
        try expect(queue.append(20), "active queue rejected second chunk")
        queue.finish()

        try expect(!queue.append(30), "finishing queue admitted new audio")
        try expectEqual(queue.removeFirst(), 10)
        try expect(!queue.shouldFinalize, "queue finalized before all work drained")
        try expectEqual(queue.removeFirst(), 20)
        try expect(queue.shouldFinalize, "empty finishing queue did not finalize")
    },
    CheckCase(name: "Whisper engine queue reset discards stale finalization state") {
        var queue = WhisperEnginePendingQueue<Int>()
        _ = queue.append(1)
        queue.finish()

        queue.reset()

        try expectEqual(queue.count, 0)
        try expect(!queue.shouldFinalize, "cancelled queue retained finalization")
        try expect(queue.append(2), "restarted queue remained closed")
        try expectEqual(queue.removeFirst(), 2)
    },
]
