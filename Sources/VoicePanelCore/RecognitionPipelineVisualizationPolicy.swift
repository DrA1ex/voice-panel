import Foundation

public enum RecognitionPipelineVisualizationFinding: Equatable, Sendable {
    case recordingRejected
    case recognitionResultsRejected(Int)
    case segmentationBoundaries(maximumDuration: Int, pauseBalanced: Int, longSilence: Int)
    case noObviousIssues
}

public enum RecognitionPipelineVisualizationPolicy {
    public static func finding(
        for summary: RecognitionPipelineValidationSummary
    ) -> RecognitionPipelineVisualizationFinding {
        guard summary.acceptedByRecordingPolicy else {
            return .recordingRejected
        }
        if summary.rejectedResultCount > 0 {
            return .recognitionResultsRejected(summary.rejectedResultCount)
        }
        let maximumDurationBoundaryCount = summary.chunks.reduce(into: 0) { count, chunk in
            if chunk.boundaryReason == .maximumDuration {
                count += 1
            }
        }
        let pauseBalancedBoundaryCount = summary.chunks.reduce(into: 0) { count, chunk in
            if chunk.boundaryReason == .balancedPause {
                count += 1
            }
        }
        let longSilenceBoundaryCount = summary.chunks.reduce(into: 0) { count, chunk in
            if chunk.boundaryReason == .longSilence {
                count += 1
            }
        }
        if maximumDurationBoundaryCount > 0 || pauseBalancedBoundaryCount > 0
            || longSilenceBoundaryCount > 0
        {
            return .segmentationBoundaries(
                maximumDuration: maximumDurationBoundaryCount,
                pauseBalanced: pauseBalancedBoundaryCount,
                longSilence: longSilenceBoundaryCount
            )
        }
        return .noObviousIssues
    }
}
