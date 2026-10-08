import Foundation
import VoicePanelCore

final class LocalONNXRecognitionEngine: RecognitionEngine, @unchecked Sendable {
    let audioInputMode: RecognitionAudioInputMode = .vadChunks
    let finalizationTimeout: TimeInterval = 300

    var onUpdate: ((RecognitionUpdate) -> Void)?
    var onFinished: (() -> Void)?
    var onMetrics: ((RecognitionPerformanceMetrics) -> Void)?
    var onChunkOutcome: ((RecognitionChunkOutcome) -> Void)?
    var onError: ((Error) -> Void)?

    var displayName: String { model.title }

    private let model: LocalONNXModelID
    private let runtime: LocalONNXRuntime
    private let policy: OfflineASRChunkPolicy
    private let hallucinationGuardConfiguration: RecognitionHallucinationGuard.Configuration
    private let hallucinationGuard = RecognitionHallucinationGuard()
    private let queue = DispatchQueue(label: "VoicePanel.LocalONNXRecognition", qos: .userInitiated)
    private let lock = NSLock()

    private var generation = 0
    private var active = false
    private var finishing = false
    private var pendingCount = 0
    private var nextSequence = 0

    init(
        model: LocalONNXModelID,
        runtime: LocalONNXRuntime,
        policy: OfflineASRChunkPolicy,
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
            guard self.canPublishAcceptedChunk(session.generation) else { return }

            switch result {
            case .success(let text):
                if !text.isEmpty,
                    self.hallucinationGuard.rejectionReason(
                        for: text,
                        chunk: chunk,
                        configuration: self.hallucinationGuardConfiguration
                    ) == nil
                {
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
        let boundedChunks = splitToSafeMaximum(chunk)
        var texts: [String] = []
        for bounded in boundedChunks {
            texts.append(try transcribeWithRetry(bounded))
        }
        return TranscriptTextMerger.merge(texts)
    }

    private func transcribeWithRetry(_ chunk: AudioChunk) throws -> String {
        let samples = LinearAudioResampler.resampleMono(samples: chunk.samples, from: chunk.sampleRate)
        guard !samples.isEmpty else { return "" }

        var lastError: Error = RecognitionEngineError.localONNXInferenceFailed(model.title)
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

    private func splitToSafeMaximum(_ chunk: AudioChunk) -> [AudioChunk] {
        let maxSamples = max(1, Int(policy.maximumDuration * chunk.sampleRate))
        guard chunk.samples.count > maxSamples else { return [chunk] }
        let overlap = max(0, Int(policy.overlapDuration * chunk.sampleRate))
        let step = max(1, maxSamples - overlap)
        var chunks: [AudioChunk] = []
        var start = 0
        while start < chunk.samples.count {
            let end = min(chunk.samples.count, start + maxSamples)
            chunks.append(
                AudioChunk(
                    samples: Array(chunk.samples[start..<end]),
                    sampleRate: chunk.sampleRate,
                    boundaryReason: end == chunk.samples.count ? chunk.boundaryReason : .maximumDuration,
                    trailingOverlapDuration: end == chunk.samples.count
                        ? chunk.trailingOverlapDuration
                        : Double(max(0, end - min(chunk.samples.count, start + step)))
                            / chunk.sampleRate
                ))
            if end == chunk.samples.count { break }
            start += step
        }
        return chunks
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
