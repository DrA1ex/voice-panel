#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

source "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh"
SWIFTC="$SWIFTC_BIN"

cat > "$TMP_DIR/sherpa_onnx.swift" <<'SWIFT'
import Foundation

public struct SherpaOnnxFeatureConfig {
    public var sample_rate: Int32 = 0
    public var feature_dim: Int32 = 0
    public init() {}
}
public struct SherpaOnnxOfflineNemoEncDecCtcModelConfig {
    public var model: UnsafePointer<CChar>? = nil
    public init() {}
}
public struct SherpaOnnxOfflineTransducerModelConfig {
    public var encoder: UnsafePointer<CChar>? = nil
    public var decoder: UnsafePointer<CChar>? = nil
    public var joiner: UnsafePointer<CChar>? = nil
    public init() {}
}
public struct SherpaOnnxOfflineModelConfig {
    public var transducer = SherpaOnnxOfflineTransducerModelConfig()
    public var nemo_ctc = SherpaOnnxOfflineNemoEncDecCtcModelConfig()
    public var tokens: UnsafePointer<CChar>? = nil
    public var num_threads: Int32 = 0
    public var provider: UnsafePointer<CChar>? = nil
    public var debug: Int32 = 0
    public init() {}
}
public struct SherpaOnnxOfflineRecognizerConfig {
    public var feat_config = SherpaOnnxFeatureConfig()
    public var model_config = SherpaOnnxOfflineModelConfig()
    public var decoding_method: UnsafePointer<CChar>? = nil
    public var max_active_paths: Int32 = 0
    public var hotwords_score: Float = 0
    public init() {}
}
public struct SherpaOnnxOfflineRecognizerResult {
    public var text: UnsafePointer<CChar>? = nil
    public init() {}
}

public func SherpaOnnxCreateOfflineRecognizer(
    _ config: UnsafePointer<SherpaOnnxOfflineRecognizerConfig>?
) -> OpaquePointer? { OpaquePointer(bitPattern: 1) }
public func SherpaOnnxDestroyOfflineRecognizer(_ recognizer: OpaquePointer?) {}
public func SherpaOnnxCreateOfflineStream(_ recognizer: OpaquePointer?) -> OpaquePointer? { OpaquePointer(bitPattern: 2) }
public func SherpaOnnxDestroyOfflineStream(_ stream: OpaquePointer?) {}
public func SherpaOnnxAcceptWaveformOffline(
    _ stream: OpaquePointer?,
    _ sampleRate: Int32,
    _ samples: UnsafePointer<Float>?,
    _ count: Int32
) {}
public func SherpaOnnxDecodeOfflineStream(_ recognizer: OpaquePointer?, _ stream: OpaquePointer?) {}
public func SherpaOnnxGetOfflineStreamResult(
    _ stream: OpaquePointer?
) -> UnsafePointer<SherpaOnnxOfflineRecognizerResult>? { nil }
public func SherpaOnnxDestroyOfflineRecognizerResult(
    _ result: UnsafePointer<SherpaOnnxOfflineRecognizerResult>?
) {}
SWIFT

cat > "$TMP_DIR/VoicePanelCore.swift" <<'SWIFT'
public enum TranscriptTextNormalizer {
    public static func normalize(_ text: String) -> String { text }
}

public enum GigaAMInferenceLimit {
    public static let sampleRate: Double = 16_000
    public static let maximumDuration: Double = 23
    public static let maximumSampleCount = 368_000
    public static func accepts(sampleCount: Int) -> Bool {
        sampleCount <= maximumSampleCount
    }
}
SWIFT

cat > "$TMP_DIR/AppStubs.swift" <<'SWIFT'
import Foundation

final class DiagnosticLogger: @unchecked Sendable {
    static let shared = DiagnosticLogger()
    func beginModelLoad(engine: String, modelID: String, modelURL: URL) -> UUID { UUID() }
    func endModelLoad(token: UUID, engine: String, modelID: String, result: String) {}
}

enum RecognitionEngineError: Error {
    case modelCouldNotBeLoaded(String)
    case inferenceFailed
    case gigaAMInputTooLong(actualDuration: TimeInterval, maximumDuration: TimeInterval)
}
SWIFT

"$SWIFTC" "${VOICEPANEL_SWIFTC_ARGS[@]}" -emit-module -module-name sherpa_onnx "$TMP_DIR/sherpa_onnx.swift" \
    -emit-module-path "$TMP_DIR/sherpa_onnx.swiftmodule"
"$SWIFTC" "${VOICEPANEL_SWIFTC_ARGS[@]}" -emit-module -module-name VoicePanelCore "$TMP_DIR/VoicePanelCore.swift" \
    -emit-module-path "$TMP_DIR/VoicePanelCore.swiftmodule"

"$SWIFTC" "${VOICEPANEL_SWIFTC_ARGS[@]}" -typecheck -I "$TMP_DIR" \
    "$TMP_DIR/AppStubs.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Models/GigaAM/GigaAMModelCatalog.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Models/GigaAM/GigaAMRuntime.swift"



# Type-check the queueing GigaAM recognition engine separately from AppKit and
# AVFoundation so Linux validation also covers the per-chunk completion API.
cd "$ROOT_DIR"
CORE_BIN_DIR="$(
    "$SWIFT_BIN" build "${VOICEPANEL_SWIFT_BUILD_ARGS[@]}" --show-bin-path
)"
"$SWIFT_BIN" build "${VOICEPANEL_SWIFT_BUILD_ARGS[@]}" --target VoicePanelCore >/dev/null
CORE_MODULE="$CORE_BIN_DIR/Modules/VoicePanelCore.swiftmodule"
if [[ ! -e "$CORE_MODULE" ]]; then
    echo "VoicePanelCore module was not produced." >&2
    exit 1
fi
CORE_MODULE_DIR="$(dirname "$CORE_MODULE")"
CORE_IMPORT_ARGS=(-I "$CORE_MODULE_DIR")
CRYPTO_MODULE_MAP="$(find "$ROOT_DIR/.build" -path '*/debug/VoicePanelCryptoCompat.build/module.modulemap' -print -quit)"
if [[ -n "$CRYPTO_MODULE_MAP" ]]; then
    CORE_IMPORT_ARGS+=(-Xcc "-fmodule-map-file=$CRYPTO_MODULE_MAP")
fi

cat > "$TMP_DIR/GigaAMEngineTypecheckSupport.swift" <<'SWIFT'
import Foundation
import VoicePanelCore

enum GigaAMModelID: Sendable {
    case v3E2ERNNT
    var title: String { "GigaAM v3 E2E RNN-T" }
}

final class GigaAMRuntime: @unchecked Sendable {
    func transcribe(samples: [Float]) throws -> String { "" }
}

enum RecognitionEngineError: Error {
    case gigaAMInferenceFailed
}

enum RecognitionChunkOutcome {
    case completed(UUID)
    case failed(UUID, message: String)
}

enum RecognitionAudioInputMode {
    case continuousBuffers
    case vadChunks
}

struct RecognitionUpdate {
    let segment: TranscriptSegmentUpdate
    let shouldDimPartialText: Bool
}

struct RecognitionPerformanceMetrics {
    let engineName: String
    let queueDepth: Int
    let chunkDuration: TimeInterval
    let processingDuration: TimeInterval
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
SWIFT

"$SWIFTC" "${VOICEPANEL_SWIFTC_ARGS[@]}" -typecheck -swift-version 5 "${CORE_IMPORT_ARGS[@]}" \
    "$TMP_DIR/GigaAMEngineTypecheckSupport.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Recognition/GigaAMRecognitionEngine.swift"

echo "GigaAM Swift/C bridge type-check passed."
