#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cd "$ROOT_DIR"
"$SWIFT_BIN" build "${VOICEPANEL_SWIFT_BUILD_ARGS[@]}" --target VoicePanelCore >/dev/null
CORE_BIN_DIR="$(
    "$SWIFT_BIN" build "${VOICEPANEL_SWIFT_BUILD_ARGS[@]}" --show-bin-path
)"
CORE_MODULE="$CORE_BIN_DIR/Modules/VoicePanelCore.swiftmodule"
if [[ ! -f "$CORE_MODULE" ]]; then
    echo "VoicePanelCore module was not produced." >&2
    exit 1
fi
CORE_MODULE_DIR="$(dirname "$CORE_MODULE")"
CORE_IMPORT_ARGS=(-I "$CORE_MODULE_DIR")
CORE_BUILD_DIR="$(dirname "$CORE_MODULE_DIR")/VoicePanelCore.build"
CORE_OBJECTS=()
for core_source in "$ROOT_DIR"/Sources/VoicePanelCore/*.swift; do
    core_object="$CORE_BUILD_DIR/$(basename "$core_source").o"
    if [[ -f "$core_object" ]]; then
        CORE_OBJECTS+=("$core_object")
    fi
done
CRYPTO_MODULE_MAP="$CORE_BIN_DIR/VoicePanelCryptoCompat.build/module.modulemap"
if [[ -f "$CRYPTO_MODULE_MAP" ]]; then
    CORE_IMPORT_ARGS+=(-Xcc "-fmodule-map-file=$CRYPTO_MODULE_MAP")
fi

mkdir -p "$TMP_DIR/whisper"
cat > "$TMP_DIR/whisper/whisper.h" <<'HEADER'
#ifndef VOICEPANEL_WHISPER_TYPECHECK_H
#define VOICEPANEL_WHISPER_TYPECHECK_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct whisper_context;
typedef int32_t whisper_token;

typedef struct whisper_token_data {
    whisper_token id;
    whisper_token tid;
    float p;
    float plog;
    float pt;
    float ptsum;
    int64_t t0;
    int64_t t1;
    int64_t t_dtw;
    float vlen;
} whisper_token_data;

typedef bool (*ggml_abort_callback)(void * data);

enum whisper_sampling_strategy {
    WHISPER_SAMPLING_GREEDY,
    WHISPER_SAMPLING_BEAM_SEARCH,
};

struct whisper_context_params {
    bool use_gpu;
    bool flash_attn;
    int gpu_device;
    bool dtw_token_timestamps;
    int dtw_aheads_preset;
    int dtw_n_top;
    size_t dtw_mem_size;
};

struct whisper_full_params {
    enum whisper_sampling_strategy strategy;
    int n_threads;
    int n_max_text_ctx;
    int offset_ms;
    int duration_ms;
    bool translate;
    bool no_context;
    bool no_timestamps;
    bool single_segment;
    bool print_special;
    bool print_progress;
    bool print_realtime;
    bool print_timestamps;
    bool token_timestamps;
    bool thold_pt;
    bool thold_ptsum;
    bool max_len;
    bool split_on_word;
    int max_tokens;
    bool debug_mode;
    int audio_ctx;
    bool tdrz_enable;
    const char * suppress_regex;
    const char * initial_prompt;
    const int32_t * prompt_tokens;
    int prompt_n_tokens;
    const char * language;
    bool detect_language;
    bool suppress_blank;
    bool suppress_nst;
    float temperature;
    float max_initial_ts;
    float length_penalty;
    float temperature_inc;
    float entropy_thold;
    float logprob_thold;
    float no_speech_thold;
    struct {
        int best_of;
    } greedy;
    struct {
        int beam_size;
        float patience;
    } beam_search;
    ggml_abort_callback abort_callback;
    void * abort_callback_user_data;
};

struct whisper_context_params whisper_context_default_params(void);
struct whisper_full_params whisper_full_default_params(enum whisper_sampling_strategy strategy);
struct whisper_context * whisper_init_from_file_with_params(const char * path_model, struct whisper_context_params params);
void whisper_free(struct whisper_context * ctx);
int whisper_full(struct whisper_context * ctx, struct whisper_full_params params, const float * samples, int n_samples);
int whisper_full_n_segments(struct whisper_context * ctx);
int whisper_full_lang_id(struct whisper_context * ctx);
int64_t whisper_full_get_segment_t0(struct whisper_context * ctx, int i_segment);
int64_t whisper_full_get_segment_t1(struct whisper_context * ctx, int i_segment);
const char * whisper_full_get_segment_text(struct whisper_context * ctx, int i_segment);
int whisper_full_n_tokens(struct whisper_context * ctx, int i_segment);
const char * whisper_full_get_token_text(struct whisper_context * ctx, int i_segment, int i_token);
whisper_token_data whisper_full_get_token_data(struct whisper_context * ctx, int i_segment, int i_token);
float whisper_full_get_token_p(struct whisper_context * ctx, int i_segment, int i_token);
float whisper_full_get_segment_no_speech_prob(struct whisper_context * ctx, int i_segment);
int whisper_lang_max_id(void);
const char * whisper_lang_str(int id);
const char * whisper_lang_str_full(int id);

#endif
HEADER
cat > "$TMP_DIR/whisper/module.modulemap" <<'MODULE'
module whisper [system] {
    header "whisper.h"
    export *
}
MODULE

cat > "$TMP_DIR/WhisperBridgeTypecheckSupport.swift" <<'SWIFT'
import Foundation
import VoicePanelCore

enum WhisperModelID: String, Sendable {
    case tiny
    var title: String { "Whisper Tiny" }
    var supportsDiarization: Bool { false }
    var minimumExpectedByteCount: Int64 { 1 }
}

struct WhisperPreparedRuntimeFiles: Sendable {
    let modelFileURL: URL
    let runtimeModelURL: URL
    let configuration: WhisperRuntimeConfiguration
}

#if VOICEPANEL_ENGINE_TESTING
final class WhisperRuntime: @unchecked Sendable {
    let runtimeConfiguration = WhisperRuntimeConfiguration(
        requestedComputeMode: .cpu,
        flashAttention: false
    )
    private let implementation: WhisperBoundaryTranscriber

    init(transcribe: @escaping WhisperBoundaryTranscriber) {
        implementation = transcribe
    }

    func transcribe(
        samples: [Float],
        languageCode: String,
        configuration: WhisperInferenceConfiguration,
        initialPrompt: String,
        metadataLevel: WhisperInferenceMetadataLevel
    ) async throws -> WhisperTranscriptionResult {
        try await implementation(
            samples,
            languageCode,
            configuration,
            initialPrompt,
            metadataLevel
        )
    }
}
#endif

final class DiagnosticLogger: @unchecked Sendable {
    static let shared = DiagnosticLogger()
    func beginModelLoad(engine: String, modelID: String, modelURL: URL) -> UUID { UUID() }
    func endModelLoad(token: UUID, engine: String, modelID: String, result: String) {}
    func info(_ message: String, metadata: [String: String] = [:]) {}
    func error(_ message: String, metadata: [String: String] = [:]) {}
}

enum RecognitionEngineError: Error {
    case inferenceFailed
}

enum RecognitionAudioInputMode {
    case continuousBuffers
    case vadChunks
}

struct RecognitionUpdate {
    let segment: TranscriptSegmentUpdate
    let shouldDimPartialText: Bool
}

enum RecognitionChunkOutcome {
    case completed(UUID)
    case failed(UUID, message: String)
    case cancelled(UUID)
}

struct RecognitionPerformanceMetrics {
    let engineName: String
    let queueDepth: Int
    let chunkDuration: TimeInterval
    let processingDuration: TimeInterval

    var realTimeFactor: Double {
        chunkDuration > 0 ? processingDuration / chunkDuration : 0
    }
}

protocol RecognitionEngine: AnyObject {
    var audioInputMode: RecognitionAudioInputMode { get }
    var finalizationTimeout: TimeInterval { get }
    var displayName: String { get }
    var onUpdate: ((RecognitionUpdate) -> Void)? { get set }
    var onFinished: (() -> Void)? { get set }
    var onMetrics: ((RecognitionPerformanceMetrics) -> Void)? { get set }
    var onChunkOutcome: ((RecognitionChunkOutcome) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    func requestAuthorization() async throws
    func start(localeIdentifier: String) async throws
    func append(_ chunk: AudioChunk)
    func finish()
    func cancel()
}

func requireStructuredWhisperRuntimeAPI(
    _ runtime: WhisperRuntime,
    configuration: WhisperInferenceConfiguration
) async throws {
    let segmentEvidence: WhisperTranscriptionResult = try await runtime.transcribe(
        samples: [0],
        languageCode: "auto",
        configuration: configuration,
        initialPrompt: "",
        metadataLevel: .segments
    )
    let timestampEvidence: WhisperTranscriptionResult = try await runtime.transcribe(
        samples: [0],
        languageCode: "auto",
        configuration: configuration,
        initialPrompt: "",
        metadataLevel: .tokenTimestamps
    )
    _ = (segmentEvidence.text, timestampEvidence.tokens)
}
SWIFT

"$SWIFTC_BIN" \
    "${VOICEPANEL_SWIFTC_ARGS[@]}" \
    -typecheck \
    -swift-version 5 \
    -I "$TMP_DIR" \
    "${CORE_IMPORT_ARGS[@]}" \
    "$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperRuntimeConfiguration.swift" \
    "$TMP_DIR/WhisperBridgeTypecheckSupport.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperRuntime.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Recognition/WhisperBoundaryProcessor.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperBenchmarkChunkClassification.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Recognition/WhisperEngineLifecycleExecutor.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Recognition/WhisperRecognitionEngine.swift"

if [[ "$(uname -s)" == "Darwin" ]]; then
    "$SWIFTC_BIN" \
        "${VOICEPANEL_SWIFTC_ARGS[@]}" \
        -swift-version 5 \
        "${CORE_IMPORT_ARGS[@]}" \
        "$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperRuntimeConfiguration.swift" \
        "$ROOT_DIR/Sources/VoicePanelApp/Recognition/WhisperBoundaryProcessor.swift" \
        "$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperBenchmarkChunkClassification.swift" \
        "$ROOT_DIR/Tests/VoicePanelAppChecks/WhisperBoundaryProcessorChecks.swift" \
        "${CORE_OBJECTS[@]}" \
        -o "$TMP_DIR/WhisperBoundaryProcessorChecks"
    "$TMP_DIR/WhisperBoundaryProcessorChecks"

    "$SWIFTC_BIN" \
        "${VOICEPANEL_SWIFTC_ARGS[@]}" \
        -swift-version 5 \
        "${CORE_IMPORT_ARGS[@]}" \
        "$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperRuntimeConfiguration.swift" \
        "$ROOT_DIR/Sources/VoicePanelApp/Recognition/RecognitionEngine.swift" \
        "$ROOT_DIR/Sources/VoicePanelApp/Recognition/WhisperBoundaryProcessor.swift" \
        "$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperBoundaryBenchmarkExecutor.swift" \
        "$ROOT_DIR/Tests/VoicePanelAppChecks/WhisperBoundaryBenchmarkExecutorChecks.swift" \
        "${CORE_OBJECTS[@]}" \
        -o "$TMP_DIR/WhisperBoundaryBenchmarkExecutorChecks"
    "$TMP_DIR/WhisperBoundaryBenchmarkExecutorChecks"

    "$SWIFTC_BIN" \
        "${VOICEPANEL_SWIFTC_ARGS[@]}" \
        -swift-version 5 \
        -D VOICEPANEL_ENGINE_TESTING \
        "${CORE_IMPORT_ARGS[@]}" \
        "$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperRuntimeConfiguration.swift" \
        "$TMP_DIR/WhisperBridgeTypecheckSupport.swift" \
        "$ROOT_DIR/Sources/VoicePanelApp/Recognition/WhisperBoundaryProcessor.swift" \
        "$ROOT_DIR/Sources/VoicePanelApp/Recognition/WhisperEngineLifecycleExecutor.swift" \
        "$ROOT_DIR/Sources/VoicePanelApp/Recognition/WhisperRecognitionEngine.swift" \
        "$ROOT_DIR/Tests/VoicePanelAppChecks/WhisperRecognitionEngineChecks.swift" \
        "${CORE_OBJECTS[@]}" \
        -o "$TMP_DIR/WhisperRecognitionEngineChecks"
    "$TMP_DIR/WhisperRecognitionEngineChecks"
fi

echo "Whisper Swift/C bridge type-check passed."
