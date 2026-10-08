#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN" "$TMP_DIR/MacOSX.sdk"

cat > "$FAKE_BIN/uname" <<'SCRIPT'
#!/usr/bin/env bash
case "${1:-}" in
    -s) printf 'Darwin\n' ;;
    -m) printf 'arm64\n' ;;
    *) printf 'Darwin\n' ;;
esac
SCRIPT
cat > "$FAKE_BIN/swift" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
cat > "$FAKE_BIN/swiftc" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
cat > "$FAKE_BIN/xcrun" <<SCRIPT
#!/usr/bin/env bash
case "\$*" in
    *"--show-sdk-path"*) printf '%s\n' "$TMP_DIR/MacOSX.sdk" ;;
    *"--find swiftc"*) printf '%s\n' "$FAKE_BIN/swiftc" ;;
    *"--find swift"*) printf '%s\n' "$FAKE_BIN/swift" ;;
    *) exit 1 ;;
esac
SCRIPT
chmod +x "$FAKE_BIN"/*

PATH="$FAKE_BIN:$PATH" \
XCRUN_BIN="$FAKE_BIN/xcrun" \
MACOSX_DEPLOYMENT_TARGET="26.0" \
bash -c '
    set -euo pipefail
    ROOT_DIR="$1"
    source "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh"
    [[ "$MACOSX_DEPLOYMENT_TARGET" == "14.0" ]]
    [[ "$VOICEPANEL_SWIFT_TARGET" == "arm64-apple-macosx14.0" ]]
    [[ " ${VOICEPANEL_SWIFT_BUILD_ARGS[*]} " == *" --triple arm64-apple-macosx14.0 "* ]]
    [[ "$SDKROOT" == "$2/MacOSX.sdk" ]]
' _ "$ROOT_DIR" "$TMP_DIR"

PATH="$FAKE_BIN:$PATH" \
XCRUN_BIN="$FAKE_BIN/xcrun" \
VOICEPANEL_TARGET_ARCH="x86_64" \
bash -c '
    set -euo pipefail
    ROOT_DIR="$1"
    source "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh"
    [[ "$VOICEPANEL_SWIFT_TARGET" == "x86_64-apple-macosx14.0" ]]
    [[ " ${VOICEPANEL_SWIFT_BUILD_ARGS[*]} " == *" --triple x86_64-apple-macosx14.0 "* ]]
' _ "$ROOT_DIR"

echo "Swift toolchain environment regression test passed."
