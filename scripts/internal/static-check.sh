#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

source "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh"

cd "$ROOT_DIR"

# Validate the validation tools themselves before relying on them.
PY_CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$PY_CHECK_DIR"' EXIT
python3 - "$ROOT_DIR/scripts/internal/check-swiftui-view-builders.py" "$PY_CHECK_DIR/checker.pyc" <<'PY_COMPILE'
import py_compile
import sys
py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)
PY_COMPILE
while IFS= read -r -d '' script; do
    bash -n "$script"
done < <(find "$ROOT_DIR/scripts" -type f -name '*.sh' -print0)

# Validates Package.swift without compiling Apple-only targets.
"$SWIFT_BIN" package dump-package >/dev/null

# The parser works on Linux even when AppKit/SwiftUI SDK modules are unavailable.
# Parse in bounded batches: one very large frontend invocation can stall in
# Linux CI, while one process per file adds excessive startup overhead.
find Sources Tests -type f -name '*.swift' -print0 \
    | xargs -0 -n 20 "$SWIFTC_BIN" "${VOICEPANEL_SWIFTC_ARGS[@]}" -parse

# swift-format adds a second parser and source-structure pass. Keep the
# project configuration explicit so toolchain defaults cannot reinterpret the
# established four-space style as thousands of failures.
FORMAT_CONFIG="$ROOT_DIR/.swift-format"
if [[ ! -f "$FORMAT_CONFIG" ]]; then
    echo ".swift-format is missing." >&2
    exit 1
fi
if command -v swift-format >/dev/null 2>&1; then
    FORMAT_BIN="$(command -v swift-format)"
elif [[ "$(uname -s)" == "Darwin" ]] && command -v xcrun >/dev/null 2>&1 \
     && xcrun --find swift-format >/dev/null 2>&1; then
    FORMAT_BIN="$(xcrun --find swift-format)"
else
    echo "swift-format was not found. Install a current Swift toolchain." >&2
    exit 1
fi
# Lint in bounded batches. Some Linux swift-format builds can stall during a
# single large recursive invocation; batching preserves complete coverage
# without paying the startup cost of one process per source file.
find Sources Tests -type f -name '*.swift' -print0 \
    | xargs -0 -n 20 "$FORMAT_BIN" lint \
        --strict \
        --configuration "$FORMAT_CONFIG"

# Compile the platform-independent checks product under the strictest checks
# available in the Linux sandbox. Building this product also compiles
# VoicePanelCore, while avoiding a second sequential SwiftPM build that can
# deadlock against a stale build-service process in constrained CI runners.
"$SWIFT_BIN" build \
    "${VOICEPANEL_SWIFT_BUILD_ARGS[@]}" \
    --product VoicePanelCoreChecks \
    --jobs "${VOICEPANEL_SWIFT_JOBS:-4}" \
    -Xswiftc -warnings-as-errors \
    -Xswiftc -strict-concurrency=complete

# macOS SDK type-checking is unavailable on Linux, so cover a high-frequency
# SwiftUI semantic failure with a source-aware project checker.
"$ROOT_DIR/scripts/internal/check-swiftui-view-builders.py" "$ROOT_DIR/Sources/VoicePanelApp"
"$ROOT_DIR/scripts/internal/test-swiftui-view-builder-check.sh"
"$ROOT_DIR/scripts/internal/test-settings-view-initializer-check.sh"

echo "Static Swift checks passed."
