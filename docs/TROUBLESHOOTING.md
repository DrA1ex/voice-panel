# Troubleshooting

## Recording does not start

Open **System Settings → Privacy & Security → Microphone** and make sure
VoicePanel is enabled.

Apple Speech and optional Apple live drafts also require **Speech Recognition**
permission. Local-model final recognition does not require that permission.

## Recording waits for a model

When a local model is still downloading, verifying, or loading into memory, VoicePanel opens the microphone first and buffers the audio in memory. The compact panel should show live level/waveform feedback together with the preparation stage. Releasing an unlatched push-to-talk shortcut stops further capture but keeps the audio already spoken so it can be processed when the model is ready. Menu or latched recording continues capturing until manual stop. The first second of preparation is always included; use **Settings → Workflow → Include audio captured while preparing** to control longer preparation intervals.

If readiness never completes, inspect the disabled model-status line in the menu and use **Settings → General → Manage Installed Models** to retry or remove the incomplete package.

## An audio file cannot be transcribed

VoicePanel accepts formats that AVFoundation can decode on the current macOS version. Try WAV, AIFF, M4A/AAC, MP3, or FLAC. A protected, corrupt, unsupported, or video-only file produces an error without modifying the source file.

Imported audio uses the active engine and profile. A local model may need to download and load before conversion begins. Files containing no detected speech produce a dedicated no-speech error. Imported audio is processed in memory and is not retained by VoicePanel.

## The global shortcut does not work

Open VoicePanel Settings and select another shortcut preset. Another application
may already own the same global shortcut.

## A model download or load fails

Open **Settings → General → Manage Installed Models**. Remove the incomplete model and
install it again. Downloads require a stable connection and enough free disk
space for both the temporary staging copy and the installed package.

The Qwen3-ASR 1.7B conversion is experimental. Try Qwen3-ASR 0.6B, Parakeet,
Whisper, or Apple Speech if it cannot load reliably on the current Mac.

## VoicePanel starts in recovery mode

After an unclean exit, VoicePanel starts with the menu-bar shell active while
heavy recognition services remain deferred. Hold Option before clicking the VoicePanel menu-bar icon and keep it held until the menu opens, then use **Use Apple Speech (Recovery)**
to reset a problematic local-model selection, or open Settings and retry the
model manually.

Developers can force the same startup mode with:

```bash
./scripts/run-safe.sh
```

## Logs

Hold Option before clicking the VoicePanel menu-bar icon and keep it held until the menu opens, then choose **Open Logs Folder**. The main log is:

```text
~/Library/Logs/VoicePanel/voicepanel.log
```

Logs contain lifecycle, model-load, chunk queue, timing, and error metadata.
They exclude microphone audio and transcript content. Native crash reports may
also appear under:

```text
~/Library/Logs/DiagnosticReports
```

## Reset preferences

Hold Option before clicking the VoicePanel menu-bar icon and keep it held until the menu opens and use **Reset Settings and Quit…**, or quit VoicePanel and run:

```bash
./scripts/reset-settings.sh
```

The reset removes current and pre-release preference domains together with
stale recovery markers. Downloaded models and transcript history are preserved.

## macOS blocks the app

Version 1.10.0 is ad-hoc signed and is not notarized by Apple. Download only
from the [official releases](https://github.com/DrA1ex/voice-panel/releases).
If macOS blocks the app:

1. Drag VoicePanel to Applications.
2. Control-click VoicePanel and choose **Open**.
3. Confirm the warning.
4. If it remains blocked, attempt to open it once and then choose **Open
   Anyway** under **System Settings → Privacy & Security**.

Do not disable Gatekeeper and do not remove quarantine attributes with terminal
commands.

## Silero VAD does not install or load

Switch **Settings → Advanced → Voice activity detection** to
**Energy** to continue recording without the neural VAD. Then retry **Install**.
The downloaded ONNX file is activated only after its pinned SHA-256 check
passes. Removing the package does not remove any recognition model or
transcript.

## Build reports `missing required module 'sherpa_onnx'`

The app imports the sherpa-onnx XCFramework directly. Older prerelease checkouts
used a transitive Swift wrapper, which could leave stale package artifacts after
an update. From the project root, remove only generated SwiftPM data and resolve
again:

```bash
rm -rf .build .swiftpm
swift package reset
swift package resolve
./scripts/build-app.sh
```

Do not delete downloaded recognition models under Application Support. They are
unrelated to SwiftPM build artifacts.

### SwiftPM reports a sherpa-onnx checksum mismatch

Build 25 and later pin the exact checksums of the files currently served by the distributor's `1.13.2` release URLs:

- `sherpa-onnx.xcframework.zip`: `62de3c1423a4f20516e8623858ee8c8d306af7ebb2a3737dc0600b1d4ee6aa4b`
- `onnxruntime.xcframework.zip`: `38bc65b3e6af3e6d99bc18a40f80bfb3e56ee1eedfa0d0a60feb1c97a2d06dee`

If a previous failed build left partial artifacts, remove generated package data and retry:

```bash
rm -rf .build .swiftpm/cache
./scripts/build-app.sh
```

A query parameter does not select a different GitHub release asset, so the URLs intentionally have no `artifact-revision` suffix. If the distributor replaces the files at those URLs in the future, SwiftPM should fail rather than silently accepting different binaries.
