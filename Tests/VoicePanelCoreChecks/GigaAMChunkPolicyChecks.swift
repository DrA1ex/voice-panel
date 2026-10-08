import VoicePanelCore

let gigaAMChunkPolicyChecks: [CheckCase] = [
    CheckCase(name: "GigaAM chunk policy never exceeds the safe 20 second limit") {
        let policy = GigaAMChunkPolicy(
            preferredDuration: 24,
            maximumDuration: 30,
            overlapDuration: 8,
            boundarySearchDuration: 9,
            retryCount: 9
        )
        try expectEqual(policy.maximumDuration, 20)
        try expectEqual(policy.preferredDuration, 20)
        try expectEqual(policy.overlapDuration, 2)
        try expectEqual(policy.boundarySearchDuration, 5)
        try expectEqual(policy.retryCount, 3)
        try expectEqual(GigaAMInferenceLimit.maximumSampleCount, 368_000)
        try expect(GigaAMInferenceLimit.accepts(sampleCount: 368_000), "23 seconds must be accepted")
        try expect(
            !GigaAMInferenceLimit.accepts(sampleCount: 368_001),
            "even one sample over 23 seconds must be rejected"
        )
    },
    CheckCase(name: "GigaAM boundary search produces a safe soft chunk limit") {
        let policy = GigaAMChunkPolicy(
            preferredDuration: 17,
            maximumDuration: 20,
            boundarySearchDuration: 2
        )
        let configuration = policy.segmenterConfiguration()
        try expectEqual(configuration.maximumChunkDuration, 19)

        let clamped = GigaAMChunkPolicy(
            preferredDuration: 19,
            maximumDuration: 20,
            boundarySearchDuration: 4
        )
        try expectEqual(clamped.segmenterConfiguration().maximumChunkDuration, 20)
    },
    CheckCase(name: "GigaAM profile limits cap the emitted chunk duration") {
        let policy = GigaAMChunkPolicy(
            preferredDuration: 18,
            maximumDuration: 20,
            boundarySearchDuration: 2
        )
        try expectEqual(
            policy.segmenterConfiguration(
                maximumDurationLimit: RecognitionProfileID.lowLatency
                    .defaultGigaAMChunkDuration
            ).maximumChunkDuration,
            3.5
        )
        try expectEqual(
            policy.segmenterConfiguration(
                maximumDurationLimit: RecognitionProfileID.recommended
                    .defaultGigaAMChunkDuration
            ).maximumChunkDuration,
            15
        )
        try expectEqual(
            policy.segmenterConfiguration(
                maximumDurationLimit: RecognitionProfileID.quality
                    .defaultGigaAMChunkDuration
            ).maximumChunkDuration,
            20
        )
    },
    CheckCase(name: "GigaAM retry split keeps a bounded overlap") {
        let policy = GigaAMChunkPolicy(overlapDuration: 0.4)
        let chunk = AudioChunk(
            samples: Array(repeating: 0.5, count: 160_000),
            sampleRate: 16_000,
            boundaryReason: .stopped
        )
        let parts = policy.split(chunk)
        try expectEqual(parts.count, 2)
        try expect(parts[0].duration < chunk.duration, "first retry part must be shorter")
        try expect(parts[1].duration < chunk.duration, "second retry part must be shorter")
        try expect(
            parts[0].samples.count + parts[1].samples.count > chunk.samples.count, "retry parts must retain overlap")
        try expectApproximatelyEqual(
            parts[0].trailingOverlapDuration,
            0.4,
            accuracy: 0.0001
        )
    },
    CheckCase(name: "GigaAM inference bounding splits long external chunks below 23 seconds") {
        let policy = GigaAMChunkPolicy(
            preferredDuration: 20,
            maximumDuration: 20,
            overlapDuration: 0.4
        )
        let chunk = AudioChunk(
            samples: Array(repeating: 0.5, count: 49 * 16_000),
            sampleRate: 16_000,
            boundaryReason: .stopped
        )
        let parts = policy.chunksBoundedToInferenceLimit(chunk)
        try expectEqual(parts.count, 3)
        try expect(
            parts.allSatisfy { $0.samples.count <= GigaAMInferenceLimit.maximumSampleCount },
            "every chunk sent to GigaAM must stay within 23 seconds"
        )
        try expectEqual(parts.last?.boundaryReason, .stopped)
    },
]
