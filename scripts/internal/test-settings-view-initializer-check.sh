#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="$ROOT_DIR/scripts/internal/check-settings-view-initializer.py"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/SettingsView.swift" <<'SWIFT'
struct SettingsView {
    init(
        settings: Settings,
        state: State,
        coordinator: Coordinator
    ) {}
}
SWIFT

cat > "$TMP_DIR/GoodController.swift" <<'SWIFT'
let view = SettingsView(
    settings: settings,
    state: state,
    coordinator: coordinator
)
SWIFT

cat > "$TMP_DIR/BadController.swift" <<'SWIFT'
let view = SettingsView(
    settings: settings,
    coordinator: coordinator,
    state: state
)
SWIFT

"$CHECKER" "$TMP_DIR/SettingsView.swift" "$TMP_DIR/GoodController.swift"

if "$CHECKER" "$TMP_DIR/SettingsView.swift" "$TMP_DIR/BadController.swift" >/dev/null 2>&1; then
    echo "SettingsView initializer checker accepted arguments in the wrong order." >&2
    exit 1
fi

echo "SettingsView initializer checker regression test passed."
