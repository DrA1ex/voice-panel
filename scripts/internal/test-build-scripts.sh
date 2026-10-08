#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR" "$ROOT_DIR/.build/app" "$ROOT_DIR/.build/artifacts/test"' EXIT

FAKE_BIN="$TMP_DIR/bin"
FAKE_SWIFT_BIN="$TMP_DIR/swift-bin"
OPEN_LOG="$TMP_DIR/open.log"
mkdir -p "$FAKE_BIN" "$FAKE_SWIFT_BIN"

# Whisper is delivered dynamically. sherpa-onnx and ONNX Runtime are modeled
# as static XCFramework slices to cover the real packaging regression: they are
# linked into the executable and must not be required in Contents/Frameworks.
mkdir -p "$ROOT_DIR/.build/artifacts/test/WhisperFramework/whisper.xcframework/macos-arm64_x86_64/whisper.framework"
mkdir -p "$ROOT_DIR/.build/artifacts/test/SherpaOnnx/sherpa-onnx.xcframework/macos-arm64_x86_64"
mkdir -p "$ROOT_DIR/.build/artifacts/test/SherpaOnnx/onnxruntime.xcframework/macos-arm64_x86_64"
printf 'static archive\n' > "$ROOT_DIR/.build/artifacts/test/SherpaOnnx/sherpa-onnx.xcframework/macos-arm64_x86_64/libsherpa-onnx.a"
printf 'static archive\n' > "$ROOT_DIR/.build/artifacts/test/SherpaOnnx/onnxruntime.xcframework/macos-arm64_x86_64/libonnxruntime.a"

cat > "$FAKE_BIN/uname" <<'SCRIPT'
#!/usr/bin/env bash
case "${1:-}" in
    -s) printf 'Darwin\n' ;;
    -m) printf 'arm64\n' ;;
    *) printf 'Darwin\n' ;;
esac
SCRIPT

cat > "$FAKE_BIN/swift" <<SCRIPT
#!/usr/bin/env bash
if [[ "\$*" == *"--show-bin-path"* ]]; then
    printf '%s\n' "$FAKE_SWIFT_BIN"
    exit 0
fi
printf 'simulated SwiftPM progress on stdout\n'
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
mkdir -p "$TMP_DIR/MacOSX.sdk"

cat > "$FAKE_BIN/codesign" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "$*" == *"--display --entitlements :-"* ]]; then
    cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
PLIST
else
    printf 'simulated codesign status\n'
fi
SCRIPT

cat > "$FAKE_BIN/plutil" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT

cat > "$FAKE_BIN/ditto" <<'SCRIPT'
#!/usr/bin/env bash
cp -R "$1" "$2"
SCRIPT

cat > "$FAKE_BIN/otool" <<'SCRIPT'
#!/usr/bin/env bash
case "$1" in
    -l)
        printf '@executable_path/../Frameworks\n'
        ;;
    -L)
        printf '%s:\n' "$2"
        printf '\t@rpath/whisper.framework/Versions/A/whisper (compatibility version 0.0.0, current version 0.0.0)\n'
        printf '\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n'
        ;;
esac
SCRIPT

cat > "$FAKE_BIN/strip" <<'SCRIPT'
#!/usr/bin/env bash
[[ "$1" == "-S" && -f "$2" ]]
SCRIPT

cat > "$FAKE_BIN/install_name_tool" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT

cat > "$FAKE_BIN/lipo" <<'SCRIPT'
#!/usr/bin/env bash
[[ "$2" == "-verify_arch" ]]
exit 0
SCRIPT

cat > "$FAKE_BIN/open" <<SCRIPT
#!/usr/bin/env bash
printf '%s\n' "\$1" > "$OPEN_LOG"
SCRIPT

chmod +x "$FAKE_BIN/uname" "$FAKE_BIN/swift" "$FAKE_BIN/swiftc" "$FAKE_BIN/xcrun" "$FAKE_BIN/codesign" "$FAKE_BIN/ditto" "$FAKE_BIN/otool" "$FAKE_BIN/install_name_tool" "$FAKE_BIN/lipo" "$FAKE_BIN/open" "$FAKE_BIN/plutil" "$FAKE_BIN/strip"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_SWIFT_BIN/VoicePanel"
chmod +x "$FAKE_SWIFT_BIN/VoicePanel"

EXPECTED_APP="$ROOT_DIR/.build/app/VoicePanel.app"
BUILD_STDOUT="$(PATH="$FAKE_BIN:$PATH" XCRUN_BIN="$FAKE_BIN/xcrun" VOICEPANEL_SKIP_TOOLCHAIN_CHECK=1 "$ROOT_DIR/scripts/build-app.sh" 2>"$TMP_DIR/build.stderr")"

[[ "$BUILD_STDOUT" == "$EXPECTED_APP" ]] || {
    echo "build-app.sh stdout was not the exact application path" >&2
    printf 'Expected: %s\nActual: %s\n' "$EXPECTED_APP" "$BUILD_STDOUT" >&2
    exit 1
}
[[ -d "$EXPECTED_APP" ]] || {
    echo "build-app.sh did not assemble the application bundle" >&2
    exit 1
}
[[ -d "$EXPECTED_APP/Contents/Frameworks/whisper.framework" ]] || {
    echo "build-app.sh did not embed the required dynamic Whisper framework" >&2
    exit 1
}
if find "$EXPECTED_APP/Contents/Frameworks" -maxdepth 1 \( -iname '*sherpa*' -o -iname '*onnxruntime*' \) | grep -q .; then
    echo "static sherpa-onnx artifacts were incorrectly copied into the app bundle" >&2
    exit 1
fi

PATH="$FAKE_BIN:$PATH" XCRUN_BIN="$FAKE_BIN/xcrun" VOICEPANEL_SKIP_TOOLCHAIN_CHECK=1 "$ROOT_DIR/scripts/run-dev.sh" >/dev/null 2>"$TMP_DIR/run.stderr"
[[ "$(cat "$OPEN_LOG")" == "$EXPECTED_APP" ]] || {
    echo "run-dev.sh did not pass the exact application path to open" >&2
    exit 1
}

echo "Build script regression test passed."
