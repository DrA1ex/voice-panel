import Foundation
import VoicePanelCore

final class GigaAMRecognitionEngine: RecognitionEngine, @unchecked Sendable {
    let audioInputMode: RecognitionAudioInputMode = .vadChunks
    let finalizationTimeout: TimeInterval = 180

    var onUpdate: ((RecognitionUpdate) -> Void)?
    var onFinished: (() -> Void)?
    var onMetrics: ((RecognitionPerformanceMetrics) -> Void)?
    var onChunkOutcome: ((RecognitionChunkOutcome) -> Void)?
    var onError: ((Error) -> Void)?

    var displayName: String { "GigaAM · \(model.title)" }

    private let model: GigaAMModelID
    private let runtime: GigaAMRuntime
    private let policy: GigaAMChunkPolicy
    private let hallucinationGuardConfiguration: RecognitionHallucinationGuard.Configuration
    private let hallucinationGuard = RecognitionHallucinationGuard()
    private let queue = DispatchQueue(label: "VoicePanel.GigaAMRecognition", qos: .userInitiated)
    private let lock = NSLock()

    private var generation = 0
    private var active = false
    private var finishing = false
    private var pendingCount = 0
    private var nextSequence = 0

    init(
        model: GigaAMModelID,
        runtime: GigaAMRuntime,
        policy: GigaAMChunkPolicy,
        hallucinationGuardConfiguration: RecognitionHallucinationGuard.Configuration = .disabled
    ) {
        self.model = model
        self.runtime = runtime
        self.policy = policy.normalized()
        self.hallucinationGuardConfiguration = hallucinationGuardConfiguration
    }

    func requestAuthorization() async throws {}

    func start(localeIdentifier: String) async throws {
        cancel()
        lock.performLocked {
            generation += 1
            active = true
            finishing = false
            pendingCount = 0
            nextSequence = 0
        }
    }

    func append(_ chunk: AudioChunk) {
        let session: (generation: Int, sequence: Int)? = lock.performLocked {
            guard active, !finishing else { return nil }
            let sequence = nextSequence
            nextSequence += 1
            pendingCount += 1
            return (generation, sequence)
        }
        guard let session else { return }
        publishMetrics(chunk: chunk, processingDuration: 0)

        queue.async { [weak self] in
            guard let self else { return }
            let started = Date()
            let result: Result<String, Error>
            do {
                let text = try self.transcribeWithRecovery(chunk)
                result = .success(text)
            } catch {
                result = .failure(error)
            }
            let elapsed = Date().timeIntervalSince(started)
            let remaining = self.lock.performLocked {
                self.pendingCount = max(0, self.pendingCount - 1)
                return self.pendingCount
            }
            self.publishMetrics(chunk: chunk, processingDuration: elapsed, queueDepth: remaining)
            // A queued chunk remains part of the session after finish() has
            // closed the input queue. Keep its result instead of discarding the
            // final phrase just because finalization is in progress.
            guard self.canPublishAcceptedChunk(session.generation) else { return }

            switch result {
            case .success(let text):
                if !text.isEmpty,
                    let reason = self.hallucinationGuard.rejectionReason(
                        for: text,
                        chunk: chunk,
                        configuration: self.hallucinationGuardConfiguration
                    )
                {
                    _ = reason
                } else if !text.isEmpty {
                    self.onUpdate?(
                        RecognitionUpdate(
                            segment: TranscriptSegmentUpdate(
                                segmentID: chunk.id,
                                sequence: session.sequence,
                                stableText: text,
                                partialText: "",
                                kind: .segmentFinal
                            ),
                            shouldDimPartialText: false
                        ))
                }
                self.onChunkOutcome?(.completed(chunk.id))
            case .failure(let error):
                self.onChunkOutcome?(.failed(chunk.id, message: error.localizedDescription))
            }
        }
    }

    func finish() {
        let sessionGeneration: Int? = lock.performLocked {
            guard active else { return nil }
            finishing = true
            return generation
        }
        guard let sessionGeneration else { return }

        queue.async { [weak self] in
            guard let self, self.isCurrent(sessionGeneration, allowFinishing: true) else { return }
            let sequence = self.lock.performLocked { self.nextSequence }
            self.onUpdate?(
                RecognitionUpdate(
                    segment: TranscriptSegmentUpdate(
                        segmentID: UUID(),
                        sequence: sequence,
                        stableText: "",
                        partialText: "",
                        kind: .sessionFinal
                    ),
                    shouldDimPartialText: false
                ))
            self.lock.performLocked {
                self.active = false
                self.finishing = false
            }
            self.onFinished?()
        }
    }

    func cancel() {
        lock.performLocked {
            generation += 1
            active = false
            finishing = false
            pendingCount = 0
        }
    }

    private func transcribeWithRecovery(_ chunk: AudioChunk) throws -> String {
        let boundedChunks = policy.chunksBoundedToInferenceLimit(chunk)
        var texts: [String] = []
        for bounded in boundedChunks {
            texts.append(try transcribeWithRetry(bounded))
        }
        return TranscriptTextMerger.merge(texts)
    }

    private func transcribeWithRetry(_ chunk: AudioChunk) throws -> String {
        let samples = LinearAudioResampler.resampleMono(samples: chunk.samples, from: chunk.sampleRate)
        guard !samples.isEmpty else { return "" }

        var lastError: Error = RecognitionEngineError.gigaAMInferenceFailed
        for _ in 0...policy.retryCount {
            do { return try runtime.transcribe(samples: samples) } catch { lastError = error }
        }

        let split = policy.split(
            AudioChunk(
                samples: samples,
                sampleRate: 16_000,
                boundaryReason: chunk.boundaryReason,
                trailingOverlapDuration: chunk.trailingOverlapDuration
            ))
        guard split.count > 1 else { throw lastError }
        return try TranscriptTextMerger.merge(
            split.map { part in
                try runtime.transcribe(samples: part.samples)
            })
    }

    private func publishMetrics(
        chunk: AudioChunk,
        processingDuration: TimeInterval,
        queueDepth: Int? = nil
    ) {
        onMetrics?(
            RecognitionPerformanceMetrics(
                engineName: displayName,
                queueDepth: queueDepth ?? lock.performLocked { pendingCount },
                chunkDuration: chunk.duration,
                processingDuration: processingDuration
            ))
    }

    private func isCurrent(_ expectedGeneration: Int, allowFinishing: Bool = false) -> Bool {
        lock.performLocked {
            generation == expectedGeneration && active && (allowFinishing || !finishing)
        }
    }

    private func canPublishAcceptedChunk(_ expectedGeneration: Int) -> Bool {
        lock.performLocked {
            RecognitionQueuedResultPolicy.shouldPublish(
                generationMatches: generation == expectedGeneration,
                sessionIsActive: active
            )
        }
    }
}

extension NSLock {
    fileprivate func performLocked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
