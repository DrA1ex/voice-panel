# Implementation status

## Release target

This archive is prepared as VoicePanel 1.10.0 for macOS 14 and later. Separate
Apple Silicon and Intel DMGs are produced from the same source tree.

## Implemented

- Native menu-bar app with push-to-talk and menu-controlled recording.
- The normal status menu stays compact; recovery, diagnostics, and reset commands are revealed only when the actual menu-bar click begins with Option held, using the captured status-item mouse event rather than menu-open modifier polling.
- Low-latency recording startup: after permission is available, the microphone opens before local-model and VAD preparation. Preparation audio is buffered for the final pipeline; the first second is always included, longer preparation follows a persisted Workflow preference, and push-to-talk release keeps a bounded 300 ms tail, then stops capture without discarding the held audio.
- Existing-audio transcription from the menu or drag-and-drop, with AVFoundation conversion to 16 kHz mono PCM, active-profile VAD/segmentation, sequential chunk processing, and the normal editable result.
- Compact, medium, and large panels with recording, preparation, finalization,
  success, copied, partial-result, and error states.
- Apple Speech, Whisper, GigaAM v3, Qwen3-ASR, and Parakeet TDT engines.
- Whisper Auto, Core ML + Metal, Core ML + CPU, Metal-only, and CPU-only
  execution modes.
- Whisper Greedy/Beam decoding, Flash Attention, vocabulary prompt, explicit
  forced-split text continuity, short-audio padding, and CPU thread controls.
- Medium and Medium English FP16, Q5, and Q8 model choices.
- Verified model catalog, staged downloads, removal, preload, and storage view.
- Optional Apple Speech live drafts and same-family Whisper/GigaAM drafts.
- Recognition profiles: Vanilla, Balanced, Quality, Low Latency, and Unsaved.
- Optional final transcript post-processing: a universal conservative pass stitches overlap, removes boundary duplicates, and repairs false punctuation/capitalization for every engine; GigaAM can additionally use a downloaded SAGE FRED-T5 95M INT8 Russian correction package. SAGE now acts as an edit proposal generator: explicit case and punctuation edits are filtered, spelling requires macOS dictionary validation, and lexical insertion, deletion, or replacement is rejected. Quality enables the package with fail-safe fallback to the cleaned ASR text.
- Quiet, Balanced, Noisy, and Custom microphone environments.
- Selectable microphone and interchangeable Energy, Silero, or Hybrid VAD.
- Resilient Core Audio topology handling: connecting or disconnecting any input refreshes the active graph without discarding captured audio; a removed selected microphone falls back to the current system default with a visible warning, while temporary periods with no input preserve the recording session for retry.
- Crash-resistant transcript checkpoints are written before and after microphone handoffs and recognition outcomes, including while the History window remains locked; checkpoint bookkeeping advances only after the encrypted write succeeds.
- A single effective recognition configuration combines profile, microphone environment, and Unsaved overrides.
- Unified General setup for microphone, environment, engine, model, language, profile, and compute mode.
- General manages local model files, Whisper Core ML encoders, and profile-scoped Live Draft.
- Dedicated Performance Testing page with a compact two-column workspace, aligned sample and configuration cards, independent sample capture and Play/Stop playback, isolated settings, explicit Save as Active Setup, animated result-card resizing, unclipped history selection, unified model-and-pipeline snapshots restored when a run is selected, stage-1 Model Benchmark with Whisper chunk-context comparison, and stage-2 end-to-end Pipeline Validation with separate signal, VAD-state, and accepted-chunk tracks, graph-adjacent legend, explicit processing-stage feedback, full-width selectable chunk inspection, per-chunk recognized text, progressive results, boundary explanations, synchronized timeline zoom, and measured VAD analysis time.
- Tunable minimum speech, end pause, pre-roll, post-roll, context, vocabulary, Whisper context reuse, and optional hallucination-loop rejection.
- Native five-tab settings navigation with General, Performance Testing, Workflow, History, and Advanced.
- Centralized AppKit window presentation and focus restoration: Settings, History, and Transcript register with one coordinator; file choosers and alerts attach to the active VoicePanel window when possible; standalone panels are explicitly activated and raised; system permission and authentication transitions restore the initiating window with bounded retries instead of leaving it behind other applications.
- macOS XCTest/XCUIAutomation regression harness that launches the packaged app with isolated preferences and covers Settings navigation, benchmark layout/mode switching, reusable history snapshots, pipeline visualization and recognized chunk text, report disclosure, release-tail controls, minimum window sizing, and frontmost audio-file chooser presentation. A deterministic recording/import driver also covers successful recognition, cancellation, retry after failure, transcript copy/open/close actions, real History-window persistence, status-menu variants, and representative settings persistence across relaunches. UI-test baseline preferences are applied only for an explicit reset launch, so persistence scenarios are not overwritten. Modal scenarios are triggered only after the Settings accessibility tree is ready, redundant relaunches are avoided, and stale test processes are cleaned up. Performance-page tests scroll the configuration form even when an off-screen SwiftUI element has not entered the accessibility tree yet, use stable visible layout anchors instead of relying on Picker internals, and expose deterministic snapshot and per-chunk text values through explicit accessibility semantics. The runner separates build and execution, preserves incremental DerivedData, offers a four-scenario quick mode without xcresult finalization, validates XCTest startup from the real suite log with an optional minimal bootstrap, writes live per-test progress markers, emits a periodic heartbeat, and applies an external stage watchdog so a failure before XCTest begins cannot remain silent forever. The UI-test Xcode project is checked in with project-relative sources, Xcode-generated Info.plists for both targets, and a preview-free minimal host; the runner has no runtime project-generation step or XcodeGen dependency.
- Complete Xcode `#Preview` coverage for every production SwiftUI view and AppKit representable, with deterministic preview fixtures, isolated preferences and temporary storage, disabled live audio services, and dedicated previews for each Settings page and Pipeline Validation layer.
- Advanced categories for Speech Detection, Segmentation, Context & Vocabulary, Whisper Decoder, and Safety & Diagnostics.
- Unsaved profile provenance with a visible Based on state, explicit override list, per-value reset, full reset to the base profile, and named presets.
- Migration infers the nearest built-in base for Unsaved settings created before provenance was stored.
- Hard chunk limits, overlap, profile-preserving final-tail flushing, a one-second product minimum, and an optional 300 ms push-to-talk release tail.
- Reusable raw sample with manual stop, a 30-second maximum, and linear recording progress.
- Repeatable Model Benchmark and Pipeline Validation runs with mode-specific controls, 1/3/5 passes, median and range timing, RTF, optional WER/CER scoring, chunk/VAD summaries, compact selectable same-sample history, full result review, reusable historical setups, and JSON export.
- Validation reports capture the Mac model/architecture, macOS version, microphone, environment profile, target configuration, transcripts, and notes without exporting audio.
- Editable transcript window and encrypted, authenticated transcript history, including an authenticated Keychain retry when the store was unavailable at startup.
- Independent System, Light, and Dark appearance preferences for application windows and the compact transcription panel.
- Privacy-safe rotating diagnostics, recovery startup, and preference reset.
- Architecture-specific app and DMG packaging with code-signing and notarization
  support.

## Deliberate limitations

- macOS 14 is the minimum supported system.
- Qwen3-ASR 1.7B uses an experimental community conversion.
- Core ML execution for sherpa-onnx models remains experimental; CPU is the
  conservative default.
- Source audio is not retained after microphone capture or file import; users can explicitly import the original file again when reprocessing is needed.
- Direct insertion into the focused application is not implemented; completion
  uses clipboard copy or the transcript editor.

## Real-device tuning still required

The app now contains the Stage 5 measurement workflow, but Balanced and
Quality have not been retuned from synthetic assumptions. Use the same spoken
sample and reference transcript across representative Apple Silicon and Intel
Macs, microphones, and room conditions, export the reports, and change profile
definitions only when the collected evidence is repeatable.

## Release verification still required on macOS

The automated suite validates source contracts and packaging behavior, but a
release must still be built, signed, notarized, installed, and exercised on real
Apple Silicon and Intel Macs. See [Validation](VALIDATION.md) and
[Release packaging](RELEASE.md).
