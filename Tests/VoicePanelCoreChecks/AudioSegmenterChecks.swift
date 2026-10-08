import VoicePanelCore

let audioSegmenterChecks: [CheckCase] = [
    CheckCase(name: "Known speech range trims silence with explicit margins") {
        let chunk = AudioChunk(
            samples: Array(repeating: 0, count: 100),
            sampleRate: 100,
            boundaryReason: .silence,
            speechRange: 40..<60,
            speechEvidenceAnalyzed: true
        )
        let trimmed = chunk.trimmingSilence(
            preRollDuration: 0.10,
            postRollDuration: 0.15
        )
        try expectEqual(trimmed?.samples.count, 45)
        try expectEqual(trimmed?.speechRange, 10..<30)

        let silent = AudioChunk(
            samples: Array(repeating: 0, count: 100),
            sampleRate: 100,
            boundaryReason: .stopped,
            speechEvidenceAnalyzed: true
        )
        try expectEqual(silent.trimmingSilence(preRollDuration: 0.2, postRollDuration: 0.1), nil)
    },

    CheckCase(name: "AudioSegmenter uses pre-roll and emits at silence boundary") {
        var segmenter = AudioSegmenter(
            configuration: .init(
                preRollDuration: 0.2,
                postRollDuration: 0.1,
                overlapDuration: 0.1,
                maximumChunkDuration: 10,
                minimumChunkDuration: 0.1
            ))
        let rate = 100.0

        try expect(
            segmenter.process(
                samples: Array(repeating: 0.01, count: 20),
                sampleRate: rate,
                event: .silence
            ).isEmpty, "silence before speech must not emit a chunk")

        try expect(
            segmenter.process(
                samples: Array(repeating: 0.5, count: 10),
                sampleRate: rate,
                event: .speechStarted
            ).isEmpty, "speech start must not prematurely emit a chunk")

        let chunks = segmenter.process(
            samples: Array(repeating: 0.01, count: 65),
            sampleRate: rate,
            event: .speechEnded(silenceDuration: 0.65)
        )

        try expectEqual(chunks.count, 1)
        try expectEqual(chunks[0].boundaryReason, .silence)
        try expect(chunks[0].speechEvidenceAnalyzed, "VAD chunks must carry analyzed speech evidence")
        try expect(chunks[0].speechRange != nil, "VAD chunks must locate the spoken range")
        try expect(chunks[0].samples.count >= 30, "chunk must include pre-roll and speech")
        try expect(chunks[0].samples.count < 95, "chunk must trim excess trailing silence")
    },

    CheckCase(name: "AudioSegmenter bounds long chunks and keeps overlap") {
        var segmenter = AudioSegmenter(
            configuration: .init(
                preRollDuration: 0,
                postRollDuration: 0,
                overlapDuration: 0.2,
                maximumChunkDuration: 1,
                minimumChunkDuration: 0.1
            ))
        let rate = 10.0

        let chunks = segmenter.process(
            samples: Array(repeating: 0.5, count: 25),
            sampleRate: rate,
            event: .speechStarted
        )

        try expectEqual(chunks.count, 2)
        try expect(chunks.allSatisfy { $0.samples.count == 10 }, "forced chunks must have maximum duration")
        try expect(
            chunks.allSatisfy { $0.boundaryReason == .maximumDuration },
            "forced chunks need the correct boundary reason")
    },
    CheckCase(name: "AudioSegmenter moves a forced boundary to the nearest recent pause") {
        var segmenter = AudioSegmenter(
            configuration: .init(
                preRollDuration: 0,
                postRollDuration: 0.1,
                overlapDuration: 0.2,
                maximumChunkDuration: 1,
                minimumChunkDuration: 0.1,
                forcedBoundaryLookbackDuration: 0.7,
                minimumForcedBoundaryPauseDuration: 0.2
            ))
        let rate = 10.0

        _ = segmenter.process(samples: [0, 1, 2], sampleRate: rate, event: .speechStarted)
        _ = segmenter.process(
            samples: [3, 4],
            sampleRate: rate,
            event: .possiblePause(duration: 0.2)
        )
        _ = segmenter.process(samples: [5], sampleRate: rate, event: .speechContinued)
        _ = segmenter.process(
            samples: [6, 7],
            sampleRate: rate,
            event: .possiblePause(duration: 0.2)
        )
        let chunks = segmenter.process(
            samples: [8, 9],
            sampleRate: rate,
            event: .speechContinued
        )

        try expectEqual(chunks.count, 1)
        try expectEqual(chunks[0].samples, [0, 1, 2, 3, 4, 5, 6])
        try expectEqual(chunks[0].boundaryReason, .balancedPause)
        try expectEqual(chunks[0].trailingOverlapDuration, 0)

        _ = segmenter.process(samples: [10, 11], sampleRate: rate, event: .speechContinued)
        guard let tail = segmenter.finish() else {
            throw CheckFailure(description: "expected the retained audio after the adaptive cut")
        }
        try expectEqual(tail.samples, [7, 8, 9, 10, 11])
        try expectEqual(
            chunks[0].samples + tail.samples,
            (0...11).map(Float.init)
        )
        try expect(
            !tail.samples.contains(6),
            "pause-aligned overlap must not reach backward into pre-pause speech"
        )
    },
    CheckCase(name: "AudioSegmenter keeps the exact forced boundary without an eligible pause") {
        var segmenter = AudioSegmenter(
            configuration: .init(
                preRollDuration: 0,
                postRollDuration: 0.1,
                overlapDuration: 0.2,
                maximumChunkDuration: 1,
                minimumChunkDuration: 0.1,
                forcedBoundaryLookbackDuration: 0.4,
                minimumForcedBoundaryPauseDuration: 0.3
            ))
        let rate = 10.0

        _ = segmenter.process(
            samples: [0, 1, 2, 3, 4, 5],
            sampleRate: rate,
            event: .speechStarted
        )
        _ = segmenter.process(
            samples: [6, 7],
            sampleRate: rate,
            event: .possiblePause(duration: 0.2)
        )
        let chunks = segmenter.process(
            samples: [8, 9],
            sampleRate: rate,
            event: .speechContinued
        )

        try expectEqual(chunks.count, 1)
        try expectEqual(chunks[0].samples, (0...9).map(Float.init))
    },
    CheckCase(name: "Immediate chunking searches up to seventy percent backward") {
        var segmenter = AudioSegmenter(
            configuration: AudioSegmenter.Configuration(
                preRollDuration: 0,
                postRollDuration: 0,
                overlapDuration: 0.5,
                maximumChunkDuration: 10,
                minimumChunkDuration: 0.1,
                minimumForcedBoundaryPauseDuration: 0.4
            ).applyingPauseBalancedChunking(false)
        )
        let rate = 10.0

        _ = segmenter.process(
            samples: Array(repeating: 1, count: 35),
            sampleRate: rate,
            event: .speechStarted
        )
        _ = segmenter.process(
            samples: Array(repeating: 0, count: 10),
            sampleRate: rate,
            event: .possiblePause(duration: 1)
        )
        let chunks = segmenter.process(
            samples: Array(repeating: 1, count: 55),
            sampleRate: rate,
            event: .speechContinued
        )

        try expectEqual(segmenter.configuration.forcedBoundaryLookbackDuration, 7)
        try expectEqual(chunks.count, 1)
        try expectApproximatelyEqual(chunks[0].duration, 4, accuracy: 0.001)
        try expectEqual(chunks[0].boundaryReason, .balancedPause)
        try expectEqual(chunks[0].trailingOverlapDuration, 0)
    },
    CheckCase(name: "Deferred segmenter balances a long window around a real pause") {
        var segmenter = AudioSegmenter(
            configuration: .init(
                preRollDuration: 0,
                postRollDuration: 0,
                overlapDuration: 0,
                maximumChunkDuration: 2,
                minimumChunkDuration: 0.1,
                forcedBoundaryLookbackDuration: 2,
                minimumForcedBoundaryPauseDuration: 0.2,
                forcedBoundaryMode: .deferredPauseBalanced,
                deferredBoundaryDecisionDuration: 3
            )
        )
        let rate = 10.0

        _ = segmenter.process(
            samples: (0...13).map(Float.init),
            sampleRate: rate,
            event: .speechStarted
        )
        _ = segmenter.process(
            samples: [14, 15],
            sampleRate: rate,
            event: .possiblePause(duration: 0.2)
        )
        _ = segmenter.process(
            samples: (16...23).map(Float.init),
            sampleRate: rate,
            event: .speechContinued
        )
        _ = segmenter.process(
            samples: [24, 25],
            sampleRate: rate,
            event: .possiblePause(duration: 0.2)
        )
        let chunks = segmenter.process(
            samples: (26...29).map(Float.init),
            sampleRate: rate,
            event: .speechContinued
        )

        try expectEqual(chunks.count, 1)
        try expectEqual(chunks[0].samples, (0...14).map(Float.init))
        try expectEqual(chunks[0].boundaryReason, .balancedPause)
        try expectEqual(chunks[0].trailingOverlapDuration, 0)
        guard let tail = segmenter.finish() else {
            throw CheckFailure(description: "expected a balanced tail")
        }
        try expectEqual(tail.samples, (15...29).map(Float.init))
        try expectEqual(chunks[0].samples + tail.samples, (0...29).map(Float.init))
        try expect(chunks[0].duration <= 2, "balanced chunk exceeded the model limit")
        try expect(tail.duration <= 2, "balanced tail exceeded the model limit")
    },
    CheckCase(name: "Deferred segmenter falls back to the hard model limit without a pause") {
        var segmenter = AudioSegmenter(
            configuration: .init(
                preRollDuration: 0,
                postRollDuration: 0,
                overlapDuration: 0,
                maximumChunkDuration: 2,
                minimumChunkDuration: 0.1,
                forcedBoundaryLookbackDuration: 2,
                minimumForcedBoundaryPauseDuration: 0.2,
                forcedBoundaryMode: .deferredPauseBalanced,
                deferredBoundaryDecisionDuration: 3
            )
        )
        let chunks = segmenter.process(
            samples: (0...29).map(Float.init),
            sampleRate: 10,
            event: .speechStarted
        )

        try expectEqual(chunks.count, 1)
        try expectEqual(chunks[0].samples, (0...19).map(Float.init))
        try expectEqual(segmenter.finish()?.samples, (20...29).map(Float.init))
    },
    CheckCase(name: "Deferred stop repartitions a thirty-one second tail around a pause") {
        var segmenter = AudioSegmenter(
            configuration: .init(
                preRollDuration: 0,
                postRollDuration: 0,
                overlapDuration: 0,
                maximumChunkDuration: 3,
                minimumChunkDuration: 0.1,
                forcedBoundaryLookbackDuration: 3,
                minimumForcedBoundaryPauseDuration: 0.2,
                forcedBoundaryMode: .deferredPauseBalanced,
                deferredBoundaryDecisionDuration: 4.5
            )
        )
        _ = segmenter.process(
            samples: (0...13).map(Float.init),
            sampleRate: 10,
            event: .speechStarted
        )
        _ = segmenter.process(
            samples: [14, 15],
            sampleRate: 10,
            event: .possiblePause(duration: 0.2)
        )
        _ = segmenter.process(
            samples: (16...30).map(Float.init),
            sampleRate: 10,
            event: .speechContinued
        )

        let chunks = segmenter.finishChunks()
        try expectEqual(chunks.count, 2)
        try expectEqual(chunks[0].samples, (0...14).map(Float.init))
        try expectEqual(chunks[0].boundaryReason, .balancedPause)
        try expectEqual(chunks[0].trailingOverlapDuration, 0)
        try expectEqual(chunks[1].samples, (15...30).map(Float.init))
        try expectEqual(chunks.flatMap(\.samples), (0...30).map(Float.init))
        try expect(chunks.allSatisfy { $0.duration <= 3 }, "stop emitted an oversized chunk")
    },
    CheckCase(name: "Pause balancing breaks equal-distance ties at the later pause") {
        var segmenter = AudioSegmenter(
            configuration: .init(
                preRollDuration: 0,
                postRollDuration: 0,
                overlapDuration: 0.2,
                maximumChunkDuration: 2,
                minimumChunkDuration: 0.1,
                forcedBoundaryLookbackDuration: 2,
                minimumForcedBoundaryPauseDuration: 0.2,
                forcedBoundaryMode: .deferredPauseBalanced,
                deferredBoundaryDecisionDuration: 3
            )
        )
        _ = segmenter.process(
            samples: (0...8).map(Float.init),
            sampleRate: 10,
            event: .speechStarted
        )
        _ = segmenter.process(samples: [9, 10], sampleRate: 10, event: .possiblePause(duration: 0.2))
        _ = segmenter.process(
            samples: (11...18).map(Float.init),
            sampleRate: 10,
            event: .speechContinued
        )
        _ = segmenter.process(samples: [19, 20], sampleRate: 10, event: .possiblePause(duration: 0.2))
        let chunks = segmenter.process(
            samples: (21...29).map(Float.init),
            sampleRate: 10,
            event: .speechContinued
        )

        try expectEqual(chunks.count, 1)
        try expectEqual(chunks[0].samples, (0...19).map(Float.init))
        try expectEqual(chunks[0].boundaryReason, .balancedPause)
        try expectEqual(chunks[0].trailingOverlapDuration, 0)
    },
    CheckCase(name: "Pause balancing ignores pauses shorter than four hundred milliseconds") {
        var segmenter = AudioSegmenter(
            configuration: .init(
                preRollDuration: 0,
                postRollDuration: 0,
                overlapDuration: 0.2,
                maximumChunkDuration: 2,
                minimumChunkDuration: 0.1,
                forcedBoundaryLookbackDuration: 2,
                forcedBoundaryMode: .deferredPauseBalanced,
                deferredBoundaryDecisionDuration: 3
            )
        )
        _ = segmenter.process(
            samples: (0...13).map(Float.init),
            sampleRate: 10,
            event: .speechStarted
        )
        _ = segmenter.process(
            samples: [14, 15, 16],
            sampleRate: 10,
            event: .possiblePause(duration: 0.3)
        )
        let chunks = segmenter.process(
            samples: (17...29).map(Float.init),
            sampleRate: 10,
            event: .speechContinued
        )

        try expectEqual(chunks.count, 1)
        try expectEqual(chunks[0].boundaryReason, .maximumDuration)
        try expectEqual(chunks[0].samples, (0...19).map(Float.init))
        try expectApproximatelyEqual(chunks[0].trailingOverlapDuration, 0.2, accuracy: 0.0001)
        try expectEqual(segmenter.finish()?.samples, (18...29).map(Float.init))
    },
    CheckCase(name: "An undersized pause continuation uses an exact hard cut and is flushed") {
        var segmenter = AudioSegmenter(
            configuration: .init(
                preRollDuration: 0,
                postRollDuration: 0,
                overlapDuration: 0.2,
                maximumChunkDuration: 2,
                minimumChunkDuration: 0.5,
                forcedBoundaryLookbackDuration: 2,
                minimumForcedBoundaryPauseDuration: 0.2,
                forcedBoundaryMode: .deferredPauseBalanced,
                deferredBoundaryDecisionDuration: 3
            )
        )
        _ = segmenter.process(
            samples: (0...17).map(Float.init),
            sampleRate: 10,
            event: .speechStarted
        )
        _ = segmenter.process(
            samples: [18, 19],
            sampleRate: 10,
            event: .possiblePause(duration: 0.2)
        )
        _ = segmenter.process(samples: [20], sampleRate: 10, event: .speechContinued)

        let chunks = segmenter.finishChunks()
        try expectEqual(chunks.count, 2)
        try expectEqual(chunks[0].boundaryReason, .maximumDuration)
        try expectEqual(chunks[0].samples, (0...19).map(Float.init))
        try expectApproximatelyEqual(chunks[0].trailingOverlapDuration, 0.2, accuracy: 0.0001)
        try expectEqual(chunks[1].samples, [18, 19, 20])
        try expectEqual(
            chunks[0].samples + Array(chunks[1].samples.dropFirst(2)),
            (0...20).map(Float.init)
        )
    },
    CheckCase(name: "Natural speech end flushes a short hard-cut continuation") {
        var segmenter = AudioSegmenter(
            configuration: .init(
                preRollDuration: 0,
                postRollDuration: 0,
                overlapDuration: 0.2,
                maximumChunkDuration: 2,
                minimumChunkDuration: 0.5,
                forcedBoundaryLookbackDuration: 2,
                forcedBoundaryMode: .deferredPauseBalanced,
                deferredBoundaryDecisionDuration: 3
            )
        )
        segmenter.seedSpeech(samples: (0...20).map(Float.init), sampleRate: 10)
        let chunks = segmenter.process(
            samples: [21],
            sampleRate: 10,
            event: .speechEnded(silenceDuration: 0.1)
        )

        try expectEqual(chunks.count, 2)
        try expectEqual(chunks[0].boundaryReason, .maximumDuration)
        try expectEqual(chunks[1].boundaryReason, .silence)
        try expectEqual(chunks[1].samples, [18, 19, 20])
    },
    CheckCase(name: "Pause balancing configuration preserves backend limits") {
        let base = AudioSegmenter.Configuration(
            preRollDuration: 0.4,
            postRollDuration: 0.3,
            overlapDuration: 0.5,
            maximumChunkDuration: 20,
            minimumChunkDuration: 0.25,
            forcedBoundaryLookbackDuration: 2
        )
        let balanced = base.applyingPauseBalancedChunking(true)
        try expectEqual(balanced.preRollDuration, base.preRollDuration)
        try expectEqual(balanced.postRollDuration, base.postRollDuration)
        try expectEqual(balanced.overlapDuration, base.overlapDuration)
        try expectEqual(balanced.maximumChunkDuration, base.maximumChunkDuration)
        try expectEqual(balanced.minimumChunkDuration, base.minimumChunkDuration)
        try expectEqual(balanced.forcedBoundaryMode, .deferredPauseBalanced)
        try expectEqual(balanced.deferredBoundaryDecisionDuration, 30)

        let immediate = balanced.applyingPauseBalancedChunking(false)
        try expectEqual(immediate.forcedBoundaryMode, .immediate)
        try expectEqual(immediate.deferredBoundaryDecisionDuration, 0)
        try expectEqual(immediate.forcedBoundaryLookbackDuration, 14)
        try expectEqual(immediate.maximumChunkDuration, 20)
    },
    CheckCase(name: "Quality chunks accumulate across short pauses and keep draining during a long recording") {
        var segmenter = AudioSegmenter(
            configuration: AudioSegmenter.Configuration(
                preRollDuration: 0, overlapDuration: 0, maximumChunkDuration: 30
            ).applyingPauseBalancedChunking(true))
        var emitted: [AudioChunk] = []
        var source: [Float] = []
        for frame in 0..<1_800 {
            let samples = (frame * 10..<(frame + 1) * 10).map(Float.init)
            source.append(contentsOf: samples)
            let pauseFrame = frame % 60
            let event: VoiceActivityEvent =
                pauseFrame >= 56
                ? .possiblePause(duration: Double(pauseFrame - 55) * 0.1)
                : .speechContinued
            emitted.append(contentsOf: segmenter.process(samples: samples, sampleRate: 100, event: event))
            if frame == 59 {
                try expect(emitted.isEmpty, "short pauses must not force small final chunks")
            }
            try expect(segmenter.pendingDuration < 45, "deferred chunks stopped draining")
        }
        try expect(emitted.count >= 4, "long recording did not deliver chunks before stop")
        try expect(
            emitted.allSatisfy { $0.duration > 10 && $0.duration <= 30 }, "Quality chunks lost their context window")
        emitted.append(contentsOf: segmenter.finishChunks())
        try expectEqual(emitted.flatMap(\.samples), source)
    },
    CheckCase(name: "Uninterrupted Quality speech drains the decision window and final tail") {
        var segmenter = AudioSegmenter(
            configuration: AudioSegmenter.Configuration(
                preRollDuration: 0, overlapDuration: 0, maximumChunkDuration: 30
            ).applyingPauseBalancedChunking(true))
        var chunks: [AudioChunk] = []
        for frame in 0..<451 {
            chunks.append(
                contentsOf: segmenter.process(
                    samples: Array(repeating: 0.1, count: 10), sampleRate: 100, event: .speechContinued
                ))
            if frame == 307 { try expect(chunks.isEmpty, "Quality lookahead was shortened for UI latency") }
        }
        try expectEqual(chunks.count, 1)
        try expectEqual(chunks[0].duration, 30)
        try expectEqual(chunks[0].boundaryReason, .maximumDuration)
        chunks.append(contentsOf: segmenter.finishChunks())
        try expectEqual(chunks.flatMap(\.samples).count, 4_510)
    },
    CheckCase(name: "Legacy finish keeps an oversized deferred tail intact") {
        var segmenter = AudioSegmenter(
            configuration: .init(
                preRollDuration: 0,
                postRollDuration: 0,
                overlapDuration: 0,
                maximumChunkDuration: 3,
                minimumChunkDuration: 0.1,
                forcedBoundaryLookbackDuration: 3,
                minimumForcedBoundaryPauseDuration: 0.2,
                forcedBoundaryMode: .deferredPauseBalanced,
                deferredBoundaryDecisionDuration: 4.5
            )
        )
        _ = segmenter.process(
            samples: (0...30).map(Float.init),
            sampleRate: 10,
            event: .speechStarted
        )

        try expectEqual(segmenter.finish()?.samples, (0...30).map(Float.init))
    },
    CheckCase(name: "AudioSegmenter keeps only the newest pre-roll samples") {
        var segmenter = AudioSegmenter(
            configuration: .init(
                preRollDuration: 0.3,
                postRollDuration: 0,
                overlapDuration: 0,
                maximumChunkDuration: 10,
                minimumChunkDuration: 0.1
            ))
        let rate = 10.0

        _ = segmenter.process(samples: [1, 2], sampleRate: rate, event: .silence)
        _ = segmenter.process(samples: [3, 4], sampleRate: rate, event: .silence)
        _ = segmenter.process(samples: [5], sampleRate: rate, event: .speechStarted)

        let chunk = segmenter.finish()
        try expectEqual(chunk?.samples, [2, 3, 4, 5])
        try expectEqual(chunk?.speechRange, 3..<4)
    },

]
