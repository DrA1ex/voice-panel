# Privacy and storage

[Back to documentation](README.md)

## Recognition and network access

Whisper, GigaAM, Qwen3-ASR, and Parakeet run on your Mac after their selected
model files are installed. VoicePanel requests on-device recognition for Apple
Speech, including Apple live drafts, by default. If the selected language does
not support it, choose another language or a downloaded local engine. Disabling
**Require on-device recognition** allows the macOS Speech framework to use Apple
servers, depending on system availability.

Downloads contact GitHub and Hugging Face to retrieve model packages. Initial
source builds also download pinned binary frameworks. The downloadable local engines
do not send audio or transcript text to a hosted transcription service.

## Audio

Normal microphone sessions, imported audio, and benchmark samples are processed
in memory. Imported source files are not modified or copied into history.
Benchmark JSON exports omit sample audio but may contain recognized text,
reference text, microphone and Mac information, and notes you entered.

**Save microphone recordings for debugging** is off by default. If enabled in
the audio debugging section of History settings, each microphone recording is
saved as a continuous 16 kHz mono WAV, including pauses, under:

```text
~/Library/Application Support/VoicePanel/Debug Recordings/
```

These files are **not encrypted**. Transcript retention, deletion, and preference
reset do not remove them. Disable the option after debugging and delete any
unneeded files yourself. Imported source audio is not saved by this option.

## Transcripts and history

History storage defaults to encrypted with seven-day retention. The app encrypts
transcript text and metadata before writing history to disk. Its encryption key
is stored in macOS Keychain. Opening the history window requires Touch ID or the
Mac login password. Pinned entries are excluded from automatic cleanup.

Choose no storage to keep future transcripts only in the current result session.
Delete existing entries separately if you want to remove previously saved
history. Resetting preferences preserves history and downloaded models.

## Clipboard

Automatic completion and Copy place transcript text on the macOS clipboard.
Once copied, text is outside VoicePanel's encrypted history. Clipboard managers,
other applications, and system clipboard features may retain it independently.

## Local files

| Data | Location |
| --- | --- |
| Models, history, and optional debug recordings | `~/Library/Application Support/VoicePanel/` |
| Preferences | macOS preferences domain `io.github.dra1ex.VoicePanel` |
| Diagnostic log | `~/Library/Logs/VoicePanel/voicepanel.log` |
| Native crash reports | `~/Library/Logs/DiagnosticReports/` |
| History encryption key | macOS Keychain |

See [Local models](MODELS.md) for model subdirectories. Logs are intended to
exclude audio and transcript content, but error messages and native crash
reports can include local paths or system information. Inspect logs, benchmark
exports, screenshots, and audio before attaching them to a public issue.
