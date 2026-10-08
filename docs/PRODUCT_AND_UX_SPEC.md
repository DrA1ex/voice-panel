# VoicePanel: product and UX specification

## Purpose

VoicePanel is a native macOS menu-bar application for starting voice capture from any application, seeing a low-latency transcription, reviewing the complete text, and copying an editable final result.

The default fast flow is:

1. hold the configured global hot key;
2. speak while holding it;
3. release the hot key;
4. receive an automatic clipboard copy;
5. either close immediately or open the editor, according to settings.

A second flow starts from the menu bar and continues until the user explicitly chooses Stop Recording.

A third flow imports an existing audio file from the menu or by drag-and-drop. VoicePanel converts it internally, applies the active recognition pipeline, transcribes bounded chunks sequentially, shows whole-session progress with an approximate remaining time, allows cancellation, and opens the same final result surface used by recording.

The application must not require Python, Node.js, Homebrew, an external process manager or another runner at runtime.

## Interface surfaces

### Menu-bar item

The application normally exists only in the macOS menu bar. The status icon indicates idle, recording, finalizing, completed or failed state. When the selected Whisper model is downloading, verifying or loading, the icon also shows a small cyan readiness badge.

The menu provides explicit Start/Stop Recording, **Transcribe Audio File…**, a disabled engine/model status line with percentage where available, access to the current transcript, History, Settings and Quit. Menu recording is independent from push-to-talk and is never ended by releasing the global hot key.

Starting a recording opens the microphone as soon as permission and the selected input are available, before a local model, draft model, or neural VAD finishes downloading or loading. The panel shows both live input feedback and the current readiness stage. Preparation audio remains in a bounded in-memory buffer and enters the same final VAD/chunking pipeline after readiness. Up to one second is always included; longer preparation audio follows the persisted **Include audio captured while preparing** preference. Releasing an unlatched push-to-talk shortcut stops further capture immediately but preserves the held buffer for later processing; latching or menu recording keeps capture active until manual stop.

### Compact recording panel

The compact panel appears near the bottom center of the active screen. It is non-activating while recording, so the currently used application keeps keyboard focus.

It contains:

- recording state with a deliberate placeholder before the first transcript;
- waveform driven by the real microphone signal;
- a bright but controlled outer glow that reacts to current voice level and renders outside the visible panel without rectangular clipping;
- the latest recognized text;
- a control to open the full transcript;
- stop and cancel controls;
- final copy and close controls after menu-driven processing;
- drag-and-drop acceptance for supported audio files while no other operation is active.

The user can select Compact, Medium or Large sizing. Compact is the default. The transparent host window is larger than the visible panel solely to provide safe rendering space for blur and completion effects; the visible panel dimensions remain those of the selected preset.

The transcript is drawn with CoreText inside fixed native viewport bounds. Compact and Medium show one line with speech-engine line breaks flattened to spaces; Large shows the last three wrapped lines. As words are appended, the newest text remains visible. Small appends scroll briefly, while larger draft revisions and corrections appear immediately. Reduced Motion disables scrolling animation. Only a bounded, cached tail is needed for panel rendering; the session model and full transcript window retain the entire recording.

### Full transcript window

The full transcript is optional and may be opened manually or automatically at recording start.

While recording it is read-only and follows the complete session. Copy during recording copies only the current snapshot and does not stop or hide the recording session.

After finalization it becomes editable. Real line breaks are preserved. Copy & Close copies the edited result, updates the saved history record, and closes both transcript surfaces.

Closing this window while recording does not stop recording.

### History

History stores final text and minimal metadata only; source audio is not persisted.

The first implementation supports:

- search;
- full text preview;
- copy;
- pin/unpin;
- delete;
- clear all unpinned records;
- retention presets.

Pinned records are excluded from automatic cleanup. Cleanup runs at launch, after retention changes, periodically while the application is active, after system wake, and after newly finalized recordings.

### Settings

Settings remain a normal key window during long model operations and do not intentionally yield focus when progress updates arrive.

Settings include:

- recognition engine;
- engine-specific recognition language: supported macOS locales for Apple Speech, or the Whisper language catalog plus Auto Detect;
- Whisper model selection, verified download, removal and memory-load progress;
- Whisper model, compute mode, and Core ML encoder management on General;
- Whisper Advanced controls for Flash Attention, decoding strategy, vocabulary prompt, context reuse, and threads;
- Unsaved profile provenance, explicit overrides, reset to the base profile, and named tuning presets;
- full-row clickable disclosure controls for every engine tuning section;
- global hot-key preset;
- compact-panel size;
- automatic opening of the full transcript;
- hot-key completion behavior;
- menu completion behavior;
- history retention;
- input-device selection;
- microphone test;
- VAD sensitivity preset located directly in the Microphone section;
- adaptive or manual threshold;
- a live level meter showing signal, noise floor, selected threshold and Speech/Silence state, updated while presets change.

## Recording contracts

### Push-to-talk hot key

- A hot-key press starts a new recording only when the application can start one.
- Repeated press events while the keys remain held are ignored.
- Releasing the hot key stops only a recording initiated by that press.
- If release occurs while permissions or audio startup are still pending, startup is cancelled.
- Releasing the keys removes the active waveform and enters a visible finalization state.
- Completion proceeds through loader, green expansion/check feedback and `Copied` before dismissal.
- The final result is copied automatically.
- Settings choose between Copy and Close or Copy and Open Editor.

### Menu recording

- Start Recording begins a persistent recording.
- It continues until Stop Recording is selected or the panel Stop button is pressed.
- Releasing the global hot key has no effect on a menu recording.
- Settings choose between a compact result and opening the editor.
- Copy on a finalized result closes the recording UI.

## Whisper model readiness

Apple Speech is ready immediately and remains the default. Whisper model installation and runtime preparation are explicit application states.

- A missing model is downloaded to a staging file, verified, and atomically installed.
- An installed selected model loads into a persistent runtime at app launch and when the model selection changes.
- Download, verification and file-read/context-load progress are shown in Settings and the menu.
- Recording never starts microphone capture and then unexpectedly pauses to load the model.
- Menu recording captures immediately during preparation and continues until manual stop or cancellation.
- Push-to-talk released before readiness is cancelled, because the user has ended the hold gesture.
- The model remains loaded across recordings until the engine, model, compute mode, or Flash Attention setting changes, or the app terminates.
- Core ML encoder packages are optional, separately installed, and shared by quantized variants of the same Whisper family.
- Performance Testing owns an isolated test configuration. Its toolbar keeps the stage selector and run actions together; a fixed left sample/result card keeps recording, Play/Stop playback, wrapped latest text, and bottom-collapsed history visible while the right-side settings scroll.
- Sample recording is independent from model download/load and inference. Recording a new sample starts a new in-memory comparison session.
- Model Benchmark is stage 1 and exposes only engine, model, compute, language, and model-specific inference controls.
- Pipeline Validation is stage 2 and reuses the stage-1 model as a read-only dependency while exposing only profile, environment, VAD, segmentation, margins, chunking, and result protection.
- Scoring, notes, and report metadata are collapsed by default; every disclosure row toggles when clicked anywhere across its full height and width. Performance Testing can compare Whisper with or without previous-chunk context, repeat inference with a clean first chunk in every pass, calculate WER/CER, retain same-sample history, render an annotated VAD/chunk waveform, and export a validation report without source audio.

## Text behavior

The session has one source of truth shared by both transcript surfaces.

It tracks ordered segment IDs, stable text, current partial text, finalized segment text, editable user result, revisions, and recording state.

A VAD pause must never end the overall recording session or replace earlier text. Apple Speech remains continuous until Stop or hot-key release. Whisper uses VAD-delimited chunks while keeping the same shared transcript session; closing a chunk is not the same as ending a recording.

Apple Speech partial hypotheses and Whisper Direct segments use one visual style because neither represents a separate refinement pass. A dimmed draft style is reserved for a true two-stage pipeline.

Speech-engine spacing around punctuation is normalized conservatively. Explicit newline characters and return symbols are preserved as real line breaks in the full transcript. The application removes spaces before closing punctuation such as periods, commas, question marks and exclamation marks, including punctuation arriving as a separate segment. It does not invent punctuation or rewrite words.

## Audio segmentation

Audio is not cut at exact digital silence. A microphone almost always contains background signal.

The segmentation layer uses:

- an estimated noise floor;
- a threshold above that noise floor;
- hysteresis between speech start and continuation;
- minimum speech duration;
- minimum end-of-speech pause;
- pre-roll to preserve initial consonants;
- post-roll to preserve word endings;
- maximum chunk duration for speech without pauses;
- overlap when a forced maximum-duration split occurs.

A manual dB threshold remains available, but adaptive mode is the default. An optional setting may omit detected silence from the recognition stream; a short buffered pre-roll is flushed when speech resumes so phrase starts are retained.

## Privacy defaults

The intended product defaults are:

- local inference;
- no content in logs;
- no saved source audio;
- configurable text retention;
- optional encrypted history in a later stage;
- direct deletion rather than moving expired data to Trash.

The product must not promise guaranteed physical overwrite on APFS or SSD media. Secure deletion will rely primarily on encryption and key destruction once encrypted history is implemented.


## Pending audio and completion contract

- The menu-bar icon is available immediately at process startup; model preparation may decorate it but never delays or removes it.
- Releasing push-to-talk schedules capture to stop after the configurable release tail, enabled at 300 ms by default and applied during both preparation and active recognition. Pressing the hot key again during that tail continues the same recording. Menu and latched Stop remain immediate. After capture closes, the final buffer is queued and processed before success can be shown.
- Recordings below one second are treated as intentional cancellations and close without inference or clipboard output.
- For accepted recordings, the panel replaces the waveform with a loader until every chunk has completed.
- Push-to-talk success uses the full-panel green transition and copies only the complete transcript.
- Menu-started recordings show Copy, Open Transcript, and Dismiss after the same queue-complete wait.
- Without live Apple draft, pending capsules represent unprocessed audio. They appear at roughly one word every two seconds, use variable word-like widths, and disappear as the matching queued duration completes.
- With Apple Speech draft, the actual draft text appears beside the selected pending indicator. Draft updates do not acknowledge final recognition work. The indicator remains active through pauses and Stop until the final model resolves the last pending chunk; final outcomes and authoritative engine completion clear it.
- A failed chunk yields a reviewable partial result and never masquerades as a fully successful copied transcript.
