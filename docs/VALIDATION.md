# Validation

Run the complete project checks from the repository root:

```bash
./scripts/test.sh
```

The command now runs all checks that are possible without launching the macOS application:

On non-macOS systems, the core target uses a small OpenSSL/libcrypto compatibility target for the AES-GCM history checks. macOS application builds continue to use the system CryptoKit framework and exclude the compatibility target.

1. test and application source-contract checks;
2. package-manifest validation;
3. Swift parser checks for every source and check file;
4. strict `swift-format` lint with the checked-in four-space project configuration;
5. strict Swift 6 compilation of the core and check runner with warnings as errors and complete concurrency checking;
6. a project SwiftUI semantic checker for missing `@ViewBuilder` annotations;
7. a regression fixture proving that checker rejects a known-bad `some View` declaration;
8. real release compilation of the application with warnings as errors when tests run on macOS;
9. shell-script syntax checks and Python checker compilation;
10. simulated `.app` packaging regression checks;
11. 128 framework-independent executable core checks;
12. isolated Whisper, GigaAM, and Qwen3-ASR/Parakeet sherpa-onnx Swift/C bridge type-checks;
13. isolated Whisper model/Core ML encoder downloader and runtime-alias type-check;
14. independent type-checking of the complete Whisper, GigaAM, Qwen3-ASR, and Parakeet model catalogs;
15. isolated type-checking of Apple/local draft refinement wrappers;
16. native macOS transcript presentation checks, including bitmap comparisons of the newest glyphs, wrapped tail rows, rapid draft revisions, animation catch-up, and pending final-chunk lifetime across Stop. These run with Command Line Tools and do not require the Xcode UI-test runner.

The supported local commands live at the top level of [`scripts/`](../scripts/README.md): build, run, test, format, clean, safe recovery, and settings reset. The individual contract, bridge, packaging, and SourceKit checks are implementation details under `scripts/internal/`; `./scripts/test.sh` orchestrates the required validation suite.

## Why an additional SwiftUI checker is required

The Linux Swift compiler can parse source files that import unavailable Apple frameworks, so `swiftc -frontend -parse` is useful for syntax validation. It cannot fully type-check AppKit and SwiftUI code without the macOS SDK.

The 0.8 settings regression was syntactically valid but semantically invalid: a computed property returned `some View` and contained two root `Section` expressions without `@ViewBuilder`. The compiler only diagnosed it while building against SwiftUI on macOS.

`scripts/internal/check-swiftui-view-builders.py` covers this class of failure on Linux. It scans every app Swift file and rejects `some View` properties or functions that contain multiple root expressions or result-builder control flow without `@ViewBuilder`. Its internal fixture check verifies the analyzer against both broken and valid declarations.

The checker is intentionally narrow. It does not claim to replace the macOS Swift type checker; it closes a recurring gap while keeping false positives manageable.

## Covered by platform-independent core checks

- adaptive VAD and hysteresis;
- visible threshold differences between sensitivity presets;
- pre-roll, silence boundaries, bounded pre-roll queue compaction, and maximum-duration chunking;
- transcript stabilization and preservation of finalized segments;
- overlap removal between adjacent segments;
- punctuation-spacing normalization, including punctuation-only segments;
- newline preservation across normalization, merge and session updates;
- silence-transmission policy and pre-roll flush decisions;
- plaintext history compatibility, AES-GCM round trips, rejection of the wrong key, absence of transcript plaintext in the stored payload, retention behavior, and cache invalidation after external replacement;
- 48 kHz to 16 kHz resampling, same-rate passthrough, endpoint preservation, and streaming callback-boundary continuity;
- GigaAM default preferred and normal chunk limits;
- normal chunk clamping to 20 seconds and the independent 23-second inference ceiling;
- boundary-search soft-limit calculation;
- retry/split policy behavior;
- transcript normalization and WER/CER edit-distance scoring;
- median/minimum/maximum timing aggregation for repeated validation runs;
- one-second minimum-recording policy and the configurable 300 ms push-to-talk release tail;
- preservation of preset-prepared inference chunks without a second fixed silence trim;
- offline Pipeline Validation using the same VAD, phrase-boundary, padding, minimum-duration, and result-protection policies as normal final recognition;
- validation-report schema and scored-run serialization.
- source contracts that require History Unlock to authenticate before retrying an unavailable Keychain-backed repository and to expose destructive recovery only after that retry fails.

## Covered by static and source-contract checks

- all Swift files are accepted by the Swift parser;
- source layout passes strict `swift-format` lint using the pinned project configuration;
- core and check-runner code compiles with warnings as errors and complete Swift concurrency checks;
- the optional SourceKit-LSP deep check can index the package successfully;
- on macOS, the actual release app compiles with warnings promoted to errors;
- multi-root `some View` declarations require `@ViewBuilder`;
- main-actor application entry point;
- Carbon event and buffer-size type contracts;
- machine-readable build path output;
- both hot-key press and release paths;
- immediate microphone startup before local recognizer/VAD readiness, ordered preparation-buffer activation, and a bounded post-release tail while preparation continues;
- audio-file menu selection, drag-and-drop surfaces, AVFoundation conversion to 16 kHz mono PCM, production-pipeline reuse, and sequential local chunk admission;
- sliding transcript without ellipsis truncation;
- continuous Apple Speech input across VAD pauses;
- VAD-chunk delivery for Whisper, GigaAM, Qwen3-ASR, and Parakeet;
- independent final and same-family draft runtime preload lifecycles;
- all 16 models in the verified whisper.cpp catalog, including language/capability metadata;
- local draft filtering requires compatible models that are smaller and faster than the final Whisper model;
- all four GigaAM v3 variants and explicit punctuation capability labels;
- per-file GigaAM SHA-256 verification, staging and single-flight installation;
- Qwen3-ASR nested tokenizer installation and exact qwen3-asr sherpa-onnx configuration;
- Parakeet encoder/decoder/joiner installation and NeMo transducer configuration;
- shared Qwen3-ASR/Parakeet preload, recovery, benchmark, storage, and Apple draft integration;
- isolated Model Benchmark and Pipeline Validation passes, explicit save-to-active behavior, WER/CER comparison, result history, and JSON report export contracts;
- sherpa-onnx NeMo CTC and transducer configuration;
- Apple Speech draft plus Whisper/GigaAM final replacement;
- same-family local draft plus final replacement for Whisper and GigaAM;
- 20-second normal GigaAM chunk cap, 23-second inference guard, boundary search, retry and split controls;
- fixed Russian language UI for GigaAM;
- pinned whisper.cpp and sherpa-onnx SwiftPM dependencies;
- runtime-aware embedding/signing of actual dynamic dependencies, while accepting static sherpa-onnx and ONNX Runtime slices;
- hardened-runtime app signing with an embedded microphone entitlement;
- inclusion of both bridge checks in the standard check command;
- strict standalone type-check of the persistent diagnostic logger;
- direct file-based Whisper initialization without full model duplication in Swift memory;
- model-load crash breadcrumbs, safe startup, and menu access to logs;
- VAD-independent forced chunking with overlap and final-tail flushing;
- final-only transcript selection for hybrid draft/final engines.

## Remaining macOS-only validation

The standard test command now performs a real release application compilation when it is run on macOS, covering AppKit, SwiftUI, Carbon, Core Audio, Speech and binary XCFramework compile/link diagnostics. Linux still cannot reproduce the Apple SDK type system, and runtime checks for microphone capture, code signing behavior, Metal/Core ML and actual model inference remain macOS-only.

After extracting on a Mac:

1. run `rm -rf .build .swiftpm && ./scripts/test.sh`;
2. run `./scripts/run-dev.sh`;
3. grant microphone and speech-recognition permissions;
4. verify Apple Speech works immediately without a model download;
5. verify push-to-talk keeps capturing for the configured 300 ms after key release while menu and latched recording stop immediately;
6. press the push-to-talk key again during the release tail and confirm the pending stop is cancelled without starting a new session;
7. verify recordings below one second are rejected while one-second and longer recordings proceed to recognition;
8. pause and continue speaking, confirming the same session retains prior text;
9. validate panel glow, preparation, finalizing, success and copied states;
10. validate microphone sensitivity presets and threshold meter live;
11. inspect all Whisper catalog entries, install representative Tiny, Medium FP16/Q5/Q8, Turbo, and English-only variants, and compare queue depth and RTF;
12. for one supported Whisper family, install its Core ML encoder and benchmark Auto, Core ML + Metal, Core ML + CPU, Metal-only, and CPU-only using the same sample;
13. remove the Core ML encoder and confirm Auto falls back to Metal while explicit Core ML modes report the missing package instead of silently changing modes;
14. select each GigaAM model and confirm the UI states exactly whether punctuation/normalization is included;
15. verify each GigaAM package downloads every required file, verifies SHA-256 and becomes Ready only after native preload;
16. quit and relaunch with GigaAM selected; confirm preload starts without opening the microphone;
17. confirm Apple Speech draft appears quickly and each completed phrase is atomically replaced rather than appended twice;
18. speak continuously beyond 23 seconds and confirm no individual GigaAM inference exceeds 23 seconds; also confirm a merged 21–22-second short tail remains accepted;
19. install Qwen3-ASR 0.6B and verify multilingual recognition, automatic language detection, punctuation, preload, and Apple draft replacement;
20. install the experimental Qwen3-ASR 1.7B package, verify every file is content-checked, and compare its accuracy, memory use, and RTF with 0.6B;
21. install Parakeet and verify Russian plus another supported European language, preload, punctuation, and lower finalization latency;
22. confirm the Performance Testing toolbar matches the reference layout, the left sample/result card remains fixed while the right Benchmark Target, Pipeline Setup, and Scoring & Report controls scroll, the latest transcript wraps, history expands from the card bottom, and Play changes to Stop during sample playback;
23. record a sample without preparing any model, stop it manually, play it back, and confirm a new sample clears only the current in-memory comparison session;
24. change Model Benchmark controls and confirm General remains unchanged until `Save as Active Setup` is pressed; verify Pipeline Validation hides engine/model/compute pickers, shows the selected benchmark model read-only, and `Change Model` returns to stage 1;
25. run Model Benchmark with Whisper previous-chunk context both disabled and enabled; confirm every repeated pass begins clean, then run Pipeline Validation on the same sample and inspect the original waveform, speech/pause/silence spans, VAD on/off markers, accepted chunk and speech windows, cut reasons, padding, minimum-duration decisions, and rejected results;
26. import a long audio file, confirm chunk count, determinate progress, approximate remaining time, and cancellation are visible in both compact and full transcript surfaces; open the full transcript during processing and confirm text updates and auto-scroll remain responsive;
27. click the empty vertical and horizontal space of every disclosure header and confirm the complete row toggles it;
28. expand the collapsed history and Scoring & Report areas, enter an exact reference transcript, run one/three/five-pass comparisons, verify median and timing ranges, and export JSON;
29. inspect the report for Mac, macOS, microphone, environment, target, individual durations, transcript, WER/CER, pipeline details, and notes, and confirm it contains no audio;
30. compare Qwen3-ASR and Parakeet CPU memory use, RTF, and Core ML provider behavior;
31. test Stop with a pending final chunk and confirm Finalizing remains until all work completes;
32. keep Settings open through downloads/preload and confirm focus remains stable;
33. run `otool -L VoicePanel.app/Contents/MacOS/VoicePanel` and verify every reported `@rpath` dependency is embedded and signed;
34. start a recording while a large local model is not installed; confirm the microphone indicator, timer, and waveform become active before download/load completes, preparation progress remains visible, and audio begins at the hot-key press rather than model readiness;
35. release push-to-talk before readiness and confirm microphone capture continues only for the configured tail, then preserves and finalizes the held preparation audio; release before microphone startup and confirm the empty preparation cancels cleanly; test preparation below and above one second with **Include audio captured while preparing** both disabled and enabled, and confirm a second press resumes capture without duplicating or reordering audio;
36. import representative WAV, M4A/AAC, MP3, FLAC, and AIFF files through both the menu picker and drag-and-drop; confirm conversion progress, active-profile VAD boundaries, sequential chunk progress, cancellation, and one editable final transcript;
37. with GigaAM Quality enabled, compare a raw transcript and a deliberately adversarial SAGE candidate; confirm punctuation, ordinary case, and a dictionary-confirmed typo such as `сейча` → `сейчас` may apply while `как` → `так`, `двойственный` → `свойственный`, content-word deletion, question/exclamation changes, mixed-case technical names, and Russian typographic quotation replacement are rejected;
38. disable or remove the system Russian spelling language and confirm SAGE remains fail-safe: punctuation and case may still apply, but no lexical spelling replacement is accepted;
37. import a silent file, a corrupt file, and a file without an audio track; confirm each produces a specific recoverable error and never opens the microphone;
38. run `codesign --display --entitlements :- VoicePanel.app` and confirm `com.apple.security.device.audio-input` is present.
39. with one microphone explicitly selected, connect and disconnect a different input while VoicePanel is idle; confirm the selected microphone remains selected and normal recording, microphone test, and benchmark sample recording all still start afterward.
40. disconnect the explicitly selected microphone during push-to-talk and menu recording; confirm VoicePanel checkpoints the partial transcript, switches to the current system default, shows a warning, preserves audio captured before the handoff, and continues the same transcript session without duplicated text.
41. temporarily remove every input during recording, continue until VoicePanel reports that the recording is preserved, reconnect an input, and confirm capture resumes; stop normally, unlock History afterward, and verify the recovered entry contains the transcript produced before and after the interruption.
42. repeat the selected-device interruption while encrypted History is enabled but its window has never been unlocked in the current launch; quit after the recovery checkpoint, relaunch, unlock History, and verify the partial transcript was persisted rather than depending on the History UI state.
43. keep another application in front, choose **Transcribe Audio File…** from the VoicePanel menu-bar menu, and confirm the open panel appears immediately above the current workspace rather than behind existing windows; repeat with Settings visible and confirm the chooser is attached as a sheet, then cancel and verify Settings returns to the front.
44. keep Settings open, start the microphone test with microphone permission still undecided, respond to the macOS permission dialog, and confirm Settings returns to the same Space and becomes the frontmost VoicePanel window after both Allow and Don’t Allow.
45. repeat the previous check for Apple Speech authorization, Touch ID/password History unlock, benchmark JSON export, and the reset-settings confirmation; confirm no VoicePanel window is hidden, reordered behind unrelated applications, or stranded on another Space after the system-owned or app-owned dialog closes.

## SettingsView initializer contract

`SettingsView` uses an explicit initializer. The internal initializer checker parses its labels and the call site in `SettingsWindowController` and compares their order, including an intentionally reordered failing fixture.

Before preparing an archive, run `./scripts/format.sh` and then `./scripts/test.sh`. The formatter must run before checks so the shipped source tree is identical to the linted source tree.
