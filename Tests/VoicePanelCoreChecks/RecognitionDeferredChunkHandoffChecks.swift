import VoicePanelCore

let recognitionDeferredChunkHandoffChecks: [CheckCase] = [
    CheckCase(name: "Deferred chunk handoff preserves release-tail ordering") {
        let handoff = RecognitionDeferredChunkHandoff()
        let first = AudioChunk(samples: [0.1], sampleRate: 1, boundaryReason: .maximumDuration)
        let releaseTail = AudioChunk(samples: [0.2], sampleRate: 1, boundaryReason: .stopped)
        let live = AudioChunk(samples: [0.3], sampleRate: 1, boundaryReason: .silence)
        var events: [String] = []

        handoff.append(first)
        handoff.append(releaseTail)
        try expectEqual(handoff.pendingCount, 2)

        handoff.attach { chunk in
            if chunk.id == first.id {
                events.append("first")
            } else if chunk.id == releaseTail.id {
                events.append("tail")
            } else if chunk.id == live.id {
                events.append("live")
            }
        }

        handoff.append(live)
        events.append("finish")

        try expectEqual(events, ["first", "tail", "live", "finish"])
        try expectEqual(handoff.pendingCount, 0)
    }
]
