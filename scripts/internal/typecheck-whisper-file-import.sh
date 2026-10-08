#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

EXECUTOR_FILE="$ROOT_DIR/Sources/VoicePanelApp/Recognition/WhisperFileImportExecutor.swift"
CHECK_FILE="$ROOT_DIR/Tests/VoicePanelAppChecks/WhisperFileImportExecutorChecks.swift"
OUTPUT_FILE="$TMP_DIR/whisper-file-import-checks"

[[ -f "$EXECUTOR_FILE" ]] || {
    echo "Whisper file import executor check failed: missing production executor" >&2
    exit 1
}

"$SWIFTC_BIN" \
    "${VOICEPANEL_SWIFTC_ARGS[@]}" \
    -swift-version 5 \
    -emit-library \
    -emit-module \
    -module-name VoicePanelCore \
    -emit-module-path "$TMP_DIR/VoicePanelCore.swiftmodule" \
    "$ROOT_DIR/Sources/VoicePanelCore/AudioSegmenter.swift" \
    "$ROOT_DIR/Sources/VoicePanelCore/AudioImportProgress.swift" \
    "$ROOT_DIR/Sources/VoicePanelCore/CompactAudioImportLayoutPolicy.swift" \
    "$ROOT_DIR/Sources/VoicePanelCore/CompactAudioImportPresentation.swift" \
    "$ROOT_DIR/Sources/VoicePanelCore/RecognitionPendingWork.swift" \
    "$ROOT_DIR/Sources/VoicePanelCore/TranscriptSession.swift" \
    "$ROOT_DIR/Sources/VoicePanelCore/TranscriptTextNormalizer.swift" \
    "$ROOT_DIR/Sources/VoicePanelCore/VoiceActivityDetector.swift" \
    "$ROOT_DIR/Sources/VoicePanelCore/WhisperBoundaryModes.swift" \
    "$ROOT_DIR/Sources/VoicePanelCore/WhisperFileImportPolicy.swift" \
    -o "$TMP_DIR/libVoicePanelCore.dylib"

"$SWIFTC_BIN" \
    "${VOICEPANEL_SWIFTC_ARGS[@]}" \
    -swift-version 5 \
    -parse-as-library \
    -I "$TMP_DIR" \
    -L "$TMP_DIR" \
    -lVoicePanelCore \
    "$ROOT_DIR/Sources/VoicePanelApp/Recognition/RecognitionEngine.swift" \
    "$EXECUTOR_FILE" \
    "$CHECK_FILE" \
    -o "$OUTPUT_FILE"

DYLD_LIBRARY_PATH="$TMP_DIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$OUTPUT_FILE"
