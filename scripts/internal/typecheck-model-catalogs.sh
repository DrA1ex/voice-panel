#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

source "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh"

"$SWIFTC_BIN" \
    "${VOICEPANEL_SWIFTC_ARGS[@]}" \
    -typecheck \
    -swift-version 5 \
    -warnings-as-errors \
    "$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperModelCatalog.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Models/GigaAM/GigaAMModelCatalog.swift" \
    "$ROOT_DIR/Sources/VoicePanelApp/Models/LocalONNX/LocalONNXModelCatalog.swift"

echo "Recognition model catalogs type-check passed."
