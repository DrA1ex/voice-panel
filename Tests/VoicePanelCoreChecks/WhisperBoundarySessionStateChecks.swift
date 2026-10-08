import Foundation
import VoicePanelCore

private func boundaryResult(_ text: String) -> WhisperTranscriptionResult {
    WhisperTranscriptionResult(
        text: text,
        segments: [],
        detectedLanguage: "en",
        inferenceDuration: 0.1
    )
}

private func storedMaximumDurationChunk() -> WhisperBoundaryAcceptedChunk {
    WhisperBoundaryAcceptedChunk(
        segmentID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        sequence: 7,
        result: boundaryResult("accepted forced boundary"),
        boundaryReason: .maximumDuration,
        audioDuration: 18
    )
}

private func storedChunk(
    id: UUID = UUID(),
    sequence: Int = 8,
    text: String = "next accepted boundary",
    boundaryReason: AudioChunkBoundaryReason
) -> WhisperBoundaryAcceptedChunk {
    WhisperBoundaryAcceptedChunk(
        segmentID: id,
        sequence: sequence,
        result: boundaryResult(text),
        boundaryReason: boundaryReason,
        audioDuration: 5
    )
}

let whisperBoundarySessionStateChecks: [CheckCase] = [
    CheckCase(name: "Whisper boundary session begins without retry context") {
        let state = WhisperBoundarySessionState()
        try expect(state.contextualRetrySource == nil, "a new session must not reuse context")
        try expectEqual(state.repairAttemptCount, 0)
        try expectEqual(state.repairRejectionCount, 0)
    },
    CheckCase(name: "Whisper boundary session exposes an accepted forced boundary") {
        var state = WhisperBoundarySessionState()
        let accepted = storedMaximumDurationChunk()

        state.recordAccepted(
            accepted,
            resampledSamples: (0..<10).map(Float.init),
            sampleRate: 2
        )

        try expectEqual(state.contextualRetrySource, accepted)
        try expectEqual(state.boundaryBridgeSource?.segmentID, accepted.segmentID)
        try expectEqual(state.boundaryBridgeSource?.sequence, accepted.sequence)
        try expectEqual(state.boundaryBridgeSource?.result, accepted.result)
        try expectEqual(state.boundaryBridgeSource?.boundaryReason, .maximumDuration)
        try expectEqual(state.boundaryBridgeSource?.resampledSamples, [3, 4, 5, 6, 7, 8, 9])
        try expectEqual(state.boundaryBridgeSource?.sampleRate, 2)
    },
    CheckCase(name: "Whisper boundary session clears context at continuity breaks") {
        let resetActions: [(inout WhisperBoundarySessionState) -> Void] = [
            { state in
                state.recordAccepted(
                    storedChunk(text: "pause", boundaryReason: .silence),
                    resampledSamples: [1, 2],
                    sampleRate: 2
                )
            },
            { state in
                state.recordAccepted(
                    storedChunk(text: "stopped", boundaryReason: .stopped),
                    resampledSamples: [1, 2],
                    sampleRate: 2
                )
            },
            { $0.recordEmptyOutput() },
            { $0.recordRejectedHallucination() },
            { $0.recordError() },
            { $0.recordCandidateFailure() },
            { $0.recordCancellation() },
            { $0.reset() },
        ]

        for reset in resetActions {
            var state = WhisperBoundarySessionState()
            state.recordAccepted(
                storedMaximumDurationChunk(),
                resampledSamples: [1, 2, 3],
                sampleRate: 1
            )
            reset(&state)
            try expect(state.contextualRetrySource == nil, "continuity break retained stale context")
            try expect(state.boundaryBridgeSource == nil, "continuity break retained stale audio")
        }
    },
    CheckCase(name: "Whisper boundary session never repairs a pause-balanced cut") {
        var state = WhisperBoundarySessionState()
        state.recordAccepted(
            storedMaximumDurationChunk(),
            resampledSamples: [1, 2, 3],
            sampleRate: 1
        )
        state.recordAccepted(
            storedChunk(text: "balanced continuation", boundaryReason: .balancedPause),
            resampledSamples: [4, 5, 6],
            sampleRate: 1
        )
        try expect(state.contextualRetrySource == nil, "balanced pause retained retry context")
        try expect(state.boundaryBridgeSource == nil, "balanced pause retained bridge audio")
    },
    CheckCase(name: "Whisper rejected bridge promotes only a forced current baseline") {
        let promotedID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let currentMaximum = storedChunk(
            id: promotedID,
            text: "independent current baseline",
            boundaryReason: .maximumDuration
        )
        var state = WhisperBoundarySessionState()
        state.recordAccepted(
            storedMaximumDurationChunk(),
            resampledSamples: [0, 1, 2],
            sampleRate: 1
        )

        state.recordRepairRejection()
        state.recordAccepted(
            currentMaximum,
            resampledSamples: [10, 11, 12, 13],
            sampleRate: 1
        )

        try expectEqual(state.boundaryBridgeSource?.segmentID, promotedID)
        try expectEqual(state.boundaryBridgeSource?.result.text, "independent current baseline")
        try expectEqual(state.boundaryBridgeSource?.resampledSamples, [11, 12, 13])

        state.recordRepairRejection()
        state.recordAccepted(
            storedChunk(text: "natural end", boundaryReason: .silence),
            resampledSamples: [20, 21],
            sampleRate: 1
        )
        try expect(state.boundaryBridgeSource == nil, "a natural end became bridge continuity")
    },
    CheckCase(name: "Whisper boundary session retains no unbounded invalid-rate audio") {
        var state = WhisperBoundarySessionState()

        state.recordAccepted(
            storedMaximumDurationChunk(),
            resampledSamples: Array(repeating: 0.5, count: 100),
            sampleRate: .nan
        )

        try expectEqual(state.boundaryBridgeSource?.resampledSamples, [])
    },
    CheckCase(name: "Whisper boundary session never rounds a retained tail beyond 3.5 seconds") {
        var state = WhisperBoundarySessionState()
        let sampleRate = (9.0 / 3.5).nextDown

        state.recordAccepted(
            storedMaximumDurationChunk(),
            resampledSamples: (0..<18).map(Float.init),
            sampleRate: sampleRate
        )

        try expectEqual(
            state.boundaryBridgeSource?.resampledSamples,
            [10, 11, 12, 13, 14, 15, 16, 17]
        )
        let retainedDuration =
            Double(state.boundaryBridgeSource?.resampledSamples.count ?? 0) / sampleRate
        try expect(
            retainedDuration <= 3.5,
            "fractional sample rates must not round a retained tail beyond the duration bound"
        )
    },
    CheckCase(name: "Whisper boundary rejection records evidence without changing baseline") {
        var state = WhisperBoundarySessionState()
        let baseline = storedMaximumDurationChunk()
        state.recordAccepted(baseline)

        state.recordRepairAttempt()
        state.recordRepairRejection()

        try expectEqual(state.repairAttemptCount, 1)
        try expectEqual(state.repairRejectionCount, 1)
        try expectEqual(state.contextualRetrySource, baseline)
    },
    CheckCase(name: "Whisper contextual revision preserves segment identity and sequence") {
        let state = WhisperBoundarySessionState()
        let baseline = storedMaximumDurationChunk()

        let revision = state.contextualRevision(
            from: baseline,
            result: boundaryResult("repaired forced boundary")
        )

        try expectEqual(revision.segmentID, baseline.segmentID)
        try expectEqual(revision.sequence, baseline.sequence)
        try expectEqual(revision.result.text, "repaired forced boundary")
    },
    CheckCase(name: "Whisper repair diagnostics encode bounded evidence without transcript text") {
        let diagnostics = WhisperBoundaryRepairDiagnostics(
            strategy: .contextualRetry,
            attempted: true,
            accepted: false,
            reasonCode: .candidateFailed,
            inferenceCount: 2,
            inferenceDuration: 0.75,
            changedBoundaryWordCounts: .init(baseline: 3, replacement: 0)
        )

        let data = try JSONEncoder().encode(diagnostics)
        let decoded = try JSONDecoder().decode(
            WhisperBoundaryRepairDiagnostics.self,
            from: data
        )
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = Set(object?.keys ?? [String: Any]().keys)

        try expectEqual(decoded, diagnostics)
        try expectEqual(decoded.inferenceCount, 2)
        try expectEqual(decoded.changedBoundaryWordCounts.baseline, 3)
        try expectEqual(
            keys,
            Set([
                "strategy", "attempted", "accepted", "reasonCode", "inferenceCount",
                "inferenceDuration", "changedBoundaryWordCounts",
            ]),
            "diagnostic payload must contain evidence fields only"
        )
    },
    CheckCase(name: "Whisper repair diagnostics bound changed words to the repair window") {
        let counts = WhisperBoundaryChangedWordCounts(baseline: 99, replacement: -2)

        try expectEqual(counts.baseline, 24)
        try expectEqual(counts.replacement, 0)
    },
]
