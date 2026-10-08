import Foundation
import VoicePanelCore
import sherpa_onnx

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class LocalONNXRuntime: @unchecked Sendable {
    let model: LocalONNXModelID
    private let recognizer: OpaquePointer
    private let lock = NSLock()

    private init(model: LocalONNXModelID, recognizer: OpaquePointer) {
        self.model = model
        self.recognizer = recognizer
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    static func load(
        package: LocalONNXInstalledPackage,
        numberOfThreads: Int,
        provider: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> LocalONNXRuntime {
        let breadcrumb = DiagnosticLogger.shared.beginModelLoad(
            engine: package.model.family.rawValue,
            modelID: package.model.rawValue,
            modelURL: package.directory
        )
        do {
            let runtime = try await Task.detached(priority: .userInitiated) {
                progress(0.08)
                let pool = LocalONNXCStringPool()

                var featureConfig = SherpaOnnxFeatureConfig()
                featureConfig.sample_rate = 16_000
                featureConfig.feature_dim = 80

                var modelConfig = SherpaOnnxOfflineModelConfig()
                modelConfig.num_threads = Int32(max(1, numberOfThreads))
                modelConfig.provider = pool.make(provider)
                modelConfig.debug = 0

                switch package.model.family {
                case .qwen3ASR:
                    guard let convFrontend = package.url(for: .convFrontend),
                        let encoder = package.url(for: .encoder),
                        let decoder = package.url(for: .decoder)
                    else {
                        throw RecognitionEngineError.modelCouldNotBeLoaded(package.directory.path)
                    }
                    var qwen = SherpaOnnxOfflineQwen3ASRModelConfig()
                    qwen.conv_frontend = pool.make(convFrontend.path)
                    qwen.encoder = pool.make(encoder.path)
                    qwen.decoder = pool.make(decoder.path)
                    qwen.tokenizer = pool.make(package.tokenizerDirectory.path)
                    qwen.max_total_len = 512
                    qwen.max_new_tokens = 512
                    qwen.temperature = 0.000_001
                    qwen.top_p = 0.8
                    qwen.seed = 42
                    qwen.hotwords = pool.make("")
                    modelConfig.qwen3_asr = qwen

                case .parakeet:
                    guard let encoder = package.url(for: .encoder),
                        let decoder = package.url(for: .decoder),
                        let joiner = package.url(for: .joiner),
                        let tokens = package.url(for: .tokens)
                    else {
                        throw RecognitionEngineError.modelCouldNotBeLoaded(package.directory.path)
                    }
                    var transducer = SherpaOnnxOfflineTransducerModelConfig()
                    transducer.encoder = pool.make(encoder.path)
                    transducer.decoder = pool.make(decoder.path)
                    transducer.joiner = pool.make(joiner.path)
                    modelConfig.transducer = transducer
                    modelConfig.tokens = pool.make(tokens.path)
                    modelConfig.model_type = pool.make("nemo_transducer")
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
                return LocalONNXRuntime(model: package.model, recognizer: recognizer)
            }.value
            DiagnosticLogger.shared.endModelLoad(
                token: breadcrumb,
                engine: package.model.family.rawValue,
                modelID: package.model.rawValue,
                result: "ready"
            )
            return runtime
        } catch {
            DiagnosticLogger.shared.endModelLoad(
                token: breadcrumb,
                engine: package.model.family.rawValue,
                modelID: package.model.rawValue,
                result: error.localizedDescription
            )
            throw error
        }
    }

    func transcribe(samples: [Float]) throws -> String {
        guard !samples.isEmpty else { return "" }
        return try lock.performLocked {
            guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
                throw RecognitionEngineError.localONNXInferenceFailed(model.title)
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
                throw RecognitionEngineError.localONNXInferenceFailed(model.title)
            }
            defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
            guard let text = result.pointee.text else { return "" }
            return TranscriptTextNormalizer.normalize(String(cString: text))
        }
    }
}

private final class LocalONNXCStringPool {
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
