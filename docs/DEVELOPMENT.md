# Development

## Requirements

- macOS 14 or later;
- a current Xcode command-line toolchain with Swift 5.10 support;
- internet access for the first SwiftPM dependency download.

The project uses Swift Package Manager rather than an Xcode project file.
On non-macOS hosts, the platform-independent history checks use the small `VoicePanelCryptoCompat` target backed by system OpenSSL/libcrypto. macOS application builds use the system CryptoKit framework and do not compile or bundle that compatibility target.

See [Building](BUILDING.md) for architecture-specific bundles and DMGs, and
[Testing](TESTING.md) for automated and manual validation.

## Build and run

```bash
./scripts/run-dev.sh
```

The first build downloads pinned whisper.cpp, sherpa-onnx, and ONNX Runtime
binary frameworks.

To launch without automatically preloading a saved local model:

```bash
./scripts/run-safe.sh
```


## Xcode previews

Open `Package.swift` in Xcode, select a SwiftUI source file, and enable the canvas with **Editor → Canvas**. Every production `View` and `NSViewRepresentable` now has at least one `#Preview`, including the five Settings pages, compact-panel states, History states, model storage, transcript views, and the individual Pipeline Validation tracks.

Preview fixtures use isolated `UserDefaults`, temporary model/history directories, and disabled Core Audio device monitors. Opening or refreshing a preview therefore does not change the normal VoicePanel preferences, inspect the real model library, unlock transcript history, or start microphone monitoring.

The preview support is compiled only for debug builds. The standard source-contract suite runs `scripts/internal/check-swiftui-previews.py` and fails when a new production view is added without preview coverage.

## Supported scripts

- `./scripts/run-dev.sh` — build and launch the app.
- `./scripts/run-safe.sh` — launch with local-model preload disabled.
- `./scripts/build-app.sh` — assemble one `.app` bundle.
- `./scripts/package-dmg.sh` — build architecture-specific DMGs.
- `./scripts/format.sh` — apply the checked-in Swift formatting rules.
- `./scripts/test.sh` — run the complete validation suite.
- `./scripts/release-check.sh` — format, validate, and check release metadata.
- `./scripts/clean.sh` — remove build output.
- `./scripts/reset-settings.sh` — reset preferences while preserving models and
  transcript history.

Implementation helpers under `scripts/internal` are not a stable command-line
interface.

## Toolchain handling

Build scripts select the SDK and Swift compiler from the same `xcrun`
toolchain and pin the deployment target to macOS 14. This prevents inherited
shell values such as a stale `SDKROOT` or `MACOSX_DEPLOYMENT_TARGET=26.0` from
selecting an incompatible standard library.

Run the normal validation command to inspect the selected toolchain:

```bash
./scripts/test.sh
```

## Runtime packaging

SwiftPM binary targets may provide dynamic frameworks or static XCFramework
slices. `build-app.sh` embeds only dynamic artifacts and validates the finished
executable with `otool -L`. Static sherpa-onnx and ONNX Runtime slices are linked
into the executable and do not need to appear under `Contents/Frameworks`.

See [Architecture](ARCHITECTURE.md), [Validation](VALIDATION.md), and
[Release packaging](RELEASE.md) for the deeper project contracts.
