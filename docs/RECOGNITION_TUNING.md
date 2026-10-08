# Recognition tuning

VoicePanel now exposes most tuning through recognition profiles. Ordinary users
choose **Vanilla**, **Balanced**, **Quality**, or **Low Latency** on
**Settings → General**. The Advanced tab shows the effective values and permits
a manual **Unsaved** configuration.

- **Vanilla** preserves the original Energy VAD, phrase boundaries, five-second
  Whisper chunks, stable whisper.cpp decoding, and no shared prompt.
- **Balanced** uses Hybrid VAD, moderate phrase padding, longer chunks,
  configured Context/Vocabulary, and conservative result protection.
- **Quality** keeps more audio around longer phrases and waits longer for a
  sentence ending. It does not enable Beam Search automatically.
- **Low Latency** closes phrases sooner and uses shorter Whisper chunks.
- **Unsaved** uses the low-level values described below until it is saved as a named preset.

Microphone activation is a separate choice: **Quiet**, **Balanced**, **Noisy**,
or **Custom**. This prevents a noisy room from being confused with a request for
faster or higher-quality decoding.

Recognition tuning controls the shared audio pipeline used before the selected
recognition engine. These settings are separate from model downloads and
model-specific compute options. See the [user guide](USER_GUIDE.md) for the
recording workflow and profile selection.

## Voice activity detection

VoicePanel offers three interchangeable modes:

- **Energy** — the original adaptive RMS detector. It starts immediately, has no
  model download, and is the safest fallback.
- **Silero** — a small neural VAD that distinguishes speech from many common
  non-speech sounds more reliably than a volume threshold.
- **Hybrid** — Silero decides when speech begins, while the energy detector may
  preserve a quiet ending until both detectors agree that speech has stopped.

Energy remains the default for existing installations. Selecting Silero or
Hybrid downloads a verified `silero_vad.onnx` package of about 629 KB. If the
neural runtime cannot produce a decision, the live pipeline falls back to the
Energy detector rather than dropping audio.

The **Speech probability** threshold applies to Silero. Higher values reject
more background sound but can miss quiet speech. The microphone environment and live input meter are on **Settings → General**.
Manual Energy sensitivity and adaptive/manual threshold values appear only in
**Advanced** after the environment is changed to Custom. Hybrid uses them and
Silero can fall back to them.

## Chunk boundaries

- **Minimum neural speech** rejects very short Silero/Hybrid activations.
  Energy mode retains the original minimum duration from its selected
  sensitivity preset.
- **Speech end pause** controls how long a pause closes the current phrase.
- **Audio before speech** keeps a short pre-roll so the beginning of the first
  word is not cut off.
- **Audio after speech** keeps a short tail so the final sound is not cut off.

For Whisper, reaching the maximum chunk duration no longer always means cutting
at that exact sample. The segmenter searches up to two seconds backward for the
nearest Energy/VAD pause lasting at least 400 ms, keeps the configured post-roll,
and starts the next chunk with the normal overlap. If no eligible pause exists,
the exact maximum-duration cut remains the deterministic fallback. Imported
files additionally keep the conservative rule that merges a final tail of at
most 1.25 seconds back into its preceding forced chunk when the PCM overlap
matches exactly and the merged audio remains within the profile and Whisper
limits.

These controls affect the normal recognition pipeline. Model-specific maximum
chunk duration, overlap, retries, and thread settings remain under **Advanced**.

## Context

Context describes the expected subject, language style, and punctuation. It is
optional. Use **Edit** to open a large multiline editor. Whisper receives
non-empty context as part of the initial prompt.

Example:

```text
Technical discussion about macOS development.
Preserve product names and use normal punctuation.
```

Keep context concise. A long or overly prescriptive prompt can consume model
context and reinforce an earlier recognition mistake.

## Vocabulary

Vocabulary is a list of names, abbreviations, product terms, and uncommon words.
Use **Edit** to open a large multiline editor, then separate entries with
commas, semicolons, or new lines.

Example:

```text
VoicePanel
Qwen
sherpa-onnx
Core ML
SwiftUI
```

Apple Speech receives these entries as contextual phrases. Whisper receives a
compact vocabulary line appended to its initial prompt. Other local engines do
not currently expose an equivalent hot-word API.

## Reusing Whisper context

**Use previous text after forced Whisper splits** is optional and disabled by
default. VoicePanel keeps whisper.cpp decoder history disabled for every call.
After an accepted chunk ending at the maximum-duration boundary, the next chunk
receives a short explicit tail from the earlier transcript. The final words are
excluded because they are already replayed by the audio overlap. Natural VAD
pauses, empty results, rejected hallucinations, failures, device changes, and
new benchmark passes reset the text context. Configured Context and Vocabulary
remain available as the static prompt on every independent call.

Whisper audio shorter than one second is padded with trailing silence before
inference so the pinned whisper.cpp 1.7.5 runtime does not silently ignore a
valid short utterance.

## Result safety

**Discard obvious hallucination loops** is optional and disabled by default. It
rejects only strong anomaly patterns, such as a repeated-token loop or an
implausibly large transcript from a very short speech fragment. It does not
rewrite uncertain words.

It also rejects standalone gratitude and subtitle-credit artifacts over low-level
audio. Whisper checks each segment's timestamp range, preserving real speech
elsewhere in the chunk. Every 20 ms audio window must be below the conservative
threshold (the manual VAD threshold, or the minimum adaptive threshold, minus
hysteresis); a brief audible utterance keeps the segment. Invalid or unavailable
timing does not prove local silence. For output without segment metadata the
same check applies to the whole chunk.
Enabled protection requests native segment timestamps without per-token
alignment. Disabled protection retains the ordinary timestamp-free baseline.

Live final recognition uses the profile's full pause-balancing decision window,
just like file recognition. The live draft supplies immediate text; short pauses
do not force five-second final chunks. The inference queue rechecks pending work
before going idle and drains accepted chunks before session finalization.

The guard applies to final results from Whisper, GigaAM, Qwen3-ASR, and
Parakeet. It is intentionally conservative because repeated text may be
intentional.

## Custom provenance and named presets

Choosing **Customize This Profile** copies the effective values into Unsaved while
remembering the built-in profile they came from. Advanced shows **Based on** and
lists only settings that differ from that base. Each override can be reset
individually, or **Reset to _Profile_** can remove all overrides and return to the
built-in profile.

Named presets store recognition tuning together with its base profile. They do
not select an engine, model, compute mode, microphone, or Live Draft source.
Saving another preset with the same name replaces the existing preset.


## Real-device validation

Performance Testing keeps its test configuration separate from General until **Save as Active Setup** is pressed. The stage selector and run actions share one toolbar, the reusable sample and wrapped latest result stay in a fixed left card, and the right-side settings scroll independently. Whisper's **Use previous text after forced splits** control is always testable in Model Benchmark; every repeated pass starts without transcript context, and only accepted maximum-duration boundaries may seed the next chunk. Pipeline Validation overlays the raw waveform with speech, possible pause, excluded silence, VAD on/off markers, accepted chunk windows, and boundary reasons.

Use the two stages in order:

1. **Model Benchmark** — select the engine, model, compute path, language, and model-specific inference settings. VAD, segmentation, audio margins, and result filtering are excluded. Three passes are the default for stable timing comparisons.
2. **Pipeline Validation** — reuse the selected model and compare Balanced, Quality, Low Latency, or Unsaved pipeline settings. Model and compute controls are hidden here; the page shows the model as a read-only dependency and provides a **Change Model** action back to stage 1. One pass is the default because the pipeline decisions should be deterministic.

The latest result stays in the fixed workspace. Same-sample history and **Scoring & Report** are collapsed by default. An exact reference transcript enables WER/CER; notes should capture room, microphone distance, and speaking style. Exported reports include system and target metadata but never audio.

Do not tune Balanced or Quality from one recording or one device. First fix functional regressions, then collect repeatable results across representative Apple Silicon and Intel systems.
## Final transcript cleanup

`finalTranscriptCleanupEnabled` runs the conservative language-independent boundary pass after all chunks finish. Balanced and Quality enable it; Vanilla and Low Latency preserve the previous merger behavior. The pass uses only neighboring segment relationships and does not rewrite general grammar.

`gigaAMRussianCorrectionEnabled` is meaningful only when GigaAM is the active backend. Quality enables it, while other built-in profiles leave it disabled. The optional SAGE FRED-T5 INT8 package proposes Russian spelling, punctuation, and case edits after boundary cleanup. VoicePanel converts those proposals into explicit operations, rejects insertions, deletions, and unvalidated word replacements, and accepts spelling only with macOS Russian dictionary evidence. If the package cannot be downloaded, loaded, or safely filtered, VoicePanel returns the boundary-cleaned GigaAM transcript. Older saved Unsaved profiles decode both new settings as disabled.
