#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="VoicePanel"
ARCHITECTURES=(arm64 x86_64)
REQUESTED_ARCHITECTURES=()
SIGN_IDENTITY="${VOICEPANEL_CODESIGN_IDENTITY:--}"
NOTARY_PROFILE="${VOICEPANEL_NOTARY_PROFILE:-}"
DIST_DIR="${VOICEPANEL_DIST_DIR:-$ROOT_DIR/dist}"
BUILD_APP_SCRIPT="${VOICEPANEL_BUILD_APP_SCRIPT:-$ROOT_DIR/scripts/build-app.sh}"
RELEASE_APP_ROOT="${VOICEPANEL_RELEASE_APP_ROOT:-$ROOT_DIR/.build/release-apps}"
DMG_BACKGROUND="$ROOT_DIR/Resources/Branding/DMGBackground.png"

usage() {
    cat <<'USAGE'
Usage: ./scripts/package-dmg.sh [--arch arm64|x86_64|all] [--sign IDENTITY] [--notarize PROFILE]

Creates one DMG per requested CPU architecture. By default both Apple Silicon
and Intel packages are built. Pass a Developer ID Application certificate with
--sign (or VOICEPANEL_CODESIGN_IDENTITY) for a distributable release. Pass a
notarytool keychain profile with --notarize (or VOICEPANEL_NOTARY_PROFILE) to
submit each DMG, wait for approval, and staple the result.

Examples:
  ./scripts/package-dmg.sh --arch arm64 --sign 'Developer ID Application: Example, Inc. (TEAMID)'
  ./scripts/package-dmg.sh --sign 'Developer ID Application: Example, Inc. (TEAMID)' --notarize VoicePanelNotary
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            case "$2" in
                arm64|x86_64) REQUESTED_ARCHITECTURES=("$2") ;;
                all) REQUESTED_ARCHITECTURES=("${ARCHITECTURES[@]}") ;;
                *)
                    echo "Unsupported architecture: $2" >&2
                    usage >&2
                    exit 2
                    ;;
            esac
            shift 2
            ;;
        --sign)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            SIGN_IDENTITY="$2"
            shift 2
            ;;
        --notarize)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ ${#REQUESTED_ARCHITECTURES[@]} -eq 0 ]]; then
    REQUESTED_ARCHITECTURES=("${ARCHITECTURES[@]}")
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "DMG packages can only be created on macOS." >&2
    exit 1
fi

if [[ -n "$NOTARY_PROFILE" && "$SIGN_IDENTITY" == "-" ]]; then
    echo "Notarization requires a Developer ID Application signing identity." >&2
    exit 1
fi

if [[ ! -f "$DMG_BACKGROUND" ]]; then
    echo "DMG background is missing: $DMG_BACKGROUND" >&2
    exit 1
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "Warning: creating ad-hoc signed local-test packages. Use --sign for publication." >&2
fi

"$ROOT_DIR/scripts/internal/check-release-metadata.sh" >&2
mkdir -p "$DIST_DIR"

for architecture in "${REQUESTED_ARCHITECTURES[@]}"; do
    app_output_dir="$RELEASE_APP_ROOT/$architecture"
    app_path="$(
        VOICEPANEL_TARGET_ARCH="$architecture" \
        VOICEPANEL_APP_OUTPUT_DIR="$app_output_dir" \
        VOICEPANEL_CODESIGN_IDENTITY="$SIGN_IDENTITY" \
        "$BUILD_APP_SCRIPT"
    )"

    if [[ ! -d "$app_path" ]]; then
        echo "Expected app bundle was not produced: $app_path" >&2
        exit 1
    fi
    if ! lipo "$app_path/Contents/MacOS/$APP_NAME" -verify_arch "$architecture"; then
        echo "Packaged app is missing $architecture: $app_path" >&2
        exit 1
    fi
    codesign --verify --deep --strict "$app_path"

    version="$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")"
    dmg_name="$APP_NAME-$version-$architecture.dmg"
    dmg_path="$DIST_DIR/$dmg_name"
    working_dir="$(mktemp -d "${TMPDIR:-/tmp}/voice-panel-dmg.XXXXXX")"
    staging_dir="$working_dir/staging"
    mount_dir="$working_dir/VoicePanel-Styling-$architecture-$$"
    finder_disk_name="$(basename "$mount_dir")"
    writable_dmg="$working_dir/VoicePanel-readwrite.dmg"
    volume_name="$APP_NAME $version ($architecture)"
    mkdir -p "$staging_dir" "$mount_dir"
    dmg_is_mounted=false
    cleanup_dmg_working_directory() {
        if [[ "$dmg_is_mounted" == true ]]; then
            hdiutil detach "$mount_dir" -force >/dev/null 2>&1 || true
        fi
        rm -rf "$working_dir"
    }
    trap cleanup_dmg_working_directory EXIT

    ditto "$app_path" "$staging_dir/$APP_NAME.app"
    ln -s /Applications "$staging_dir/Applications"
    rm -f "$dmg_path"
    hdiutil create \
        -volname "$volume_name" \
        -srcfolder "$staging_dir" \
        -ov \
        -fs HFS+ \
        -format UDRW \
        "$writable_dmg" >&2

    hdiutil attach \
        "$writable_dmg" \
        -readwrite \
        -noverify \
        -noautoopen \
        -mountpoint "$mount_dir" >&2
    dmg_is_mounted=true
    mkdir -p "$mount_dir/.background"
    cp "$DMG_BACKGROUND" "$mount_dir/.background/DMGBackground.png"

    if ! osascript \
        - \
        "$finder_disk_name" \
        "$APP_NAME.app" \
        "$mount_dir/.background/DMGBackground.png" <<'APPLESCRIPT'
on run arguments
    set volumeName to item 1 of arguments
    set appName to item 2 of arguments
    set backgroundPicture to POSIX file (item 3 of arguments) as alias
    tell application "Finder"
        tell disk volumeName
            open
            tell container window
                set current view to icon view
                set toolbar visible to false
                set statusbar visible to false
                set pathbar visible to false
                set bounds to {100, 100, 760, 540}
            end tell
            set viewOptions to the icon view options of container window
            tell viewOptions
                set arrangement to not arranged
                set icon size to 104
                set text size to 12
            end tell
            set background picture of viewOptions to backgroundPicture
            set position of item appName of container window to {150, 205}
            set position of item "Applications" of container window to {510, 205}
            close
            open
            delay 1
            tell container window
                set bounds to {100, 100, 750, 530}
            end tell
        end tell
        delay 1
        tell disk volumeName
            tell container window
                set bounds to {100, 100, 760, 540}
            end tell
        end tell
        delay 3
    end tell
end run
APPLESCRIPT
    then
        echo "Could not configure the DMG Finder layout." >&2
        echo "Allow the invoking terminal or automation host to control Finder in System Settings → Privacy & Security → Automation, then retry." >&2
        exit 1
    fi

    for _ in {1..10}; do
        [[ -f "$mount_dir/.DS_Store" ]] && break
        sleep 1
    done
    if [[ ! -f "$mount_dir/.DS_Store" ]]; then
        echo "Finder did not persist the DMG layout to .DS_Store." >&2
        exit 1
    fi

    sync
    hdiutil detach "$mount_dir" >&2
    dmg_is_mounted=false
    hdiutil convert \
        "$writable_dmg" \
        -format UDZO \
        -imagekey zlib-level=9 \
        -o "$dmg_path" >&2
    rm -rf "$working_dir"
    trap - EXIT

    hdiutil verify "$dmg_path" >&2
    if [[ "$SIGN_IDENTITY" != "-" ]]; then
        codesign --force --sign "$SIGN_IDENTITY" --timestamp "$dmg_path" >&2
        codesign --verify --strict --verbose=2 "$dmg_path" >&2
    fi

    if [[ -n "$NOTARY_PROFILE" ]]; then
        xcrun notarytool submit "$dmg_path" --keychain-profile "$NOTARY_PROFILE" --wait >&2
        xcrun stapler staple "$dmg_path" >&2
        xcrun stapler validate "$dmg_path" >&2
    fi

    (cd "$(dirname "$dmg_path")" && shasum -a 256 "$dmg_name" > "$dmg_name.sha256")

    printf '%s\n' "$dmg_path"
done
