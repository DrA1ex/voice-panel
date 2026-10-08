# Architecture

## VoicePanelCore

Platform-independent logic with executable checks:

- `VoiceActivityDetector` estimates background noise and emits speech/pause events;
- `AudioSegmenter` converts VAD events and mono samples into bounded chunks;
- `OfflineASRChunkPolicy` derives a safe soft boundary, a normal 20-second chunk cap and retry/split behavior for native offline ASR engines; `GigaAMInferenceLimit` independently keeps every GigaAM model call at or below 23 seconds, and `GigaAMChunkPolicy` remains a compatibility alias;
- `TranscriptStabilizer` separates a repeatable prefix from a changing hypothesis tail;
- `TranscriptSession` owns ordered independent transcript segments;
- `TranscriptTextNormalizer` repairs whitespace around punctuation and preserves explicit line breaks without rewriting words;
- `RecognitionAudioTransmissionPolicy` controls optional silence suppression without clipping phrase starts;
- `TranscriptHistoryRepository` encrypts complete history payloads with AES-GCM and writes them atomically;
- `LinearAudioResampler` converts mono samples to the 16 kHz input expected by local ASR engines;
- `RecognitionValidationRun`, `RecognitionTranscriptScorer`, and `RecognitionValidationReport` provide platform-independent repeated timing aggregation, WER/CER scoring, and a versioned export schema.

The core target uses Foundation and CryptoKit and remains independently checkable.

## Audio capture and segmentation

`AudioCaptureService` owns `AVAudioEngine`, extracts microphone samples, calculates RMS and peak values, drives VAD and emits chunks. When optional continuous-draft silence suppression is enabled, it buffers a short recognition pre-roll and flushes it when speech starts. `AudioInputDeviceManager` lists Core Audio input devices and applies the selected device before capture begins.

The detector configuration can be updated while the microphone input test is running, so preset and manual-threshold changes are visible immediately.

`AudioFileDecoder` is the offline input boundary. It uses `AVURLAsset` and `AVAssetReaderTrackOutput` to decode supported audio containers into mono 16 kHz float PCM. The resulting sample is passed to `RecognitionPipelineValidator`, which reuses the production VAD, fusion, segmenter, padding, overlap, and chunk-limit policies. `AudioChunkPCMBuffer` adapts accepted chunks for continuous-buffer engines without introducing a second recognition pipeline.

Whisper, GigaAM, Qwen3-ASR, and Parakeet receive completed VAD chunks. GigaAM, Qwen3-ASR, and Parakeet use `OfflineASRChunkPolicy`: normal pauses close a chunk, continuous speech waits through the configured boundary-search window, and the hard application cap never exceeds 20 seconds including overlap.

## Shared recognition tuning

`RecognitionAudioChunkPipeline` owns the deterministic energy detector, VAD
fusion, segmenter, forced-tail fallback, and chunk-delivery bookkeeping.
`SileroVADRuntime` supplies an optional neural speech decision through the
sherpa-onnx C API. Energy remains available independently, and missing neural
output falls back to the energy decision.

Context and vocabulary are stored globally in `AppSettings`. Engine adapters
translate them only where a backend supports an equivalent mechanism. The
opt-in `RecognitionHallucinationGuard` runs after final local inference and
before a chunk is published.

## Recognition engine boundary

`RecognitionEngine` is the engine boundary. Every engine declares its input mode, display name, finalization timeout and metrics callback.

### Apple Speech

`SystemSpeechRecognitionEngine` requires Apple on-device Speech and consumes continuous `AVAudioPCMBuffer` input. It keeps one logical stream alive until Stop; VAD pauses never end the user session. Apple-specific tuning includes locale, on-device requirement, punctuation and contextual phrases.

### Whisper

`WhisperRecognitionEngine` consumes completed `AudioChunk` values, resamples them to mono 16 kHz, submits work to a persistent `WhisperRuntime`, emits ordered final segments, reports queue/latency/RTF metrics and waits for queued work before completion.

`WhisperRuntimeManager` coordinates installation, preload, readiness, selection changes, compute-mode changes, and unload. Runtime identity includes the requested CPU/Metal/Core ML mode and Flash Attention setting, so changing either reloads the context. `WhisperModelManager` owns fixed model metadata, SHA-1/SHA-256 verification, Core ML encoder ZIP installation, atomic model installation and removal. A runtime alias without an adjacent `.mlmodelc` package is used when Core ML must be disabled even though an encoder is installed.

`WhisperRuntimeConfiguration` resolves Auto, Core ML + Metal, Core ML + CPU, Metal, and CPU modes. Core ML handles only the encoder; decoding follows the selected Metal or CPU path. `WhisperInferenceConfiguration` carries thread count, Greedy/Beam strategy, candidate count, vocabulary prompt, and chunk-context behavior into both normal recognition and benchmark inference.

### GigaAM

`GigaAMModelCatalog` describes four GigaAM v3 variants and every file required by each package. CTC packages contain a model and token vocabulary; RNN-T packages contain encoder, decoder, joiner and token vocabulary files. Plain CTC/RNN-T variants are explicitly labeled as no-punctuation output; E2E variants are labeled as punctuation plus text normalization.

`GigaAMModelManager` downloads each package into a private staging directory, reports weighted progress, verifies every file against its pinned SHA-256, and atomically installs the complete package only when all files pass.

`GigaAMRuntime` is a thin Swift layer over the sherpa-onnx C API. It configures either the NeMo CTC graph or transducer encoder/decoder/joiner graph, creates one persistent offline recognizer and runs inference under a serialized lock. sherpa-onnx owns the CTC or RNN-T greedy decoder loop; VoicePanel does not embed Python, PyTorch, ffmpeg or a separate daemon.

`GigaAMRuntimeManager` provides the same persistent lifecycle contract as Whisper: single-flight installation, load progress, selected-model preload, readiness, failure and unload.

`GigaAMRecognitionEngine` consumes bounded VAD chunks, performs ordered native inference, applies retries, optionally splits a repeatedly failing chunk, reports queue/latency/RTF metrics and flushes the last chunk before finishing.

### Qwen3-ASR and Parakeet

`LocalONNXModelCatalog` exposes a curated set of compatible Qwen3-ASR packages: the pinned 0.6B INT8 default and a larger experimental 1.7B INT8 community export. It also pins Parakeet TDT 0.6B v3 INT8. Qwen uses a convolutional frontend, encoder, decoder, and nested tokenizer directory. Parakeet uses a NeMo transducer encoder, decoder, joiner, and token vocabulary. Arbitrary Hugging Face repositories are intentionally not accepted because quantized Qwen variants can use incompatible runtimes and file layouts.

`LocalONNXModelManager` provides weighted multi-file downloads, nested-path staging, per-file content verification, atomic installation, removal, and installed-size reporting. The 0.6B package uses pinned SHA-256 digests. Every file in the curated 1.7B community export is checked against the content identity returned by Hugging Face during the same download: SHA-256 for LFS objects or Git blob SHA-1 for regular repository files. `LocalONNXRuntimeManager` owns single-flight installation and preload, recovery blocking, readiness, and unload.

`LocalONNXRuntime` configures the Qwen3-ASR or NeMo transducer fields exposed by the pinned sherpa-onnx C API and keeps one serialized native recognizer alive. `LocalONNXRecognitionEngine` shares the bounded offline chunk, retry, split, metrics, and finalization contract used by GigaAM. No Python process, model server, or Homebrew dependency is introduced.

`AppleDraftRefinementRecognitionEngine` runs Apple Speech beside Whisper, GigaAM, Qwen3-ASR, or Parakeet. `ChunkDraftRefinementRecognitionEngine` runs a separately selected faster model from the same family as the final model: Whisper beside Whisper, or GigaAM beside GigaAM. `DraftFinalSegmentAlignment` maps both streams to the exact emitted chunk ID so final text atomically replaces its draft. The final engine is authoritative for completion; draft failure cannot keep finalization open.

## Coordination

`TranscriptionCoordinator` owns session transitions and distinguishes two initiation contracts:

- hot-key push-to-talk: press starts, release stops, then loader, success animation, automatic copy and configured presentation;
- menu recording: explicit Start/Stop toggle with a result surface.

Preparation is visible but is no longer a microphone gate. `TranscriptionCoordinator` requests permission, installs metric-only callbacks, and calls `AudioCaptureService.startPreparationCapture` before creating or starting the final recognition engine and before preparing Silero VAD. `AudioCaptureService` keeps the same `AVAudioEngine` alive, stores bounded PCM buffers, and later calls `activatePreparedCapture` to install the final VAD/chunking/transmission policy and drain those buffers in order without an input restart or gap. `RecordingPreparationAudioPolicy` always includes preparation lasting at most one second and applies the persisted long-preparation preference beyond that threshold. A push-to-talk release schedules the same configurable tail used during active recognition. When the tail expires, `pauseCaptureForDeferredStop` suspends any preparation, activation, or already-active capture state while preserving the pipeline, then finalizes the held buffer once recognition is ready. A new press or latch calls `resumeCaptureAfterDeferredStop` and continues the same preparation session. Activation drain work is counted with live callbacks so stop/cancel cannot race final handoff.

For imported files, the coordinator uses the same final-engine factory and recognition callbacks but skips microphone authorization, capture, and optional live-draft engines. It converts the file, runs the active offline pipeline, then submits local-model chunks sequentially through a per-chunk continuation. Cancellation resumes any waiting continuation and invalidates the operation ID, preventing late results from continuing an abandoned import.

The coordinator routes audio by engine mode:

- Apple Speech: continuous buffers;
- Whisper: VAD chunks;
- Apple Draft → Whisper/GigaAM: both continuous buffers and VAD chunks.
- Same-family local draft → final refinement: shared VAD chunks sent to both selected local models.

The Apple draft runs as one continuous request. `TimedDraftTimeline` maps each draft word to session capture time and partitions the hypothesis at the actual chunk cuts, including retrospective balanced cuts; a chunk's final text replaces only the words of its own audio range. Apple Speech (verified on macOS 26) behaves as follows, and the draft must not assume a cumulative hypothesis:

- interim results carry zero word timings, so a word is placed at the capture time when Apple first reported it, slightly after it was spoken;
- after a pause of roughly two seconds or longer, Apple repeats the phrase once with `speechRecognitionMetadata` and real word timings, then restarts `formattedString` from empty without `isFinal`; a task's final result contains only its last utterance.

`SpeechUtteranceAccumulator` keeps closed utterances inside the task, so a pause never clears or relocates recognized text, in either the draft or the standalone Apple Speech backend. Because estimated word positions lag the speech, the timeline drops leading draft words after a cut when the preceding final text already ends with them.

It also persists finalized text through `HistoryModel` and protects live read-only sessions from accidental copy/close behavior.

## Final transcript post-processing

`TranscriptPostProcessor` is a core, language-independent final pass over ordered recognition segments. It performs conservative exact or near-exact boundary alignment, removes overlap duplicates, and repairs boundary punctuation/capitalization conflicts. It also exposes a separate opt-in language-mismatch blacklist for deployments that can provide sufficient external evidence; VoicePanel leaves mixed-language phrases intact by default. It never performs a general rewrite.

`TranscriptionCoordinator` runs this pass once after the engine queue is complete and before history persistence, clipboard copy, or result presentation. When GigaAM Russian correction is enabled, `RussianTextCorrectionRuntimeManager` installs and loads the pinned SAGE FRED-T5 INT8 package, then runs bounded encoder-decoder generation through `VoicePanelORTBridge` and ONNX Runtime. `TranscriptCandidateEditFilter` converts every generated sentence candidate into explicit case, punctuation, spelling, replacement, insertion, or deletion operations. VoicePanel applies case and conservative punctuation changes directly, accepts spelling only when the source is unknown and the candidate is known to the macOS Russian spell checker, and rejects word insertion, deletion, or unvalidated lexical replacement. The optional model is isolated from ASR runtime ownership. Cancellation invalidates the operation, and any correction failure falls back to the universal cleaned result.

## History

`HistoryModel` wraps the core repository for SwiftUI. A random 256-bit history key is stored in the device-only macOS Keychain and complete payloads are encrypted with AES-GCM. Plaintext records are loaded into UI memory only after `deviceOwnerAuthentication` succeeds, and closing the history window locks and clears them again. If the Keychain was unavailable during application startup, every explicit Unlock action authenticates again and then rebuilds the repository from the existing key; destructive start-over recovery is offered only after that authenticated retry still cannot open the encrypted store. Existing `history.json` data is migrated into `history.enc` and the plaintext file is removed. The `None` storage mode deletes persisted history and keeps only the currently open transcript in memory. Audio is not saved.

## UI

AppKit owns window behavior:

- `CompactPanelController` creates and resizes the non-activating `NSPanel`;
- `FullTranscriptWindowController` creates the complete transcript/editor window;
- `HistoryWindowController` creates history browsing;
- `SettingsWindowController` creates a retained key window and reasserts activation after status-menu dismissal races;
- `AppDelegate` owns the menu-bar item, model status, preparation badge and Carbon hot key.

SwiftUI owns the window content. `SlidingTranscriptView` reserves stable columns for text and pending feedback. `TranscriptTextViewport` draws a cached, bounded transcript tail with CoreText inside fixed native bounds, following the newest words without oversized SwiftUI text surfaces. Compact and Medium render one line; Large renders the last three wrapped lines. Small single-line appends use a bounded 100 ms display-link animation; larger revisions snap immediately. Draft updates never resolve final-chunk feedback: `AppState` tracks it until chunk outcomes or engine completion, including after capture stops. The compact and full transcript views expose the same URL drop destination and route accepted files back through `AppDelegate` to the coordinator.

`ModelBenchmarkRunner` owns the in-memory reusable sample. Sample capture and Play/Stop playback are independent from model preparation and inference, so recording never waits for a benchmark target to load. The runner serializes one test at a time, supports one, three, or five independent passes, stores immutable target snapshots, and produces a validation report through the core schema. `WhisperChunkContextPolicy` builds a bounded explicit prompt only from accepted text preceding a maximum-duration boundary. whisper.cpp hidden decoder history stays disabled; pauses, rejected results, failures, and repeated benchmark passes reset continuity. Pipeline tracing records the original waveform, every VAD state span and transition, accepted chunk and speech ranges, boundary reasons, and minimum-duration rejection. Source audio never enters the report. `SettingsView` uses a two-column Performance Testing workspace: a fixed sample/result card on the left, scrolling stage-specific controls on the right, and one toolbar for stage and run actions. Shared disclosure rows use a full-width button target rather than a chevron-only target.

## Important boundaries

- UI does not call Speech, whisper.cpp, sherpa-onnx or ONNX Runtime directly.
- Model installation and persistent runtime ownership are separate responsibilities.
- VAD and ASR remain separate concerns; engine input mode decides how audio is delivered.
- Compact and full transcript views share one `AppState` and one `TranscriptSession`.
- Audio chunks remain bounded when no pause is detected.
- GigaAM's normal chunk target stays at or below 20 seconds, while an independent 23-second inference guard leaves headroom below the model's 25-second failure limit.
- Recognition language values are stored separately per engine; GigaAM v3 is fixed to Russian.
- Draft text and final text are mapped by stable segment sequence and replaced atomically.
- Punctuation normalization is applied in the text pipeline, not as a visual-only transformation.
- History stores final user-facing text, not recognition events, model files or source audio.
