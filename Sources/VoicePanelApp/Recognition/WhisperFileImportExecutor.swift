import Foundation
import VoicePanelCore

enum WhisperFileImportExecutionOutcome: Equatable, Sendable {
    case completed
    case cancelled
}

struct WhisperContinuousAttemptResolution: Equatable {
    let outcome: WhisperContinuousAttemptOutcome
    let recoveredFailureID: UUID?
}

struct WhisperFileImportChunkFailure: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? { message }
}

enum WhisperFileImportOutcomeInterpreter {
    static func continuousResolution(
        after outcome: RecognitionChunkOutcome,
        recoverFailure: (UUID) -> Void
    ) -> WhisperContinuousAttemptResolution {
        switch outcome {
        case .completed:
            return WhisperContinuousAttemptResolution(
                outcome: .completed,
                recoveredFailureID: nil
            )
        case .failed(let id, _):
            recoverFailure(id)
            return WhisperContinuousAttemptResolution(
                outcome: .failed,
                recoveredFailureID: id
            )
        case .cancelled:
            return WhisperContinuousAttemptResolution(
                outcome: .cancelled,
                recoveredFailureID: nil
            )
        }
    }

    static func segmentedFallbackError(
        after outcome: RecognitionChunkOutcome?,
        isFallback: Bool
    ) -> WhisperFileImportChunkFailure? {
        guard isFallback, case .failed(_, let message)? = outcome else { return nil }
        return WhisperFileImportChunkFailure(message: message)
    }
}

@MainActor
enum WhisperFileImportExecutor {
    static func execute<Engine, DecodedAudio>(
        route: WhisperFileImportRoute,
        prepareEngine: (WhisperBoundaryStrategy?) async throws -> Engine,
        decode: () async throws -> DecodedAudio,
        transcribeContinuous: (Engine, DecodedAudio) async throws -> WhisperContinuousAttemptOutcome,
        transcribeSegmented: (Engine, DecodedAudio, Bool) async throws -> Void,
        cancelEngine: (Engine) -> Void,
        beginFallback: (WhisperFileImportFallbackReason) -> Void
    ) async throws -> WhisperFileImportExecutionOutcome {
        switch route {
        case .profileVAD:
            let engine = try await prepareEngine(nil)
            let decoded = try await decode()
            try await transcribeSegmented(engine, decoded, false)
            return .completed

        case .continuousFullAudio:
            let engine: Engine
            do {
                engine = try await prepareEngine(.standard)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                beginFallback(.preparationFailed)
                let fallbackEngine = try await prepareEngine(.standard)
                let decoded = try await decode()
                try await transcribeSegmented(fallbackEngine, decoded, true)
                return .completed
            }

            let decoded = try await decode()
            let outcome = try await transcribeContinuous(engine, decoded)
            guard WhisperFileImportPolicy.shouldFallback(after: outcome) else {
                return outcome == .cancelled ? .cancelled : .completed
            }

            cancelEngine(engine)
            beginFallback(.recognitionFailed)
            let fallbackEngine = try await prepareEngine(.standard)
            try await transcribeSegmented(fallbackEngine, decoded, true)
            return .completed
        }
    }
}
