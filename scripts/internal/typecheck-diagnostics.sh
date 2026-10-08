#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh"
SWIFTC="$SWIFTC_BIN"

"$SWIFTC" \
    "${VOICEPANEL_SWIFTC_ARGS[@]}" \
    -typecheck \
    -warnings-as-errors \
    -strict-concurrency=complete \
    "$ROOT_DIR/Sources/VoicePanelApp/Diagnostics/DiagnosticLogger.swift"

echo "Diagnostic logger type-check passed."
