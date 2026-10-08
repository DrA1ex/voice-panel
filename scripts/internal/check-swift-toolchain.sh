#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=swift-toolchain-env.sh
source "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh"

if [[ "${VOICEPANEL_SKIP_TOOLCHAIN_CHECK:-0}" == "1" ]]; then
    echo "Swift toolchain target check skipped by test harness."
    exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Swift toolchain target check skipped outside macOS."
    exit 0
fi

CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
cat > "$CHECK_DIR/ToolchainCheck.swift" <<'SWIFT'
import Foundation
let value = ProcessInfo.processInfo.operatingSystemVersion
_ = value
SWIFT

if ! "$SWIFTC_BIN" \
    "${VOICEPANEL_SWIFTC_ARGS[@]}" \
    -typecheck \
    "$CHECK_DIR/ToolchainCheck.swift"; then
    cat >&2 <<MESSAGE
VoicePanel could not use the selected Apple Swift toolchain.
Swift: $SWIFT_BIN
SDKROOT: $SDKROOT
Target: $VOICEPANEL_SWIFT_TARGET

A global SDKROOT or MACOSX_DEPLOYMENT_TARGET often causes this. VoicePanel
already overrides both to macOS 14. If the check still fails, verify that
'xcode-select -p', 'xcrun swift --version', and the installed SDK belong to the
same Xcode or Command Line Tools installation.
MESSAGE
    exit 1
fi

echo "Swift toolchain target check passed: $VOICEPANEL_SWIFT_TARGET"
