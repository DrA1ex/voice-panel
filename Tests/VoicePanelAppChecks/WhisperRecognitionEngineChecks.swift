import Foundation
import VoicePanelCore

private enum EngineCheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private final class PublicationPause: @unchecked Sendable {
    private let target: WhisperEnginePublicationAttempt
    private let lock = NSLock()
    private let reached = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private let completed = DispatchSemaphore(value: 0)
    private var claimed = false

    init(_ target: WhisperEnginePublicationAttempt) {
        self.target = target
    }

    func pause(_ attempt: WhisperEnginePublicationAttempt) {
        let shouldPause = lock.withLock {
            guard !claimed, attempt == target else { return false }
            claimed = true
            return true
        }
        guard shouldPause else { return }
        reached.signal()
        resume.wait()
    }

    func waitUntilReached() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [reached] in
                continuation.resume(
                    returning: reached.wait(timeout: .now() + .seconds(5)) == .success
                )
            }
        }
    }

    func release() {
        resume.signal()
    }

    func complete(_ attempt: WhisperEnginePublicationAttempt) {
        if attempt == target { completed.signal() }
    }

    func waitUntilCompleted() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [completed] in
                continuation.resume(
                    returning: completed.wait(timeout: .now() + .seconds(5)) == .success
                )
            }
        }
    }
}

private final class EngineEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var metrics = 0
    private var updates: [TranscriptSegmentUpdate] = []
    private var outcomes: [UUID] = []
    private var finished = 0

    func recordMetric() { lock.withLock { metrics += 1 } }
    func recordUpdate(_ update: TranscriptSegmentUpdate) { lock.withLock { updates.append(update) } }
    func recordOutcome(_ id: UUID) { lock.withLock { outcomes.append(id) } }
    func recordFinished() { lock.withLock { finished += 1 } }

    func snapshot() -> (
        metrics: Int,
        updates: [TranscriptSegmentUpdate],
        outcomes: [UUID],
        finished: Int
    ) {
        lock.withLock { (metrics, updates, outcomes, finished) }
    }
}

private actor ResultSequence {
    private var texts: [String]

    init(_ texts: [String]) {
        self.texts = texts
    }

    func next() -> WhisperTranscriptionResult {
        let text = texts.isEmpty ? "fallback" : texts.removeFirst()
        return result(text)
    }
}

private func result(_ text: String) -> WhisperTranscriptionResult {
    WhisperTranscriptionResult(
        text: text,
        segments: [
            WhisperSegmentEvidence(
                text: text,
                startTime: 0,
                endTime: 1,
                noSpeechProbability: 0,
                tokens: [
                    WhisperTokenEvidence(
                        text: text,
                        startTime: nil,
                        endTime: nil,
                        probability: 0.9
                    )
                ]
            )
        ],
        detectedLanguage: "en",
        inferenceDuration: 0.01
    )
}

private func configuration() -> WhisperInferenceConfiguration {
    WhisperInferenceConfiguration(
        numberOfThreads: 2,
        usesCustomDecoding: false,
        decodingStrategy: .greedy,
        greedyBestOf: 1,
        beamSize: 1,
        initialPrompt: "Static",
        boundaryStrategy: .standard,
        overlapDuration: 0.2,
        contextPromptMode: .lexicalOverlapAligned
    )
}

private func chunk(id: UUID = UUID()) -> AudioChunk {
    AudioChunk(
        id: id,
        samples: Array(repeating: 0.1, count: 16_000),
        sampleRate: 16_000,
        boundaryReason: .stopped
    )
}

private func engine(
    pause: PublicationPause? = nil,
    transcribe: @escaping WhisperBoundaryTranscriber
) -> WhisperRecognitionEngine {
    let runtime = WhisperRuntime(transcribe: transcribe)
    let engine = WhisperRecognitionEngine(
        model: .tiny,
        runtime: runtime,
        inferenceConfiguration: configuration()
    )
    if let pause {
        engine.beforePublicationAttempt = { [pause] attempt in
            pause.pause(attempt)
        }
        engine.afterPublicationAttempt = { [pause] attempt in
            pause.complete(attempt)
        }
    }
    return engine
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw EngineCheckFailure.failed(message) }
}

private func waitFor(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(
                returning: semaphore.wait(timeout: .now() + .seconds(5)) == .success
            )
        }
    }
}

private func checkCancelBeforeMetricCommitSuppressesStaleMetric() async throws {
    let pause = PublicationPause(.metrics)
    let events = EngineEvents()
    let engine = engine(pause: pause) { _, _, _, _, _ in
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return result("late")
    }
    engine.onMetrics = { _ in events.recordMetric() }
    try await engine.start(localeIdentifier: "en")

    let appending = Task.detached { engine.append(chunk()) }
    let reachedMetric = await pause.waitUntilReached()
    try require(reachedMetric, "metric publication did not reach pre-commit pause")
    engine.cancel()
    pause.release()
    await appending.value
    let completedMetric = await pause.waitUntilCompleted()

    try require(completedMetric, "metric publication attempt did not complete")
    try require(events.snapshot().metrics == 0, "cancel between metric validation and callback leaked metric")
}

private func checkCancelBeforeRevisionCommitSuppressesRevisionAndOutcome() async throws {
    let pause = PublicationPause(.revision)
    let events = EngineEvents()
    let engine = engine(pause: pause) { _, _, _, _, _ in result("recognized") }
    engine.onUpdate = { events.recordUpdate($0.segment) }
    engine.onChunkOutcome = {
        if case .completed(let id) = $0 { events.recordOutcome(id) }
    }
    try await engine.start(localeIdentifier: "en")
    engine.append(chunk())

    let reachedRevision = await pause.waitUntilReached()
    try require(reachedRevision, "revision publication did not reach pre-commit pause")
    engine.cancel()
    pause.release()
    let completedRevision = await pause.waitUntilCompleted()

    try require(completedRevision, "revision publication attempt did not complete")
    let snapshot = events.snapshot()
    try require(snapshot.updates.isEmpty, "cancel between revision validation and callback leaked revision")
    try require(snapshot.outcomes.isEmpty, "cancelled revision path leaked chunk outcome")
}

private func checkRestartBeforeOutcomeCommitSuppressesStaleOutcome() async throws {
    let pause = PublicationPause(.outcome)
    let events = EngineEvents()
    let source = chunk()
    let engine = engine(pause: pause) { _, _, _, _, _ in result("recognized") }
    engine.onChunkOutcome = {
        if case .completed(let id) = $0 { events.recordOutcome(id) }
    }
    try await engine.start(localeIdentifier: "en")
    engine.append(source)

    let reachedOutcome = await pause.waitUntilReached()
    try require(reachedOutcome, "outcome publication did not reach pre-commit pause")
    try await engine.start(localeIdentifier: "en")
    pause.release()
    let completedOutcome = await pause.waitUntilCompleted()

    try require(completedOutcome, "outcome publication attempt did not complete")
    try require(events.snapshot().outcomes.isEmpty, "restart between outcome validation and callback leaked outcome")
    engine.cancel()
}

private func checkCancelBeforeSessionFinalCommitSuppressesFinalAndFinished() async throws {
    let pause = PublicationPause(.sessionFinal)
    let events = EngineEvents()
    let engine = engine(pause: pause) { _, _, _, _, _ in result("unused") }
    engine.onUpdate = { events.recordUpdate($0.segment) }
    engine.onFinished = { events.recordFinished() }
    try await engine.start(localeIdentifier: "en")
    engine.finish()

    let reachedFinal = await pause.waitUntilReached()
    try require(reachedFinal, "session final did not reach pre-commit pause")
    engine.cancel()
    pause.release()
    let completedFinal = await pause.waitUntilCompleted()

    try require(completedFinal, "session-final publication attempt did not complete")
    let snapshot = events.snapshot()
    try require(snapshot.updates.isEmpty, "cancel between final validation and callback leaked session final")
    try require(snapshot.finished == 0, "cancelled final path leaked completion callback")
}

private func checkRestartBeforeFinishedCommitSuppressesStaleFinished() async throws {
    let pause = PublicationPause(.finished)
    let events = EngineEvents()
    let engine = engine(pause: pause) { _, _, _, _, _ in result("unused") }
    engine.onUpdate = { events.recordUpdate($0.segment) }
    engine.onFinished = { events.recordFinished() }
    try await engine.start(localeIdentifier: "en")
    engine.finish()

    let reachedFinished = await pause.waitUntilReached()
    try require(reachedFinished, "finished callback did not reach pre-commit pause")
    try await engine.start(localeIdentifier: "en")
    pause.release()
    let completedFinished = await pause.waitUntilCompleted()

    try require(completedFinished, "finished publication attempt did not complete")
    let snapshot = events.snapshot()
    try require(
        snapshot.updates.map(\.kind) == [.sessionFinal],
        "current session final was not published before restart"
    )
    try require(snapshot.finished == 0, "restart between finished validation and callback leaked completion")
    engine.cancel()
}

private func checkOutcomeCallbackRefillsFIFOAndFinishesWithoutDeadlock() async throws {
    let firstID = UUID()
    let secondID = UUID()
    let sequence = ResultSequence(["first", "second"])
    let events = EngineEvents()
    let completed = DispatchSemaphore(value: 0)
    let engine = engine { _, _, _, _, _ in await sequence.next() }
    engine.onUpdate = { events.recordUpdate($0.segment) }
    engine.onChunkOutcome = { outcome in
        guard case .completed(let id) = outcome else { return }
        events.recordOutcome(id)
        if id == firstID {
            engine.append(chunk(id: secondID))
            engine.finish()
        }
    }
    engine.onFinished = {
        events.recordFinished()
        completed.signal()
    }
    try await engine.start(localeIdentifier: "en")

    engine.append(chunk(id: firstID))
    let didFinish = await waitFor(completed)
    try require(didFinish, "callback refill/finalization deadlocked or finished early")

    let snapshot = events.snapshot()
    try require(
        snapshot.updates.map(\.stableText) == ["first", "second", ""],
        "callback refill did not preserve FIFO revisions before final"
    )
    try require(snapshot.outcomes == [firstID, secondID], "callback refill outcomes were not FIFO")
    try require(snapshot.finished == 1, "refilled queue did not finish exactly once")
}

private func checkSuccessiveWavesKeepDrainingBeforeStop() async throws {
    let events = EngineEvents()
    let outcomeArrived = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let engine = engine { _, _, _, _, _ in result("recognized") }
    engine.onUpdate = { events.recordUpdate($0.segment) }
    engine.onChunkOutcome = { outcome in
        if case .completed(let id) = outcome {
            events.recordOutcome(id)
            outcomeArrived.signal()
        }
    }
    engine.onFinished = {
        events.recordFinished()
        finished.signal()
    }
    try await engine.start(localeIdentifier: "en")
    var ids: [UUID] = []
    for _ in 0..<32 {
        let id = UUID()
        ids.append(id)
        engine.append(chunk(id: id))
        let drained = await waitFor(outcomeArrived)
        try require(drained, "new wave remained queued until recording stop")
    }
    try require(events.snapshot().outcomes == ids, "successive waves lost chunk order")
    try require(events.snapshot().finished == 0, "queue idle incorrectly ended recording")
    engine.finish()
    let didFinish = await waitFor(finished)
    try require(didFinish, "drained session did not finish")
    try require(events.snapshot().finished == 1, "session finished more than once")
}

@main
private struct WhisperRecognitionEngineChecksMain {
    static func main() async {
        let checks: [(String, () async throws -> Void)] = [
            ("metric publication", checkCancelBeforeMetricCommitSuppressesStaleMetric),
            ("revision publication", checkCancelBeforeRevisionCommitSuppressesRevisionAndOutcome),
            ("outcome publication", checkRestartBeforeOutcomeCommitSuppressesStaleOutcome),
            ("session final publication", checkCancelBeforeSessionFinalCommitSuppressesFinalAndFinished),
            ("finished publication", checkRestartBeforeFinishedCommitSuppressesStaleFinished),
            ("callback refill and finalization", checkOutcomeCallbackRefillsFIFOAndFinishesWithoutDeadlock),
            ("successive waves before stop", checkSuccessiveWavesKeepDrainingBeforeStop),
        ]
        var failures: [String] = []
        for (name, check) in checks {
            do {
                try await check()
            } catch {
                failures.append("\(name): \(error)")
            }
        }
        guard failures.isEmpty else {
            let message = failures.joined(separator: "\n")
            FileHandle.standardError.write(Data("Whisper engine checks failed:\n\(message)\n".utf8))
            exit(1)
        }
        print("Whisper recognition engine behavioral checks passed.")
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
