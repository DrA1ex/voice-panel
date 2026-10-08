#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/.swift-format"

if [[ "$(uname -s)" == "Darwin" ]] && command -v xcrun >/dev/null 2>&1 \
   && xcrun --find swift-format >/dev/null 2>&1; then
    FORMAT_BIN="$(xcrun --find swift-format)"
else
    FORMAT_BIN="$(command -v swift-format || true)"
fi

if [[ -z "$FORMAT_BIN" || ! -x "$FORMAT_BIN" ]]; then
    echo "swift-format was not found. Install a current Swift toolchain." >&2
    exit 1
fi

cd "$ROOT_DIR"
find Sources Tests -type f -name '*.swift' -print0 \
    | xargs -0 -n 20 "$FORMAT_BIN" format \
        --configuration "$CONFIG_FILE" \
        --in-place
