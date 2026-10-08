#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="VoicePanel"
CONFIGURATION="${CONFIGURATION:-release}"
TARGET_ARCH="${VOICEPANEL_TARGET_ARCH:-}"
OUTPUT_DIR="${VOICEPANEL_APP_OUTPUT_DIR:-$ROOT_DIR/.build/app}"
CODE_SIGN_IDENTITY="${VOICEPANEL_CODESIGN_IDENTITY:--}"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
ENTITLEMENTS_FILE="$ROOT_DIR/Resources/VoicePanel.entitlements"
APP_ICON_FILE="$ROOT_DIR/Resources/VoicePanel.icns"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This app can only be built on macOS." >&2
    exit 1
fi

source "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh"
"$ROOT_DIR/scripts/internal/check-swift-toolchain.sh" >&2
"$ROOT_DIR/scripts/internal/check-app-source-contracts.sh"

if [[ -n "$TARGET_ARCH" && "$TARGET_ARCH" != "$VOICEPANEL_SWIFT_ARCH" ]]; then
    echo "Requested architecture does not match the selected Swift target: $TARGET_ARCH" >&2
    exit 1
fi

NESTED_CODE_SIGN_ARGS=(--force --sign "$CODE_SIGN_IDENTITY")
APP_CODE_SIGN_ARGS=(
    --force
    --sign "$CODE_SIGN_IDENTITY"
    --entitlements "$ENTITLEMENTS_FILE"
)
if [[ "$CODE_SIGN_IDENTITY" != "-" ]]; then
    NESTED_CODE_SIGN_ARGS+=(--options runtime --timestamp)
    APP_CODE_SIGN_ARGS+=(--options runtime --timestamp)
fi

echo "Building $APP_NAME for $VOICEPANEL_SWIFT_ARCH ($CONFIGURATION)..." >&2
cd "$ROOT_DIR"
BIN_DIR="$("$SWIFT_BIN" build "${VOICEPANEL_SWIFT_BUILD_ARGS[@]}" -c "$CONFIGURATION" --show-bin-path)"
"$SWIFT_BIN" build "${VOICEPANEL_SWIFT_BUILD_ARGS[@]}" -c "$CONFIGURATION" --product "$APP_NAME" >&2

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"
cp "$BIN_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$APP_ICON_FILE" "$RESOURCES_DIR/VoicePanel.icns"
cp "$ROOT_DIR/LICENSE" "$RESOURCES_DIR/LICENSE"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"
plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
plutil -lint "$ENTITLEMENTS_FILE" >/dev/null

# SwiftPM binary targets may contain either dynamic frameworks/dylibs or static
# libraries. Only dynamic artifacts belong in Contents/Frameworks; static
# libraries are already linked into the executable and must not be required here.
EMBEDDED_DYNAMIC_COUNT=0
while IFS= read -r -d '' framework; do
    framework_name="$(basename "$framework")"
    destination="$FRAMEWORKS_DIR/$framework_name"
    if [[ ! -d "$destination" ]]; then
        ditto "$framework" "$destination"
        EMBEDDED_DYNAMIC_COUNT=$((EMBEDDED_DYNAMIC_COUNT + 1))
    fi
done < <(find "$ROOT_DIR/.build/artifacts" -type d -name '*.framework' -path '*macos*' -print0 2>/dev/null || true)

while IFS= read -r -d '' dylib; do
    dylib_name="$(basename "$dylib")"
    destination="$FRAMEWORKS_DIR/$dylib_name"
    if [[ ! -f "$destination" ]]; then
        cp -p "$dylib" "$destination"
        EMBEDDED_DYNAMIC_COUNT=$((EMBEDDED_DYNAMIC_COUNT + 1))
    fi
done < <(find "$ROOT_DIR/.build/artifacts" -type f -name '*.dylib' -path '*macos*' -print0 2>/dev/null || true)

chmod +x "$MACOS_DIR/$APP_NAME"
if ! lipo "$MACOS_DIR/$APP_NAME" -verify_arch "$VOICEPANEL_SWIFT_ARCH"; then
    echo "Built executable is missing the requested architecture: $VOICEPANEL_SWIFT_ARCH" >&2
    exit 1
fi
if ! otool -l "$MACOS_DIR/$APP_NAME" | grep -Fq '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$MACOS_DIR/$APP_NAME"
fi

# Validate what the finished executable actually loads. This correctly handles
# sherpa-onnx/ONNX Runtime builds that are delivered as static XCFrameworks,
# while still failing if a required dynamic dependency was not embedded.
while IFS= read -r dependency; do
    case "$dependency" in
        @rpath/*.framework/*)
            framework_name="$(printf '%s\n' "$dependency" | sed -E 's#^@rpath/([^/]+\.framework)/.*#\1#')"
            if [[ ! -d "$FRAMEWORKS_DIR/$framework_name" ]]; then
                echo "Required dynamic framework was not embedded: $framework_name" >&2
                exit 1
            fi
            ;;
        @rpath/*.dylib)
            dylib_name="$(basename "$dependency")"
            if [[ ! -f "$FRAMEWORKS_DIR/$dylib_name" ]]; then
                echo "Required dynamic library was not embedded: $dylib_name" >&2
                exit 1
            fi
            ;;
    esac
done < <(otool -L "$MACOS_DIR/$APP_NAME" | awk 'NR > 1 { print $1 }')

while IFS= read -r -d '' framework; do
    framework_binary="$framework/$(basename "$framework" .framework)"
    if ! lipo "$framework_binary" -verify_arch "$VOICEPANEL_SWIFT_ARCH"; then
        echo "Embedded framework is missing $VOICEPANEL_SWIFT_ARCH: $(basename "$framework")" >&2
        exit 1
    fi
    codesign "${NESTED_CODE_SIGN_ARGS[@]}" "$framework" >&2
done < <(find "$FRAMEWORKS_DIR" -maxdepth 1 -type d -name '*.framework' -print0)
while IFS= read -r -d '' dylib; do
    if ! lipo "$dylib" -verify_arch "$VOICEPANEL_SWIFT_ARCH"; then
        echo "Embedded library is missing $VOICEPANEL_SWIFT_ARCH: $(basename "$dylib")" >&2
        exit 1
    fi
    codesign "${NESTED_CODE_SIGN_ARGS[@]}" "$dylib" >&2
done < <(find "$FRAMEWORKS_DIR" -maxdepth 1 -type f -name '*.dylib' -print0)
# SwiftPM release binaries retain linker debug paths unless explicitly stripped.
# Remove debug symbols before signing so public builds do not expose local paths.
if [[ "$CONFIGURATION" == "release" ]]; then
    strip -S "$MACOS_DIR/$APP_NAME" >&2
fi
codesign "${APP_CODE_SIGN_ARGS[@]}" "$APP_DIR" >&2
codesign --verify --deep --strict --verbose=2 "$APP_DIR" >&2
SIGNED_ENTITLEMENTS="$(codesign --display --entitlements :- "$APP_DIR" 2>&1)"
if ! grep -Fq 'com.apple.security.device.audio-input' <<<"$SIGNED_ENTITLEMENTS"; then
    echo "Signed application is missing the microphone entitlement." >&2
    exit 1
fi

echo "Embedded dynamic runtime artifacts: $EMBEDDED_DYNAMIC_COUNT" >&2

# stdout is intentionally reserved for the resulting path. run-dev.sh uses it
# as a machine-readable value and must not receive SwiftPM progress messages.
printf '%s\n' "$APP_DIR"
