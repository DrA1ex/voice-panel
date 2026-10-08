#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
FAKE_APP_ROOT="$TMP_DIR/apps"
DIST_DIR="$TMP_DIR/dist"
BUILD_LOG="$TMP_DIR/build.log"
mkdir -p "$FAKE_BIN" "$FAKE_APP_ROOT"

cat > "$FAKE_BIN/uname" <<'SCRIPT'
#!/usr/bin/env bash
printf 'Darwin\n'
SCRIPT

cat > "$FAKE_BIN/lipo" <<'SCRIPT'
#!/usr/bin/env bash
[[ "$2" == "-verify_arch" ]]
exit 0
SCRIPT

cat > "$FAKE_BIN/codesign" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT

cat > "$FAKE_BIN/plutil" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "$1" == "-extract" ]]; then
    printf '1.0.0\n'
fi
SCRIPT

cat > "$FAKE_BIN/ditto" <<'SCRIPT'
#!/usr/bin/env bash
cp -R "$1" "$2"
SCRIPT

cat > "$FAKE_BIN/hdiutil" <<'SCRIPT'
#!/usr/bin/env bash
case "$1" in
    create) touch "${!#}" ;;
    attach|detach) exit 0 ;;
    convert) touch "${!#}" ;;
    verify) [[ -f "$2" ]] ;;
    *) exit 1 ;;
esac
SCRIPT

cat > "$FAKE_BIN/osascript" <<'SCRIPT'
#!/usr/bin/env bash
mount_dir="$(dirname "$(dirname "$4")")"
touch "$mount_dir/.DS_Store"
exit 0
SCRIPT

cat > "$TMP_DIR/build-app.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$VOICEPANEL_TARGET_ARCH" >> "$VOICEPANEL_TEST_BUILD_LOG"
app_path="$VOICEPANEL_APP_OUTPUT_DIR/VoicePanel.app"
mkdir -p "$app_path/Contents/MacOS"
printf '#!/usr/bin/env bash\n' > "$app_path/Contents/MacOS/VoicePanel"
chmod +x "$app_path/Contents/MacOS/VoicePanel"
printf '%s\n' "$app_path"
SCRIPT

chmod +x "$FAKE_BIN"/* "$TMP_DIR/build-app.sh"

PACKAGE_OUTPUT="$(
    PATH="$FAKE_BIN:$PATH" \
    VOICEPANEL_BUILD_APP_SCRIPT="$TMP_DIR/build-app.sh" \
    VOICEPANEL_TEST_BUILD_LOG="$BUILD_LOG" \
    VOICEPANEL_DIST_DIR="$DIST_DIR" \
    VOICEPANEL_RELEASE_APP_ROOT="$FAKE_APP_ROOT" \
    "$ROOT_DIR/scripts/package-dmg.sh" --sign 'Developer ID Application: Test' 2>"$TMP_DIR/package.stderr"
)"

EXPECTED_ARM="$DIST_DIR/VoicePanel-1.0.0-arm64.dmg"
EXPECTED_INTEL="$DIST_DIR/VoicePanel-1.0.0-x86_64.dmg"
[[ "$PACKAGE_OUTPUT" == "$EXPECTED_ARM"$'\n'"$EXPECTED_INTEL" ]] || {
    echo "package-dmg.sh did not print both architecture-specific DMG paths" >&2
    exit 1
}
[[ -f "$EXPECTED_ARM" && -f "$EXPECTED_INTEL" ]] || {
    echo "package-dmg.sh did not create both DMG files" >&2
    exit 1
}
[[ -f "$EXPECTED_ARM.sha256" && -f "$EXPECTED_INTEL.sha256" ]] || {
    echo "package-dmg.sh did not create DMG checksums" >&2
    exit 1
}
[[ "$(cat "$BUILD_LOG")" == $'arm64\nx86_64' ]] || {
    echo "package-dmg.sh did not request independent arm64 and x86_64 builds" >&2
    exit 1
}

echo "DMG packaging regression test passed."
