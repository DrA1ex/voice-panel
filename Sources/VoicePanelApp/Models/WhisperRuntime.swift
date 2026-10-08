import Foundation
import VoicePanelCore
import whisper

enum WhisperRuntimeError: LocalizedError {
    case modelReadFailed
    case modelInitializationFailed

    var errorDescription: String? {
        switch self {
        case .modelReadFailed: return "The Whisper model file could not be read."
        case .modelInitializationFailed: return "whisper.cpp could not initialize the selected model."
        }
    }
}

private final class WhisperInferenceRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class WhisperRuntime: @unchecked Sendable {
    let model: WhisperModelID
    let runtimeConfiguration: WhisperRuntimeConfiguration

    private static let loaderQueue = DispatchQueue(
        label: "io.github.dra1ex.voicepanel.whisper.loader", qos: .userInitiated)
    private let queue = DispatchQueue(
        label: "io.github.dra1ex.voicepanel.whisper.runtime", qos: .userInitiated)
    private var context: OpaquePointer?

    private init(
        model: WhisperModelID,
        runtimeConfiguration: WhisperRuntimeConfiguration,
        context: OpaquePointer
    ) {
        self.model = model
        self.runtimeConfiguration = runtimeConfiguration
        self.context = context
    }

    deinit { if let context { whisper_free(context) } }

    static func load(
        model: WhisperModelID,
        preparedFiles: WhisperPreparedRuntimeFiles,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> WhisperRuntime {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: preparedFiles.modelFileURL.path)
        guard let size = attributes[FileAttributeKey.size] as? NSNumber,
            size.int64Value >= model.minimumExpectedByteCount
        else {
            throw WhisperRuntimeError.modelReadFailed
        }
        try Task.checkCancellation()
        progress(0.08)
        let configuration = preparedFiles.configuration
        let breadcrumb = DiagnosticLogger.shared.beginModelLoad(
            engine: "whisper", modelID: model.rawValue, modelURL: preparedFiles.runtimeModelURL
        )
        do {
            let runtime = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<WhisperRuntime, Error>) in
                loaderQueue.async {
                    var params = whisper_context_default_params()
                    params.use_gpu = configuration.useGPU
                    params.flash_attn = configuration.useFlashAttention
                    let loadedContext = preparedFiles.runtimeModelURL.path.withCString { path in
                        whisper_init_from_file_with_params(path, params)
                    }
                    guard let loadedContext else {
                        continuation.resume(throwing: WhisperRuntimeError.modelInitializationFailed)
                        return
                    }
                    progress(1)
                    continuation.resume(
                        returning: WhisperRuntime(
                            model: model,
                            runtimeConfiguration: configuration,
                            context: loadedContext
                        ))
                }
            }
            try Task.checkCancellation()
            DiagnosticLogger.shared.endModelLoad(
                token: breadcrumb, engine: "whisper", modelID: model.rawValue, result: "ready"
            )
            DiagnosticLogger.shared.info(
                "Whisper runtime loaded",
                metadata: [
                    "compute": configuration.displayTitle,
                    "flashAttention": String(configuration.useFlashAttention),
                    "model": model.rawValue,
                ]
            )
            return runtime
        } catch {
            DiagnosticLogger.shared.endModelLoad(
                token: breadcrumb, engine: "whisper", modelID: model.rawValue,
                result: error.localizedDescription
            )
            throw error
        }
    }

    func transcribe(
        samples: [Float],
        languageCode: String,
        configuration: WhisperInferenceConfiguration,
        initialPromptProvider: (@Sendable () -> String)? = nil,
        metadataLevel: WhisperInferenceMetadataLevel = .segments,
        completion: @escaping @Sendable (Result<WhisperTranscriptionResult, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, let context = self.context else {
                completion(.failure(WhisperRuntimeError.modelInitializationFailed))
                return
            }
            do {
                let initialPrompt =
                    initialPromptProvider?() ?? configuration.normalizedInitialPrompt
                completion(
                    .success(
                        try self.transcribeNow(
                            samples: samples,
                            languageCode: languageCode,
                            configuration: configuration,
                            initialPrompt: initialPrompt,
                            metadataLevel: metadataLevel,
                            request: WhisperInferenceRequest(),
                            context: context
                        )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func transcribe(
        samples: [Float],
        languageCode: String,
        configuration: WhisperInferenceConfiguration,
        initialPrompt: String,
        metadataLevel: WhisperInferenceMetadataLevel
    ) async throws -> WhisperTranscriptionResult {
        let request = WhisperInferenceRequest()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<WhisperTranscriptionResult, Error>) in
                queue.async { [self] in
                    guard let context else {
                        continuation.resume(
                            throwing: WhisperRuntimeError.modelInitializationFailed)
                        return
                    }
                    do {
                        guard !request.isCancelled else { throw CancellationError() }
                        continuation.resume(
                            returning: try transcribeNow(
                                samples: samples,
                                languageCode: languageCode,
                                configuration: configuration,
                                initialPrompt: initialPrompt,
                                metadataLevel: metadataLevel,
                                request: request,
                                context: context
                            ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            request.cancel()
        }
    }

    func afterPending(_ completion: @escaping @Sendable () -> Void) {
        queue.async(execute: completion)
    }

    private func transcribeNow(
        samples: [Float],
        languageCode: String,
        configuration: WhisperInferenceConfiguration,
        initialPrompt: String,
        metadataLevel: WhisperInferenceMetadataLevel,
        request: WhisperInferenceRequest,
        context: OpaquePointer
    ) throws -> WhisperTranscriptionResult {
        let strategy: whisper_sampling_strategy =
            configuration.usesCustomDecoding
                && configuration.decodingStrategy == .beamSearch
            ? WHISPER_SAMPLING_BEAM_SEARCH
            : WHISPER_SAMPLING_GREEDY
        var params = whisper_full_default_params(strategy)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        // Keep every inference independent. Continuity is supplied through a
        // bounded explicit prompt built from accepted VoicePanel results, so a
        // rejected hallucination or natural pause cannot contaminate later chunks.
        params.no_context = true
        switch metadataLevel {
        case .segments:
            params.no_timestamps = true
            params.token_timestamps = false
            params.split_on_word = false
        case .segmentTimestamps:
            params.no_timestamps = false
            params.token_timestamps = false
            params.split_on_word = false
        case .tokenTimestamps:
            params.no_timestamps = false
            params.token_timestamps = true
            params.split_on_word = true
        }
        params.single_segment = false
        params.suppress_blank = true
        params.suppress_nst = true
        params.tdrz_enable = model.supportsDiarization
        // In whisper.cpp `detect_language` is a detection-only mode: the call
        // returns immediately after choosing a language and produces no text.
        // Passing `auto` as the language performs detection and then continues
        // with normal transcription.
        params.detect_language = false
        params.n_threads = Int32(max(1, min(16, configuration.numberOfThreads)))
        if configuration.usesCustomDecoding {
            params.greedy.best_of = Int32(max(1, min(8, configuration.greedyBestOf)))
            params.beam_search.beam_size = Int32(max(1, min(10, configuration.beamSize)))
        }

        let prompt = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let preparedSamples = WhisperAudioPreparation.paddedToMinimumDuration(samples)
        let retainedRequest = Unmanaged.passRetained(request)
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<WhisperInferenceRequest>.fromOpaque(userData)
                .takeUnretainedValue().isCancelled
        }
        params.abort_callback_user_data = retainedRequest.toOpaque()
        defer { retainedRequest.release() }

        let inferenceStarted = Date()
        let result: Int32 = languageCode.withCString { language in
            params.language = language
            let run: (UnsafePointer<CChar>?) -> Int32 = { promptPointer in
                params.initial_prompt = promptPointer
                return preparedSamples.withUnsafeBufferPointer { buffer in
                    whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                }
            }
            return prompt.isEmpty ? run(nil) : prompt.withCString(run)
        }
        let inferenceDuration = Date().timeIntervalSince(inferenceStarted)
        guard result == 0 else {
            if request.isCancelled {
                throw CancellationError()
            }
            DiagnosticLogger.shared.error(
                "Whisper inference failed",
                metadata: [
                    "compute": runtimeConfiguration.displayTitle,
                    "decoding": configuration.usesCustomDecoding
                        ? configuration.decodingStrategy.rawValue : "whisper-default",
                    "language": languageCode,
                    "model": model.rawValue,
                    "result": String(result),
                    "seconds": String(format: "%.3f", Double(samples.count) / 16_000),
                    "paddedSeconds": String(format: "%.3f", Double(preparedSamples.count) / 16_000),
                ]
            )
            throw RecognitionEngineError.inferenceFailed
        }
        var text = ""
        var segments: [WhisperSegmentEvidence] = []
        let count = whisper_full_n_segments(context)
        if count > 0 {
            for index in 0..<count {
                let segmentText = String(
                    cString: whisper_full_get_segment_text(context, index))
                text += segmentText
                var tokens: [WhisperTokenEvidence] = []
                let tokenCount = whisper_full_n_tokens(context, index)
                if tokenCount > 0 {
                    tokens.reserveCapacity(Int(tokenCount))
                    for tokenIndex in 0..<tokenCount {
                        let tokenText = String(
                            cString: whisper_full_get_token_text(context, index, tokenIndex))
                        let tokenStartTime: TimeInterval?
                        let tokenEndTime: TimeInterval?
                        if metadataLevel == .tokenTimestamps {
                            let tokenData = whisper_full_get_token_data(
                                context, index, tokenIndex)
                            tokenStartTime =
                                tokenData.t0 >= 0
                                ? Self.seconds(fromWhisperTimestamp: tokenData.t0) : nil
                            tokenEndTime =
                                tokenData.t1 >= 0
                                ? Self.seconds(fromWhisperTimestamp: tokenData.t1) : nil
                        } else {
                            tokenStartTime = nil
                            tokenEndTime = nil
                        }
                        tokens.append(
                            WhisperTokenEvidence(
                                text: tokenText,
                                startTime: tokenStartTime,
                                endTime: tokenEndTime,
                                probability: Double(
                                    whisper_full_get_token_p(context, index, tokenIndex))
                            ))
                    }
                }
                segments.append(
                    WhisperSegmentEvidence(
                        text: segmentText,
                        startTime: Self.seconds(
                            fromWhisperTimestamp: whisper_full_get_segment_t0(context, index)),
                        endTime: Self.seconds(
                            fromWhisperTimestamp: whisper_full_get_segment_t1(context, index)),
                        noSpeechProbability: Double(
                            whisper_full_get_segment_no_speech_prob(context, index)),
                        tokens: tokens
                    ))
            }
        }
        let normalized = TranscriptTextNormalizer.normalize(text)
        let detectedLanguageID = whisper_full_lang_id(context)
        let detectedLanguage =
            whisper_lang_str(detectedLanguageID).map(String.init(cString:))
            ?? languageCode
        DiagnosticLogger.shared.info(
            normalized.isEmpty ? "Whisper inference produced no text" : "Whisper inference completed",
            metadata: [
                "characters": String(normalized.count),
                "compute": runtimeConfiguration.displayTitle,
                "decoding": configuration.usesCustomDecoding
                    ? configuration.decodingStrategy.rawValue : "whisper-default",
                "language": languageCode,
                "model": model.rawValue,
                "seconds": String(format: "%.3f", Double(samples.count) / 16_000),
                "paddedSeconds": String(format: "%.3f", Double(preparedSamples.count) / 16_000),
                "promptCharacters": String(prompt.count),
                "segments": String(count),
            ]
        )
        return WhisperTranscriptionResult(
            text: normalized,
            segments: segments,
            detectedLanguage: detectedLanguage,
            inferenceDuration: inferenceDuration
        )
    }

    private static func seconds(fromWhisperTimestamp value: Int64) -> TimeInterval {
        Double(value) / 100.0
    }
}
