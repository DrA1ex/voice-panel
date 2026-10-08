import Foundation
import VoicePanelCore

let forcedChunkAccumulatorChecks: [CheckCase] = [
    CheckCase(name: "Forced chunk accumulator emits continuous speech without a VAD boundary") {
        var accumulator = ForcedChunkAccumulator(
            configuration: .init(
                maximumChunkDuration: 2,
                overlapDuration: 0.25,
                minimumSpeechEvidenceDuration: 0.25
            ))
        var chunks: [AudioChunk] = []
        for _ in 0..<5 {
            chunks += accumulator.process(
                samples: Array(repeating: 0.2, count: 10),
                sampleRate: 10,
                hasSpeechEvidence: true
            )
        }
        try expect(!chunks.isEmpty, "continuous speech should emit a forced chunk")
        try expectApproximatelyEqual(chunks[0].duration, 2, accuracy: 0.001)
        try expect(accumulator.pendingDuration >= 0.25, "the next chunk should retain overlap")
    },
    CheckCase(name: "Forced chunk accumulator does not emit background silence") {
        var accumulator = ForcedChunkAccumulator(
            configuration: .init(
                maximumChunkDuration: 1,
                overlapDuration: 0.2,
                minimumSpeechEvidenceDuration: 0.3
            ))
        let chunks = accumulator.process(
            samples: Array(repeating: 0.001, count: 30),
            sampleRate: 10,
            hasSpeechEvidence: false
        )
        try expect(chunks.isEmpty, "pure background should not become a recognition chunk")
        try expect(accumulator.finish() == nil, "silent tail should not flush")
    },
    CheckCase(name: "Forced chunk accumulator flushes a short active tail at stop") {
        var accumulator = ForcedChunkAccumulator(
            configuration: .init(
                maximumChunkDuration: 5,
                overlapDuration: 0.5,
                minimumChunkDuration: 0.2,
                minimumSpeechEvidenceDuration: 0.2
            ))
        _ = accumulator.process(
            samples: Array(repeating: 0.2, count: 12),
            sampleRate: 10,
            hasSpeechEvidence: true
        )
        let tail = accumulator.finish()
        try expect(tail != nil, "active tail should flush")
        try expectApproximatelyEqual(tail?.duration ?? 0, 1.2, accuracy: 0.001)
    },
    CheckCase(name: "Explicit stop can flush accepted audio before VAD activates") {
        var accumulator = ForcedChunkAccumulator(
            configuration: .init(
                maximumChunkDuration: 5,
                overlapDuration: 0.5,
                minimumChunkDuration: 0.2,
                minimumSpeechEvidenceDuration: 0.35
            ))
        _ = accumulator.process(
            samples: Array(repeating: 0.02, count: 30),
            sampleRate: 10,
            hasSpeechEvidence: false
        )
        let tail = accumulator.finish(requireSpeechEvidence: false)
        try expect(tail != nil, "an accepted recording must not disappear when Stop beats VAD")
        try expectApproximatelyEqual(tail?.duration ?? 0, 3, accuracy: 0.001)
        try expectEqual(tail?.speechEvidenceAnalyzed, true)
        try expectEqual(tail?.speechRange, nil)
        try expectEqual(
            tail?.trimmingSilence(preRollDuration: 0.2, postRollDuration: 0.12),
            nil
        )
    },
]
