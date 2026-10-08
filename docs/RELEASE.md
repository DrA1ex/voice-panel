# Release packaging

VoicePanel 1.10.0 is configured with:

```text
Build number:      68
Bundle identifier: io.github.dra1ex.VoicePanel
Minimum macOS:    14.0
Architectures:    arm64 and x86_64
```

The project produces separate DMGs for Apple Silicon and Intel Macs. A public
release distributed outside the Mac App Store should use a Developer ID
Application certificate and Apple notarization.

## Before packaging

1. Confirm the MIT license in `LICENSE` and preserve third-party notices. Scan
   the intended public source tree and its Git history for secrets, personal
   paths, recordings, and private diagnostic artifacts.
2. Confirm `CFBundleShortVersionString`, `CFBundleVersion`, and
   `CFBundleIdentifier` in `Resources/Info.plist`. Increment the patch version
   for small fixes and the minor version for meaningful feature or workflow
   updates. Keep the major version unchanged unless compatibility is
   intentionally broken. Increase `CFBundleVersion` for every packaged build.
3. Run the release validation:

```bash
./scripts/release-check.sh
```

The DMG builder uses Finder once to save the custom background and icon
positions. macOS may require the invoking terminal or automation host to be
allowed to control Finder under **System Settings → Privacy & Security →
Automation**.

The command formats the source, runs the complete test suite, and rejects
placeholder bundle identifiers or development-version strings.

## Store notarization credentials

Create a notarytool keychain profile once:

```bash
xcrun notarytool store-credentials VoicePanelNotary
```

Use a Developer ID Application certificate for the app and disk image.
Notarization uses `notarytool`; legacy `altool` workflows are not supported.

## Build, sign, and notarize

Run from the repository root on macOS:

```bash
./scripts/package-dmg.sh \
  --sign 'Developer ID Application: Your Name (TEAMID)' \
  --notarize VoicePanelNotary
```

For each architecture the script:

1. builds the release executable for the requested target;
2. assembles the `.app` bundle;
3. embeds and signs dynamically loaded frameworks and libraries;
4. signs the outer app bundle with hardened runtime, the microphone entitlement, and a secure timestamp;
5. verifies the app signature and target architecture;
6. creates the DMG with the branded background, drag-to-Applications arrow,
   and fixed Finder icon layout, then verifies it;
7. signs the DMG with the Developer ID Application identity;
8. submits the DMG with `notarytool`, waits for acceptance, and staples the
   ticket.

Output is written to `dist/`:

```text
VoicePanel-1.10.0-arm64.dmg
VoicePanel-1.10.0-x86_64.dmg
```

To package one architecture:

```bash
./scripts/package-dmg.sh \
  --arch arm64 \
  --sign 'Developer ID Application: Your Name (TEAMID)' \
  --notarize VoicePanelNotary
```

Use `--arch x86_64` for the Intel package.

## Local unsigned package

Omit `--sign` only for local smoke testing:

```bash
./scripts/package-dmg.sh --arch arm64
```

This creates an ad-hoc signed package and cannot be notarized with that signature.
Version 1.10.0 publishes the existing ad-hoc signed packages. Its release notes
and installation documentation explicitly identify the lack of Developer ID
signing and Apple notarization. Future Developer ID releases should follow the
signed workflow above.

## Verify the finished release

The packaging script performs structural and signature checks. Before
publication, also inspect the finished artifacts manually:

```bash
hdiutil verify dist/VoicePanel-1.10.0-arm64.dmg
codesign --verify --deep --strict --verbose=4 \
  .build/release-apps/arm64/VoicePanel.app
codesign --display --verbose=4 \
  .build/release-apps/arm64/VoicePanel.app
codesign --display --entitlements :- \
  .build/release-apps/arm64/VoicePanel.app
xcrun stapler validate dist/VoicePanel-1.10.0-arm64.dmg
```

Review the notarization log for warnings when Apple rejects a submission or when
an accepted submission contains unexpected diagnostics:

```bash
xcrun notarytool log <submission-id> \
  --keychain-profile VoicePanelNotary notarization-log.json
```

Test installation from a freshly downloaded or copied DMG on a Mac that has not
run the development build. Verify Gatekeeper, first-launch permission prompts,
menu-bar startup, and model download behavior.

## Architecture verification

The pinned whisper.cpp, sherpa-onnx, and ONNX Runtime packages expose macOS
slices for both supported architectures. The packaging script validates the app
executable and every embedded dynamic dependency with `lipo`.

Cross-compilation is not a substitute for runtime testing. Test the arm64 build
on Apple Silicon and the x86_64 build on a real Intel Mac before publication.

## Release checklist

1. Confirm the MIT license and third-party notices; scan the public source and history.
2. Increment the marketing version and numeric build number.
3. Run `./scripts/release-check.sh`.
4. Build signed and notarized arm64 and x86_64 DMGs, or explicitly document ad-hoc signing in the release notes.
5. Review the notary result and validate both stapled DMGs when notarization is used.
6. Install each DMG on a clean matching Mac.
7. Verify the signed app contains `com.apple.security.device.audio-input`, then verify microphone and Speech permissions.
8. Verify Apple Speech and at least one downloaded local model.
9. Verify push-to-talk, menu recording, clipboard completion, editor, history,
   model management, and the 30-second benchmark sample.
10. Publish both DMGs, third-party notices, the MIT license, and release notes.

## Development builds

`./scripts/build-app.sh` creates one `.app` bundle and prints only its path on
stdout. Use environment variables when a specific target or output path is
needed:

```bash
VOICEPANEL_TARGET_ARCH=x86_64 \
VOICEPANEL_APP_OUTPUT_DIR=.build/intel-app \
./scripts/build-app.sh
```

`VOICEPANEL_CODESIGN_IDENTITY` controls signing when the builder is called
directly. `package-dmg.sh` supplies it automatically.

## Publish with GitHub CLI

Authenticate with `gh auth login` if needed. Push only the intended public
branch and release tag, then attach the existing verified artifacts:

```bash
git push origin main
git tag -a v1.10.0 -m 'VoicePanel 1.10.0'
git push origin v1.10.0
gh release create v1.10.0 dist/VoicePanel-1.10.0-*.dmg \
  LICENSE THIRD_PARTY_NOTICES.md \
  --title 'VoicePanel 1.10.0' --notes-file docs/releases/1.10.0.md --verify-tag
```

Do not push local development-history branches containing private paths or test data.
