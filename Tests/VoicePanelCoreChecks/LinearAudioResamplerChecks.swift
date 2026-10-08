import VoicePanelCore

let linearAudioResamplerChecks: [CheckCase] = [
    CheckCase(name: "resampler preserves 16 kHz input") {
        let input: [Float] = [0, 0.25, -0.5, 1]
        let output = LinearAudioResampler.resampleMono(
            samples: input,
            from: LinearAudioResampler.whisperSampleRate
        )
        try expectEqual(output, input)
    },
    CheckCase(name: "resampler converts 48 kHz duration to 16 kHz") {
        let input = Array(repeating: Float(0.5), count: 48_000)
        let output = LinearAudioResampler.resampleMono(samples: input, from: 48_000)
        try expectEqual(output.count, 16_000)
        try expectApproximatelyEqual(Double(output.first ?? 0), 0.5, accuracy: 0.000_001)
        try expectApproximatelyEqual(Double(output.last ?? 0), 0.5, accuracy: 0.000_001)
    },
    CheckCase(name: "resampler preserves signal endpoints") {
        let input: [Float] = [0, 1, 0, -1, 0]
        let output = LinearAudioResampler.resampleMono(samples: input, from: 5, to: 9)
        try expectEqual(output.count, 9)
        try expectApproximatelyEqual(Double(output.first ?? 1), 0, accuracy: 0.000_001)
        try expectApproximatelyEqual(Double(output.last ?? 1), 0, accuracy: 0.000_001)
    },
    CheckCase(name: "streaming resampler preserves duration across callback boundaries") {
        var resampler = StreamingLinearAudioResampler(targetSampleRate: 16_000)
        var output: [Float] = []
        for _ in 0..<3 {
            output.append(
                contentsOf: resampler.process(
                    samples: Array(repeating: Float(0.25), count: 1_024),
                    from: 48_000
                )
            )
        }
        try expectEqual(output.count, 1_024)
        try expect(output.allSatisfy { abs($0 - 0.25) < 0.000_001 }, "streaming output changed a constant signal")
    },
    CheckCase(name: "audio sample accumulator resamples one contiguous capture") {
        var accumulator = LinearAudioSampleAccumulator()
        for _ in 0..<3 {
            accumulator.append(
                samples: Array(repeating: Float(-0.4), count: 1_024),
                sampleRate: 48_000
            )
        }
        let output = accumulator.resampled(to: 16_000)
        try expectEqual(output.count, 1_024)
        try expect(output.allSatisfy { abs($0 + 0.4) < 0.000_001 }, "accumulator changed a constant signal")
    },
]
