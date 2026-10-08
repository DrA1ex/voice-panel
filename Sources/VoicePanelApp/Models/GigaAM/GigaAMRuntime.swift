import Foundation
import VoicePanelCore
import sherpa_onnx

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class GigaAMRuntime: @unchecked Sendable {
    let model: GigaAMModelID
    private let recognizer: OpaquePointer
    private let lock = NSLock()

    private init(model: GigaAMModelID, recognizer: OpaquePointer) {
        self.model = model
        self.recognizer = recognizer
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    static func load(
        package: GigaAMInstalledPackage,
        numberOfThreads: Int,
        provider: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> GigaAMRuntime {
        let breadcrumb = DiagnosticLogger.shared.beginModelLoad(
            engine: "gigaam",
            modelID: package.model.rawValue,
            modelURL: package.directory
        )
        do {
            let runtime = try await Task.detached(priority: .userInitiated) {
                progress(0.08)
                let pool = GigaAMCStringPool()

                guard let tokensURL = package.url(for: .tokens) else {
                    throw RecognitionEngineError.modelCouldNotBeLoaded(package.directory.path)
                }

                var featureConfig = SherpaOnnxFeatureConfig()
                featureConfig.sample_rate = 16_000
                featureConfig.feature_dim = 64

                var modelConfig = SherpaOnnxOfflineModelConfig()
                modelConfig.tokens = pool.make(tokensURL.path)
                modelConfig.num_threads = Int32(max(1, numberOfThreads))
                modelConfig.provider = pool.make(provider)
                modelConfig.debug = 0

                switch package.model.architecture {
                case .ctc:
                    guard let modelURL = package.url(for: .model) else {
                        throw RecognitionEngineError.modelCouldNotBeLoaded(package.directory.path)
                    }
                    var ctc = SherpaOnnxOfflineNemoEncDecCtcModelConfig()
                    ctc.model = pool.make(modelURL.path)
                    modelConfig.nemo_ctc = ctc

                case .rnnt:
                    guard let encoder = package.url(for: .encoder),
                        let decoder = package.url(for: .decoder),
                        let joiner = package.url(for: .joiner)
                    else {
                        throw RecognitionEngineError.modelCouldNotBeLoaded(package.directory.path)
                    }
                    var transducer = SherpaOnnxOfflineTransducerModelConfig()
                    transducer.encoder = pool.make(encoder.path)
                    transducer.decoder = pool.make(decoder.path)
                    transducer.joiner = pool.make(joiner.path)
                    modelConfig.transducer = transducer
                }

                progress(0.32)
                var recognizerConfig = SherpaOnnxOfflineRecognizerConfig()
                recognizerConfig.feat_config = featureConfig
                recognizerConfig.model_config = modelConfig
                recognizerConfig.decoding_method = pool.make("greedy_search")
                recognizerConfig.max_active_paths = 4
                recognizerConfig.hotwords_score = 1.5

                progress(0.55)
                let recognizer = withUnsafePointer(to: &recognizerConfig) {
                    SherpaOnnxCreateOfflineRecognizer($0)
                }
                guard let recognizer else {
                    throw RecognitionEngineError.modelCouldNotBeLoaded(package.directory.path)
                }
                progress(1)
                return GigaAMRuntime(model: package.model, recognizer: recognizer)
            }.value
            DiagnosticLogger.shared.endModelLoad(
                token: breadcrumb,
                engine: "gigaam",
                modelID: package.model.rawValue,
                result: "ready"
            )
            return runtime
        } catch {
            DiagnosticLogger.shared.endModelLoad(
                token: breadcrumb,
                engine: "gigaam",
                modelID: package.model.rawValue,
                result: error.localizedDescription
            )
            throw error
        }
    }

    func transcribe(samples: [Float]) throws -> String {
        guard !samples.isEmpty else { return "" }
        guard GigaAMInferenceLimit.accepts(sampleCount: samples.count) else {
            throw RecognitionEngineError.gigaAMInputTooLong(
                actualDuration: Double(samples.count) / GigaAMInferenceLimit.sampleRate,
                maximumDuration: GigaAMInferenceLimit.maximumDuration
            )
        }
        return try lock.performLocked {
            guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
                throw RecognitionEngineError.inferenceFailed
            }
            defer { SherpaOnnxDestroyOfflineStream(stream) }

            samples.withUnsafeBufferPointer { buffer in
                SherpaOnnxAcceptWaveformOffline(
                    stream,
                    16_000,
                    buffer.baseAddress,
                    Int32(buffer.count)
                )
            }
            SherpaOnnxDecodeOfflineStream(recognizer, stream)

            guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
                throw RecognitionEngineError.inferenceFailed
            }
            defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
            guard let text = result.pointee.text else { return "" }
            return TranscriptTextNormalizer.normalize(String(cString: text))
        }
    }
}

private final class GigaAMCStringPool {
    private var values: [UnsafeMutablePointer<CChar>] = []

    func make(_ value: String) -> UnsafePointer<CChar>? {
        guard let pointer = strdup(value) else { return nil }
        values.append(pointer)
        return UnsafePointer(pointer)
    }

    deinit {
        for value in values {
            free(value)
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
