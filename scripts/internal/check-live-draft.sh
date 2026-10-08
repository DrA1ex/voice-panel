#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Native live draft checks skipped outside macOS."
    exit 0
fi
source "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
cd "$ROOT_DIR"
"$SWIFT_BIN" build "${VOICEPANEL_SWIFT_BUILD_ARGS[@]}" --target VoicePanelCore >/dev/null
CORE_BIN_DIR="$("$SWIFT_BIN" build "${VOICEPANEL_SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
CORE_OBJECTS=("$CORE_BIN_DIR"/VoicePanelCore.build/*.swift.o)
"$SWIFTC_BIN" "${VOICEPANEL_SWIFTC_ARGS[@]}" -swift-version 5 -parse-as-library \
    -emit-module -module-name Speech -emit-module-path "$TMP_DIR/Speech.swiftmodule" \
    -c "$ROOT_DIR/Tests/VoicePanelAppChecks/Fixtures/SpeechStub.swift" -o "$TMP_DIR/Speech.o"
"$SWIFTC_BIN" "${VOICEPANEL_SWIFTC_ARGS[@]}" -swift-version 5 -warnings-as-errors \
    -I "$TMP_DIR" -I "$CORE_BIN_DIR/Modules" \
    "$ROOT_DIR/Sources/VoicePanelApp/Recognition/RecognitionEngine.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/App/AppState.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Recognition/SystemSpeechRecognitionEngine.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Recognition/AppleDraftGigaAMRecognitionEngine.swift" \
    "$ROOT_DIR/Tests/VoicePanelAppChecks/LiveDraftRecognitionChecks.swift" \
    "$TMP_DIR/Speech.o" "${CORE_OBJECTS[@]}" -o "$TMP_DIR/LiveDraftRecognitionChecks"
"$TMP_DIR/LiveDraftRecognitionChecks"
