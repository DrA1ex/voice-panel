# Local recognition models

VoicePanel installs models only when the user selects a local engine. Model
files are downloaded into Application Support and are not embedded in the app
or DMG.

## Choosing an engine

### Whisper

Whisper provides the broadest model catalog. VoicePanel includes verified Tiny,
Base, Small, Medium, Large v1/v2/v3, Large v3 Turbo, English-only, Q5, Q8, and
the supported English speaker-turn variant. Medium and Medium English are
available as FP16, Q5, and Q8 packages.

Approximate download sizes range from 75 MB to 3 GB. Smaller models start and
process faster; larger models generally use more memory and may produce better
results. A separate smaller Whisper model can be selected for live draft text.

### Whisper compute and decoding

The General page exposes five Whisper execution choices:

- Auto — use an installed Core ML encoder with a Metal decoder, otherwise use Metal only;
- Core ML + Metal — require the matching Core ML encoder and use Metal for decoding;
- Core ML + CPU — require the matching Core ML encoder and use CPU for decoding;
- Metal GPU — run without Core ML and use Metal for supported model work;
- CPU only — run without Core ML or Metal.

Core ML accelerates the encoder and may schedule compatible operations on the
Apple Neural Engine. The decoder remains on Metal or CPU according to the
selected mode. Core ML encoder packages are installed separately and shared by
FP16, Q5, and Q8 variants from the same model family. Specialized models without
a verified matching encoder remain available through Metal and CPU.

The default path preserves original VoicePanel behavior: Metal, Flash Attention,
and the untouched `whisper.cpp` Greedy sampling defaults. Custom Greedy/Beam
controls and candidate counts are explicitly opt-in. The page also exposes CPU
thread count, while optional context, vocabulary, and explicit forced-split
text continuity live under Advanced.

### GigaAM v3

GigaAM is intended for Russian speech. Available variants are:

- CTC — fastest plain text;
- RNN-T — more accurate plain text;
- E2E CTC — punctuation and normalization;
- E2E RNN-T — highest-quality punctuation-aware final text.

Packages are approximately 240–330 MB. A faster plain-text GigaAM model can be
used as the live draft for a punctuation-aware final model.

### Qwen3-ASR

VoicePanel exposes only packages that match its supported sherpa-onnx layout:

- Qwen3-ASR 0.6B INT8 — balanced default, about 1 GB;
- Qwen3-ASR 1.7B INT8 — larger experimental community export, about 2.3 GB.

Qwen3-ASR detects the spoken language automatically. The app does not accept an
arbitrary Hugging Face repository because Qwen LLM, GGUF, MLX, OpenVINO, and
other exports are not interchangeable with the Qwen3-ASR sherpa-onnx runtime.

### Parakeet TDT

Parakeet TDT 0.6B v3 INT8 is about 640 MB. It is the lower-latency multilingual
local option and supports Russian together with other European languages.

## Download and integrity checks

Every supported package has an expected file layout and minimum file sizes.
Whisper model files use pinned SHA-1 or SHA-256 values published by the upstream
repository. Whisper Core ML encoder ZIPs use pinned SHA-256 values and are
installed only after their compiled `.mlmodelc` directory is found and validated.
GigaAM, Qwen3-ASR 0.6B, and Parakeet use pinned SHA-256 values. The experimental
Qwen3-ASR 1.7B conversion is accepted only when each downloaded object matches
the content identity supplied by Hugging Face.

Files are downloaded to a staging directory. A model becomes installed only
after every required file has passed verification. Interrupted or invalid
packages are not activated.

## Model locations

```text
~/Library/Application Support/VoicePanel/Models/Whisper
~/Library/Application Support/VoicePanel/Models/GigaAM
~/Library/Application Support/VoicePanel/Models/LocalONNX
~/Library/Application Support/VoicePanel/Models/VAD
```

Use **Settings → General → Manage Installed Models** to inspect recognition-model
storage. Whisper Core ML encoders are also managed from General beside the
selected Whisper compute mode. The small Silero VAD package is installed or removed from
**Settings → Advanced**. The microphone environment is selected on General;
manual Energy sensitivity and adaptive threshold controls are under Advanced
Custom settings.

## Live draft and final recognition

Final recognition and the Live Draft source are configured independently, while
Live Draft enablement belongs to the selected recognition profile rather than an
individual model. Switching engines or model sizes therefore keeps the profile's
enabled or disabled state.

- Apple Speech can provide immediate draft text for any local final engine.
- Whisper can use a smaller and faster Whisper draft model.
- GigaAM can use a faster plain-text GigaAM draft model.
- Qwen3-ASR and Parakeet use Apple Speech when Live Draft is enabled for the profile.

Draft text is replaced by matching final-model chunks. Only final-model text is
copied to the clipboard and stored in history.

## Performance Testing

The **Performance Testing** page uses one toolbar for the two-stage mode switch and run actions, a fixed sample/result card on the left, and scrolling configuration on the right. The card contains reusable sample controls, Play/Stop playback, a wrapped latest transcript, and same-sample history collapsed at the bottom. Recording a sample is independent from model preparation and inference, may be stopped manually, and stops automatically at 30 seconds. The sample remains only in memory. Whisper benchmarks expose forced-split text continuity explicitly; each repeated pass starts clean, and only accepted maximum-duration boundaries may seed the next chunk. Pipeline Validation shows the original waveform together with VAD speech/pause/silence spans, VAD switches, accepted chunk windows, and cut reasons.

**Model Benchmark** is stage 1. Its scrolling section contains only the engine, model, language, compute path, and model-specific inference controls. It bypasses VAD, phrase segmentation, audio margins, and result filtering. One, three, or five passes can be measured; repeated tests report median, minimum, maximum, RTF, transcript, and optional WER/CER.

**Pipeline Validation** is stage 2. It reuses the model selected in Model Benchmark as a read-only dependency and replaces model controls with profile, microphone environment, VAD, phrase boundaries, pre/post-roll, chunking, and result-protection controls. It rebuilds those decisions from the same raw sample and reports detected speech, chunk boundaries, padding, rejected results, timing, transcript, and optional WER/CER.

Scoring fields, notes, system metadata, and report options are kept in a collapsed **Scoring & Report** area. Completed runs are retained in a collapsed history for the current sample. Exported JSON contains target snapshots, timing passes, transcripts, accuracy, pipeline details, Mac, macOS, microphone, environment, and notes; source audio is never exported. Recording a new sample starts a new comparison and clears the previous in-memory history.

Performance settings remain isolated from General until **Save as Active Setup** is pressed. The save action combines the model selected in stage 1 with the pipeline selected in stage 2.

## Shared recognition tuning

VAD selection, phrase boundaries, context, vocabulary, and optional result
safety are shared pipeline settings rather than model choices. See
[Recognition tuning](RECOGNITION_TUNING.md).
## Russian final-text correction

GigaAM can optionally run `SAGE FRED-T5 distilled 95M` after the universal chunk-boundary cleanup. VoicePanel uses the community INT8 ONNX export pinned in `RussianCorrectionModelCatalog.swift`: separate encoder and no-cache decoder graphs plus the GPT-2 BPE vocabulary and merge table. The complete package is approximately 125 MB and is downloaded only when requested or on the first GigaAM finalization that enables the option.

The model runs through the bundled ONNX Runtime using `VoicePanelORTBridge`; no Python process, PyTorch installation, or model server is required. Generation is limited to bounded Russian-dominant sentence windows. Generated text is never accepted as a complete replacement. `TranscriptCandidateEditFilter` converts it into explicit local operations: punctuation and ordinary casing may be accepted, while word insertion, deletion, reordering, and replacement are rejected. A spelling replacement is accepted only when it differs by one edit and the macOS Russian spell checker marks the source as unknown and the candidate as valid. Mixed-case technical names and existing typographic quotation marks are preserved. A load, inference, or validation failure leaves the universal cleaned transcript unchanged.

This correction package is Russian-specific. Other engines and languages still receive the language-independent boundary cleanup, but they are not routed through SAGE.

