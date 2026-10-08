import AppKit
import Foundation
import VoicePanelCore

private enum FixtureError: Error, Equatable {
    case preparation(Int)
    case segmented
}

private final class Recorder {
    var events: [String] = []
    var prepareCount = 0
    var decodeCount = 0
    var continuousCount = 0
    var segmentedCount = 0
    var fallbackCount = 0
    var cancelledEngineCount = 0
}

@MainActor
private func executeFixture(
    route: WhisperFileImportRoute,
    continuousOutcome: WhisperContinuousAttemptOutcome = .completed,
    failingPreparations: Set<Int> = [],
    segmentedError: FixtureError? = nil
) async throws -> (WhisperFileImportExecutionOutcome, Recorder) {
    let recorder = Recorder()
    let outcome = try await WhisperFileImportExecutor.execute(
        route: route,
        prepareEngine: { override in
            recorder.prepareCount += 1
            recorder.events.append("prepare:\(override?.rawValue ?? "configured")")
            if failingPreparations.contains(recorder.prepareCount) {
                throw FixtureError.preparation(recorder.prepareCount)
            }
            return recorder.prepareCount
        },
        decode: {
            recorder.decodeCount += 1
            recorder.events.append("decode")
            return [Float](repeating: 0.25, count: 4)
        },
        transcribeContinuous: { _, samples in
            recorder.continuousCount += 1
            recorder.events.append("continuous:\(samples.count)")
            return continuousOutcome
        },
        transcribeSegmented: { _, samples, isFallback in
            recorder.segmentedCount += 1
            recorder.events.append("segmented:\(samples.count):\(isFallback)")
            if let segmentedError { throw segmentedError }
        },
        cancelEngine: { _ in
            recorder.cancelledEngineCount += 1
            recorder.events.append("cancel-engine")
        },
        beginFallback: { reason in
            recorder.fallbackCount += 1
            recorder.events.append("fallback:\(reason.rawValue)")
        }
    )
    return (outcome, recorder)
}

@main
private enum WhisperFileImportExecutorChecks {
    @MainActor
    static func main() async {
        do {
            try await checkProfileRouteUsesConfiguredSegmentation()
            try await checkContinuousSuccessUsesOneDecodeAndNoVAD()
            try await checkPreparationFailureFallsBackOnce()
            try await checkRuntimeFailureFallsBackOnce()
            try await checkCancellationNeverFallsBack()
            try await checkSecondPreparationFailureSurfaces()
            try await checkSegmentedFallbackFailureSurfaces()
            try checkRuntimeFailureRecoveryUsesCoordinatorInterpreter()
            try checkFallbackFailurePreservesExactMessage()
            try checkCompactFallbackFitsProductionLayout()
            print("Whisper file import executor behavioral checks passed.")
        } catch {
            FileHandle.standardError.write(
                Data("Whisper file import executor check failed: \(error)\n".utf8)
            )
            exit(1)
        }
    }

    @MainActor
    private static func checkProfileRouteUsesConfiguredSegmentation() async throws {
        let (outcome, recorder) = try await executeFixture(route: .profileVAD)
        try require(outcome == .completed, "profile route did not complete")
        try require(
            recorder.events == ["prepare:configured", "decode", "segmented:4:false"],
            "profile route changed configured segmented ordering"
        )
    }

    @MainActor
    private static func checkContinuousSuccessUsesOneDecodeAndNoVAD() async throws {
        let (outcome, recorder) = try await executeFixture(route: .continuousFullAudio)
        try require(outcome == .completed, "continuous success did not complete")
        try require(recorder.decodeCount == 1, "continuous success decoded more than once")
        try require(recorder.continuousCount == 1, "continuous success did not run exactly once")
        try require(recorder.segmentedCount == 0, "continuous success prepared segmented VAD")
        try require(recorder.fallbackCount == 0, "continuous success entered fallback")
        try require(
            recorder.events == ["prepare:standard", "decode", "continuous:4"],
            "continuous success call order changed"
        )
    }

    @MainActor
    private static func checkPreparationFailureFallsBackOnce() async throws {
        let (outcome, recorder) = try await executeFixture(
            route: .continuousFullAudio,
            failingPreparations: [1]
        )
        try require(outcome == .completed, "preparation fallback did not complete")
        try require(recorder.prepareCount == 2, "preparation failure did not prepare exactly twice")
        try require(recorder.decodeCount == 1, "preparation fallback decoded more than once")
        try require(recorder.continuousCount == 0, "failed preparation retried continuous")
        try require(recorder.segmentedCount == 1, "preparation fallback did not segment once")
        try require(recorder.fallbackCount == 1, "preparation failure reported fallback more than once")
        try require(
            recorder.events == [
                "prepare:standard", "fallback:preparationFailed", "prepare:standard", "decode",
                "segmented:4:true",
            ],
            "preparation fallback was not lazy and ordered"
        )
    }

    @MainActor
    private static func checkRuntimeFailureFallsBackOnce() async throws {
        let (outcome, recorder) = try await executeFixture(
            route: .continuousFullAudio,
            continuousOutcome: .failed
        )
        try require(outcome == .completed, "runtime fallback did not complete")
        try require(recorder.prepareCount == 2, "runtime failure did not prepare one fallback")
        try require(recorder.decodeCount == 1, "runtime fallback decoded the file again")
        try require(recorder.continuousCount == 1, "runtime failure retried continuous")
        try require(recorder.segmentedCount == 1, "runtime fallback did not segment once")
        try require(recorder.fallbackCount == 1, "runtime failure reported fallback more than once")
        try require(recorder.cancelledEngineCount == 1, "failed continuous engine stayed active")
    }

    @MainActor
    private static func checkCancellationNeverFallsBack() async throws {
        let (outcome, recorder) = try await executeFixture(
            route: .continuousFullAudio,
            continuousOutcome: .cancelled
        )
        try require(outcome == .cancelled, "continuous cancellation changed outcome")
        try require(recorder.fallbackCount == 0, "continuous cancellation entered fallback")
        try require(recorder.prepareCount == 1, "continuous cancellation prepared another engine")
        try require(recorder.segmentedCount == 0, "continuous cancellation prepared segmented VAD")
    }

    @MainActor
    private static func checkSecondPreparationFailureSurfaces() async throws {
        do {
            _ = try await executeFixture(
                route: .continuousFullAudio,
                failingPreparations: [1, 2]
            )
            throw CheckFailure("second preparation failure was swallowed")
        } catch FixtureError.preparation(2) {
        }
    }

    @MainActor
    private static func checkSegmentedFallbackFailureSurfaces() async throws {
        do {
            _ = try await executeFixture(
                route: .continuousFullAudio,
                continuousOutcome: .failed,
                segmentedError: .segmented
            )
            throw CheckFailure("segmented fallback failure was swallowed")
        } catch FixtureError.segmented {
        }
    }

    private static func checkRuntimeFailureRecoveryUsesCoordinatorInterpreter() throws {
        let continuousID = UUID()
        let fallbackID = UUID()
        var work = RecognitionPendingWork()
        work.queueChunk(id: continuousID, duration: 45)
        work.failChunk(id: continuousID)

        let resolution = WhisperFileImportOutcomeInterpreter.continuousResolution(
            after: .failed(continuousID, message: "Continuous pass exhausted memory."),
            recoverFailure: { recoveredID in
                _ = work.recoverFailedChunk(id: recoveredID)
            }
        )
        work.queueChunk(id: fallbackID, duration: 12)
        work.completeChunk(id: fallbackID)

        try require(resolution.outcome == .failed, "runtime failure did not request fallback")
        try require(work.failedChunkCount == 0, "recovered Continuous failure stayed terminal")
        try require(
            WhisperFileImportPolicy.terminalPresentation(
                hasText: true,
                failedChunkCount: work.failedChunkCount
            ) == .interactive,
            "successful segmented fallback did not use normal imported presentation"
        )
    }

    private static func checkFallbackFailurePreservesExactMessage() throws {
        let message = "Fallback model rejected the second segment."
        let error = WhisperFileImportOutcomeInterpreter.segmentedFallbackError(
            after: .failed(UUID(), message: message),
            isFallback: true
        )

        try require(error?.localizedDescription == message, "fallback failure message was replaced")
    }

    private static func checkCompactFallbackFitsProductionLayout() throws {
        let layout = CompactAudioImportLayoutPolicy.productionCompact
        let font = NSFont.systemFont(ofSize: layout.fallbackFontSize)
        var requiredFallbackHeights: [CGFloat] = []

        for reason in [
            WhisperFileImportFallbackReason.preparationFailed,
            .recognitionFailed,
        ] {
            let fallbackDescription = WhisperFileImportPolicy.fallbackDescription(for: reason)
            let presentation = CompactAudioImportPresentation.resolve(
                phase: .preparing,
                isImportingAudioFile: true,
                progress: AudioImportProgress(
                    stage: .preparing,
                    fallbackDescription: fallbackDescription
                ),
                preparationProgress: nil
            )
            let measuredTextHeight = ceil(
                (fallbackDescription as NSString).boundingRect(
                    with: NSSize(
                        width: layout.contentWidth,
                        height: .greatestFiniteMagnitude
                    ),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font]
                ).height
            )
            requiredFallbackHeights.append(
                layout.requiredProgressHeight(fallbackTextHeight: measuredTextHeight)
            )

            try require(
                presentation.recordingLayout == .dedicatedImportProgress,
                "fallback preparation retained the transcript row"
            )
        }

        guard let requiredHeight = requiredFallbackHeights.max() else {
            throw CheckFailure("fallback layout fixture did not measure production copy")
        }

        try require(
            requiredHeight <= layout.dedicatedProgressHeight,
            "indicator and complete fallback text exceed the dedicated compact budget"
        )
        try require(
            requiredHeight > layout.standardProgressHeight,
            "layout fixture no longer reproduces the ordinary compact overflow"
        )

        let ordinaryPreparation = CompactAudioImportPresentation.resolve(
            phase: .preparing,
            isImportingAudioFile: true,
            progress: AudioImportProgress(stage: .preparing),
            preparationProgress: nil
        )
        try require(
            ordinaryPreparation.recordingLayout == .standardRecording,
            "ordinary preparation dropped the transcript row"
        )
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure(message) }
}
