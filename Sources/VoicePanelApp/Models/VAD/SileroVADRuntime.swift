import Foundation
import VoicePanelCore
import sherpa_onnx

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class SileroVADRuntime: @unchecked Sendable {
    struct Configuration: Equatable, Sendable {
        var threshold: Float = 0.5
        var minimumSpeechDuration: TimeInterval = 0.10
        var minimumSilenceDuration: TimeInterval = 0.25
        var maximumSpeechDuration: TimeInterval = 30
    }

    private let detector: OpaquePointer
    private let lock = NSLock()
    private var resampler = StreamingLinearAudioResampler(targetSampleRate: 16_000)

    init(modelURL: URL, configuration: Configuration) throws {
        let pool = SileroVADCStringPool()
        var silero = SherpaOnnxSileroVadModelConfig()
        silero.model = pool.make(modelURL.path)
        silero.threshold = configuration.threshold
        silero.min_silence_duration = Float(configuration.minimumSilenceDuration)
        silero.min_speech_duration = Float(configuration.minimumSpeechDuration)
        silero.window_size = 512
        silero.max_speech_duration = Float(configuration.maximumSpeechDuration)

        var config = SherpaOnnxVadModelConfig()
        config.silero_vad = silero
        config.sample_rate = 16_000
        config.num_threads = 1
        config.provider = pool.make("cpu")
        config.debug = 0

        guard
            let detector = withUnsafePointer(
                to: &config,
                {
                    SherpaOnnxCreateVoiceActivityDetector($0, 60)
                })
        else {
            throw SileroVADRuntimeError.couldNotLoadModel
        }
        self.detector = detector
    }

    deinit {
        SherpaOnnxDestroyVoiceActivityDetector(detector)
    }

    func process(samples: [Float], sampleRate: Double) -> Bool? {
        guard !samples.isEmpty, sampleRate > 0 else { return nil }

        return lock.performSileroLocked {
            processLocked(samples: samples, sampleRate: sampleRate)
        }
    }

    func reset() {
        lock.performSileroLocked {
            resetLocked()
        }
    }

    func detectsSpeech(in chunk: AudioChunk) -> Bool? {
        guard !chunk.samples.isEmpty, chunk.sampleRate > 0 else { return nil }
        return lock.performSileroLocked {
            resetLocked()
            defer { resetLocked() }

            let frameSampleCount = max(1, Int((0.032 * chunk.sampleRate).rounded()))
            var receivedEvidence = false
            var offset = 0
            while offset < chunk.samples.count {
                let upperBound = min(chunk.samples.count, offset + frameSampleCount)
                guard
                    let detected = processLocked(
                        samples: Array(chunk.samples[offset..<upperBound]),
                        sampleRate: chunk.sampleRate
                    )
                else {
                    offset = upperBound
                    continue
                }
                receivedEvidence = true
                if detected { return true }
                offset = upperBound
            }
            return receivedEvidence ? false : nil
        }
    }

    private func processLocked(samples: [Float], sampleRate: Double) -> Bool? {
        let normalizedSamples = resampler.process(samples: samples, from: sampleRate)
        guard !normalizedSamples.isEmpty else { return nil }

        normalizedSamples.withUnsafeBufferPointer { buffer in
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(
                detector,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        let detected = SherpaOnnxVoiceActivityDetectorDetected(detector) == 1
        while SherpaOnnxVoiceActivityDetectorEmpty(detector) == 0 {
            SherpaOnnxVoiceActivityDetectorPop(detector)
        }
        return detected
    }

    private func resetLocked() {
        resampler.reset()
        SherpaOnnxVoiceActivityDetectorReset(detector)
    }
}

enum SileroVADRuntimeError: LocalizedError {
    case couldNotLoadModel

    var errorDescription: String? {
        "Silero VAD could not load its local model."
    }
}

private final class SileroVADCStringPool {
    private var values: [UnsafeMutablePointer<CChar>] = []

    func make(_ value: String) -> UnsafePointer<CChar>? {
        guard let pointer = strdup(value) else { return nil }
        values.append(pointer)
        return UnsafePointer(pointer)
    }

    deinit {
        for value in values { free(value) }
    }
}

extension NSLock {
    fileprivate func performSileroLocked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
