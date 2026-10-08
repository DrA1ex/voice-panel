#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

source "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh"

"$ROOT_DIR/scripts/internal/check-swift-toolchain.sh"
"$ROOT_DIR/scripts/internal/test-swift-toolchain-env.sh"

"$ROOT_DIR/scripts/internal/check-test-source-contracts.sh"
"$ROOT_DIR/scripts/internal/check-app-source-contracts.sh"
"$ROOT_DIR/scripts/internal/check-ui-test-source-contracts.sh"
"$ROOT_DIR/scripts/internal/check-release-metadata.sh"
"$ROOT_DIR/scripts/internal/static-check.sh"
"$ROOT_DIR/scripts/internal/macos-app-check.sh"
"$ROOT_DIR/scripts/internal/check-transcript-presentation.sh"
"$ROOT_DIR/scripts/internal/check-live-draft.sh"
"$ROOT_DIR/scripts/internal/test-build-scripts.sh"
"$ROOT_DIR/scripts/internal/test-ui-script.sh"
"$ROOT_DIR/scripts/internal/test-package-dmg.sh"

cd "$ROOT_DIR"
CORE_CHECKS_BIN_DIR="$(
    "$SWIFT_BIN" build \
        "${VOICEPANEL_SWIFT_BUILD_ARGS[@]}" \
        -c debug \
        --show-bin-path
)"
CORE_CHECKS_BIN="$CORE_CHECKS_BIN_DIR/VoicePanelCoreChecks"
if [[ ! -x "$CORE_CHECKS_BIN" ]]; then
    echo "VoicePanelCoreChecks executable was not produced at $CORE_CHECKS_BIN" >&2
    exit 1
fi
"$CORE_CHECKS_BIN"
"$ROOT_DIR/scripts/internal/typecheck-diagnostics.sh"
"$ROOT_DIR/scripts/internal/typecheck-whisper-bridge.sh"
"$ROOT_DIR/scripts/internal/typecheck-gigaam-bridge.sh"
"$ROOT_DIR/scripts/internal/typecheck-local-onnx-bridge.sh"
"$ROOT_DIR/scripts/internal/typecheck-vad-bridge.sh"
"$ROOT_DIR/scripts/internal/typecheck-vad-download.sh"
"$ROOT_DIR/scripts/internal/typecheck-local-onnx-download.sh"
"$ROOT_DIR/scripts/internal/typecheck-whisper-download.sh"

"$ROOT_DIR/scripts/internal/typecheck-text-correction.sh"
"$ROOT_DIR/scripts/internal/typecheck-model-catalogs.sh"
"$ROOT_DIR/scripts/internal/typecheck-hybrid-engines.sh"

if [[ "${VOICEPANEL_RUN_UI_TESTS:-0}" == "1" ]]; then
    "$ROOT_DIR/scripts/test-ui.sh"
fi
