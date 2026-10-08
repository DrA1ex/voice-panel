#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "macOS application type-check skipped outside macOS."
    exit 0
fi

source "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh"

cd "$ROOT_DIR"
"$SWIFT_BIN" build \
    "${VOICEPANEL_SWIFT_BUILD_ARGS[@]}" \
    -c release \
    --product VoicePanel \
    -Xswiftc -warnings-as-errors

echo "macOS VoicePanel release compilation passed with warnings as errors."
