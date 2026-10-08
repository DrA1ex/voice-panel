#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Native transcript presentation checks skipped outside macOS."
    exit 0
fi
source "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
cd "$ROOT_DIR"
"$SWIFT_BIN" build "${VOICEPANEL_SWIFT_BUILD_ARGS[@]}" --target VoicePanelCore >/dev/null
CORE_BIN_DIR="$("$SWIFT_BIN" build "${VOICEPANEL_SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
CORE_OBJECTS=("$CORE_BIN_DIR"/VoicePanelCore.build/*.swift.o)
"$SWIFTC_BIN" "${VOICEPANEL_SWIFTC_ARGS[@]}" -swift-version 5 -warnings-as-errors \
    -I "$CORE_BIN_DIR/Modules" \
    "$ROOT_DIR/Sources/VoicePanelApp/Recognition/RecognitionEngine.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/App/AppState.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/UI/WindowDisplayLinkDriver.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/UI/TranscriptScrollCoordinator.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/UI/TranscriptTextViewport.swift" \
    "$ROOT_DIR/Tests/VoicePanelAppChecks/TranscriptPresentationChecks.swift" \
    "${CORE_OBJECTS[@]}" -o "$TMP_DIR/TranscriptPresentationChecks"
"$TMP_DIR/TranscriptPresentationChecks"
