# Testing VoicePanel

[Back to documentation](README.md) · [Building](BUILDING.md)

## Standard validation

```bash
./scripts/test.sh
```

This runs toolchain, source-contract, formatting, build-script, DMG-script, and
release-metadata checks; builds the platform-independent core checks; validates
the macOS application; and type-checks runtime bridges. The project uses the
`VoicePanelCoreChecks` executable for core regression checks rather than relying
on `swift test` alone.

When preparing changed Swift sources, format first:

```bash
./scripts/format.sh
./scripts/test.sh
```

For the combined release validation:

```bash
./scripts/release-check.sh
```

[Validation contracts](VALIDATION.md) lists the covered behavior and manual
checks. On non-macOS hosts, app-only checks cannot run and the core encryption
compatibility target needs system OpenSSL/libcrypto.

## UI regression suite

Full Xcode is required. Select its developer directory if Command Line Tools
are currently active:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./scripts/test-ui.sh --quick
./scripts/test-ui.sh --full
```

Use `--test NAME` for an individual scenario or `--bootstrap` to diagnose the
XCTest host. The checked-in harness requires no project generator. Results are
written under `.build/ui-tests/`. Test fixtures use isolated preferences,
synthetic recognition, and temporary history. See [UI test documentation](../UITests/README.md).

## Manual checks

Use a synthetic phrase and a non-sensitive audio file to verify:

1. First launch, menu-bar startup, microphone permission, and Apple Speech permission.
2. Hold/release push-to-talk, menu start/stop, and cancellation while preparing.
3. Live drafts, final transcript, automatic copy, and editable completion.
4. Audio import through the picker and drag-and-drop, including cancellation.
5. Model download, integrity checks, switching engines, and recovery startup.
6. Encrypted history unlock, retention, pinning, and deletion.
7. Reusable benchmark samples, pipeline visualization, and JSON export.

Test each architecture on matching hardware. Cross-compiling Intel or running
it through Rosetta does not establish microphone reliability on an Intel Mac.

## Recording-panel screenshot fixture

The app can display synthetic recording text without opening the microphone.
Run an assembled app executable with isolated test preferences:

```bash
VOICEPANEL_UI_TESTING=1 \
VOICEPANEL_PANEL_PREVIEW=recording \
VOICEPANEL_PANEL_PREVIEW_PATH=/tmp/VoicePanel-recording-preview.png \
.build/release-apps/arm64/VoicePanel.app/Contents/MacOS/VoicePanel
```

The window is rendered to PNG and the app exits. The preview never captures
real speech. Other states are `processing`, `success`, and `error`. Adjust the
executable path to match your app output directory.
