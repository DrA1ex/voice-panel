import Foundation
import VoicePanelCore

let modelBenchmarkProgressChecks: [CheckCase] = [
    CheckCase(name: "Benchmark recording progress starts at zero") {
        try expectApproximatelyEqual(
            ModelBenchmarkProgress.recordingFraction(elapsed: 0, maximumDuration: 30),
            0,
            accuracy: 0.0001
        )
    },
    CheckCase(name: "Benchmark recording progress is linear") {
        try expectApproximatelyEqual(
            ModelBenchmarkProgress.recordingFraction(elapsed: 7.5, maximumDuration: 30),
            0.25,
            accuracy: 0.0001
        )
        try expectApproximatelyEqual(
            ModelBenchmarkProgress.recordingFraction(elapsed: 15, maximumDuration: 30),
            0.5,
            accuracy: 0.0001
        )
    },
    CheckCase(name: "Benchmark recording progress stays within bounds") {
        try expectApproximatelyEqual(
            ModelBenchmarkProgress.recordingFraction(elapsed: -1, maximumDuration: 30),
            0,
            accuracy: 0.0001
        )
        try expectApproximatelyEqual(
            ModelBenchmarkProgress.recordingFraction(elapsed: 31, maximumDuration: 30),
            1,
            accuracy: 0.0001
        )
    },
]
