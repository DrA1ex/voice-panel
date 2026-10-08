#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

if ! command -v sourcekit-lsp >/dev/null 2>&1; then
    echo "warning: sourcekit-lsp is unavailable; indexing check was skipped" >&2
    exit 0
fi

LOG_FILE="$(mktemp)"
trap 'rm -f "$LOG_FILE"' EXIT

if ! sourcekit-lsp debug index --project "$ROOT_DIR" >"$LOG_FILE" 2>&1; then
    echo "SourceKit-LSP indexing failed:" >&2
    cat "$LOG_FILE" >&2
    exit 1
fi

if grep -Eq 'Finished with exit code [1-9][0-9]*' "$LOG_FILE"; then
    echo "SourceKit-LSP reported a failed compiler/indexing process:" >&2
    cat "$LOG_FILE" >&2
    exit 1
fi

echo "SourceKit-LSP indexing check passed."
