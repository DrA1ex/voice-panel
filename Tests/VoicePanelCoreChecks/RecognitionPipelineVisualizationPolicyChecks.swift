import Foundation
import VoicePanelCore

let recognitionPipelineVisualizationPolicyChecks: [CheckCase] = [
    CheckCase(name: "Pipeline visualization reports recording policy rejection first") {
        let summary = RecognitionPipelineValidationSummary(
            capturedDuration: 0.1,
            minimumAcceptedDuration: 0.2,
            acceptedByRecordingPolicy: false,
            chunks: [],
            rejectedResultCount: 2
        )
        try expectEqual(
            RecognitionPipelineVisualizationPolicy.finding(for: summary),
            .recordingRejected
        )
    },
    CheckCase(name: "Pipeline visualization reports rejected recognition results") {
        let summary = RecognitionPipelineValidationSummary(
            capturedDuration: 2,
            minimumAcceptedDuration: 0.2,
            acceptedByRecordingPolicy: true,
            chunks: [
                RecognitionPipelineValidationChunk(
                    boundaryReason: .maximumDuration,
                    duration: 2,
                    speechDuration: 1.5
                )
            ],
            rejectedResultCount: 1
        )
        try expectEqual(
            RecognitionPipelineVisualizationPolicy.finding(for: summary),
            .recognitionResultsRejected(1)
        )
    },
    CheckCase(name: "Pipeline visualization calls out maximum-duration boundaries") {
        let summary = RecognitionPipelineValidationSummary(
            capturedDuration: 9,
            minimumAcceptedDuration: 0.2,
            acceptedByRecordingPolicy: true,
            chunks: [
                RecognitionPipelineValidationChunk(
                    boundaryReason: .maximumDuration,
                    duration: 8,
                    speechDuration: 7.5
                ),
                RecognitionPipelineValidationChunk(
                    boundaryReason: .stopped,
                    duration: 1,
                    speechDuration: 0.8
                ),
            ]
        )
        try expectEqual(
            RecognitionPipelineVisualizationPolicy.finding(for: summary),
            .segmentationBoundaries(maximumDuration: 1, pauseBalanced: 0, longSilence: 0)
        )
    },
    CheckCase(name: "Pipeline visualization reports a clean segmentation result") {
        let summary = RecognitionPipelineValidationSummary(
            capturedDuration: 4,
            minimumAcceptedDuration: 0.2,
            acceptedByRecordingPolicy: true,
            chunks: [
                RecognitionPipelineValidationChunk(
                    boundaryReason: .silence,
                    duration: 3,
                    speechDuration: 2.4
                ),
                RecognitionPipelineValidationChunk(
                    boundaryReason: .stopped,
                    duration: 1,
                    speechDuration: 0.7
                ),
            ]
        )
        try expectEqual(
            RecognitionPipelineVisualizationPolicy.finding(for: summary),
            .noObviousIssues
        )
    },
    CheckCase(name: "Pipeline visualization counts hard and pause-balanced cuts separately") {
        let summary = RecognitionPipelineValidationSummary(
            capturedDuration: 30,
            minimumAcceptedDuration: 0.2,
            acceptedByRecordingPolicy: true,
            chunks: [
                .init(boundaryReason: .maximumDuration, duration: 10, speechDuration: 9),
                .init(boundaryReason: .balancedPause, duration: 10, speechDuration: 8),
                .init(boundaryReason: .balancedPause, duration: 10, speechDuration: 8),
            ]
        )
        try expectEqual(
            RecognitionPipelineVisualizationPolicy.finding(for: summary),
            .segmentationBoundaries(maximumDuration: 1, pauseBalanced: 2, longSilence: 0)
        )
    },
    CheckCase(name: "Pipeline visualization reports compacted long silence") {
        let summary = RecognitionPipelineValidationSummary(
            capturedDuration: 12,
            minimumAcceptedDuration: 0.2,
            acceptedByRecordingPolicy: true,
            chunks: [
                .init(boundaryReason: .longSilence, duration: 5, speechDuration: 4),
                .init(boundaryReason: .stopped, duration: 5, speechDuration: 4),
            ]
        )
        try expectEqual(
            RecognitionPipelineVisualizationPolicy.finding(for: summary),
            .segmentationBoundaries(maximumDuration: 0, pauseBalanced: 0, longSilence: 1)
        )
    },
]
