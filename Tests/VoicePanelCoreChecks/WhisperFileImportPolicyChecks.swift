import Foundation
import VoicePanelCore

private func pipelineResult(_ chunks: [AudioChunk]) -> RecognitionPipelineValidator.Result {
    RecognitionPipelineValidator.Result(
        chunks: chunks,
        summary: RecognitionPipelineValidationSummary(
            capturedDuration: chunks.reduce(0) { $0 + $1.duration },
            minimumAcceptedDuration: 0.1,
            acceptedByRecordingPolicy: true,
            chunks: chunks.map {
                RecognitionPipelineValidationChunk(
                    boundaryReason: $0.boundaryReason,
                    duration: $0.duration,
                    speechDuration: $0.duration
                )
            }
        )
    )
}

let whisperFileImportPolicyChecks: [CheckCase] = [
    CheckCase(name: "Whisper continuous file mode selects one full-audio route") {
        try expectEqual(
            WhisperFileImportPolicy.route(isWhisper: true, mode: .continuousFullAudio),
            .continuousFullAudio
        )
    },
    CheckCase(name: "non-Whisper file imports remain profile VAD segmented") {
        for mode in WhisperFileTranscriptionMode.allCases {
            try expectEqual(
                WhisperFileImportPolicy.route(isWhisper: false, mode: mode),
                .profileVAD
            )
        }
    },
    CheckCase(name: "Whisper profile VAD file mode remains segmented") {
        try expectEqual(
            WhisperFileImportPolicy.route(isWhisper: true, mode: .profileVAD),
            .profileVAD
        )
    },
    CheckCase(name: "continuous failure alone permits one segmented fallback") {
        try expectEqual(
            WhisperFileImportPolicy.shouldFallback(after: .failed),
            true
        )
        try expectEqual(
            WhisperFileImportPolicy.shouldFallback(after: .completed),
            false
        )
        try expectEqual(
            WhisperFileImportPolicy.shouldFallback(after: .cancelled),
            false
        )
    },
    CheckCase(name: "continuous route constructs one stopped chunk from every decoded sample") {
        let samples: [Float] = [0.25, -0.5, 0.75, 1]
        let chunks = WhisperFileImportPolicy.continuousChunks(
            samples: samples,
            sampleRate: 16_000
        )

        try expectEqual(chunks.count, 1)
        try expectEqual(chunks[0].samples, samples)
        try expectEqual(chunks[0].sampleRate, 16_000)
        try expectEqual(chunks[0].boundaryReason, .stopped)
        try expectEqual(chunks[0].speechEvidenceAnalyzed, false)
    },
    CheckCase(name: "successful recovered fallback uses normal imported result presentation") {
        try expectEqual(
            WhisperFileImportPolicy.terminalPresentation(
                hasText: true,
                failedChunkCount: 0
            ),
            .interactive
        )
        try expectEqual(
            WhisperFileImportPolicy.terminalPresentation(
                hasText: true,
                failedChunkCount: 1
            ),
            .partialIssue
        )
    },
    CheckCase(name: "Whisper file screening excludes a forced chunk with no isolated speech") {
        let speech = AudioChunk(
            samples: Array(repeating: 0.4, count: 40),
            sampleRate: 10,
            boundaryReason: .maximumDuration,
            speechRange: 0..<40,
            speechEvidenceAnalyzed: true
        )
        let neuralSilence = AudioChunk(
            samples: Array(repeating: 0.01, count: 40),
            sampleRate: 10,
            boundaryReason: .maximumDuration,
            speechRange: 0..<40,
            speechEvidenceAnalyzed: true
        )

        let screening = WhisperFileImportPolicy.screeningForcedChunks(
            in: pipelineResult([speech, neuralSilence]),
            detectsIsolatedSpeech: { $0.id == speech.id }
        )

        try expectEqual(screening.result.chunks.map(\.id), [speech.id])
        try expectEqual(screening.excludedChunkIndices, [1])
        try expectEqual(screening.result.summary.chunks.count, 1)
    },
    CheckCase(name: "Whisper file screening fails open without neural evidence") {
        let chunk = AudioChunk(
            samples: Array(repeating: 0.01, count: 40),
            sampleRate: 10,
            boundaryReason: .maximumDuration,
            speechRange: 0..<40,
            speechEvidenceAnalyzed: true
        )

        let screening = WhisperFileImportPolicy.screeningForcedChunks(
            in: pipelineResult([chunk]),
            detectsIsolatedSpeech: { _ in nil }
        )

        try expectEqual(screening.result.chunks.map(\.id), [chunk.id])
        try expect(screening.excludedChunkIndices.isEmpty, "missing neural evidence removed audio")
    },
    CheckCase(name: "Whisper file import merges a short forced tail without duplicate overlap") {
        let previousSamples = (0..<100).map(Float.init)
        let previous = AudioChunk(
            samples: previousSamples,
            sampleRate: 10,
            boundaryReason: .maximumDuration,
            speechRange: 10..<90,
            speechEvidenceAnalyzed: true
        )
        let tail = AudioChunk(
            samples: Array(previousSamples.suffix(2)) + [100, 101, 102],
            sampleRate: 10,
            boundaryReason: .silence,
            speechRange: 1..<5,
            speechEvidenceAnalyzed: true
        )

        let result = WhisperFileImportPolicy.mergingShortForcedTail(
            in: pipelineResult([previous, tail]),
            segmenterConfiguration: .init(
                overlapDuration: 0.2,
                maximumChunkDuration: 10
            )
        )

        try expectEqual(result.chunks.count, 1)
        try expectEqual(result.chunks[0].samples.count, 103)
        try expectEqual(Array(result.chunks[0].samples.suffix(5)), [98, 99, 100, 101, 102])
        try expectEqual(result.chunks[0].boundaryReason, .silence)
        try expectEqual(result.chunks[0].speechRange, 10..<103)
        try expectEqual(result.chunks[0].id, previous.id)
        try expectEqual(result.summary.chunks.count, 1)
        try expectEqual(result.summary.chunks[0].boundaryReason, .silence)
    },
    CheckCase(name: "Whisper file import keeps short-tail merging after an adaptive forced cut") {
        var segmenter = AudioSegmenter(
            configuration: .init(
                preRollDuration: 0,
                postRollDuration: 0.1,
                overlapDuration: 0.2,
                maximumChunkDuration: 1,
                minimumChunkDuration: 0.1,
                forcedBoundaryLookbackDuration: 0.4,
                minimumForcedBoundaryPauseDuration: 0.2
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
        let forced = segmenter.process(
            samples: [8, 9],
            sampleRate: rate,
            event: .speechContinued
        )
        guard let tail = segmenter.finish() else {
            throw CheckFailure(description: "expected the retained adaptive tail")
        }

        let configuration = segmenter.configuration
        let result = WhisperFileImportPolicy.mergingShortForcedTail(
            in: pipelineResult(forced + [tail]),
            segmenterConfiguration: configuration
        )

        try expectEqual(result.chunks.count, 1)
        try expectEqual(result.chunks[0].samples, (0...9).map(Float.init))
        try expectEqual(result.chunks[0].boundaryReason, .stopped)
    },
    CheckCase(name: "Whisper file import keeps a short tail when overlap evidence differs") {
        let previous = AudioChunk(
            samples: Array(repeating: 0.25, count: 100),
            sampleRate: 10,
            boundaryReason: .maximumDuration
        )
        let tail = AudioChunk(
            samples: Array(repeating: 0.5, count: 5),
            sampleRate: 10,
            boundaryReason: .stopped
        )

        let result = WhisperFileImportPolicy.mergingShortForcedTail(
            in: pipelineResult([previous, tail]),
            segmenterConfiguration: .init(
                overlapDuration: 0.2,
                maximumChunkDuration: 10
            )
        )

        try expectEqual(result.chunks.count, 2)
    },
    CheckCase(name: "Whisper file import keeps a tail longer than the short-tail limit") {
        let previous = AudioChunk(
            samples: Array(repeating: 0.25, count: 100),
            sampleRate: 10,
            boundaryReason: .maximumDuration
        )
        let tail = AudioChunk(
            samples: Array(repeating: 0.25, count: 14),
            sampleRate: 10,
            boundaryReason: .stopped
        )

        let result = WhisperFileImportPolicy.mergingShortForcedTail(
            in: pipelineResult([previous, tail]),
            segmenterConfiguration: .init(
                overlapDuration: 0.2,
                maximumChunkDuration: 10
            )
        )

        try expectEqual(result.chunks.count, 2)
    },
    CheckCase(name: "Whisper file tail merge stays inside profile headroom") {
        let previous = AudioChunk(
            samples: Array(repeating: 0.25, count: 120),
            sampleRate: 10,
            boundaryReason: .maximumDuration
        )
        let tail = AudioChunk(
            samples: Array(repeating: 0.25, count: 5),
            sampleRate: 10,
            boundaryReason: .stopped
        )

        let result = WhisperFileImportPolicy.mergingShortForcedTail(
            in: pipelineResult([previous, tail]),
            segmenterConfiguration: .init(
                overlapDuration: 0.2,
                maximumChunkDuration: 10
            )
        )

        try expectEqual(result.chunks.count, 2)
    },
    CheckCase(name: "Whisper file tail merge respects the thirty-second model limit") {
        let previous = AudioChunk(
            samples: Array(repeating: 0.25, count: 300),
            sampleRate: 10,
            boundaryReason: .maximumDuration
        )
        let tail = AudioChunk(
            samples: Array(repeating: 0.25, count: 5),
            sampleRate: 10,
            boundaryReason: .stopped
        )

        let result = WhisperFileImportPolicy.mergingShortForcedTail(
            in: pipelineResult([previous, tail]),
            segmenterConfiguration: .init(
                overlapDuration: 0.2,
                maximumChunkDuration: 30
            )
        )

        try expectEqual(result.chunks.count, 2)
    },
]
