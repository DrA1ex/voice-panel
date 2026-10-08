#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT_DIR/scripts/format.sh"
"$ROOT_DIR/scripts/test.sh"
"$ROOT_DIR/scripts/internal/check-release-metadata.sh"

echo "Release checks passed. Build signed and notarized DMGs on macOS with scripts/package-dmg.sh."
