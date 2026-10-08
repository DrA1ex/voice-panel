import Foundation
import VoicePanelCore

let recognitionAudioChunkPipelineChecks: [CheckCase] = [
    CheckCase(name: "Hybrid chunking can align a forced cut to an Energy pause") {
        var pipeline = RecognitionAudioChunkPipeline(
            vadConfiguration: .init(
                adaptiveThreshold: false,
                manualThresholdDB: -40,
                minimumSpeechDuration: 0.1,
                endOfSpeechSilenceDuration: 0.5
            ),
            segmenterConfiguration: .init(
                preRollDuration: 0,
                postRollDuration: 0.1,
                overlapDuration: 0.1,
                maximumChunkDuration: 1,
                minimumChunkDuration: 0.1,
                forcedBoundaryLookbackDuration: 0.5,
                minimumForcedBoundaryPauseDuration: 0.2
            ),
            detectionMode: .hybrid
        )

        var chunks: [AudioChunk] = []
        for _ in 0..<6 {
            chunks +=
                pipeline.process(
                    samples: [0.5],
                    sampleRate: 10,
                    rmsDB: -20,
                    neuralSpeechDetected: true
                )?.chunks ?? []
        }
        for _ in 0..<2 {
            chunks +=
                pipeline.process(
                    samples: [0.01],
                    sampleRate: 10,
                    rmsDB: -60,
                    neuralSpeechDetected: true
                )?.chunks ?? []
        }
        for _ in 0..<2 {
            chunks +=
                pipeline.process(
                    samples: [0.5],
                    sampleRate: 10,
                    rmsDB: -20,
                    neuralSpeechDetected: true
                )?.chunks ?? []
        }

        try expectEqual(chunks.count, 1)
        try expectApproximatelyEqual(chunks[0].duration, 0.7, accuracy: 0.001)
        try expectEqual(chunks[0].boundaryReason, .balancedPause)
        let stopped = pipeline.stop()
        try expectEqual(stopped.finalChunks.count, 1)
        try expectEqual(stopped.finalChunks[0].samples, [0.01, 0.5, 0.5])
    },
    CheckCase(name: "Silero chunking can align a forced cut to an Energy pause") {
        var pipeline = RecognitionAudioChunkPipeline(
            vadConfiguration: .init(
                adaptiveThreshold: false,
                manualThresholdDB: -40,
                minimumSpeechDuration: 0.1,
                endOfSpeechSilenceDuration: 0.5
            ),
            segmenterConfiguration: .init(
                preRollDuration: 0,
                postRollDuration: 0.1,
                overlapDuration: 0.2,
                maximumChunkDuration: 1,
                minimumChunkDuration: 0.1,
                forcedBoundaryLookbackDuration: 0.5,
                minimumForcedBoundaryPauseDuration: 0.2
            ),
            detectionMode: .silero
        )

        var chunks: [AudioChunk] = []
        for _ in 0..<6 {
            chunks +=
                pipeline.process(
                    samples: [0.5],
                    sampleRate: 10,
                    rmsDB: -20,
                    neuralSpeechDetected: true
                )?.chunks ?? []
        }
        for _ in 0..<2 {
            chunks +=
                pipeline.process(
                    samples: [0.01],
                    sampleRate: 10,
                    rmsDB: -60,
                    neuralSpeechDetected: true
                )?.chunks ?? []
        }
        for _ in 0..<2 {
            chunks +=
                pipeline.process(
                    samples: [0.5],
                    sampleRate: 10,
                    rmsDB: -20,
                    neuralSpeechDetected: true
                )?.chunks ?? []
        }

        try expectEqual(chunks.count, 1)
        try expectApproximatelyEqual(chunks[0].duration, 0.7, accuracy: 0.001)
        let stopped = pipeline.stop()
        try expectEqual(stopped.finalChunks.count, 1)
        try expectEqual(stopped.finalChunks[0].samples, [0.01, 0.5, 0.5])
    },
    CheckCase(name: "Hybrid forced cuts accept an independent Silero pause") {
        var pipeline = RecognitionAudioChunkPipeline(
            vadConfiguration: .init(
                adaptiveThreshold: false,
                manualThresholdDB: -50,
                minimumSpeechDuration: 0.1,
                endOfSpeechSilenceDuration: 0.5
            ),
            segmenterConfiguration: .init(
                preRollDuration: 0,
                postRollDuration: 0,
                overlapDuration: 0.2,
                maximumChunkDuration: 2,
                minimumChunkDuration: 0.1,
                forcedBoundaryLookbackDuration: 1.4,
                minimumForcedBoundaryPauseDuration: 0.4
            ),
            detectionMode: .hybrid
        )

        var chunks: [AudioChunk] = []
        for _ in 0..<10 {
            chunks +=
                pipeline.process(
                    samples: [1], sampleRate: 10, rmsDB: -20,
                    neuralSpeechDetected: true
                )?.chunks ?? []
        }
        for _ in 0..<5 {
            chunks +=
                pipeline.process(
                    samples: [0], sampleRate: 10, rmsDB: -20,
                    neuralSpeechDetected: false
                )?.chunks ?? []
        }
        for _ in 0..<5 {
            chunks +=
                pipeline.process(
                    samples: [1], sampleRate: 10, rmsDB: -20,
                    neuralSpeechDetected: true
                )?.chunks ?? []
        }

        try expectEqual(chunks.count, 1)
        try expectEqual(chunks[0].boundaryReason, .balancedPause)
        try expectEqual(chunks[0].trailingOverlapDuration, 0)
        try expectApproximatelyEqual(chunks[0].duration, 1.2, accuracy: 0.001)
    },
    CheckCase(name: "Hybrid forced cuts accept a relative Energy valley") {
        var pipeline = RecognitionAudioChunkPipeline(
            vadConfiguration: .init(
                adaptiveThreshold: false,
                manualThresholdDB: -50,
                minimumSpeechDuration: 0.1,
                endOfSpeechSilenceDuration: 0.5
            ),
            segmenterConfiguration: .init(
                preRollDuration: 0,
                postRollDuration: 0,
                overlapDuration: 0.2,
                maximumChunkDuration: 2,
                minimumChunkDuration: 0.1,
                forcedBoundaryLookbackDuration: 1.4,
                minimumForcedBoundaryPauseDuration: 0.4
            ),
            detectionMode: .hybrid
        )

        var chunks: [AudioChunk] = []
        for _ in 0..<10 {
            chunks +=
                pipeline.process(
                    samples: [1], sampleRate: 10, rmsDB: -15,
                    neuralSpeechDetected: true
                )?.chunks ?? []
        }
        for _ in 0..<5 {
            chunks +=
                pipeline.process(
                    samples: [0], sampleRate: 10, rmsDB: -35,
                    neuralSpeechDetected: true
                )?.chunks ?? []
        }
        for _ in 0..<5 {
            chunks +=
                pipeline.process(
                    samples: [1], sampleRate: 10, rmsDB: -15,
                    neuralSpeechDetected: true
                )?.chunks ?? []
        }

        try expectEqual(chunks.count, 1)
        try expectEqual(chunks[0].boundaryReason, .balancedPause)
        try expectEqual(chunks[0].trailingOverlapDuration, 0)
        try expectApproximatelyEqual(chunks[0].duration, 1.2, accuracy: 0.001)
    },
    CheckCase(name: "Hybrid compacts a long independent Silero silence") {
        var pipeline = RecognitionAudioChunkPipeline(
            vadConfiguration: .init(
                adaptiveThreshold: false,
                manualThresholdDB: -50,
                minimumSpeechDuration: 0.1,
                endOfSpeechSilenceDuration: 0.5
            ),
            segmenterConfiguration: .init(
                preRollDuration: 0.3,
                postRollDuration: 0.2,
                overlapDuration: 0.2,
                maximumChunkDuration: 10,
                minimumChunkDuration: 0.1,
                forcedBoundaryLookbackDuration: 7,
                minimumForcedBoundaryPauseDuration: 0.4
            ),
            detectionMode: .hybrid
        )

        var chunks: [AudioChunk] = []
        for _ in 0..<10 {
            chunks +=
                pipeline.process(
                    samples: [1], sampleRate: 10, rmsDB: -15,
                    neuralSpeechDetected: true
                )?.chunks ?? []
        }
        for _ in 0..<16 {
            chunks +=
                pipeline.process(
                    samples: [0], sampleRate: 10, rmsDB: -40,
                    neuralSpeechDetected: false
                )?.chunks ?? []
        }
        for _ in 0..<110 {
            chunks +=
                pipeline.process(
                    samples: [0], sampleRate: 10, rmsDB: -40,
                    neuralSpeechDetected: false
                )?.chunks ?? []
        }
        for _ in 0..<10 {
            chunks +=
                pipeline.process(
                    samples: [1], sampleRate: 10, rmsDB: -15,
                    neuralSpeechDetected: true
                )?.chunks ?? []
        }

        try expectEqual(chunks.count, 1)
        try expectEqual(chunks[0].boundaryReason, .longSilence)
        try expectApproximatelyEqual(chunks[0].duration, 1.2, accuracy: 0.001)
        let stopped = pipeline.stop()
        try expectEqual(stopped.finalChunks.count, 1)
        try expectApproximatelyEqual(stopped.finalChunks[0].duration, 1.3, accuracy: 0.001)
        try expect(
            chunks[0].duration + stopped.finalChunks[0].duration < 2.6,
            "the recognizer must not receive the middle of a long silence"
        )
    },
    CheckCase(name: "Five-second recording flushes when Stop arrives before a VAD boundary") {
        var pipeline = RecognitionAudioChunkPipeline(
            vadConfiguration: .init(
                adaptiveThreshold: false,
                manualThresholdDB: -30,
                minimumSpeechDuration: 0.1,
                endOfSpeechSilenceDuration: 0.65
            ),
            segmenterConfiguration: .init(maximumChunkDuration: 18),
            minimumChunkDeliveryDuration: RecordingStopPolicy.defaultMinimumDuration
        )

        var chunksBeforeStop: [AudioChunk] = []
        for _ in 0..<50 {
            let result = pipeline.process(
                samples: Array(repeating: 0.2, count: 10),
                sampleRate: 100,
                rmsDB: -12
            )
            chunksBeforeStop += result?.chunks ?? []
        }

        try expect(chunksBeforeStop.isEmpty, "no silence or maximum-duration boundary should fire")
        let stopped = pipeline.stop(
            flushFinalChunk: true,
            forceChunkIfDurationAtLeast: RecordingStopPolicy.defaultMinimumDuration
        )
        try expectEqual(stopped.finalChunks.count, 1)
        try expectApproximatelyEqual(stopped.capturedDuration, 5, accuracy: 0.001)
        try expectApproximatelyEqual(stopped.finalChunks[0].duration, 5, accuracy: 0.001)
        try expectEqual(stopped.finalChunks[0].samples.count, 500)
    },

    CheckCase(name: "Deferred Quality stop delivers every balanced chunk") {
        var pipeline = RecognitionAudioChunkPipeline(
            vadConfiguration: .init(
                adaptiveThreshold: false,
                manualThresholdDB: -40,
                minimumSpeechDuration: 0.1,
                endOfSpeechSilenceDuration: 1
            ),
            segmenterConfiguration: .init(
                preRollDuration: 0,
                postRollDuration: 0,
                overlapDuration: 0,
                maximumChunkDuration: 3,
                minimumChunkDuration: 0.1,
                forcedBoundaryLookbackDuration: 3,
                minimumForcedBoundaryPauseDuration: 0.2,
                forcedBoundaryMode: .deferredPauseBalanced,
                deferredBoundaryDecisionDuration: 4.5
            ),
            detectionMode: .hybrid
        )

        _ = pipeline.process(
            samples: Array(repeating: 0.5, count: 14),
            sampleRate: 10,
            rmsDB: -20,
            neuralSpeechDetected: true
        )
        _ = pipeline.process(
            samples: Array(repeating: 0.01, count: 2),
            sampleRate: 10,
            rmsDB: -60,
            neuralSpeechDetected: true
        )
        _ = pipeline.process(
            samples: Array(repeating: 0.5, count: 15),
            sampleRate: 10,
            rmsDB: -20,
            neuralSpeechDetected: true
        )

        let stopped = pipeline.stop()
        try expectEqual(stopped.finalChunks.count, 2)
        try expect(
            stopped.finalChunks.allSatisfy { $0.duration <= 3 },
            "deferred stop must preserve the model limit"
        )
        try expectApproximatelyEqual(
            stopped.finalChunks.reduce(0) { $0 + $1.duration },
            3.1,
            accuracy: 0.001
        )
    },

    CheckCase(name: "Final chunk reaches a mock recognizer before finish") {
        let chunk = AudioChunk(
            samples: Array(repeating: 0.2, count: 500),
            sampleRate: 100,
            boundaryReason: .stopped
        )
        var events: [String] = []
        var mockRecognizerChunks: [AudioChunk] = []

        RecognitionStopHandoff.perform(
            finalChunks: [chunk],
            acceptsChunks: true,
            append: { delivered in
                events.append("append")
                mockRecognizerChunks.append(delivered)
            },
            prepareToFinish: {
                events.append("prepare")
            },
            finish: {
                events.append("finish")
            }
        )

        try expectEqual(events, ["append", "prepare", "finish"])
        try expectEqual(mockRecognizerChunks.count, 1)
        try expectEqual(mockRecognizerChunks[0].id, chunk.id)
    },

    CheckCase(name: "Ten-second Whisper chunk closes after one-second pause") {
        var pipeline = RecognitionAudioChunkPipeline(
            vadConfiguration: .init(
                adaptiveThreshold: false,
                manualThresholdDB: -40,
                hysteresisDB: 3,
                minimumSpeechDuration: 0.10,
                endOfSpeechSilenceDuration: 0.65,
                maximumHysteresisHoldDuration: 1.0
            ),
            segmenterConfiguration: .init(maximumChunkDuration: 10)
        )

        var chunks: [AudioChunk] = []
        for _ in 0..<5 {
            chunks +=
                pipeline.process(
                    samples: Array(repeating: 0.2, count: 10),
                    sampleRate: 100,
                    rmsDB: -20
                )?.chunks ?? []
        }
        for _ in 0..<10 {
            chunks +=
                pipeline.process(
                    samples: Array(repeating: 0.01, count: 10),
                    sampleRate: 100,
                    rmsDB: -42
                )?.chunks ?? []
        }

        try expectEqual(chunks.count, 1)
        try expectEqual(chunks[0].boundaryReason, .silence)
        try expect(chunks[0].duration < 10, "a stable pause must beat the configured maximum duration")
    },

    CheckCase(name: "Input change flushes the accepted tail without ending the session") {
        var pipeline = RecognitionAudioChunkPipeline(
            vadConfiguration: .init(
                adaptiveThreshold: false,
                manualThresholdDB: -40,
                minimumSpeechDuration: 0.10
            ),
            segmenterConfiguration: .init(maximumChunkDuration: 10),
            minimumChunkDeliveryDuration: 2
        )

        for _ in 0..<25 {
            _ = pipeline.process(
                samples: Array(repeating: 0.2, count: 10),
                sampleRate: 100,
                rmsDB: -20
            )
        }
        let handoffChunks = pipeline.inputChanged()
        try expectEqual(handoffChunks.count, 1)
        try expectEqual(handoffChunks[0].boundaryReason, .inputChanged)
        try expectApproximatelyEqual(pipeline.capturedDuration, 2.5, accuracy: 0.000_001)

        for _ in 0..<5 {
            _ = pipeline.process(
                samples: Array(repeating: 0.15, count: 20),
                sampleRate: 200,
                rmsDB: -22
            )
        }
        let stopped = pipeline.stop(forceChunkIfDurationAtLeast: 2)
        try expectApproximatelyEqual(stopped.capturedDuration, 3, accuracy: 0.000_001)
        try expectEqual(stopped.emittedChunkCount, 2)
        try expectEqual(stopped.finalChunks.last?.boundaryReason, .stopped)
    },

    CheckCase(name: "Input change keeps a sub-threshold deferred chunk") {
        var pipeline = RecognitionAudioChunkPipeline(
            vadConfiguration: .init(
                adaptiveThreshold: false,
                manualThresholdDB: -40,
                minimumSpeechDuration: 0.10
            ),
            segmenterConfiguration: .init(maximumChunkDuration: 10),
            minimumChunkDeliveryDuration: 2
        )

        for _ in 0..<10 {
            _ = pipeline.process(
                samples: Array(repeating: 0.2, count: 10),
                sampleRate: 100,
                rmsDB: -20
            )
        }
        try expect(pipeline.inputChanged().isEmpty, "the short first-device tail must stay deferred")

        var deliveredAfterReconnect: [AudioChunk] = []
        for _ in 0..<10 {
            deliveredAfterReconnect +=
                pipeline.process(
                    samples: Array(repeating: 0.2, count: 10),
                    sampleRate: 100,
                    rmsDB: -20
                )?.chunks ?? []
        }
        try expectEqual(deliveredAfterReconnect.count, 1)
        try expectEqual(deliveredAfterReconnect[0].boundaryReason, .inputChanged)
    },
]
