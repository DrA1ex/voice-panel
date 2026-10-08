#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$("$ROOT_DIR/scripts/build-app.sh")"

if [[ ! -d "$APP_PATH" ]]; then
    echo "Built application does not exist: $APP_PATH" >&2
    exit 1
fi

open "$APP_PATH"
