#!/usr/bin/env bash
# Shared Swift toolchain selection for VoicePanel scripts.
# Source this file after ROOT_DIR has been defined.

VOICEPANEL_SWIFT_BUILD_ARGS=()
VOICEPANEL_SWIFTC_ARGS=()

if [[ "$(uname -s)" == "Darwin" ]]; then
    XCRUN_BIN="${XCRUN_BIN:-$(command -v xcrun || true)}"
    if [[ ! -x "$XCRUN_BIN" ]]; then
        echo "xcrun was not found at $XCRUN_BIN." >&2
        return 1 2>/dev/null || exit 1
    fi

    # A shell-wide MACOSX_DEPLOYMENT_TARGET can silently force Swift to target
    # a newer OS than the selected toolchain can load (for example macOS 26).
    # VoicePanel supports macOS 14+, so keep every script on that explicit target.
    export MACOSX_DEPLOYMENT_TARGET="${VOICEPANEL_MACOS_DEPLOYMENT_TARGET:-14.0}"
    SWIFT_BIN="$($XCRUN_BIN --sdk macosx --find swift)"
    SWIFTC_BIN="$($XCRUN_BIN --sdk macosx --find swiftc)"

    VOICEPANEL_HOST_ARCH="$(uname -m)"
    VOICEPANEL_SWIFT_ARCH="${VOICEPANEL_TARGET_ARCH:-$VOICEPANEL_HOST_ARCH}"
    case "$VOICEPANEL_SWIFT_ARCH" in
        arm64) VOICEPANEL_SWIFT_ARCH="arm64" ;;
        x86_64) VOICEPANEL_SWIFT_ARCH="x86_64" ;;
        *)
            echo "Unsupported macOS target architecture: $VOICEPANEL_SWIFT_ARCH" >&2
            return 1 2>/dev/null || exit 1
            ;;
    esac

    VOICEPANEL_SWIFT_TARGET="${VOICEPANEL_SWIFT_ARCH}-apple-macosx${MACOSX_DEPLOYMENT_TARGET}"
    DEFAULT_SDKROOT="$($XCRUN_BIN --sdk macosx --show-sdk-path)"
    SDKROOT="${VOICEPANEL_SDKROOT:-$DEFAULT_SDKROOT}"

    # Command Line Tools updates can temporarily leave the unversioned SDK
    # symlink and Swift compiler on different patch releases. Select the first
    # installed SDK the active compiler can actually import instead of making
    # every public script fail with a SwiftShims/module-version error.
    if [[ -z "${VOICEPANEL_SDKROOT:-}" ]]; then
        MODULE_CACHE_ROOT="${VOICEPANEL_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/voice-panel-module-cache}"
        mkdir -p "$MODULE_CACHE_ROOT"
        export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_ROOT"
        export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_ROOT"

        SDK_CHECK_FILE="$(mktemp "${TMPDIR:-/tmp}/voice-panel-sdk-check.XXXXXX.swift")"
        printf 'import Foundation\n' > "$SDK_CHECK_FILE"
        SDK_DIRECTORY="$(dirname "$DEFAULT_SDKROOT")"
        for SDK_CANDIDATE in "$DEFAULT_SDKROOT" "$SDK_DIRECTORY"/MacOSX*.sdk; do
            [[ -d "$SDK_CANDIDATE" ]] || continue
            if "$SWIFTC_BIN" \
                -target "$VOICEPANEL_SWIFT_TARGET" \
                -sdk "$SDK_CANDIDATE" \
                -module-cache-path "$MODULE_CACHE_ROOT" \
                -typecheck "$SDK_CHECK_FILE" >/dev/null 2>&1; then
                SDKROOT="$SDK_CANDIDATE"
                break
            fi
        done
        rm -f "$SDK_CHECK_FILE"
    fi
    export SDKROOT

    VOICEPANEL_SWIFTPM_CACHE_PATH="${VOICEPANEL_SWIFTPM_CACHE_PATH:-$ROOT_DIR/.swiftpm/cache}"
    mkdir -p "$VOICEPANEL_SWIFTPM_CACHE_PATH"

    VOICEPANEL_SWIFT_BUILD_ARGS=(
        --cache-path "$VOICEPANEL_SWIFTPM_CACHE_PATH"
        --triple "$VOICEPANEL_SWIFT_TARGET"
    )
    VOICEPANEL_SWIFTC_ARGS=(
        -target "$VOICEPANEL_SWIFT_TARGET"
        -sdk "$SDKROOT"
    )
else
    SWIFT_BIN="$(command -v swift || true)"
    SWIFTC_BIN="$(command -v swiftc || true)"
    VOICEPANEL_SWIFT_TARGET=""
fi

if [[ -z "${SWIFT_BIN:-}" || ! -x "$SWIFT_BIN" ]]; then
    echo "Swift compiler driver was not found." >&2
    return 1 2>/dev/null || exit 1
fi
if [[ -z "${SWIFTC_BIN:-}" || ! -x "$SWIFTC_BIN" ]]; then
    echo "swiftc was not found." >&2
    return 1 2>/dev/null || exit 1
fi
