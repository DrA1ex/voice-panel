#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

source "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh"
SWIFTC="$SWIFTC_BIN"

cat > "$TMP_DIR/sherpa_onnx.swift" <<'SWIFT'
import Foundation

public struct SherpaOnnxSileroVadModelConfig {
    public var model: UnsafePointer<CChar>? = nil
    public var threshold: Float = 0
    public var min_silence_duration: Float = 0
    public var min_speech_duration: Float = 0
    public var window_size: Int32 = 0
    public var max_speech_duration: Float = 0
    public init() {}
}

public struct SherpaOnnxVadModelConfig {
    public var silero_vad = SherpaOnnxSileroVadModelConfig()
    public var sample_rate: Int32 = 0
    public var num_threads: Int32 = 0
    public var provider: UnsafePointer<CChar>? = nil
    public var debug: Int32 = 0
    public init() {}
}

public func SherpaOnnxCreateVoiceActivityDetector(
    _ config: UnsafePointer<SherpaOnnxVadModelConfig>?,
    _ bufferSizeInSeconds: Float
) -> OpaquePointer? { OpaquePointer(bitPattern: 1) }
public func SherpaOnnxDestroyVoiceActivityDetector(_ vad: OpaquePointer?) {}
public func SherpaOnnxVoiceActivityDetectorAcceptWaveform(
    _ vad: OpaquePointer?,
    _ samples: UnsafePointer<Float>?,
    _ count: Int32
) {}
public func SherpaOnnxVoiceActivityDetectorDetected(_ vad: OpaquePointer?) -> Int32 { 0 }
public func SherpaOnnxVoiceActivityDetectorEmpty(_ vad: OpaquePointer?) -> Int32 { 1 }
public func SherpaOnnxVoiceActivityDetectorPop(_ vad: OpaquePointer?) {}
public func SherpaOnnxVoiceActivityDetectorClear(_ vad: OpaquePointer?) {}
public func SherpaOnnxVoiceActivityDetectorReset(_ vad: OpaquePointer?) {}
SWIFT

"$SWIFTC" "${VOICEPANEL_SWIFTC_ARGS[@]}" -emit-module -module-name sherpa_onnx \
    "$TMP_DIR/sherpa_onnx.swift" -emit-module-path "$TMP_DIR/sherpa_onnx.swiftmodule"

cd "$ROOT_DIR"
"$SWIFT_BIN" build "${VOICEPANEL_SWIFT_BUILD_ARGS[@]}" --target VoicePanelCore --jobs 2 >/dev/null
CORE_BIN_DIR="$(
    "$SWIFT_BIN" build "${VOICEPANEL_SWIFT_BUILD_ARGS[@]}" --show-bin-path
)"
CORE_MODULE="$CORE_BIN_DIR/Modules/VoicePanelCore.swiftmodule"
if [[ ! -f "$CORE_MODULE" ]]; then
    echo "VoicePanelCore module was not produced." >&2
    exit 1
fi
CORE_MODULE_DIR="$(dirname "$CORE_MODULE")"
CORE_IMPORT_ARGS=(-I "$CORE_MODULE_DIR" -I "$TMP_DIR")
CRYPTO_MODULE_MAP="$CORE_BIN_DIR/VoicePanelCryptoCompat.build/module.modulemap"
if [[ -f "$CRYPTO_MODULE_MAP" ]]; then
    CORE_IMPORT_ARGS+=(-Xcc "-fmodule-map-file=$CRYPTO_MODULE_MAP")
fi

"$SWIFTC" "${VOICEPANEL_SWIFTC_ARGS[@]}" -typecheck -swift-version 5 \
    "${CORE_IMPORT_ARGS[@]}" \
    "$ROOT_DIR/Sources/VoicePanelApp/Models/VAD/SileroVADRuntime.swift"

echo "Silero VAD sherpa-onnx bridge type-check passed."
