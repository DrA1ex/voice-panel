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

cat > "$TMP_DIR/AVFoundation.swift" <<'SWIFT'
public final class AVAudioPCMBuffer {
    public init() {}
}
SWIFT
"$SWIFTC" "${VOICEPANEL_SWIFTC_ARGS[@]}" -emit-module -module-name AVFoundation "$TMP_DIR/AVFoundation.swift" \
    -emit-module-path "$TMP_DIR/AVFoundation.swiftmodule"

cat > "$TMP_DIR/SystemSpeechStub.swift" <<'SWIFT'
import AVFoundation
import Foundation
import VoicePanelCore

final class DiagnosticLogger {
    static let shared = DiagnosticLogger()
    func warning(_ message: String, metadata: [String: String]) {}
    func info(_ message: String, metadata: [String: String]) {}
}

final class SystemSpeechRecognitionEngine: RecognitionEngine {
    let displayName = "Apple Speech"
    let audioInputMode: RecognitionAudioInputMode = .continuousBuffers
    let finalizationTimeout: TimeInterval = 5
    let providesLiveDraft = true
    var onUpdate: ((RecognitionUpdate) -> Void)?
    var onFinished: (() -> Void)?
    var onMetrics: ((RecognitionPerformanceMetrics) -> Void)?
    var onChunkOutcome: ((RecognitionChunkOutcome) -> Void)?
    var onError: ((Error) -> Void)?
    func requestAuthorization() async throws {}
    func start(localeIdentifier: String) async throws {}
    func startDraft(localeIdentifier: String) async throws {}
    func advanceDraftSegment(to sequence: Int) {}
    func append(_ buffer: AVAudioPCMBuffer) {}
    func append(_ chunk: AudioChunk) {}
    func finishCurrentSegment() {}
    func finish() {}
    func cancel() {}
}
SWIFT

"$SWIFTC" "${VOICEPANEL_SWIFTC_ARGS[@]}" -typecheck -swift-version 5 -I "$TMP_DIR" "${CORE_IMPORT_ARGS[@]}" \
    "$ROOT_DIR/Sources/VoicePanelApp/Recognition/RecognitionEngine.swift" \
    "$TMP_DIR/SystemSpeechStub.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Recognition/AppleDraftGigaAMRecognitionEngine.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Recognition/ChunkDraftRefinementRecognitionEngine.swift"

echo "Hybrid draft/refinement engine type-check passed."
