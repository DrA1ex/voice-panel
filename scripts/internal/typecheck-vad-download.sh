#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

source "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh"
SWIFTC="$SWIFTC_BIN"

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
    public static func hash(data: Data) -> CryptoDigest { CryptoDigest() }
}
SWIFT

"$SWIFTC" "${VOICEPANEL_SWIFTC_ARGS[@]}" -emit-module -module-name Combine \
    "$TMP_DIR/Combine.swift" -emit-module-path "$TMP_DIR/Combine.swiftmodule"
"$SWIFTC" "${VOICEPANEL_SWIFTC_ARGS[@]}" -emit-module -module-name CryptoKit \
    "$TMP_DIR/CryptoKit.swift" -emit-module-path "$TMP_DIR/CryptoKit.swiftmodule"

"$SWIFTC" "${VOICEPANEL_SWIFTC_ARGS[@]}" -typecheck -swift-version 5 -I "$TMP_DIR" \
    "$ROOT_DIR/Sources/VoicePanelApp/Models/VAD/SileroVADModelManager.swift"

echo "Silero VAD downloader and integrity check type-check passed."
