#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
SWIFTC="$SWIFTC_BIN"

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
CRYPTO_MODULE_MAP="$CORE_BIN_DIR/VoicePanelCryptoCompat.build/module.modulemap"
if [[ -f "$CRYPTO_MODULE_MAP" ]]; then
    CORE_IMPORT_ARGS+=(-Xcc "-fmodule-map-file=$CRYPTO_MODULE_MAP")
fi

cat > "$TMP_DIR/VoicePanelORTBridge.swift" <<'SWIFT'
import Foundation

public func vp_ort_runtime_create(
    _ encoderPath: UnsafePointer<CChar>?,
    _ decoderPath: UnsafePointer<CChar>?,
    _ threads: Int32,
    _ error: UnsafeMutablePointer<CChar>?,
    _ errorCapacity: Int
) -> OpaquePointer? { OpaquePointer(bitPattern: 1) }

public func vp_ort_runtime_destroy(_ runtime: OpaquePointer?) {}

public func vp_ort_encode(
    _ runtime: OpaquePointer?,
    _ inputIDs: UnsafePointer<Int64>?,
    _ attentionMask: UnsafePointer<Int64>?,
    _ count: Int,
    _ error: UnsafeMutablePointer<CChar>?,
    _ errorCapacity: Int
) -> OpaquePointer? { OpaquePointer(bitPattern: 2) }

public func vp_ort_hidden_state_destroy(_ hidden: OpaquePointer?) {}

public func vp_ort_decode_next_token(
    _ runtime: OpaquePointer?,
    _ hidden: OpaquePointer?,
    _ attentionMask: UnsafePointer<Int64>?,
    _ attentionMaskCount: Int,
    _ decoderIDs: UnsafePointer<Int64>?,
    _ decoderIDCount: Int,
    _ nextToken: UnsafeMutablePointer<Int64>?,
    _ error: UnsafeMutablePointer<CChar>?,
    _ errorCapacity: Int
) -> Int32 { 1 }
SWIFT
"$SWIFTC" "${VOICEPANEL_SWIFTC_ARGS[@]}" -emit-module -module-name VoicePanelORTBridge \
    "$TMP_DIR/VoicePanelORTBridge.swift" -emit-module-path "$TMP_DIR/VoicePanelORTBridge.swiftmodule"

cat > "$TMP_DIR/TextCorrectionStubs.swift" <<'SWIFT'
import Foundation

enum RussianCorrectionModelID: Sendable {
    case sageFREDT5Int8
}

enum RussianCorrectionPackageFile: Sendable {
    case encoder
    case decoder
    case vocabulary
    case merges
}

struct RussianCorrectionInstalledPackage: Sendable {
    let model: RussianCorrectionModelID
    func url(for file: RussianCorrectionPackageFile) -> URL? {
        URL(fileURLWithPath: "/tmp/model")
    }
}
SWIFT

"$SWIFTC" "${VOICEPANEL_SWIFTC_ARGS[@]}" -typecheck -swift-version 5 -I "$TMP_DIR" \
    "${CORE_IMPORT_ARGS[@]}" \
    "$TMP_DIR/TextCorrectionStubs.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Models/TextCorrection/FREDT5Tokenizer.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Models/TextCorrection/RussianTextCorrectionRuntime.swift"

echo "SAGE edit-based correction runtime type-check passed."
