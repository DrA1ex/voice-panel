import Foundation
import VoicePanelCore

private enum BenchmarkCheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private struct BenchmarkInferenceRequest: Sendable {
    let sampleCount: Int
    let prompt: String
    let metadataLevel: WhisperInferenceMetadataLevel
}

private actor BenchmarkInferenceRecorder {
    private var results: [Result<WhisperTranscriptionResult, Error>]
    private(set) var requests: [BenchmarkInferenceRequest] = []

    init(_ results: [Result<WhisperTranscriptionResult, Error>]) {
        self.results = results
    }

    func transcribe(
        samples: [Float],
        prompt: String,
        metadataLevel: WhisperInferenceMetadataLevel
    ) throws -> WhisperTranscriptionResult {
        requests.append(
            BenchmarkInferenceRequest(
                sampleCount: samples.count,
                prompt: prompt,
                metadataLevel: metadataLevel
            )
        )
        guard !results.isEmpty else {
            throw BenchmarkCheckFailure.failed("unexpected extra benchmark inference")
        }
        return try results.removeFirst().get()
    }
}

private func benchmarkResult(
    _ text: String,
    inferenceDuration: TimeInterval = 0.1
) -> WhisperTranscriptionResult {
    WhisperTranscriptionResult(
        text: text,
        segments: [
            WhisperSegmentEvidence(
                text: text,
                startTime: 0,
                endTime: 2,
                noSpeechProbability: 0,
                tokens: [
                    WhisperTokenEvidence(
                        text: text,
                        startTime: nil,
                        endTime: nil,
                        probability: 0.8
                    )
                ]
            )
        ],
        detectedLanguage: "en",
        inferenceDuration: inferenceDuration
    )
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw BenchmarkCheckFailure.failed(message) }
}

private func makeExecutor(
    recorder: BenchmarkInferenceRecorder,
    hallucinationProtection: Bool = false
) -> WhisperBoundaryBenchmarkExecutor {
    var vad = VoiceActivityDetector.Configuration.sensitive
    vad.adaptiveThreshold = false
    vad.manualThresholdDB = -60
    vad.minimumSpeechDuration = 0.02
    vad.endOfSpeechSilenceDuration = 0.05
    return WhisperBoundaryBenchmarkExecutor(
        vadConfiguration: vad,
        segmenterConfiguration: .init(
            preRollDuration: 0,
            postRollDuration: 0,
            overlapDuration: 0,
            maximumChunkDuration: 2,
            minimumChunkDuration: 0.05
        ),
        detectionMode: .energy,
        inferenceConfiguration: WhisperInferenceConfiguration(
            numberOfThreads: 2,
            usesCustomDecoding: false,
            decodingStrategy: .greedy,
            greedyBestOf: 1,
            beamSize: 1,
            initialPrompt: "Static Context",
            boundaryStrategy: .standard,
            overlapDuration: 0.2,
            contextPromptMode: .legacyFixedWords
        ),
        languageCode: "en",
        hallucinationGuardConfiguration: .init(isEnabled: hallucinationProtection),
        neuralSpeechDetector: nil,
        transcribe: { samples, _, _, prompt, metadata in
            try await recorder.transcribe(
                samples: samples,
                prompt: prompt,
                metadataLevel: metadata
            )
        }
    )
}

private func segmentedEntry(
    variant: WhisperBenchmarkVariant,
    padding: TimeInterval = 0
) -> WhisperBenchmarkMatrixEntry {
    WhisperBenchmarkMatrixEntry(
        variant: variant,
        audioConfiguration: .init(
            edgePadding: padding,
            maximumChunkDurationOffset: 0
        )
    )
}

private func checkSequentialRevisionsAndExplicitEvidence() async throws {
    let previous = benchmarkResult("prefix context лева один два")
    let baseline = benchmarkResult("ошибка общий якорь здесь. неизменный хвост 你好。")
    let candidate = benchmarkResult("один два исправление общий якорь здесь иначе")
    let recorder = BenchmarkInferenceRecorder([
        .success(previous), .success(baseline), .success(candidate),
    ])
    let execution = try await makeExecutor(recorder: recorder).execute(
        entry: segmentedEntry(variant: .contextualRetry(.legacyFixedWords)),
        // Keep the final chunk above the file-import short-tail threshold so this
        // check continues to exercise a real boundary retry.
        samples: Array(repeating: 0.5, count: 60_000)
    )

    try require(execution.acceptedRepairCount == 1, "accepted retry was not counted")
    try require(
        execution.transcript.contains("один два исправление общий якорь"),
        "later revision did not replace the sequential baseline"
    )
    try require(
        !execution.transcript.contains("ошибка общий"),
        "superseded baseline leaked into the final transcript"
    )
    try require(
        execution.explicitReport.chunks.last?.baselineText == baseline.text,
        "explicit report lost raw baseline evidence"
    )
    try require(
        execution.explicitReport.chunks.last?.candidateText == candidate.text,
        "explicit report lost raw candidate evidence"
    )
    try require(
        execution.inferenceCount == execution.diagnostics.reduce(0) { $0 + $1.inferenceCount },
        "execution inference total diverged from diagnostics"
    )
}

private func checkLegacyGuardRejectsAndResetsContinuity() async throws {
    let rejected = benchmarkResult("loop loop loop loop loop")
    let accepted = benchmarkResult("second accepted phrase has enough context")
    let final = benchmarkResult("third accepted phrase")
    let recorder = BenchmarkInferenceRecorder([
        .success(rejected), .success(accepted), .success(final),
    ])
    let execution = try await makeExecutor(
        recorder: recorder,
        hallucinationProtection: true
    ).execute(
        entry: segmentedEntry(variant: .legacyContext),
        samples: Array(repeating: 0.5, count: 88_000)
    )
    let requests = await recorder.requests

    try require(!execution.transcript.contains(rejected.text), "rejected legacy text was published")
    try require(
        execution.diagnostics.first?.reasonCode == .baselineRejectedHallucination,
        "legacy rejection did not use production diagnostic semantics"
    )
    try require(
        execution.pipelineSummary?.rejectedResultCount == 1,
        "legacy rejection did not reach the pipeline summary"
    )
    try require(requests.count == 3, "legacy control used an unexpected inference count")
    try require(requests[1].prompt == "Static Context", "rejected legacy text retained continuity")
    try require(
        requests[2].prompt.contains("second accepted"),
        "accepted legacy text did not restore bounded continuity"
    )
    try require(
        execution.explicitReport.chunks.first?.baselineText == rejected.text,
        "explicit report discarded rejected raw evidence"
    )
}

private func checkContinuousFallbackAndExecutedDurations() async throws {
    let source = Array(repeating: Float(0.5), count: 56_000)
    let fallbackFirst = benchmarkResult("fallback first")
    let fallbackSecond = benchmarkResult("fallback second")
    let fallbackThird = benchmarkResult("fallback third")
    let recorder = BenchmarkInferenceRecorder([
        .failure(BenchmarkCheckFailure.failed("continuous failed")),
        .success(fallbackFirst),
        .success(fallbackSecond),
        .success(fallbackThird),
    ])
    let continuous = try await makeExecutor(recorder: recorder).execute(
        entry: .init(variant: .continuousFullAudio, audioConfiguration: nil),
        samples: source
    )
    let requests = await recorder.requests

    try require(continuous.fallbackCount == 1, "Continuous did not use exactly one fallback")
    try require(
        requests.filter { $0.sampleCount == source.count }.count == 1,
        "Continuous made more than one full-audio request"
    )
    try require(
        continuous.inferenceCount == requests.count,
        "failed Continuous inference was omitted from the total"
    )
    try require(
        continuous.explicitReport.chunks.count == requests.count - 1
            && continuous.explicitReport.chunks.first?.baselineText == fallbackFirst.text,
        "fallback raw evidence did not remain explicit"
    )
    try require(
        abs(continuous.executedAudioDuration - 3.5) < 0.000_001,
        "Continuous RTF input was not the original full-audio duration"
    )

    let paddedRecorder = BenchmarkInferenceRecorder([
        .success(benchmarkResult("padded sample result")),
        .success(benchmarkResult("padded sample continuation")),
        .success(benchmarkResult("padded sample tail")),
    ])
    let padded = try await makeExecutor(recorder: paddedRecorder).execute(
        entry: segmentedEntry(variant: .standard, padding: 0.4),
        samples: Array(repeating: 0.5, count: 32_000)
    )
    try require(
        abs(padded.executedAudioDuration - 2.8) < 0.000_001,
        "segmented RTF input omitted executed edge padding"
    )
}

@main
private struct WhisperBoundaryBenchmarkExecutorChecksMain {
    static func main() async {
        do {
            do {
                try await checkSequentialRevisionsAndExplicitEvidence()
            } catch {
                throw BenchmarkCheckFailure.failed("sequential revisions: \(error)")
            }
            do {
                try await checkLegacyGuardRejectsAndResetsContinuity()
            } catch {
                throw BenchmarkCheckFailure.failed("legacy guard: \(error)")
            }
            do {
                try await checkContinuousFallbackAndExecutedDurations()
            } catch {
                throw BenchmarkCheckFailure.failed("fallback/duration: \(error)")
            }
            print("Whisper boundary benchmark executor behavioral checks passed.")
        } catch {
            FileHandle.standardError.write(Data("Whisper benchmark executor check failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
