# Building VoicePanel

[Back to documentation](README.md) · [Development](DEVELOPMENT.md) · [Testing](TESTING.md)

## Requirements

- macOS 14 or later and an Apple Silicon or Intel Mac.
- Xcode Command Line Tools with Swift 5.10 language support or newer.
- Internet access for the first download of pinned SwiftPM binary frameworks.
- Full Xcode for the optional XCUIAutomation suite and SwiftUI canvas previews.

Clone the repository and enter its directory:

```bash
git clone https://github.com/DrA1ex/voice-panel.git
cd voice-panel
```

## Run a development build

```bash
./scripts/run-dev.sh
```

To defer automatic local-model preload:

```bash
./scripts/run-safe.sh
```

The scripts use Swift Package Manager. You can open `Package.swift` in Xcode;
no generated application project is required.

## Assemble an app

```bash
./scripts/build-app.sh
```

The builder prints the assembled `.app` path on stdout. By default it builds a
release executable for the host architecture and applies an ad-hoc signature.
To choose an architecture and output directory explicitly:

```bash
VOICEPANEL_TARGET_ARCH=arm64 \
VOICEPANEL_APP_OUTPUT_DIR=.build/apple-silicon-app \
./scripts/build-app.sh

VOICEPANEL_TARGET_ARCH=x86_64 \
VOICEPANEL_APP_OUTPUT_DIR=.build/intel-app \
./scripts/build-app.sh
```

The builder embeds dynamic dependencies, checks architecture and runtime linkage,
removes release debug symbols, includes license notices, signs the app, and
verifies the microphone entitlement. The scripts select a
matching Swift compiler and SDK and target macOS 14.

## Package disk images

```bash
./scripts/package-dmg.sh
```

This writes both architecture-specific DMGs to `dist/`. Use `--arch arm64` or `--arch x86_64` to build one. Without a Developer
ID identity the packages are ad-hoc signed and are not notarized.

See [Release packaging](RELEASE.md) for Developer ID signing, notarization,
artifact verification, and publication. Downloaded recognition models are
installed at runtime and are not bundled in the app.

## Build problems

Check [Troubleshooting](TROUBLESHOOTING.md) for stale SwiftPM artifacts,
framework checksum failures, and missing modules. Use `./scripts/clean.sh` when
you intentionally want to remove generated build output.
