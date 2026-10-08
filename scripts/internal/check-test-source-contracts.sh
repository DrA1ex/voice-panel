#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_DIR="$ROOT_DIR/Tests/VoicePanelCoreChecks"
PACKAGE_FILE="$ROOT_DIR/Package.swift"
PUBLIC_TEST_SCRIPT="$ROOT_DIR/scripts/test.sh"
TEST_SCRIPT="$ROOT_DIR/scripts/internal/test-suite.sh"

fail() {
    echo "Test source contract failed: $1" >&2
    exit 1
}

[[ -d "$CHECK_DIR" ]] \
    || fail "framework-independent core checks are missing"

if grep -R -Eq '^[[:space:]]*import[[:space:]]+(XCTest|Testing)([[:space:]]|$)' "$ROOT_DIR/Tests"; then
    fail "core checks must not depend on XCTest or Swift Testing"
fi

if grep -Fq '.testTarget(' "$PACKAGE_FILE"; then
    fail "Package.swift must not create a SwiftPM test target that can require XCTest"
fi

grep -Fq '.executableTarget(' "$PACKAGE_FILE" \
    || fail "the core check executable target is missing"
grep -Fq 'name: "VoicePanelCoreChecks"' "$PACKAGE_FILE" \
    || fail "the VoicePanelCoreChecks target is missing"
grep -Fq 'coreDependencies.append("VoicePanelCryptoCompat")' "$PACKAGE_FILE" \
    || fail "VoicePanelCore must link the offline crypto compatibility target outside macOS"
grep -Fq 'linkerSettings: [.linkedLibrary("crypto")]' "$PACKAGE_FILE" \
    || fail "the non-macOS compatibility target must link system libcrypto"
grep -Fq '#if canImport(CryptoKit)' "$ROOT_DIR/Sources/VoicePanelCore/AESGCMCompat.swift" \
    || fail "history encryption must prefer Apple CryptoKit"
grep -Fq '#elseif canImport(VoicePanelCryptoCompat)' "$ROOT_DIR/Sources/VoicePanelCore/AESGCMCompat.swift" \
    || fail "history encryption must support the offline non-macOS compatibility target"
grep -Fq 'EVP_aes_256_gcm' "$ROOT_DIR/Sources/VoicePanelCryptoCompat/VoicePanelCryptoCompat.c" \
    || fail "the non-macOS compatibility target must implement AES-GCM"
grep -Fq 'test-suite.sh' "$PUBLIC_TEST_SCRIPT" \
    || fail "scripts/test.sh must delegate to the internal test suite"
grep -Fq 'VoicePanelCoreChecks' "$TEST_SCRIPT" \
    || fail "the internal test suite does not run the core check executable"
grep -Fq -- '--show-bin-path' "$TEST_SCRIPT" \
    || fail "the internal test suite must locate the strictly compiled check runner"
if grep -Fq '"$SWIFT_BIN" run' "$TEST_SCRIPT"; then
    fail "the internal test suite must execute the compiled core-check binary directly"
fi

grep -Fq 'scripts/internal/static-check.sh' "$TEST_SCRIPT" \
    || fail "the internal test suite must run the static Swift checks"
grep -Fq 'scripts/internal/check-app-source-contracts.sh' "$TEST_SCRIPT" \
    || fail "the internal test suite must run app source contracts"
grep -Fq 'scripts/internal/test-build-scripts.sh' "$TEST_SCRIPT" \
    || fail "the internal test suite must run build-script regression checks"
[[ -x "$ROOT_DIR/scripts/internal/test-package-dmg.sh" ]] \
    || fail "the DMG packaging regression test is missing or not executable"
grep -Fq 'scripts/internal/test-package-dmg.sh' "$TEST_SCRIPT" \
    || fail "the internal test suite must run DMG packaging regression checks"
[[ -x "$ROOT_DIR/scripts/internal/typecheck-diagnostics.sh" ]] \
    || fail "the diagnostic logger type-check is missing"
grep -Fq 'scripts/internal/typecheck-diagnostics.sh' "$TEST_SCRIPT" \
    || fail "the internal test suite must type-check persistent diagnostics"
[[ -x "$ROOT_DIR/scripts/internal/typecheck-local-onnx-download.sh" ]] \
    || fail "the local ONNX downloader type-check is missing or not executable"
grep -Fq 'scripts/internal/typecheck-local-onnx-download.sh' "$TEST_SCRIPT" \
    || fail "the internal test suite must type-check the local ONNX downloader"
[[ -x "$ROOT_DIR/scripts/internal/check-swiftui-view-builders.py" ]] \
    || fail "the SwiftUI ViewBuilder analyzer is missing or not executable"
[[ -x "$ROOT_DIR/scripts/internal/check-swiftui-previews.py" ]] \
    || fail "the SwiftUI preview coverage checker is missing or not executable"
grep -Fq 'check-swiftui-previews.py' "$ROOT_DIR/scripts/internal/check-app-source-contracts.sh" \
    || fail "app source contracts must enforce SwiftUI preview coverage"
[[ -x "$ROOT_DIR/scripts/internal/check-settings-view-initializer.py" ]] \
    || fail "the SettingsView initializer analyzer is missing or not executable"
grep -Fq 'init(' "$ROOT_DIR/Sources/VoicePanelApp/UI/SettingsView.swift" \
    || fail "SettingsView must expose an explicit initializer contract"
[[ -x "$ROOT_DIR/scripts/internal/test-swiftui-view-builder-check.sh" ]] \
    || fail "the SwiftUI ViewBuilder analyzer regression test is missing"
[[ -x "$ROOT_DIR/scripts/internal/test-settings-view-initializer-check.sh" ]] \
    || fail "the SettingsView initializer regression test is missing"
grep -Fq 'scripts/internal/test-settings-view-initializer-check.sh' "$ROOT_DIR/scripts/internal/static-check.sh" \
    || fail "the SettingsView initializer regression test must run with static checks"
[[ -f "$ROOT_DIR/.swift-format" ]] \
    || fail "the project swift-format configuration is missing"
grep -Fq '"spaces": 4' "$ROOT_DIR/.swift-format" \
    || fail "swift-format must use the project's four-space indentation"
grep -Fq -- '--configuration "$FORMAT_CONFIG"' "$ROOT_DIR/scripts/internal/static-check.sh" \
    || fail "swift-format lint must use the explicit project configuration"
grep -Fq -- '-warnings-as-errors' "$ROOT_DIR/scripts/internal/static-check.sh" \
    || fail "core static compilation must treat warnings as errors"
grep -Fq -- '-strict-concurrency=complete' "$ROOT_DIR/scripts/internal/static-check.sh" \
    || fail "core static compilation must enable complete concurrency checks"
grep -Fq -- '--product VoicePanelCoreChecks' "$ROOT_DIR/scripts/internal/static-check.sh" \
    || fail "the strict check runner build must link the executable product"
grep -Fq 'xargs -0 -n 20 "$SWIFTC_BIN"' "$ROOT_DIR/scripts/internal/static-check.sh" \
    || fail "Swift parser checks must use bounded batched compiler invocations"
grep -Fq -- '"${VOICEPANEL_SWIFTC_ARGS[@]}" -parse' "$ROOT_DIR/scripts/internal/static-check.sh" \
    || fail "Swift parser checks must use the public swiftc -parse option"
grep -Fq 'xargs -0 -n 20 "$FORMAT_BIN" lint' "$ROOT_DIR/scripts/internal/static-check.sh" \
    || fail "swift-format checks must use bounded batches"
if grep -Fq -- '-frontend -parse' "$ROOT_DIR/scripts/internal/static-check.sh"; then
    fail "static checks must not rely on the unsupported swiftc -frontend driver escape"
fi
grep -Fq 'struct CheckCase: Sendable' "$CHECK_DIR/CheckSupport.swift" \
    || fail "the core check harness must be Sendable under Swift 6 checks"
grep -Fq 'recognitionProfilesChecks' "$CHECK_DIR/VoicePanelCoreChecksMain.swift" \
    || fail "recognition profile regression checks must run with the core suite"
[[ -f "$CHECK_DIR/RecognitionProfilesChecks.swift" ]] \
    || fail "recognition profile regression checks are missing"
[[ -f "$CHECK_DIR/WhisperBoundaryModesChecks.swift" ]] \
    || fail "Whisper boundary mode regression checks are missing"
grep -Fq 'whisperBoundaryModesChecks' "$CHECK_DIR/VoicePanelCoreChecksMain.swift" \
    || fail "Whisper boundary mode checks must run with the core suite"
[[ -f "$CHECK_DIR/WhisperBoundaryPromptBuilderChecks.swift" ]] \
    || fail "Whisper boundary prompt regression checks are missing"
grep -Fq 'whisperBoundaryPromptBuilderChecks' "$CHECK_DIR/VoicePanelCoreChecksMain.swift" \
    || fail "Whisper boundary prompt checks must run with the core suite"
[[ -f "$CHECK_DIR/WhisperBoundaryRepairPolicyChecks.swift" ]] \
    || fail "Whisper boundary repair regression checks are missing"
grep -Fq 'whisperBoundaryRepairPolicyChecks' "$CHECK_DIR/VoicePanelCoreChecksMain.swift" \
    || fail "Whisper boundary repair checks must run with the core suite"
[[ -f "$CHECK_DIR/WhisperBoundaryBridgeChecks.swift" ]] \
    || fail "Whisper boundary bridge regression checks are missing"
grep -Fq 'whisperBoundaryBridgeChecks' "$CHECK_DIR/VoicePanelCoreChecksMain.swift" \
    || fail "Whisper boundary bridge checks must run with the core suite"
[[ -f "$CHECK_DIR/HotKeyReleaseTailPolicyChecks.swift" ]] \
    || fail "hot-key release tail regression checks are missing"
[[ -f "$CHECK_DIR/RecognitionPipelineValidatorChecks.swift" ]] \
    || fail "pipeline validation regression checks are missing"
[[ -f "$CHECK_DIR/RecognitionPipelineVisualizationPolicyChecks.swift" ]] \
    || fail "pipeline visualization policy regression checks are missing"
[[ -f "$CHECK_DIR/RecognitionInferenceChunkPolicyChecks.swift" ]] \
    || fail "inference chunk admission regression checks are missing"
grep -Fq 'recognitionInferenceChunkPolicyChecks' "$CHECK_DIR/VoicePanelCoreChecksMain.swift" \
    || fail "inference chunk admission checks must run with the core suite"
grep -Fq 'hotKeyReleaseTailPolicyChecks' "$CHECK_DIR/VoicePanelCoreChecksMain.swift" \
    || fail "hot-key release tail checks must run with the core suite"
grep -Fq 'recognitionPipelineValidatorChecks' "$CHECK_DIR/VoicePanelCoreChecksMain.swift" \
    || fail "pipeline validation checks must run with the core suite"
grep -Fq 'recognitionPipelineVisualizationPolicyChecks' "$CHECK_DIR/VoicePanelCoreChecksMain.swift" \
    || fail "pipeline visualization policy checks must run with the core suite"
[[ -x "$ROOT_DIR/scripts/format.sh" ]] \
    || fail "the project formatter script is missing"
grep -Fq 'xargs -0 -n 20 "$FORMAT_BIN" format' "$ROOT_DIR/scripts/format.sh" \
    || fail "the formatter script must use bounded batches"
[[ -x "$ROOT_DIR/scripts/internal/sourcekit-check.sh" ]] \
    || fail "the SourceKit-LSP indexing check is missing"
[[ -x "$ROOT_DIR/scripts/internal/macos-app-check.sh" ]] \
    || fail "the macOS application compilation check is missing"
grep -Fq 'scripts/internal/macos-app-check.sh' "$TEST_SCRIPT" \
    || fail "the internal test suite must compile the real macOS app when running on macOS"
grep -Fq -- '-warnings-as-errors' "$ROOT_DIR/scripts/internal/macos-app-check.sh" \
    || fail "the macOS app check must promote warnings to errors"

# Whisper Core ML downloads and runtime aliases require an isolated downloader type-check.
grep -Fq 'typecheck-whisper-download.sh' "$ROOT_DIR/scripts/internal/test-suite.sh" \
    || fail "Whisper model downloader type-check must run in the standard test suite"
grep -Fq 'typecheck-vad-download.sh' "$ROOT_DIR/scripts/internal/test-suite.sh" \
    || fail "Silero VAD downloader type-check must run in the standard test suite"

echo "Test source contracts passed."
