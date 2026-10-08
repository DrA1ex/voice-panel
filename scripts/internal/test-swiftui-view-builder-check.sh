#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="$ROOT_DIR/scripts/internal/check-swiftui-view-builders.py"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/Bad.swift" <<'SWIFT'
import SwiftUI
struct BadView: View {
    private var sections: some View {
        Text("First")
        Text("Second")
    }
    var body: some View { sections }
}
SWIFT

cat > "$TMP_DIR/Good.swift" <<'SWIFT'
import SwiftUI
struct GoodView: View {
    @ViewBuilder
    private var sections: some View {
        Text("First")
        Text("Second")
    }

    private var oneSection: some View {
        Text("Only")
    }

    var body: some View { sections }
}
SWIFT

if "$CHECKER" "$TMP_DIR/Bad.swift" >"$TMP_DIR/bad.out" 2>"$TMP_DIR/bad.err"; then
    echo "SwiftUI ViewBuilder checker accepted a known-bad fixture." >&2
    exit 1
fi
grep -Fq "missing @ViewBuilder" "$TMP_DIR/bad.err" || {
    echo "SwiftUI ViewBuilder checker did not explain the fixture failure." >&2
    exit 1
}
"$CHECKER" "$TMP_DIR/Good.swift"

echo "SwiftUI ViewBuilder checker regression test passed."
