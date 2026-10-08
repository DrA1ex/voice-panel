# VoicePanel scripts

Supported project commands:

- `./scripts/run-dev.sh` — build and launch VoicePanel.
- `./scripts/run-safe.sh` — launch without automatic local-model preload.
- `./scripts/build-app.sh` — assemble one `.app` bundle and print its path.
- `./scripts/package-dmg.sh` — create architecture-specific DMGs with optional
  Developer ID signing and notarization.
- `./scripts/format.sh` — format Swift sources with the checked-in rules.
- `./scripts/test.sh` — run the complete non-interactive validation suite.
- `./scripts/test-ui.sh` — build the real app and run the macOS XCUIAutomation regression suite.
- `./scripts/release-check.sh` — format, test, and validate release metadata.
- `./scripts/clean.sh` — remove build output.
- `./scripts/reset-settings.sh` — reset current and legacy preferences while
  preserving models and transcript history.

`scripts/internal` contains implementation checks and fixtures invoked by the
supported commands. It is not a stable user-facing interface.
