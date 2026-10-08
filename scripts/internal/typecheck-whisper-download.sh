#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

source "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh"
SWIFTC="$SWIFTC_BIN"

cd "$ROOT_DIR"
if [[ -n "${VOICEPANEL_WHISPER_DOWNLOAD_SCRATCH_PATH:-}" ]]; then
    VOICEPANEL_SWIFT_BUILD_ARGS+=(
        --scratch-path "$VOICEPANEL_WHISPER_DOWNLOAD_SCRATCH_PATH"
    )
fi
ACTIVE_BUILD_DIR="$(
    "$SWIFT_BIN" build \
        "${VOICEPANEL_SWIFT_BUILD_ARGS[@]}" \
        -c debug \
        --show-bin-path
)"
CORE_MODULE="$ACTIVE_BUILD_DIR/Modules/VoicePanelCore.swiftmodule"
if [[ ! -e "$CORE_MODULE" ]]; then
    "$SWIFT_BIN" build \
        "${VOICEPANEL_SWIFT_BUILD_ARGS[@]}" \
        -c debug \
        --target VoicePanelCore \
        >/dev/null
fi
if [[ ! -e "$CORE_MODULE" ]]; then
    echo "VoicePanelCore module was not produced." >&2
    exit 1
fi
CORE_MODULE_DIR="$(dirname "$CORE_MODULE")"
CORE_IMPORT_ARGS=(-I "$CORE_MODULE_DIR")
CRYPTO_MODULE_MAP="$ACTIVE_BUILD_DIR/VoicePanelCryptoCompat.build/module.modulemap"
if [[ -f "$CRYPTO_MODULE_MAP" ]]; then
    CORE_IMPORT_ARGS+=(-Xcc "-fmodule-map-file=$CRYPTO_MODULE_MAP")
fi

cat > "$TMP_DIR/Combine.swift" <<'SWIFT'
@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
}

public protocol ObservableObject: AnyObject {}
SWIFT

cat > "$TMP_DIR/CryptoKit.swift" <<'SWIFT'
import Foundation

public struct CryptoDigest: Sequence {
    public typealias Element = UInt8
    public init() {}
    public func makeIterator() -> Array<UInt8>.Iterator { [].makeIterator() }
}

public struct SHA256 {
    public init() {}
    public mutating func update(data: Data) {}
    public func finalize() -> CryptoDigest { CryptoDigest() }
}

public enum Insecure {
    public struct SHA1 {
        public init() {}
        public mutating func update(data: Data) {}
        public func finalize() -> CryptoDigest { CryptoDigest() }
    }
}
SWIFT

"$SWIFTC" "${VOICEPANEL_SWIFTC_ARGS[@]}" -emit-module -module-name Combine \
    "$TMP_DIR/Combine.swift" -emit-module-path "$TMP_DIR/Combine.swiftmodule"
"$SWIFTC" "${VOICEPANEL_SWIFTC_ARGS[@]}" -emit-module -module-name CryptoKit \
    "$TMP_DIR/CryptoKit.swift" -emit-module-path "$TMP_DIR/CryptoKit.swiftmodule"

"$SWIFTC" "${VOICEPANEL_SWIFTC_ARGS[@]}" -typecheck -swift-version 5 -I "$TMP_DIR" \
    "${CORE_IMPORT_ARGS[@]}" \
    "$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperRuntimeConfiguration.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperModelCatalog.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperModelManager.swift"

echo "Whisper model and Core ML package downloader type-check passed."
