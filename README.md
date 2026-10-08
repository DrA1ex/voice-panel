# VoicePanel

**Speak, release, paste.** VoicePanel is a native macOS menu-bar app that turns
speech into text from anywhere on your Mac. Hold a shortcut to dictate a quick
message, record a longer thought, or transcribe an existing audio file.

[Download the latest release](https://github.com/DrA1ex/voice-panel/releases/latest) ·
[User guide](docs/USER_GUIDE.md) ·
[Troubleshooting](docs/TROUBLESHOOTING.md)

## Why VoicePanel?

- **Dictate from any app.** Hold `Control + Option + Space`, speak, then release.
  Copy the completed transcript and paste it where you need it.
- **Choose your recognition engine.** Use Apple Speech or download local
  Whisper, GigaAM v3, Qwen3-ASR, and Parakeet models.
- **See words as you speak.** A compact recording panel shows audio activity,
  optional live drafts, and progress while final text is prepared.
- **Review before sharing.** Open the editable transcript instead of copying
  automatically, or import an audio file through the menu or drag-and-drop.
- **Keep an encrypted history.** Unlock previous transcripts with Touch ID or
  your Mac login password, or turn history storage off.
- **Find a setup that fits your Mac.** Choose a recognition profile and compare
  local models using a reusable recording in Performance Testing.

## Install

Requires **macOS 14 or later** on Apple Silicon or Intel.

| Your Mac | Download |
| --- | --- |
| Apple Silicon (M-series chip) | [VoicePanel for Apple Silicon](https://github.com/DrA1ex/voice-panel/releases/latest/download/VoicePanel-1.10.0-arm64.dmg) |
| Intel | [VoicePanel for Intel](https://github.com/DrA1ex/voice-panel/releases/latest/download/VoicePanel-1.10.0-x86_64.dmg) |

1. Open the DMG and drag **VoicePanel** to **Applications**.
2. Open VoicePanel. Its icon appears in the menu bar; there is no Dock icon.
3. Allow **Microphone** access. Allow **Speech Recognition** access if you use
   Apple Speech or Apple live drafts.
4. Open **Settings → General** to select your microphone, language, and engine.

**Version 1.10.0 is ad-hoc signed and is not notarized by Apple.** macOS may
block the first launch. Follow
[the opening instructions](docs/TROUBLESHOOTING.md#macos-blocks-the-app).

## Your first recording

1. Hold **Control + Option + Space** and speak.
2. Release the shortcut when you finish.
3. Wait for the remaining audio to be transcribed, then paste the copied text.

The microphone opens while local models prepare, so you can begin speaking
without waiting for a model to load. Longer recordings can be started and
stopped from the menu bar. Completion settings let you choose automatic copy or
an editable result window. See the [user guide](docs/USER_GUIDE.md) for details.

## Recognition engines

| Engine | Useful for | Approximate model download |
| --- | --- | --- |
| Apple Speech | Quick setup with macOS on-device recognition | No VoicePanel model download |
| Whisper | Multilingual dictation with a broad model choice | 75 MB–3 GB |
| GigaAM v3 | Russian speech and punctuation-aware variants | 240–330 MB |
| Qwen3-ASR | Multilingual speech with automatic language detection | 1 GB; experimental 1.7B model about 2.3 GB |
| Parakeet TDT | Local recognition for European languages | 640 MB |

Models download separately and are not bundled in the DMG. Optional live draft,
voice detection, correction, and Core ML packages may require additional
storage. See [Local models](docs/MODELS.md) for the available choices.

## Privacy

Downloaded recognition models run locally. Apple Speech requires on-device
recognition by default; availability depends on the selected language and macOS.
If you disable **Require on-device recognition**, macOS may use Apple servers.
Model downloads require an internet connection.

Audio is processed in memory by default. An optional audio debugging setting
saves **unencrypted WAV files** locally and is off by default. Encrypted
transcript history is enabled by default with seven-day retention; its key is
stored in macOS Keychain. You can disable history or delete saved entries.

[Privacy and storage](docs/PRIVACY.md) explains these settings, clipboard behavior,
logs, and local file locations.

## Documentation and support

- [User guide](docs/USER_GUIDE.md) — recording, live drafts, files, profiles, and history.
- [Local models](docs/MODELS.md) and [Recognition tuning](docs/RECOGNITION_TUNING.md).
- [Troubleshooting](docs/TROUBLESHOOTING.md) and [Report an issue](https://github.com/DrA1ex/voice-panel/issues).
- [Development](docs/DEVELOPMENT.md), [Building](docs/BUILDING.md),
  [Testing](docs/TESTING.md), and [Release packaging](docs/RELEASE.md).
- [All documentation](docs/README.md).

## License

VoicePanel source code is available under the [MIT License](LICENSE).
Third-party runtimes and downloaded models retain their own licenses; see
[Third-party notices](THIRD_PARTY_NOTICES.md).
