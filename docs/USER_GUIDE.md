# User guide

[Back to documentation](README.md) · [Download VoicePanel](https://github.com/DrA1ex/voice-panel/releases/latest)

## First launch

VoicePanel requires macOS 14 or later. Download `arm64` for an Apple Silicon Mac
or `x86_64` for an Intel Mac. Check **Apple menu → About This Mac** if you are
unsure. Drag VoicePanel from the disk image to Applications and open it there.
The app appears in the menu bar without a Dock icon.

Version 1.10.0 is ad-hoc signed and is not notarized by Apple. If macOS blocks
it, follow [the installation troubleshooting steps](TROUBLESHOOTING.md#macos-blocks-the-app).

Allow Microphone access. Apple Speech and Apple live drafts also need Speech
Recognition access. These permissions can be changed under **System Settings →
Privacy & Security**. A downloaded local engine does not need Speech Recognition
permission to produce its final transcript.

## Choose your setup

Open **Settings → General**, choose your microphone and language, then choose an
engine. Apple Speech needs no VoicePanel model download and defaults to requiring on-device
recognition support for the selected language. Disabling **Require on-device
recognition** permits macOS to use Apple servers. Whisper offers a wide range of
local multilingual models; GigaAM targets Russian; Qwen3-ASR and Parakeet offer
additional multilingual options.

Local engines download their selected model on first use. Use **Manage Installed
Models** to view download progress, install, remove, or preload model files.
Choose a smaller model if startup or processing is too slow on your Mac.
[Local models](MODELS.md) explains model sizes and compute modes.

Select a recognition profile:

| Profile | Purpose |
| --- | --- |
| Vanilla | Simple baseline with energy-based speech detection |
| Balanced | General use with moderate phrase boundaries |
| Quality | More audio context and longer phrases |
| Low Latency | Faster feedback with shorter chunks |
| Unsaved | Your customized settings, which can be saved as a named preset |

Choose Quiet, Balanced, Noisy, or Custom for your microphone environment.
The environment controls speech detection; the profile controls how phrases
are prepared for recognition. Start with a built-in profile before adjusting
[advanced recognition tuning](RECOGNITION_TUNING.md).

## Record and review

## Quick start

The default shortcut is `Control + Option + Space`.

1. Hold the shortcut and begin speaking. After microphone permission is available, VoicePanel opens the microphone immediately, even while a local model or voice detector is still preparing.
2. Audio captured during preparation is buffered. The first second is always included; longer preparation audio follows **Workflow → Include audio captured while preparing**, which is enabled by default.
3. Release the shortcut when you finish. VoicePanel keeps capturing for the configurable release tail, including while the recognizer or VAD is still preparing; the default is 300 ms. A second press during that interval continues the same recording.
4. Wait while the remaining audio is processed.
5. VoicePanel copies the final text or opens it for review, according to your settings.

Diagnostic and recovery commands stay out of the normal menu. Hold **Option** before clicking the VoicePanel menu-bar icon and keep it held until the menu opens to reveal **Use Apple Speech (Recovery)**, **Open Logs Folder**, and **Reset Settings and Quit…**. This does not require a special first launch.

You can also start and stop a longer recording from the menu-bar menu. Open
**Settings → General** to choose the microphone, environment, recognition profile,
engine, model, language, compute mode, Live Draft, and local model files. Use
**Performance Testing** to benchmark models or validate the complete recognition pipeline; low-level speech tuning
remains under **Advanced**.

## More recording workflows

### Push-to-talk from any app

Use the global shortcut for a quick phrase, message, or prompt. Recording lasts
only while the shortcut is held, unless you latch the panel into manual-stop
mode.

### Menu recording

Choose **Start Recording** from the menu-bar menu when you do not want to hold a
shortcut. Choose **Stop Recording** when finished.

### Review before copying

VoicePanel can open the full transcript editor instead of closing immediately.
The text remains editable before you copy it elsewhere.

### Transcribe an existing audio file

Choose **Transcribe Audio File…** from the menu-bar menu, or drop an audio file onto the compact panel or full transcript window. VoicePanel converts supported AVFoundation formats to 16 kHz mono PCM, applies the active VAD and segmentation profile, processes the resulting chunks sequentially, and presents one editable final transcript. Long imports show whole-session chunk progress and an estimated remaining time in both transcript surfaces, and can be cancelled at any stage. Transcript callbacks and automatic scrolling are coalesced so opening the full transcript window does not overload SwiftUI during large files. Imported source audio is not retained.

### Compare local models

The **Performance Testing** tab follows a two-column layout: a fixed sample/result card on the left and scrolling benchmark controls on the right, with the stage selector and run actions in one toolbar. Record one sample for up to 30 seconds without loading a model, play or stop playback from the same control, and reuse it while changing test parameters. **Model Benchmark** compares engines, models, compute modes, model-side inference settings, and optional Whisper context reuse between chunks. **Pipeline Validation** reuses the selected benchmark model and overlays the original waveform with VAD speech, possible pauses, excluded silence, accepted chunk windows, VAD switches, and exact cut reasons. The latest transcript wraps inside the sample card; older runs remain collapsed at the bottom and restore their complete model-and-pipeline setup when selected. Changes affect normal recording only after **Save as Active Setup** is pressed. Optional reference text adds WER/CER scoring, and JSON export includes Mac, microphone, profile, environment, room notes, and benchmark context settings. Recorded audio remains in memory and is never exported.

### Search previous transcripts

Encrypted history can retain transcripts for a configurable period. Opening
history requires Touch ID or the Mac login password. History can also be
disabled completely.


## Panel and appearance

Choose Compact, Medium, or Large to control the recording panel size. App windows
and the recording panel have independent System, Light, and Dark appearance
settings. The waveform and input level show microphone activity; processing
feedback indicates that final recognition is still running.

Live Draft can show provisional text while a local engine prepares the final
result. Draft words may change and final text may arrive after you stop. Apple
live drafts need Speech Recognition permission; a supported local draft model
is another option. See [Local models](MODELS.md).

## Completion and clipboard

Shortcut recordings and menu recordings have separate completion preferences.
Choose automatic copy for quick dictation or a result window when you want to
review the text first. Final transcripts can be edited before copying.
Copying replaces the current clipboard content. VoicePanel does not type the
text into another app: paste it where you want it.

## History

By default, history is encrypted and retained for seven days. Open History and
use Touch ID or your Mac login password to unlock it. Search, copy, edit, pin,
or delete previous transcripts. Pinned transcripts are excluded from automatic
retention cleanup. Change retention or disable storage in History settings.
Disabling storage does not automatically delete existing entries.

Read [Privacy and storage](PRIVACY.md) for local data locations, debug recordings,
and what to inspect before sharing a diagnostic report.

## Help and feedback

Use [Troubleshooting](TROUBLESHOOTING.md) for permissions, downloads, shortcuts,
and recovery startup. Report reproducible problems in
[GitHub Issues](https://github.com/DrA1ex/voice-panel/issues), including your
macOS version, Mac architecture, VoicePanel version, engine, and model. Use
synthetic speech when demonstrating a problem and inspect any attached files
for personal information.
