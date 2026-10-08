import Foundation
import VoicePanelCore

let recognitionInferenceChunkPolicyChecks: [CheckCase] = [
    CheckCase(name: "Inference admission preserves profile-prepared audio exactly") {
        let samples = (0..<1_600).map { Float($0) / 1_600 }
        let chunk = AudioChunk(
            samples: samples,
            sampleRate: 16_000,
            boundaryReason: .silence,
            speechRange: 320..<1_280,
            speechEvidenceAnalyzed: true
        )
        guard let admitted = RecognitionInferenceChunkPolicy.admittedChunk(chunk) else {
            throw CheckFailure(description: "speech chunk should be admitted")
        }
        try expect(admitted.samples == samples, "admission must not re-trim preset margins")
        try expect(admitted.speechRange == chunk.speechRange, "speech evidence must stay unchanged")
    },
    CheckCase(name: "Inference admission rejects chunks proven silent") {
        let chunk = AudioChunk(
            samples: Array(repeating: 0, count: 1_600),
            sampleRate: 16_000,
            boundaryReason: .stopped,
            speechRange: nil,
            speechEvidenceAnalyzed: true
        )
        try expect(
            RecognitionInferenceChunkPolicy.admittedChunk(chunk) == nil,
            "known silence must not reach inference"
        )
    },
]
