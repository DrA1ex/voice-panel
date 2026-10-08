#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ENTRY_FILE="$ROOT_DIR/Sources/VoicePanelApp/VoicePanelMain.swift"
LEGACY_ENTRY_FILE="$ROOT_DIR/Sources/VoicePanelApp/main.swift"
HOT_KEY_FILE="$ROOT_DIR/Sources/VoicePanelApp/HotKey/GlobalHotKey.swift"

fail() {
    echo "App source contract failed: $1" >&2
    exit 1
}

"$ROOT_DIR/scripts/internal/check-swiftui-view-builders.py" "$ROOT_DIR/Sources/VoicePanelApp"
"$ROOT_DIR/scripts/internal/check-swiftui-previews.py" "$ROOT_DIR/Sources/VoicePanelApp"

[[ ! -e "$LEGACY_ENTRY_FILE" ]] \
    || fail "legacy top-level main.swift must not be restored"
[[ -f "$ENTRY_FILE" ]] \
    || fail "VoicePanelMain.swift is missing"
grep -Eq '^@main$' "$ENTRY_FILE" \
    || fail "the application entry point must use @main"
grep -Eq '^@MainActor$' "$ENTRY_FILE" \
    || fail "the application entry point must be isolated to MainActor"
grep -Fq 'withExtendedLifetime(delegate)' "$ENTRY_FILE" \
    || fail "the weak NSApplication delegate must be retained around application.run()"

if grep -Fq 'UInt32(MemoryLayout<EventHotKeyID>.size)' "$HOT_KEY_FILE"; then
    fail "GetEventParameter expects an Int-sized buffer length on the supported macOS SDK"
fi
grep -Fq 'MemoryLayout<EventHotKeyID>.size,' "$HOT_KEY_FILE" \
    || fail "the EventHotKeyID buffer length is missing"
if grep -Eq 'UInt32\([^)]*\.count\)' "$HOT_KEY_FILE"; then
    fail "InstallEventHandler expects an Int event-count on the supported macOS SDK"
fi
grep -Fq 'buffer.count,' "$HOT_KEY_FILE" \
    || fail "InstallEventHandler must receive the native Int buffer count"

BUILD_SCRIPT="$ROOT_DIR/scripts/build-app.sh"
RUN_SCRIPT="$ROOT_DIR/scripts/run-dev.sh"
PACKAGE_SCRIPT="$ROOT_DIR/scripts/package-dmg.sh"

# build-app.sh stdout is an API: it must contain only the final .app path.
grep -Fq '"$SWIFT_BIN" build "${VOICEPANEL_SWIFT_BUILD_ARGS[@]}" -c "$CONFIGURATION" --product "$APP_NAME" >&2' "$BUILD_SCRIPT" \
    || fail "the app build must select only the VoicePanel product and redirect progress away from stdout"
grep -Fq "printf '%s\n'" "$BUILD_SCRIPT" \
    || fail "build-app.sh must print the final application path explicitly"
grep -Fq '[[ ! -d "$APP_PATH" ]]' "$RUN_SCRIPT" \
    || fail "run-dev.sh must validate the path returned by build-app.sh"
[[ -x "$PACKAGE_SCRIPT" ]] \
    || fail "DMG packaging script is missing or not executable"
grep -Fq 'VOICEPANEL_TARGET_ARCH' "$BUILD_SCRIPT" \
    || fail "the app build must support an explicit macOS target architecture"
grep -Fq ' -verify_arch ' "$BUILD_SCRIPT" \
    || fail "the app build must validate the requested executable architecture"
grep -Fq 'cp "$APP_ICON_FILE" "$RESOURCES_DIR/VoicePanel.icns"' "$BUILD_SCRIPT" \
    || fail "the app builder must embed the custom application icon"
grep -Fq 'hdiutil create' "$PACKAGE_SCRIPT" \
    || fail "the release packaging script must create DMG images"
grep -Fq 'DMGBackground.png' "$PACKAGE_SCRIPT" \
    || fail "the DMG package must include its custom installer background"
grep -Fq 'set position of item appName' "$PACKAGE_SCRIPT" \
    || fail "the DMG package must position the app icon on its installer background"
grep -Fq 'set position of item "Applications"' "$PACKAGE_SCRIPT" \
    || fail "the DMG package must position the Applications shortcut"
grep -Fq 'notarytool submit' "$PACKAGE_SCRIPT" \
    || fail "the release packaging script must support notarization"
grep -Fq 'codesign --force --sign "$SIGN_IDENTITY" --timestamp "$dmg_path"' "$PACKAGE_SCRIPT" \
    || fail "the release DMG must be signed before notarization"
grep -Fq 'hdiutil verify "$dmg_path"' "$PACKAGE_SCRIPT" \
    || fail "the release DMG must be verified after creation"
if grep -Fq 'codesign --deep' "$BUILD_SCRIPT"; then
    fail "release signing must sign nested code explicitly instead of using codesign --deep"
fi
grep -Fq 'codesign "${APP_CODE_SIGN_ARGS[@]}" "$APP_DIR"' "$BUILD_SCRIPT" \
    || fail "the outer application bundle must be signed after nested code"
ENTITLEMENTS_FILE="$ROOT_DIR/Resources/VoicePanel.entitlements"
[[ -f "$ENTITLEMENTS_FILE" ]] \
    || fail "the release application entitlements file is missing"
grep -Fq '<key>com.apple.security.device.audio-input</key>' "$ENTITLEMENTS_FILE" \
    || fail "the release application must declare microphone access for hardened runtime"
grep -Fq -- '--entitlements "$ENTITLEMENTS_FILE"' "$BUILD_SCRIPT" \
    || fail "the outer application signature must embed the release entitlements"
grep -Fq 'codesign --display --entitlements :- "$APP_DIR"' "$BUILD_SCRIPT" \
    || fail "the finished application signature must be checked for embedded entitlements"

COMPACT_VIEW_FILE="$ROOT_DIR/Sources/VoicePanelApp/UI/CompactPanelView.swift"
SLIDING_VIEW_FILE="$ROOT_DIR/Sources/VoicePanelApp/UI/SlidingTranscriptView.swift"
TRANSCRIPT_VIEWPORT_FILE="$ROOT_DIR/Sources/VoicePanelApp/UI/TranscriptTextViewport.swift"
PANEL_CONTROLLER_FILE="$ROOT_DIR/Sources/VoicePanelApp/UI/CompactPanelController.swift"
DISPLAY_LINK_DRIVER_FILE="$ROOT_DIR/Sources/VoicePanelApp/UI/WindowDisplayLinkDriver.swift"
MODEL_BENCHMARK_FILE="$ROOT_DIR/Sources/VoicePanelApp/Models/ModelBenchmarkRunner.swift"
SILERO_MODEL_MANAGER_FILE="$ROOT_DIR/Sources/VoicePanelApp/Models/VAD/SileroVADModelManager.swift"
SETTINGS_VIEW_FILE="$ROOT_DIR/Sources/VoicePanelApp/UI/SettingsView.swift"
PERFORMANCE_SNAPSHOT_FILE="$ROOT_DIR/Sources/VoicePanelApp/Settings/PerformanceConfigurationSnapshot.swift"
VALIDATION_FILE="$ROOT_DIR/Sources/VoicePanelCore/RecognitionValidation.swift"
COORDINATOR_FILE="$ROOT_DIR/Sources/VoicePanelApp/Recognition/TranscriptionCoordinator.swift"
APP_DELEGATE_FILE="$ROOT_DIR/Sources/VoicePanelApp/App/AppDelegate.swift"
SPEECH_FILE="$ROOT_DIR/Sources/VoicePanelApp/Recognition/SystemSpeechRecognitionEngine.swift"
HISTORY_FILE="$ROOT_DIR/Sources/VoicePanelApp/History/HistoryModel.swift"
AUDIO_FILE_DECODER_FILE="$ROOT_DIR/Sources/VoicePanelApp/Audio/AudioFileDecoder.swift"
AUDIO_CHUNK_BUFFER_FILE="$ROOT_DIR/Sources/VoicePanelApp/Audio/AudioChunkPCMBuffer.swift"
AUDIO_FILE_DROP_HANDLER_FILE="$ROOT_DIR/Sources/VoicePanelApp/Audio/AudioFileDropHandler.swift"
AUDIO_IMPORT_PROGRESS_FILE="$ROOT_DIR/Sources/VoicePanelCore/AudioImportProgress.swift"
RECORDING_START_CUE_FILE="$ROOT_DIR/Sources/VoicePanelApp/Audio/RecordingStartCue.swift"
FULL_TRANSCRIPT_VIEW_FILE="$ROOT_DIR/Sources/VoicePanelApp/UI/FullTranscriptView.swift"
APP_STATE_FILE="$ROOT_DIR/Sources/VoicePanelApp/App/AppState.swift"

SETTINGS_CONTROLLER_FILE="$ROOT_DIR/Sources/VoicePanelApp/UI/SettingsWindowController.swift"
WHISPER_ENGINE_FILE="$ROOT_DIR/Sources/VoicePanelApp/Recognition/WhisperRecognitionEngine.swift"
WHISPER_RUNTIME_MANAGER_FILE="$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperRuntimeManager.swift"
WHISPER_RUNTIME_FILE="$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperRuntime.swift"
WHISPER_BENCHMARK_CLASSIFICATION_FILE="$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperBenchmarkChunkClassification.swift"
LANGUAGE_CATALOG_FILE="$ROOT_DIR/Sources/VoicePanelApp/Recognition/RecognitionLanguageCatalog.swift"
GIGAAM_RUNTIME_FILE="$ROOT_DIR/Sources/VoicePanelApp/Models/GigaAM/GigaAMRuntime.swift"
GIGAAM_ENGINE_FILE="$ROOT_DIR/Sources/VoicePanelApp/Recognition/GigaAMRecognitionEngine.swift"

[[ -f "$DISPLAY_LINK_DRIVER_FILE" ]] \
    || fail "the window display-link driver is missing"
grep -Fq 'window.displayLink(' "$DISPLAY_LINK_DRIVER_FILE" \
    || fail "live capture presentation must follow the window display cadence"
grep -Fq 'let state: AppState' "$SETTINGS_VIEW_FILE" \
    || fail "SettingsView must not observe every high-frequency AppState change"
grep -Fq 'stateActivity.phase == .monitoring && presentationContext.isVisible' "$SETTINGS_VIEW_FILE" \
    || fail "settings input metrics must exist only for visible Test Input monitoring"
grep -Fq '&& phase == .monitoring' "$SETTINGS_CONTROLLER_FILE" \
    || fail "settings display updates must stay disabled during ordinary recording"
python3 - "$COORDINATOR_FILE" <<'PYCAPTUREPRESENTATION'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
mailbox = source[
    source.index("private final class LatestCaptureMetricsMailbox"):
    source.index("extension NSLock")
]
if "DispatchQueue.main" in mailbox:
    raise SystemExit(
        "App source contract failed: audio callbacks must not enqueue one main-thread delivery per metrics update"
    )
if "func takeLatest()" not in mailbox or "flushCaptureMetricsForDisplay()" not in source:
    raise SystemExit(
        "App source contract failed: capture metrics must be pulled by the display presentation path"
    )
PYCAPTUREPRESENTATION

grep -Fq 'PerformancePipelineVisualizationView' "$SETTINGS_VIEW_FILE" \
    || fail "the pipeline visualization view is missing"
grep -Fq 'PerformancePipelineSignalTrack' "$SETTINGS_VIEW_FILE" \
    || fail "pipeline visualization must separate the signal track"
grep -Fq 'PerformancePipelineStateTrack' "$SETTINGS_VIEW_FILE" \
    || fail "pipeline visualization must separate the VAD state track"
grep -Fq 'PerformancePipelineChunkTrack' "$SETTINGS_VIEW_FILE" \
    || fail "pipeline visualization must separate accepted chunks"
grep -Fq 'let timelineWidth = viewportWidth * zoomScale' "$SETTINGS_VIEW_FILE" \
    || fail "pipeline Fit must map exactly to the available timeline viewport"
grep -Fq 'Button("Fit")' "$SETTINGS_VIEW_FILE" \
    || fail "pipeline zoom controls must expose an explicit Fit action"
grep -Fq 'tickTimes(for: geometry.size.width)' "$SETTINGS_VIEW_FILE" \
    || fail "fitted pipeline timelines must thin time labels based on available width"
grep -Fq 'PerformancePipelineChunkLayout.placements' "$SETTINGS_VIEW_FILE" \
    || fail "overlapping pipeline chunks must be assigned to separate visual lanes"
grep -Fq 'timelineHeight + activeScrollbarGutter' "$SETTINGS_VIEW_FILE" \
    || fail "the pipeline timeline must reserve space for its horizontal scrollbar"
grep -Fq 'PerformancePipelineChunkInspector' "$SETTINGS_VIEW_FILE" \
    || fail "pipeline visualization must provide an interactive chunk inspector"
grep -Fq 'RecognitionPipelineVisualizationPolicy.finding' "$SETTINGS_VIEW_FILE" \
    || fail "pipeline visualization must surface an explicit result assessment"
grep -Fq 'boundarySilenceDuration' "$MODEL_BENCHMARK_FILE" \
    || fail "pipeline visualization must retain the measured pause duration for inspection"
if grep -Fq 'Cut / VAD switch' "$SETTINGS_VIEW_FILE"; then
    fail "pipeline visualization must not merge cut and VAD transition semantics"
fi
if grep -Fq 'silence cut' "$SETTINGS_VIEW_FILE"; then
    fail "normal pause boundaries must not be presented as red cut errors"
fi
grep -Fq 'enum WhisperBenchmarkChunkRecognitionState' "$WHISPER_BENCHMARK_CLASSIFICATION_FILE"     || fail "pipeline chunks must retain their individual recognition result"
grep -Fq 'updateChunkRecognition(at: chunkIndex' "$MODEL_BENCHMARK_FILE"     || fail "pipeline chunk transcripts must publish progressively"
grep -Fq 'cachedSileroRuntime' "$MODEL_BENCHMARK_FILE"     || fail "benchmark VAD runtime must be reused across compatible runs"
grep -Fq 'fixedAnalysisDuration: prepared.analysisDuration' "$MODEL_BENCHMARK_FILE"     || fail "repeated inference must reuse one VAD trace while preserving timing semantics"
grep -Fq 'Recognized text' "$SETTINGS_VIEW_FILE"     || fail "the selected chunk inspector must show its recognized text"
grep -Fq '.frame(maxWidth: .infinity, alignment: .leading)' "$SETTINGS_VIEW_FILE"     || fail "the selected chunk inspector must fill the available width"
grep -Fq 'displayedPerformancePipelineSummary' "$SETTINGS_VIEW_FILE"     || fail "pipeline visualization must be visible while recognition is still running"
grep -Fq 'GigaAMInferenceLimit.accepts(sampleCount: samples.count)' "$GIGAAM_RUNTIME_FILE" \
    || fail "GigaAM runtime must reject audio above the independent inference limit"
grep -Fq 'chunksBoundedToInferenceLimit(chunk)' "$GIGAAM_ENGINE_FILE" \
    || fail "GigaAM recognition must split external chunks before inference"
grep -Fq '.chunksBoundedToInferenceLimit(chunk)' "$MODEL_BENCHMARK_FILE" \
    || fail "GigaAM benchmark runs must split external chunks before inference"
python3 - "$MODEL_BENCHMARK_FILE" "$SILERO_MODEL_MANAGER_FILE" <<'PYPERFORMANCE'
import pathlib
import sys

benchmark = pathlib.Path(sys.argv[1]).read_text()
silero_manager = pathlib.Path(sys.argv[2]).read_text()

begin_start = benchmark.index("    private func begin(")
begin_end = benchmark.index("    func playRecordedSample()", begin_start)
begin = benchmark[begin_start:begin_end]
analysis = begin.index("let prepared = await self.prepareAudio(")
backend_switch = begin.index("switch backend", analysis)
whisper_prepare = begin.index("whisperRuntime.prepare(", backend_switch)
if not analysis < backend_switch < whisper_prepare:
    raise SystemExit(
        "App source contract failed: VAD analysis must publish before final-model preparation"
    )

run_pass_start = benchmark.index("    private func runPass(")
run_pass_end = benchmark.index("    private func prepareAudio(", run_pass_start)
if "prepareAudio(" in benchmark[run_pass_start:run_pass_end]:
    raise SystemExit(
        "App source contract failed: repeated passes must not recompute the VAD trace"
    )

installed_start = silero_manager.index("    var isInstalled: Bool {")
installed_end = silero_manager.index("    var statusText:", installed_start)
if "sha256" in silero_manager[installed_start:installed_end]:
    raise SystemExit(
        "App source contract failed: SwiftUI reads must not hash the Silero model repeatedly"
    )
PYPERFORMANCE

python3 - "$MODEL_BENCHMARK_FILE" "$COORDINATOR_FILE" <<'PYINPUTRECOVERY'
import pathlib
import sys

contracts = [
    (
        pathlib.Path(sys.argv[1]),
        "    private func audioInputDeviceDidChange(_ event: AudioInputDeviceChangeEvent) {",
        "    private func performInputRecovery(",
    ),
    (
        pathlib.Path(sys.argv[2]),
        "    private func scheduleInputRecovery(",
        "    private func performInputRecovery(",
    ),
]

for path, schedule_marker, worker_marker in contracts:
    source = path.read_text()
    schedule_start = source.index(schedule_marker)
    worker_start = source.index(worker_marker, schedule_start)
    schedule = source[schedule_start:worker_start]

    if "Task<Void, Never> { @MainActor [weak self] in" not in schedule:
        raise SystemExit(
            f"App source contract failed: {path.name} must schedule input recovery with a small explicitly MainActor-isolated task"
        )
    if "AudioInputRecoveryPolicy.decision" in schedule:
        raise SystemExit(
            f"App source contract failed: {path.name} must keep recovery work outside the Task initializer expression"
        )
    if "[weak self, weak settings]" in schedule:
        raise SystemExit(
            f"App source contract failed: {path.name} must not capture AppSettings in the recovery Task initializer"
        )

    worker_end = source.index("    private func finishInputRecovery(id: UUID) {", worker_start)
    worker = source[worker_start:worker_end]
    if "defer { finishInputRecovery(id: recoveryID) }" not in worker:
        raise SystemExit(
            f"App source contract failed: {path.name} input recovery must clear only its own scheduled task"
        )
    if "guard inputRecoveryID == id else { return }" not in source[worker_end:]:
        raise SystemExit(
            f"App source contract failed: {path.name} must protect newer recovery tasks from stale completion"
        )
PYINPUTRECOVERY

# Keep the SettingsView call aligned with its explicit initializer. This is
# parsed from the source rather than duplicated as a brittle hard-coded string.
"$ROOT_DIR/scripts/internal/check-settings-view-initializer.py" \
    "$ROOT_DIR/Sources/VoicePanelApp/UI/SettingsView.swift" \
    "$SETTINGS_CONTROLLER_FILE"

# Swift 6 diagnostics in the hot-key and recognition boundaries are regressions.
grep -Fq 'let eventTypes = [' "$HOT_KEY_FILE" \
    || fail "Carbon event types must be immutable"
grep -Fq 'let status = eventTypes.withUnsafeBufferPointer' "$HOT_KEY_FILE" \
    || fail "InstallEventHandler result must be consumed"
grep -Fq 'if status != noErr' "$HOT_KEY_FILE" \
    || fail "InstallEventHandler failures must be checked"
grep -Fq 'statusItem.isVisible = true' "$ROOT_DIR/Sources/VoicePanelApp/App/AppDelegate.swift" \
    || fail "the menu-bar status item must be explicitly visible"
grep -Fq 'statusSymbolImage(named:' "$ROOT_DIR/Sources/VoicePanelApp/App/AppDelegate.swift" \
    || fail "the menu-bar icon must provide a symbol fallback"
grep -Fq 'Always provide a visible template fallback' "$ROOT_DIR/Sources/VoicePanelApp/App/AppDelegate.swift" \
    || fail "the menu-bar icon fallback contract is missing"
grep -Fq 'let generation = lock.performLocked {' "$SPEECH_FILE" \
    || fail "Apple Speech async startup must use scoped locking"
grep -Fq 'RecognitionEngine, @unchecked Sendable' "$WHISPER_ENGINE_FILE" \
    || fail "the queue-confined Whisper engine must declare its Sendable contract"
grep -Fq 'final class WhisperRuntime: @unchecked Sendable' "$WHISPER_RUNTIME_FILE" \
    || fail "the persistent Whisper runtime must declare its Sendable contract"

# Push-to-talk requires both Carbon hot-key edge events.
grep -Fq 'kEventHotKeyPressed' "$HOT_KEY_FILE" \
    || fail "the hot key press event is missing"
grep -Fq 'kEventHotKeyReleased' "$HOT_KEY_FILE" \
    || fail "the hot key release event is missing"
grep -Fq 'startHotKeyRecording()' "$COORDINATOR_FILE" \
    || fail "the push-to-talk start path is missing"
grep -Fq 'stopHotKeyRecording()' "$COORDINATOR_FILE" \
    || fail "the push-to-talk release path is missing"
grep -Fq 'HotKeyReleaseTailPolicy.scheduledDuration' "$COORDINATOR_FILE" \
    || fail "push-to-talk release must preserve a configurable tail during preparation and listening"
grep -Fq 'Scheduled hot-key release stop cancelled by a new press' "$COORDINATOR_FILE" \
    || fail "a repeated hot-key press must cancel the pending release stop"
grep -Fq 'case hotKeyLatched' "$ROOT_DIR/Sources/VoicePanelCore/RecordingControlPolicy.swift" \
    || fail "push-to-talk must support latching into manual-stop recording"
grep -Fq 'Audio capture started before recognition engine' "$COORDINATOR_FILE" \
    || fail "push-to-talk must open the microphone before model preparation"
grep -Fq 'startPreparationCapture(' "$COORDINATOR_FILE" \
    || fail "recording preparation must buffer microphone audio immediately"
grep -Fq 'activatePreparedCapture(' "$COORDINATOR_FILE" \
    || fail "prepared microphone audio must enter the final recognition pipeline"
grep -Fq 'pauseCaptureForDeferredStop()' "$COORDINATOR_FILE" \
    || fail "hot-key release during preparation must stop collecting new microphone audio"
grep -Fq 'resumeCaptureAfterDeferredStop(' "$COORDINATOR_FILE" \
    || fail "a repeated press or latch must resume capture after a deferred preparation stop"
grep -Fq 'cancelCurrentSession(showFeedback: false)' "$COORDINATOR_FILE" \
    || fail "release before microphone startup must cancel the empty preparation immediately"
grep -Fq 'RecordingPreparationAudioPolicy.decision' "$ROOT_DIR/Sources/VoicePanelApp/Audio/AudioCaptureService.swift" \
    || fail "long preparation audio must follow the explicit inclusion policy"
grep -Fq 'includeAudioCapturedWhilePreparing' "$ROOT_DIR/Sources/VoicePanelApp/Settings/AppSettings.swift" \
    || fail "the preparation-audio preference must be persisted"
if grep -Fq 'await RecordingStartCue.play()' "$COORDINATOR_FILE"; then
    fail "an audible readiness cue must not delay or contaminate immediate microphone capture"
fi
python3 - "$COORDINATOR_FILE" <<'PYCONTRACT'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
start = source.index("    func startRecording(")
end = source.index("    func transcribeAudioFile(", start)
body = source[start:end]
capture = body.index("try self.audioCapture.startPreparationCapture(")
panel = body.index("self.onShowCompactPanel?()")
if panel < capture:
    raise SystemExit("App source contract failed: the compact panel must not delay microphone startup")
PYCONTRACT
grep -Fq 'onLatchHotKey:' "$PANEL_CONTROLLER_FILE" \
    || fail "the compact panel must expose the hot-key latch action"
grep -Fq 'isMovableByWindowBackground = false' "$PANEL_CONTROLLER_FILE" \
    || fail "native background dragging must stay disabled to avoid double movement"
if grep -Fq 'mouseDownCanMoveWindow' "$PANEL_CONTROLLER_FILE"; then
    fail "the hosting view must not compete with the explicit panel drag gesture"
fi

# The compact transcript must shift and clip rather than truncate with an ellipsis.
grep -Fq 'SlidingTranscriptView' "$COMPACT_VIEW_FILE" \
    || fail "the compact panel must use the sliding transcript viewport"
grep -Fq 'TranscriptTextViewport(text: text, fontSize: fontSize)' "$SLIDING_VIEW_FILE" \
    || fail "the sliding transcript must draw text inside bounded native view bounds"
grep -Fq '.clipped()' "$SLIDING_VIEW_FILE" \
    || fail "the sliding transcript viewport must clip overflowing old text"
grep -Fq 'TranscriptOverflowLayout' "$SLIDING_VIEW_FILE" \
    || fail "the sliding transcript must follow its newest content without stale width measurements"
grep -Fq 'CTLineDraw(line, context)' "$TRANSCRIPT_VIEWPORT_FILE" \
    || fail "long transcript tails must use single-line native drawing"
grep -Fq 'width: proposal.width ?? nsView.intrinsicContentSize.width' "$TRANSCRIPT_VIEWPORT_FILE" \
    || fail "transcript viewport must use its allocated width without stale text measurements"
grep -Fq 'x: drawingOrigin' "$TRANSCRIPT_VIEWPORT_FILE" \
    || fail "transcript text must follow the current viewport width"

# Existing audio files use the active recognition pipeline rather than a separate shortcut.
for required in "$AUDIO_FILE_DECODER_FILE" "$AUDIO_CHUNK_BUFFER_FILE" "$AUDIO_FILE_DROP_HANDLER_FILE"; do
    [[ -f "$required" ]] || fail "missing audio import file: $required"
done
grep -Fq 'Transcribe Audio File…' "$APP_DELEGATE_FILE" \
    || fail "the menu-bar audio import action is missing"
grep -Fq 'func transcribeAudioFile(at url: URL)' "$COORDINATOR_FILE" \
    || fail "audio file transcription coordination is missing"
grep -Fq 'includeDraft: false,' "$COORDINATOR_FILE" \
    || fail "offline file transcription must avoid an unnecessary live-draft engine"
grep -Fq 'RecognitionPipelineValidator.process' "$COORDINATOR_FILE" \
    || fail "imported audio must use the active VAD and segmenter pipeline"
grep -Fq 'appendImportedChunkAndWait' "$COORDINATOR_FILE" \
    || fail "imported local-model chunks must be processed sequentially"
grep -Fq 'AVAssetReaderTrackOutput' "$AUDIO_FILE_DECODER_FILE" \
    || fail "audio import must convert supported media formats through AVFoundation"
grep -Fq 'outputSampleRate: Double = 16_000' "$AUDIO_FILE_DECODER_FILE" \
    || fail "imported audio must be normalized to 16 kHz PCM"
grep -Fq 'of: [UTType.fileURL.identifier]' "$COMPACT_VIEW_FILE" \
    || fail "the compact panel must accept dropped audio files"
grep -Fq 'of: [UTType.fileURL.identifier]' "$FULL_TRANSCRIPT_VIEW_FILE" \
    || fail "the full transcript window must accept dropped audio files"
grep -Fq 'import VoicePanelCore' "$FULL_TRANSCRIPT_VIEW_FILE" \
    || fail "the full transcript window must import VoicePanelCore for audio import progress"
grep -Fq 'loadItem(' "$AUDIO_FILE_DROP_HANDLER_FILE" \
    || fail "dropped Finder file URLs must be resolved through NSItemProvider"
[[ -f "$AUDIO_IMPORT_PROGRESS_FILE" ]] \
    || fail "audio imports need a reusable progress and ETA model"
grep -Fq 'estimateRemainingDuration' "$AUDIO_IMPORT_PROGRESS_FILE" \
    || fail "long audio imports must estimate remaining processing time"
grep -Fq 'publishImportedAudioProgress' "$COORDINATOR_FILE" \
    || fail "audio imports must publish whole-session chunk progress"
grep -Fq 'Cancel Audio Transcription' "$COMPACT_VIEW_FILE" \
    || fail "the compact panel must allow a long audio import to be cancelled"
grep -Fq 'Button("Cancel", role: .cancel, action: onCancel)' "$FULL_TRANSCRIPT_VIEW_FILE" \
    || fail "the full transcript window must allow a long audio import to be cancelled"
grep -Fq 'enqueueRecognitionUpdate' "$COORDINATOR_FILE" \
    || fail "recognition callbacks must be coalesced before updating SwiftUI"
grep -Fq 'applyRecognitionUpdates' "$APP_STATE_FILE" \
    || fail "AppState must publish batched transcript updates"
grep -Fq 'transcriptScroll.schedule' "$FULL_TRANSCRIPT_VIEW_FILE" \
    || fail "the full transcript window must throttle automatic scrolling"
grep -Fq '.onChange(of: state.transcriptPresentation.combinedText, initial: true)' "$FULL_TRANSCRIPT_VIEW_FILE" \
    || fail "transcript corrections of the same length must update scrolling"

# Punctuation normalization belongs in the recognition/text pipeline, not only in UI.
grep -Fq 'TranscriptTextNormalizer.normalize' "$SPEECH_FILE" \
    || fail "Apple Speech hypotheses must pass through punctuation normalization"

# Stage 9 requires an actual persisted history model.
[[ -f "$HISTORY_FILE" ]] \
    || fail "the persisted history model is missing"
grep -Fq 'applyRetentionPolicy' "$HISTORY_FILE" \
    || fail "history retention cleanup is missing"

DIAGNOSTIC_FILE="$ROOT_DIR/Sources/VoicePanelApp/Diagnostics/DiagnosticLogger.swift"
FORCED_CHUNK_FILE="$ROOT_DIR/Sources/VoicePanelCore/ForcedChunkAccumulator.swift"
CHUNK_PIPELINE_FILE="$ROOT_DIR/Sources/VoicePanelCore/RecognitionAudioChunkPipeline.swift"
TRANSCRIPT_SESSION_FILE="$ROOT_DIR/Sources/VoicePanelCore/TranscriptSession.swift"
AUDIO_CAPTURE_FILE="$ROOT_DIR/Sources/VoicePanelApp/Audio/AudioCaptureService.swift"
RECOGNITION_PROTOCOL_FILE="$ROOT_DIR/Sources/VoicePanelApp/Recognition/RecognitionEngine.swift"

grep -Fq 'Recovery startup active; heavy services are deferred until user action' "$APP_DELEGATE_FILE" \
    || fail "unclean startup must defer crash-prone services"
grep -Fq 'Use Apple Speech (Recovery)' "$APP_DELEGATE_FILE" \
    || fail "recovery mode must allow resetting a crashing model selection"
grep -Fq 'ensureSettingsWindowController()' "$APP_DELEGATE_FILE" \
    || fail "the hidden Settings window must be created lazily"
grep -Fq 'ensureCompactPanelController()' "$APP_DELEGATE_FILE" \
    || fail "the compact panel must be created lazily"
grep -Fq 'Startup stage' "$APP_DELEGATE_FILE" \
    || fail "startup crash localization breadcrumbs are missing"
grep -Fq 'NSSetUncaughtExceptionHandler' "$ENTRY_FILE" \
    || fail "Objective-C startup exceptions must be logged"

TOOLCHAIN_ENV_SCRIPT="$ROOT_DIR/scripts/internal/swift-toolchain-env.sh"
TOOLCHAIN_CHECK_SCRIPT="$ROOT_DIR/scripts/internal/check-swift-toolchain.sh"
[[ -x "$TOOLCHAIN_ENV_SCRIPT" ]] \
    || fail "the shared Swift toolchain environment script is missing"
[[ -x "$TOOLCHAIN_CHECK_SCRIPT" ]] \
    || fail "the Swift toolchain target check is missing"
grep -Fq 'MACOSX_DEPLOYMENT_TARGET' "$TOOLCHAIN_ENV_SCRIPT" \
    || fail "build scripts must pin the supported macOS deployment target"

[[ -f "$DIAGNOSTIC_FILE" ]] \
    || fail "persistent diagnostics are missing"
grep -Fq 'Library/Logs/VoicePanel' "$DIAGNOSTIC_FILE" \
    || fail "diagnostics must use the standard per-user macOS logs directory"
grep -Fq 'beginModelLoad' "$DIAGNOSTIC_FILE" \
    || fail "model-load crash breadcrumbs are missing"
grep -Fq 'Open Logs Folder' "$APP_DELEGATE_FILE" \
    || fail "the menu must expose the diagnostics folder"
grep -Fq 'StatusMenuAdvancedItemsPolicy.shouldShow' "$APP_DELEGATE_FILE" \
    || fail "advanced menu actions must be gated by the Option modifier"
grep -Fq 'advancedMenuSeparator.isHidden = true' "$APP_DELEGATE_FILE" \
    || fail "advanced menu actions must start hidden"
grep -Fq 'func menuDidClose(_ menu: NSMenu)' "$APP_DELEGATE_FILE" \
    || fail "advanced menu actions must return to hidden state after the menu closes"
grep -Fq -- '--safe-mode' "$APP_DELEGATE_FILE" \
    || fail "safe startup must be supported after native model crashes"
[[ -x "$ROOT_DIR/scripts/run-safe.sh" ]] \
    || fail "the safe startup script is missing"
[[ -f "$FORCED_CHUNK_FILE" ]] \
    || fail "VAD-independent hard chunking is missing"
[[ -f "$CHUNK_PIPELINE_FILE" ]] \
    || fail "the testable recognition chunk pipeline is missing"
grep -Fq 'RecognitionAudioChunkPipeline' "$AUDIO_CAPTURE_FILE" \
    || fail "live audio capture must use the testable chunk pipeline"
grep -Fq 'ForcedChunkAccumulator' "$CHUNK_PIPELINE_FILE" \
    || fail "the chunk pipeline must retain a hard boundary fallback"
grep -Fq 'overlapDuration: segmenterConfiguration.overlapDuration' "$CHUNK_PIPELINE_FILE" \
    || fail "forced chunks must preserve configured overlap"
grep -Fq 'case finalizedSegmentsOnly' "$RECOGNITION_PROTOCOL_FILE" \
    || fail "hybrid engines must declare a final-text policy"
grep -Fq 'finalizedText' "$TRANSCRIPT_SESSION_FILE" \
    || fail "draft-only text must be separable from finalized transcript text"
grep -Fq 'finalizedSegmentsOnly: finalizedSegmentsOnly' "$COORDINATOR_FILE" \
    || fail "clipboard and history must finalize according to the engine text policy"
grep -Fq 'processedText: finalText' "$COORDINATOR_FILE" \
    || fail "final transcript post-processing must feed the persisted and presented result"
TEXT_CORRECTION_CATALOG_FILE="$ROOT_DIR/Sources/VoicePanelApp/Models/TextCorrection/RussianCorrectionModelCatalog.swift"
grep -Fq '3343e7765f2cd668a04e3200f8753b382444f274' "$TEXT_CORRECTION_CATALOG_FILE" \
    || fail "SAGE INT8 weights must stay pinned to their verified conversion revision"
grep -Fq 'ed51b4a46603931380951a3d8456685c9215864f' "$TEXT_CORRECTION_CATALOG_FILE" \
    || fail "SAGE tokenizer files must stay pinned to the official model revision"
grep -Fq 'c8fb179fb56ed9c80026891bf7339a5804072bc02351ddf76d792293b70c2821' "$TEXT_CORRECTION_CATALOG_FILE" \
    || fail "SAGE encoder checksum is missing"
grep -Fq '062cfd09b268fb9e12dd45ad57bf1a5969956b19094e448321c9e2b431b0e7b2' "$TEXT_CORRECTION_CATALOG_FILE" \
    || fail "SAGE decoder checksum is missing"
TEXT_CORRECTION_RUNTIME_FILE="$ROOT_DIR/Sources/VoicePanelApp/Models/TextCorrection/RussianTextCorrectionRuntime.swift"
TEXT_EDIT_FILTER_FILE="$ROOT_DIR/Sources/VoicePanelCore/TranscriptCandidateEditFilter.swift"
[[ -f "$TEXT_EDIT_FILTER_FILE" ]] \
    || fail "the edit-based transcript safety layer is missing"
grep -Fq 'TranscriptCandidateEditFilter.apply' "$TEXT_CORRECTION_RUNTIME_FILE" \
    || fail "SAGE output must pass through the edit-based safety layer"
grep -Fq 'rejectedMeaningChangingEditCount' "$TEXT_CORRECTION_RUNTIME_FILE" \
    || fail "SAGE correction must report rejected meaning-changing edits"
grep -Fq 'NSSpellChecker.shared' "$TEXT_CORRECTION_RUNTIME_FILE" \
    || fail "spelling changes must require system dictionary validation"
grep -Fq 'case lexicalReplacement' "$TEXT_EDIT_FILTER_FILE" \
    || fail "the edit layer must classify lexical substitutions explicitly"

# Apple Speech and Whisper use different audio delivery contracts.
RECOGNITION_PROTOCOL_FILE="$ROOT_DIR/Sources/VoicePanelApp/Recognition/RecognitionEngine.swift"
WHISPER_ENGINE_FILE="$ROOT_DIR/Sources/VoicePanelApp/Recognition/WhisperRecognitionEngine.swift"
MODEL_MANAGER_FILE="$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperModelManager.swift"
MODEL_CATALOG_FILE="$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperModelCatalog.swift"
SETTINGS_FILE="$ROOT_DIR/Sources/VoicePanelApp/Settings/AppSettings.swift"
FULL_TRANSCRIPT_FILE="$ROOT_DIR/Sources/VoicePanelApp/UI/FullTranscriptView.swift"
APP_STATE_FILE="$ROOT_DIR/Sources/VoicePanelApp/App/AppState.swift"
AUDIO_CAPTURE_FILE="$ROOT_DIR/Sources/VoicePanelApp/Audio/AudioCaptureService.swift"
PACKAGE_FILE="$ROOT_DIR/Package.swift"

# Recognition selection reconciliation must be idempotent and non-reentrant.
grep -Fq 'private var isReconcilingDraftSelections = false' "$SETTINGS_FILE" \
    || fail "AppSettings draft reconciliation needs a reentrancy barrier"
grep -Fq 'whisperModelID.isEnglishOnly, whisperLanguageCode != "en"' "$SETTINGS_FILE" \
    || fail "English-only Whisper reconciliation must not republish the same language"
grep -Fq 'private var isReconcilingRecognitionSelection = false' "$APP_DELEGATE_FILE" \
    || fail "AppDelegate recognition reconciliation needs a reentrancy barrier"
grep -Fq '.removeDuplicates()' "$APP_DELEGATE_FILE" \
    || fail "recognition selection observers must ignore duplicate published values"
grep -Fq 'settings.whisperLanguageCode != "en"' "$ROOT_DIR/Sources/VoicePanelApp/UI/SettingsView.swift" \
    || fail "Settings language validation must avoid same-value publication"
grep -Fq 'Reset Settings and Quit…' "$APP_DELEGATE_FILE" \
    || fail "the menu must offer a settings reset recovery action"
[[ -x "$ROOT_DIR/scripts/reset-settings.sh" ]] \
    || fail "the command-line settings reset helper is missing"
grep -Fq 'migrateLegacyPreferencesIfNeeded' "$SETTINGS_FILE" \
    || fail "the release bundle identifier change must migrate prototype preferences"
grep -Fq 'dev.voicepanel.prototype' "$SETTINGS_FILE" \
    || fail "the legacy preference domain must remain available for one-time migration"
grep -Fq 'dev.voicepanel.prototype' "$ROOT_DIR/scripts/reset-settings.sh" \
    || fail "settings reset must also clear the legacy preference domain"


for required in "$WHISPER_ENGINE_FILE" "$MODEL_MANAGER_FILE" "$MODEL_CATALOG_FILE"; do
    [[ -f "$required" ]] || fail "missing Whisper integration file: $required"
done
grep -Fq 'case continuousBuffers' "$RECOGNITION_PROTOCOL_FILE" \
    || fail "continuous audio input mode is missing"
grep -Fq 'case vadChunks' "$RECOGNITION_PROTOCOL_FILE" \
    || fail "VAD chunk input mode is missing"
grep -Fq 'audioInputMode: RecognitionAudioInputMode = .continuousBuffers' "$SPEECH_FILE" \
    || fail "Apple Speech must remain a continuous input engine"
grep -Fq 'audioInputMode: RecognitionAudioInputMode = .vadChunks' "$WHISPER_ENGINE_FILE" \
    || fail "Whisper must consume completed VAD chunks"
grep -Fq 'LinearAudioResampler.resampleMono' "$WHISPER_ENGINE_FILE" \
    || fail "Whisper input must be resampled to 16 kHz mono"
grep -Fq 'runtime.transcribe' "$WHISPER_ENGINE_FILE" \
    || fail "Whisper engine must use the preloaded persistent runtime"
grep -Fq 'kind: .segmentFinal' "$WHISPER_ENGINE_FILE" \
    || fail "direct Whisper recognition must publish authoritative final segments"
if grep -Fq 'chunk.trimmingSilence(' "$WHISPER_ENGINE_FILE"; then
    fail "Whisper must not re-trim chunks after profile-aware segmentation"
fi
grep -Fq 'RecognitionInferenceChunkPolicy.admittedChunk(chunk)' "$WHISPER_ENGINE_FILE" \
    || fail "Whisper must use the tested admission policy without overriding preset margins"
grep -Fq 'Silent Whisper chunk skipped' "$WHISPER_ENGINE_FILE" \
    || fail "known silent chunks must not reach Whisper inference"
grep -Fq '"textAuthority": "final-model-only"' "$COORDINATOR_FILE" \
    || fail "the no-draft Whisper path must remain explicitly final-model-only"
grep -Fq 'whisper_full(' "$WHISPER_RUNTIME_FILE" \
    || fail "Whisper inference is not connected"
grep -Fq 'params.no_context = true' "$WHISPER_RUNTIME_FILE" \
    || fail "Whisper inference must not reuse hidden prompt_past state"
grep -Fq 'WhisperAudioPreparation.paddedToMinimumDuration' "$WHISPER_RUNTIME_FILE" \
    || fail "short Whisper chunks must be padded instead of silently dropped"
grep -Fq 'whisper_init_from_file_with_params' "$WHISPER_RUNTIME_FILE" \
    || fail "Whisper must initialize directly from the verified model file"
if grep -Fq 'readModelData(' "$WHISPER_RUNTIME_FILE"; then
    fail "Whisper model loading must not duplicate the complete model in Swift Data"
fi
grep -Fq 'loaderQueue' "$WHISPER_RUNTIME_FILE" \
    || fail "Whisper final and draft model loads must be serialized"
grep -Fq 'Insecure.SHA1' "$MODEL_MANAGER_FILE" \
    || fail "Whisper model verification is missing"
grep -Fq 'installationTasks' "$MODEL_MANAGER_FILE" \
    || fail "Whisper model installation must be single-flight"
grep -Fq 'ensureInstalled' "$MODEL_MANAGER_FILE" \
    || fail "automatic Whisper model installation is missing"
grep -Fq 'preloadIfInstalled' "$WHISPER_RUNTIME_MANAGER_FILE" \
    || fail "installed Whisper models must preload before recording"
grep -Fq 'case loading(WhisperModelID, Double)' "$WHISPER_RUNTIME_MANAGER_FILE" \
    || fail "Whisper memory loading progress is missing"
grep -Fq 'case appleSpeech' "$SETTINGS_FILE" \
    || fail "Apple Speech backend option is missing"
grep -Fq ') ?? .appleSpeech' "$SETTINGS_FILE" \
    || fail "Apple Speech must remain the default backend"
grep -Fq 'WhisperFramework' "$PACKAGE_FILE" \
    || fail "the whisper.cpp XCFramework dependency is missing"
grep -Fq 'c7faeb328620d6012e130f3d705c51a6ea6c995605f2df50f6e1ad68c59c6c4a' "$PACKAGE_FILE" \
    || fail "the pinned whisper.cpp XCFramework checksum is missing"
grep -Fq -- "-type d -name '*.framework'" "$BUILD_SCRIPT" \
    || fail "dynamic SwiftPM frameworks must be discovered generically"
grep -Fq '@rpath/*.framework/*)' "$BUILD_SCRIPT" \
    || fail "the app bundle must validate framework dependencies reported by otool"

# Optional silence suppression applies only to the continuous Apple stream.
grep -Fq 'suppressDetectedSilence' "$SETTINGS_FILE" \
    || fail "optional detected-silence suppression setting is missing"
grep -Fq 'RecognitionAudioTransmissionPolicy' "$AUDIO_CAPTURE_FILE" \
    || fail "recognition audio transmission policy is missing"
grep -Fq 'flushBufferedAndTransmit' "$AUDIO_CAPTURE_FILE" \
    || fail "silence suppression must flush pre-roll before speech"

# Newlines and explicit compact-panel states remain required.
grep -Fq '.replacingOccurrences(of: "\n", with: " ")' "$ROOT_DIR/Sources/VoicePanelCore/TranscriptTextNormalizer.swift" \
    || fail "compact transcript must flatten line breaks"
grep -Fq 'compactText = TranscriptTextNormalizer.singleLinePreview(combinedText)' "$APP_STATE_FILE" \
    || fail "compact transcript normalization must be cached with its presentation"
grep -Fq 'state.transcriptPresentation.runs.reduce(Text(""))' "$FULL_TRANSCRIPT_FILE" \
    || fail "full transcript must render all pending and finalized segments in timeline order"
grep -Fq 'Recording — your transcript will appear here' "$COMPACT_VIEW_FILE" \
    || fail "compact panel empty-state placeholder is missing"
for layout in compactRecordingContent mediumRecordingContent largeRecordingContent; do
    grep -Fq "$layout" "$COMPACT_VIEW_FILE" \
        || fail "panel size is missing its dedicated recording layout: $layout"
done
grep -Fq 'state.transcriptPresentation.multilineText' "$COMPACT_VIEW_FILE" \
    || fail "large panel transcripts must keep the recognizer's line breaks"
grep -Fq 'Processing recording' "$COMPACT_VIEW_FILE" \
    || fail "compact panel processing feedback is missing"
grep -Fq 'private var processingLoader' "$COMPACT_VIEW_FILE" \
    || fail "processing feedback must use an indeterminate loader"
if grep -Fq 'processingTrack' "$COMPACT_VIEW_FILE"; then
    fail "processing feedback must not present an indeterminate animation as measured progress"
fi
grep -Fq 'private func terminalContent(' "$COMPACT_VIEW_FILE" \
    || fail "success and error must share the adaptive terminal-state layout"
grep -Fq 'voiceGlowStrength' "$COMPACT_VIEW_FILE" \
    || fail "voice-reactive panel glow is missing"
grep -Fq 'windowWidth' "$COMPACT_VIEW_FILE" \
    || fail "the glow must render in an expanded transparent window"
grep -Fq 'case .medium: return 600' "$SETTINGS_FILE" \
    || fail "Medium panel width must remain 600 points"
grep -Fq 'case .medium: return 150' "$SETTINGS_FILE" \
    || fail "Medium panel height must remain 150 points"
grep -Fq 'case .large: return 650' "$SETTINGS_FILE" \
    || fail "Large panel width must remain 650 points"
grep -Fq 'case .large: return 300' "$SETTINGS_FILE" \
    || fail "Large panel height must remain 300 points"
PANEL_SETTINGS_VIEW_FILE="$ROOT_DIR/Sources/VoicePanelApp/UI/SettingsView.swift"
grep -Fq 'Toggle("Transparent panel background"' "$PANEL_SETTINGS_VIEW_FILE" \
    || fail "Panel appearance must expose background transparency"
grep -Fq 'Toggle("Blur content behind panel"' "$PANEL_SETTINGS_VIEW_FILE" \
    || fail "Panel appearance must expose supported macOS background blur"
grep -Fq 'if !settings.panelBackgroundIsTransparent' "$COMPACT_VIEW_FILE" \
    || fail "Panel must render an opaque background when transparency is disabled"
grep -Fq 'settings.panelBackgroundBlurEnabled && VisualEffectBackground.isSupported' "$COMPACT_VIEW_FILE" \
    || fail "Panel blur must respect both the preference and macOS support"
grep -Fq '.simultaneousGesture(' "$COMPACT_VIEW_FILE" \
    || fail "Panel dragging must remain active alongside recording controls"
grep -Fq 'window.setFrameOrigin(' "$COMPACT_VIEW_FILE" \
    || fail "Panel drag must track the pointer until mouse release"
grep -Fq 'let pointerLocation = NSEvent.mouseLocation' "$COMPACT_VIEW_FILE" \
    || fail "Panel drag must use stable screen coordinates instead of moving view coordinates"
grep -Fq 'terminalWashExpanded' "$COMPACT_VIEW_FILE" \
    || fail "the center-out terminal-state wash is missing"
grep -Fq 'completionPresentation = .copied' "$COORDINATOR_FILE" \
    || fail "push-to-talk must show copied feedback before dismissing"

# Recognition language choices are backend-specific.
[[ -f "$LANGUAGE_CATALOG_FILE" ]] || fail "recognition language catalog is missing"
grep -Fq 'SFSpeechRecognizer.supportedLocales()' "$LANGUAGE_CATALOG_FILE" \
    || fail "Apple Speech languages must come from macOS"
grep -Fq 'whisper_lang_max_id()' "$LANGUAGE_CATALOG_FILE" \
    || fail "Whisper languages must come from whisper.cpp"
grep -Fq 'whisperLanguageCode' "$SETTINGS_FILE" \
    || fail "Whisper language setting is missing"
grep -Fq 'appleSpeechLanguageIdentifier' "$SETTINGS_FILE" \
    || fail "Apple Speech language setting is missing"

# General keeps the microphone and environment beside the live input test;
# manual energy controls remain available only in Advanced Custom mode.
grep -Fq 'Section("Microphone")' "$ROOT_DIR/Sources/VoicePanelApp/UI/SettingsView.swift" \
    || fail "General microphone section is missing"
grep -Fq 'Picker("Environment"' "$ROOT_DIR/Sources/VoicePanelApp/UI/SettingsView.swift" \
    || fail "General microphone environment picker is missing"
grep -Fq 'Picker("Energy sensitivity"' "$ROOT_DIR/Sources/VoicePanelApp/UI/SettingsView.swift" \
    || fail "custom microphone sensitivity picker is missing"
grep -Fq 'updateVADConfiguration' "$AUDIO_CAPTURE_FILE" \
    || fail "live VAD configuration updates are missing"
grep -Fq 'case silero' "$ROOT_DIR/Sources/VoicePanelCore/VoiceActivityFusion.swift" \
    || fail "Silero VAD mode is missing"
grep -Fq 'case hybrid' "$ROOT_DIR/Sources/VoicePanelCore/VoiceActivityFusion.swift" \
    || fail "hybrid VAD mode is missing"
grep -Fq 'SherpaOnnxCreateVoiceActivityDetector' "$ROOT_DIR/Sources/VoicePanelApp/Models/VAD/SileroVADRuntime.swift" \
    || fail "native Silero VAD runtime is missing"
grep -Fq 'Context & Vocabulary' "$ROOT_DIR/Sources/VoicePanelApp/UI/SettingsView.swift" \
    || fail "recognition context and vocabulary controls are missing"
grep -Fq 'Discard obvious hallucination loops' "$ROOT_DIR/Sources/VoicePanelApp/UI/SettingsView.swift" \
    || fail "optional hallucination protection is missing"
# Model preparation and visual feedback contracts.
grep -Fq 'static let visualEffectInset: CGFloat = 48' "$SETTINGS_FILE" \
    || fail "the transparent panel host must leave enough room for the constrained glow"
grep -Fq 'visibleLevelCount: state.audioLevelCount' "$COMPACT_VIEW_FILE" \
    || fail "recording waveform must fill progressively from an empty track"
if grep -Fq '"Pause"' "$COMPACT_VIEW_FILE"; then
    fail "quiet input must remain Recording instead of exposing VAD pause state"
fi
grep -Fq 'terminalAnimationScheduled' "$COMPACT_VIEW_FILE" \
    || fail "terminal wash must not restart when success changes to copied"
grep -Fq 'typecheck-whisper-bridge.sh' "$ROOT_DIR/scripts/internal/test-suite.sh" \
    || fail "the Swift/C Whisper bridge type-check must run with the core checks"
grep -Fq 'typecheck-hybrid-engines.sh' "$ROOT_DIR/scripts/internal/test-suite.sh" \
    || fail "hybrid draft/refinement engines must be type-checked outside macOS"
grep -Fq 'typecheck-vad-bridge.sh' "$ROOT_DIR/scripts/internal/test-suite.sh" \
    || fail "Silero VAD bridge must be type-checked outside macOS"
grep -Fq 'typecheck-vad-download.sh' "$ROOT_DIR/scripts/internal/test-suite.sh" \
    || fail "Silero VAD download must be type-checked outside macOS"
grep -Fq 'hallucinationGuardConfiguration: settings.hallucinationGuardConfiguration' "$COORDINATOR_FILE" \
    || fail "result safety must be passed to local final recognition engines"


# GigaAM v3 is a native ONNX backend with four explicit model variants.
GIGA_CATALOG_FILE="$ROOT_DIR/Sources/VoicePanelApp/Models/GigaAM/GigaAMModelCatalog.swift"
GIGA_MODEL_MANAGER_FILE="$ROOT_DIR/Sources/VoicePanelApp/Models/GigaAM/GigaAMModelManager.swift"
GIGA_RUNTIME_FILE="$ROOT_DIR/Sources/VoicePanelApp/Models/GigaAM/GigaAMRuntime.swift"
GIGA_RUNTIME_MANAGER_FILE="$ROOT_DIR/Sources/VoicePanelApp/Models/GigaAM/GigaAMRuntimeManager.swift"
GIGA_ENGINE_FILE="$ROOT_DIR/Sources/VoicePanelApp/Recognition/GigaAMRecognitionEngine.swift"
GIGA_HYBRID_FILE="$ROOT_DIR/Sources/VoicePanelApp/Recognition/AppleDraftGigaAMRecognitionEngine.swift"
CHUNK_HYBRID_FILE="$ROOT_DIR/Sources/VoicePanelApp/Recognition/ChunkDraftRefinementRecognitionEngine.swift"
GIGA_POLICY_FILE="$ROOT_DIR/Sources/VoicePanelCore/GigaAMChunkPolicy.swift"

for required in "$GIGA_CATALOG_FILE" "$GIGA_MODEL_MANAGER_FILE" "$GIGA_RUNTIME_FILE" \
                "$GIGA_RUNTIME_MANAGER_FILE" "$GIGA_ENGINE_FILE" "$GIGA_HYBRID_FILE" \
                "$CHUNK_HYBRID_FILE" "$GIGA_POLICY_FILE"; do
    [[ -f "$required" ]] || fail "missing GigaAM integration file: $required"
done

grep -Fq 'case v3CTC' "$GIGA_CATALOG_FILE" || fail "GigaAM v3 CTC is missing"
grep -Fq 'case v3RNNT' "$GIGA_CATALOG_FILE" || fail "GigaAM v3 RNN-T is missing"
grep -Fq 'case v3E2ECTC' "$GIGA_CATALOG_FILE" || fail "GigaAM v3 E2E CTC is missing"
grep -Fq 'case v3E2ERNNT' "$GIGA_CATALOG_FILE" || fail "GigaAM v3 E2E RNN-T is missing"
grep -Fq 'Plain text · no punctuation' "$GIGA_CATALOG_FILE" \
    || fail "plain GigaAM variants must be clearly labeled as having no punctuation"
grep -Fq 'Punctuation and text normalization' "$GIGA_CATALOG_FILE" \
    || fail "E2E GigaAM variants must be clearly labeled"
grep -Fq 'Insecure.SHA1' "$GIGA_MODEL_MANAGER_FILE" \
    && fail "GigaAM packages must use SHA-256 rather than SHA-1"
grep -Fq 'SHA256()' "$GIGA_MODEL_MANAGER_FILE" \
    || fail "GigaAM package SHA-256 verification is missing"
grep -Fq 'installationTasks' "$GIGA_MODEL_MANAGER_FILE" \
    || fail "GigaAM installation must be single-flight"
grep -Fq 'import sherpa_onnx' "$GIGA_RUNTIME_FILE" \
    || fail "GigaAM runtime must use the native sherpa-onnx bridge"
grep -Fq 'SherpaOnnxOfflineNemoEncDecCtcModelConfig' "$GIGA_RUNTIME_FILE" \
    || fail "GigaAM CTC runtime configuration is missing"
grep -Fq 'SherpaOnnxOfflineTransducerModelConfig' "$GIGA_RUNTIME_FILE" \
    || fail "GigaAM RNN-T runtime configuration is missing"
grep -Fq 'final class AppleDraftRefinementRecognitionEngine' "$GIGA_HYBRID_FILE" \
    || fail "generic Apple Speech live-draft refinement is missing"
grep -Fq 'Apple Draft → GigaAM' "$COORDINATOR_FILE" \
    || fail "Apple Speech live draft plus GigaAM refinement is missing"
grep -Fq 'Apple Draft → Whisper' "$COORDINATOR_FILE" \
    || fail "Apple Speech live draft plus Whisper refinement is missing"
grep -Fq 'case .localGigaAM:' "$COORDINATOR_FILE" \
    || fail "same-family local GigaAM draft plus GigaAM refinement is missing"
grep -Fq 'DraftFinalSegmentAlignment' "$GIGA_HYBRID_FILE" \
    || fail "draft/final output must align to emitted chunk IDs"
grep -Fq 'maximumDuration = min(max(maximumDuration, 3), 20)' "$GIGA_POLICY_FILE" \
    || fail "GigaAM hard chunk limit must remain capped at 20 seconds"
grep -Fq 'preferredDuration + value.boundarySearchDuration' "$GIGA_POLICY_FILE" \
    || fail "GigaAM soft boundary-search window is not applied"
grep -Fq 'case gigaAM' "$SETTINGS_FILE" \
    || fail "GigaAM backend option is missing"
grep -Fq 'return "ru-RU"' "$SETTINGS_FILE" \
    || fail "GigaAM v3 language must remain fixed to Russian"
grep -Fq 'name: "sherpa-onnx"' "$PACKAGE_FILE" \
    || fail "direct sherpa-onnx binary target is missing"
grep -Fq 'name: "onnxruntime"' "$PACKAGE_FILE" \
    || fail "direct ONNX Runtime binary target is missing"
grep -Fq 'releases/download/1.13.2/sherpa-onnx.xcframework.zip' "$PACKAGE_FILE" \
    || fail "sherpa-onnx binary URL must pin release 1.13.2"
grep -Fq 'releases/download/1.13.2/onnxruntime.xcframework.zip' "$PACKAGE_FILE" \
    || fail "ONNX Runtime binary URL must pin release 1.13.2"
if grep -Fq 'artifact-revision=' "$PACKAGE_FILE"; then
    fail "binary artifact URLs must not use ineffective query-string cache revisions"
fi
grep -Fq '62de3c1423a4f20516e8623858ee8c8d306af7ebb2a3737dc0600b1d4ee6aa4b' "$PACKAGE_FILE" \
    || fail "sherpa-onnx 1.13.2 checksum is missing"
grep -Fq '38bc65b3e6af3e6d99bc18a40f80bfb3e56ee1eedfa0d0a60feb1c97a2d06dee' "$PACKAGE_FILE" \
    || fail "ONNX Runtime 1.13.2 checksum is missing"
grep -Fq 'VOICEPANEL_SWIFTPM_CACHE_PATH' "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh" \
    || fail "VoicePanel must isolate its SwiftPM binary artifact cache"
grep -Fq -- '--cache-path "$VOICEPANEL_SWIFTPM_CACHE_PATH"' "$ROOT_DIR/scripts/internal/swift-toolchain-env.sh" \
    || fail "Swift builds must use the isolated VoicePanel cache"
grep -Fq 'import sherpa_onnx' "$ROOT_DIR/Sources/VoicePanelApp/Models/VAD/SileroVADRuntime.swift" \
    || fail "Silero VAD must import the direct binary module"
if grep -Fq 'The sherpa-onnx macOS framework could not be found' "$BUILD_SCRIPT"; then
    fail "sherpa-onnx may be statically linked and must not require a runtime framework"
fi
if grep -Fq 'The ONNX Runtime macOS framework could not be found' "$BUILD_SCRIPT"; then
    fail "ONNX Runtime may be statically linked and must not require a runtime framework"
fi
grep -Fq 'static XCFrameworks' "$BUILD_SCRIPT" \
    || fail "the app packager must document static binary-target handling"
grep -Fq 'GigaAM model' "$ROOT_DIR/Sources/VoicePanelApp/UI/SettingsView.swift" \
    || fail "GigaAM model selection UI is missing"
grep -Fq 'GigaAM engine tuning' "$ROOT_DIR/Sources/VoicePanelApp/UI/SettingsView.swift" \
    || fail "GigaAM engine tuning UI is missing"

SETTINGS_VIEW_FILE="$ROOT_DIR/Sources/VoicePanelApp/UI/SettingsView.swift"
INPUT_METER_FILE="$ROOT_DIR/Sources/VoicePanelApp/UI/InputLevelMeterView.swift"
WAVEFORM_FILE="$ROOT_DIR/Sources/VoicePanelApp/UI/WaveformView.swift"

# Settings use native macOS tabs. The minimum width is part of the contract so
# the five short labels fit without relying on the overflow menu.
grep -Fq 'TabView(selection: $selectedPage)' "$SETTINGS_VIEW_FILE" \
    || fail "native settings TabView is missing"
grep -Fq '.frame(minWidth: 1120, idealWidth: 1180' "$SETTINGS_VIEW_FILE" \
    || fail "settings TabView minimum width contract is missing"
if grep -Fq 'private var settingsNavigationBar' "$SETTINGS_VIEW_FILE"; then
    fail "legacy custom settings navigation must not be restored"
fi
grep -Fq 'enum SettingsPage' "$SETTINGS_VIEW_FILE" \
    || fail "settings page grouping is missing"
grep -Fq 'RecognitionTextEditorSheet' "$SETTINGS_VIEW_FILE" \
    || fail "large context and vocabulary editors are missing"
grep -Fq 'Custom decoding strategy' "$SETTINGS_VIEW_FILE" \
    || fail "Whisper custom decoding must be explicitly opt-in"
grep -Fq 'Restore Original Whisper Behavior' "$SETTINGS_VIEW_FILE" \
    || fail "Whisper original-behavior recovery action is missing"
grep -Fq 'usesCustomDecoding' "$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperRuntime.swift" \
    || fail "Whisper runtime must preserve default sampling unless custom decoding is enabled"
grep -Fq ') ?? .metal' "$SETTINGS_FILE" \
    || fail "Whisper default compute mode must preserve the original Metal path"
grep -Fq 'whisperCustomDecodingEnabled) as? Bool ?? false' "$SETTINGS_FILE" \
    || fail "custom Whisper decoding must remain opt-in"
grep -Fq 'whisperGreedyBestOf) as? Int ?? 5' "$SETTINGS_FILE" \
    || fail "custom Greedy candidate default must not regress to one"
grep -Fq 'voicePreRollDuration) as? Double ?? 0.25' "$SETTINGS_FILE" \
    || fail "original pre-roll default must be preserved"
grep -Fq 'voicePostRollDuration) as? Double ?? 0.15' "$SETTINGS_FILE" \
    || fail "original post-roll default must be preserved"
for page in general performance workflow history advanced; do
    grep -Fq "case $page" "$SETTINGS_VIEW_FILE" \
        || fail "settings navigation page is missing: $page"
done
if grep -Fq 'case recognition' "$SETTINGS_VIEW_FILE" || grep -Fq 'case microphone' "$SETTINGS_VIEW_FILE"; then
    fail "legacy Recognition and Microphone settings tabs must not return"
fi
grep -Fq 'private var generalSection' "$SETTINGS_VIEW_FILE" \
    || fail "unified General settings page is missing"
grep -Fq 'private var performanceSection' "$SETTINGS_VIEW_FILE" \
    || fail "dedicated Performance Testing settings page is missing"
grep -Fq 'Label("Manage Installed Models…", systemImage: "internaldrive")' "$SETTINGS_VIEW_FILE" \
    || fail "General must expose installed-model storage management"
grep -Fq 'engineSelectionControls(showAvailability: false, showCoreML: true)' "$SETTINGS_VIEW_FILE" \
    || fail "General must expose Whisper Core ML encoder management"
grep -Fq 'private var generalModelFileControls' "$SETTINGS_VIEW_FILE" \
    || fail "General must expose selected-model install and load controls"
if grep -Fq 'Button("Advanced Tuning…")' "$SETTINGS_VIEW_FILE"; then
    fail "Current setup must explain the active configuration without shortcut buttons"
fi
grep -Fq 'LabeledContent("Processing")' "$SETTINGS_VIEW_FILE" \
    || fail "Current setup must describe the active profile, environment, and compute path"
grep -Fq 'InputLevelMeterView(' "$SETTINGS_VIEW_FILE" \
    || fail "General must retain the live microphone test"
grep -Fq 'performanceTestWorkspace' "$SETTINGS_VIEW_FILE" \
    || fail "Performance Testing must keep benchmark actions in the fixed workspace"
grep -Fq 'LabeledContent("Model size")' "$SETTINGS_VIEW_FILE" \
    || fail "Performance Testing must show the selected model size"
[[ -f "$VALIDATION_FILE" ]] \
    || fail "Stage 5 validation report types are missing"
grep -Fq 'Picker("Inference passes"' "$SETTINGS_VIEW_FILE" \
    || fail "Performance Testing must support repeated inference passes"
grep -Fq 'Reference transcript for WER/CER' "$SETTINGS_VIEW_FILE" \
    || fail "Performance Testing must expose reference transcript scoring"
grep -Fq '"History · \(modelBenchmark.runs.count)"' "$SETTINGS_VIEW_FILE" \
    || fail "Performance Testing must retain same-sample history"
grep -Fq 'selectPerformanceRun(run)' "$SETTINGS_VIEW_FILE" \
    || fail "Performance Testing history rows must restore their saved test setup"
grep -Fq 'performanceSettings.applyPerformanceConfigurationSnapshot(snapshot)' "$SETTINGS_VIEW_FILE" \
    || fail "Selecting a historical run must immediately restore its complete setup"
grep -Fq 'performanceSetupSnapshot' "$SETTINGS_VIEW_FILE" \
    || fail "Performance Testing runs must retain a reusable configuration snapshot"
[[ -f "$PERFORMANCE_SNAPSHOT_FILE" ]] \
    || fail "Performance Testing configuration snapshot support is missing"
grep -Fq 'func applyPerformanceConfigurationSnapshot' "$PERFORMANCE_SNAPSHOT_FILE" \
    || fail "Performance Testing history must restore a complete setup"
grep -Fq 'let effectiveConfiguration = effectiveRecognitionConfiguration' "$PERFORMANCE_SNAPSHOT_FILE" \
    || fail "Performance Testing snapshots must resolve the selected built-in profile"
grep -Fq 'whisperChunkDuration: tuning.whisperChunkDuration' "$PERFORMANCE_SNAPSHOT_FILE" \
    || fail "Performance Testing snapshots must serialize effective profile tuning"
grep -Fq 'configuration["performanceSetupScope"] = "model-and-pipeline"' "$SETTINGS_VIEW_FILE" \
    || fail "Every performance run must retain one unified model-and-pipeline snapshot"
grep -Fq '.scrollClipDisabled()' "$SETTINGS_VIEW_FILE" \
    || fail "Performance history selection outlines must not be clipped by the scroll view"
grep -Fq 'displayedPerformanceResultLayoutKey' "$SETTINGS_VIEW_FILE" \
    || fail "Performance result height changes must be animated"
grep -Fq 'performancePipelineStageStatus' "$SETTINGS_VIEW_FILE" \
    || fail "Pipeline Validation must explain work that continues after visualization"
grep -Fq 'performance.pipeline-legend' "$SETTINGS_VIEW_FILE" \
    || fail "The pipeline legend must remain directly below the graph"
grep -Fq 'Button("Export JSON…")' "$SETTINGS_VIEW_FILE" \
    || fail "Performance Testing must export validation reports"
grep -Fq 'Save as Active Setup' "$SETTINGS_VIEW_FILE" \
    || fail "Performance Testing must keep test configuration isolated until explicitly saved"
grep -Fq 'performanceTestWorkspace' "$SETTINGS_VIEW_FILE" \
    || fail "Performance Testing must keep sample actions and the latest result outside the scrolling form"
grep -Fq 'DisclosureGroup(' "$SETTINGS_VIEW_FILE" \
    || fail "Performance Testing secondary report controls must remain collapsible"
if grep -Fq 'Label("Unsaved test changes"' "$SETTINGS_VIEW_FILE"; then
    fail "Performance Testing must not reserve a permanent row for unsaved test state"
fi
grep -Fq 'Text("Benchmark Target")' "$SETTINGS_VIEW_FILE" \
    || fail "Model Benchmark must have a dedicated model-only configuration section"
grep -Fq 'Text("Pipeline Setup")' "$SETTINGS_VIEW_FILE" \
    || fail "Pipeline Validation must have a dedicated pipeline-only configuration section"
grep -Fq 'performance.configuration-heading' "$SETTINGS_VIEW_FILE" \
    || fail "Performance Testing must expose a stable visible configuration-column anchor"
python3 - "$SETTINGS_VIEW_FILE" <<'PY_SWIFTUI_SECTION_CONTRACT'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
validation_start = source.index("private var pipelineValidationConfigurationSection")
validation_end = source.index("private var performancePipelineStageStatus", validation_start)
validation_section = source[validation_start:validation_end]
if '} header: {' not in validation_section or 'Text("Pipeline Setup")' not in validation_section:
    raise SystemExit(
        "Pipeline Setup must be attached to the enclosing SwiftUI Section header."
    )
advanced_start = source.index("private var performanceAdvancedPipelineControls")
advanced_end = source.index("private var performanceScoringAndReportSection", advanced_start)
advanced_controls = source[advanced_start:advanced_end]
if '} header: {' in advanced_controls:
    raise SystemExit(
        "Advanced pipeline controls must not pass a Section-style header closure to SettingsDisclosureGroup."
    )
PY_SWIFTUI_SECTION_CONTRACT
grep -Fq 'Button("Change Model")' "$SETTINGS_VIEW_FILE" \
    || fail "Pipeline Validation must link back to Model Benchmark instead of duplicating model controls"
if grep -Fq 'Section("Current test target")' "$SETTINGS_VIEW_FILE"; then
    fail "Performance Testing must not duplicate the selected target in a second summary section"
fi
if grep -Fq 'Section("Validation setup")' "$SETTINGS_VIEW_FILE"; then
    fail "Performance Testing report metadata must not occupy a permanent primary section"
fi
grep -Fq 'recordNewSample' "$MODEL_BENCHMARK_FILE" \
    || fail "performance sample recording must be independent from model loading and inference"
grep -Fq 'playRecordedSample' "$MODEL_BENCHMARK_FILE" \
    || fail "the reusable performance sample must support playback before comparisons"
grep -Fq 'stopSamplePlayback' "$MODEL_BENCHMARK_FILE" \
    || fail "performance sample playback must expose a Stop state"
grep -Fq 'modelBenchmark.isPlayingSample ? "Stop" : "Play"' "$SETTINGS_VIEW_FILE" \
    || fail "Performance Testing must switch Play to Stop during sample playback"
grep -Fq 'AppSettings.makeIsolatedPerformanceCopy' "$SETTINGS_VIEW_FILE" \
    || fail "Performance Testing must use an isolated settings copy"
grep -Fq 'case pipelineValidation' "$MODEL_BENCHMARK_FILE" \
    || fail "Performance Testing must include end-to-end pipeline validation"
grep -Fq 'RecognitionPipelineValidator.process' "$MODEL_BENCHMARK_FILE" \
    || fail "Pipeline Validation must execute the production chunking pipeline"
grep -Fq 'nonisolated private static func tracePipelineVisualization' "$MODEL_BENCHMARK_FILE" \
    || fail "pipeline visualization tracing must remain callable from detached work"
grep -Fq 'runRepeatedInference' "$MODEL_BENCHMARK_FILE" \
    || fail "benchmark timing must support repeatable inference passes"
grep -Fq 'RecognitionTranscriptScorer' "$VALIDATION_FILE" \
    || fail "validation reports must support WER/CER scoring"
grep -Fq 'RecognitionValidationReport' "$VALIDATION_FILE" \
    || fail "machine-readable validation report schema is missing"
grep -Fq 'if settings.recognitionBackend == .whisper {' "$SETTINGS_VIEW_FILE" \
    || fail "Whisper fine-tuning must be gated to the Whisper engine"
grep -Fq 'private var appleSpeechAdvancedSection' "$SETTINGS_VIEW_FILE" \
    || fail "Apple Speech must have a dedicated reduced Advanced section"
grep -Fq 'beginCustomizingMicrophoneEnvironment' "$SETTINGS_FILE" \
    || fail "built-in microphone environments need a safe Custom transition"

PROFILE_FILE="$ROOT_DIR/Sources/VoicePanelCore/RecognitionProfiles.swift"
[[ -f "$PROFILE_FILE" ]] || fail "recognition profile definitions are missing"
grep -Fq 'case classic' "$PROFILE_FILE" || fail "Classic recognition profile is missing"
grep -Fq 'case recommended' "$PROFILE_FILE" || fail "Recommended recognition profile is missing"
grep -Fq 'case quality' "$PROFILE_FILE" || fail "Quality recognition profile is missing"
grep -Fq 'case lowLatency' "$PROFILE_FILE" || fail "Low Latency recognition profile is missing"
grep -Fq 'RecognitionConfigurationResolver.resolve' "$SETTINGS_FILE" \
    || fail "AppSettings must resolve one effective recognition configuration"
grep -Fq 'effectiveVoiceActivityDetectionMode' "$COORDINATOR_FILE" \
    || fail "audio capture must use the effective recognition profile"
grep -Fq 'Picker("Profile"' "$SETTINGS_VIEW_FILE" \
    || fail "recognition profile picker is missing"

grep -Fq 'migrateRecognitionProfilesIfNeeded' "$SETTINGS_FILE" \
    || fail "recognition profile preference migration is missing"
grep -Fq 'recognitionProfilesMigratedV1' "$SETTINGS_FILE" \
    || fail "recognition profile migration must be versioned"
grep -Fq 'markRecognitionProfileCustom' "$SETTINGS_FILE" \
    || fail "manual recognition tuning must switch the profile to Custom"
grep -Fq 'markMicrophoneEnvironmentCustom' "$SETTINGS_FILE" \
    || fail "manual microphone tuning must switch the environment to Custom"
grep -Fq 'customRecognitionBaseProfileV1' "$SETTINGS_FILE" \
    || fail "Custom recognition tuning must persist its base profile"
grep -Fq 'recognitionOverrideFields' "$SETTINGS_FILE" \
    || fail "Advanced must expose explicit recognition override provenance"
grep -Fq 'resetRecognitionOverridesToBase' "$SETTINGS_FILE" \
    || fail "Custom recognition overrides need a reset-to-base action"
grep -Fq 'savedRecognitionPresetsV1' "$SETTINGS_FILE" \
    || fail "named recognition presets must use a versioned preference key"
grep -Fq 'Section("Speech Detection")' "$SETTINGS_VIEW_FILE" \
    || fail "Advanced must contain the Speech Detection category"
grep -Fq 'Section("Segmentation")' "$SETTINGS_VIEW_FILE" \
    || fail "Advanced must contain the Segmentation category"
grep -Fq 'Section("Context & Vocabulary")' "$SETTINGS_VIEW_FILE" \
    || fail "Advanced must contain the Context & Vocabulary category"
grep -Fq 'Section("Whisper Decoder")' "$SETTINGS_VIEW_FILE" \
    || fail "Advanced must contain the Whisper Decoder category"
grep -Fq 'Section("Safety & Diagnostics")' "$SETTINGS_VIEW_FILE" \
    || fail "Advanced must contain the Safety & Diagnostics category"
grep -Fq 'LabeledContent("Based on")' "$SETTINGS_VIEW_FILE" \
    || fail "Custom recognition profiles must show their base profile"
grep -Fq 'Save as Preset…' "$SETTINGS_VIEW_FILE" \
    || fail "Advanced must allow named Custom recognition presets"

# Voice detection controls must explain their visual meter. Tuning disclosure
# headers must expose a full-width button target rather than a chevron-only hit area.
grep -Fq 'SettingsDisclosureGroup' "$SETTINGS_VIEW_FILE" \
    || fail "settings tuning groups are missing"
grep -Fq '.frame(maxWidth: .infinity, alignment: .leading)' "$SETTINGS_VIEW_FILE" \
    || fail "settings disclosure headers must span the full row"
grep -Fq '.contentShape(Rectangle())' "$SETTINGS_VIEW_FILE" \
    || fail "settings disclosure headers must use the full row as their hit target"
grep -Fq '.frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)' "$SETTINGS_VIEW_FILE" \
    || fail "settings disclosure headers must keep the complete row clickable"
grep -Fq '.padding(.top, 8)' "$SETTINGS_VIEW_FILE" \
    || fail "expanded settings disclosures need content spacing"
grep -Fq 'Noise floor' "$INPUT_METER_FILE" \
    || fail "input meter must label the noise-floor marker"
grep -Fq 'Speech threshold' "$INPUT_METER_FILE" \
    || fail "input meter must label the speech-threshold marker"
grep -Fq 'let isTesting: Bool' "$INPUT_METER_FILE" \
    || fail "live input fill must be hidden until Test Input is active"
if grep -Fq 'speechRange(' "$INPUT_METER_FILE"; then
    fail "the unexplained blue speech-range overlay must not return"
fi
if grep -Fq 'slider.horizontal.3' "$INPUT_METER_FILE"; then
    fail "the non-interactive sensitivity settings icon must not return"
fi

# Pending feedback is a single duration-driven state for both live-draft and
# no-draft recognition. Users can choose any of the three visual styles.
grep -Fq 'PendingFeedbackStyle' "$SETTINGS_FILE" \
    || fail "pending-feedback style preference is missing"
for style in blurredWords gradientBars pulse; do
    grep -Fq "case $style" "$SETTINGS_FILE" \
        || fail "pending-feedback style is missing: $style"
done
grep -Fq 'PendingFeedbackVisual' "$SLIDING_VIEW_FILE" \
    || fail "shared pending-feedback view is missing"
grep -Fq 'GradientBarShimmer' "$SLIDING_VIEW_FILE" \
    || fail "gradient feedback must use a single shimmering streak"
grep -Fq 'highlightTravel * phase' "$SLIDING_VIEW_FILE" \
    || fail "gradient feedback must animate its highlight across the streak"
grep -Fq '.animation(.smooth(duration: 0.22), value: containerWidth)' "$SLIDING_VIEW_FILE" \
    || fail "gradient feedback width must grow continuously"
grep -Fq 'feedbackSlotWidth: feedbackSlotWidth' "$SLIDING_VIEW_FILE" \
    || fail "transcript feedback must reserve stable indicator space"
grep -Fq 'let feedbackWidth = min(feedbackSlotWidth, width * 0.4)' "$SLIDING_VIEW_FILE" \
    || fail "transcript feedback width must stay stable while speech updates"
grep -Fq 'min(0, bounds.width - lineWidth)' "$TRANSCRIPT_VIEWPORT_FILE" \
    || fail "a growing feedback bar must progressively move overflowing text left"
grep -Fq 'GradientBarShimmer(isActive: isActive)' "$SLIDING_VIEW_FILE" \
    || fail "gradient feedback animation must stay independent from its changing item count"
grep -Fq 'pendingItemExtent: pendingFeedbackItemExtent' "$COMPACT_VIEW_FILE" \
    || fail "gradient feedback must receive continuous pending-speech extent"
grep -Fq 'Color.primary.opacity(0.035)' "$SLIDING_VIEW_FILE" \
    || fail "gradient feedback backing must remain translucent and panel-adaptive"
grep -Fq 'displayedPendingFeedbackItemExtent' "$COMPACT_VIEW_FILE" \
    || fail "gradient feedback extent must remain frozen for its minimum visible duration"
grep -Fq 'PendingFeedbackTimingPolicy.appearanceDelay' "$COMPACT_VIEW_FILE" \
    || fail "pending feedback must wait before appearing"
grep -Fq 'PendingFeedbackTimingPolicy.remainingVisibleDuration' "$COMPACT_VIEW_FILE" \
    || fail "pending feedback must honor its minimum visible duration"
grep -Fq 'frozenPendingFeedbackExtent' "$APP_STATE_FILE" \
    || fail "queued recognition chunks must preserve their fractional feedback extent"
if grep -Fq '.background(.quaternary.opacity(0.35)' "$SLIDING_VIEW_FILE"; then
    fail "pending-feedback settings preview must not add a gray backing panel"
fi
grep -Fq 'pendingFeedbackStyle: state.phase.isRecordingRelated' "$COMPACT_VIEW_FILE" \
    || fail "compact transcript must reserve indicator space throughout recording"
grep -Fq 'isRecording: phase.isRecordingRelated' "$APP_STATE_FILE" \
    || fail "pending feedback must survive stopping and finalization"
grep -Fq 'state.pendingFeedbackPresentation(' "$COMPACT_VIEW_FILE" \
    || fail "pending feedback must use the duration-driven presentation policy"
grep -Fq 'voiceActivityState: voiceActivityState' "$APP_STATE_FILE" \
    || fail "pending feedback must respond to VAD state"
grep -Fq 'activeVoicedDuration: activePendingFeedbackVoicedDuration' "$APP_STATE_FILE" \
    || fail "pending feedback must grow from voiced duration"
grep -Fq 'Picker("Pending feedback", selection: $settings.pendingFeedbackStyle)' "$SETTINGS_VIEW_FILE" \
    || fail "Panel settings must expose the pending-feedback style"
grep -Fq 'PendingFeedbackPreview' "$SETTINGS_VIEW_FILE" \
    || fail "Panel settings must preview the selected feedback style"
grep -Fq 'activePendingFeedbackVoicedDuration = 0' "$APP_STATE_FILE" \
    || fail "recognition updates must acknowledge the consumed live pending tail"
grep -Fq 'animatesActiveTail' "$ROOT_DIR/Sources/VoicePanelCore/PendingFeedbackPolicy.swift" \
    || fail "pending feedback must remain animated while recognition work is unresolved"
grep -Fq 'PanelPositionPreset' "$SETTINGS_FILE" \
    || fail "panel position preference is missing"
grep -Fq 'case .aboveDock:' "$PANEL_CONTROLLER_FILE" \
    || fail "the panel must support an above-Dock position"
grep -Fq 'panel.level = settings.panelAlwaysOnTop ? .floating : .normal' "$PANEL_CONTROLLER_FILE" \
    || fail "the compact panel must default to a configurable normal window level"
grep -Fq 'Toggle("Keep panel above other windows", isOn: $settings.panelAlwaysOnTop)' "$SETTINGS_VIEW_FILE" \
    || fail "Panel settings must expose the always-on-top preference"
[[ -f "$MODEL_BENCHMARK_FILE" ]] \
    || fail "local model performance test is missing"
grep -Fq 'Record Sample · 30 s max' "$SETTINGS_VIEW_FILE" \
    || fail "Recognition settings must expose the 30-second local model performance test"
grep -Fq 'Button("Stop Recording")' "$SETTINGS_VIEW_FILE" \
    || fail "the performance sample must support manual recording stop"
grep -Fq 'case qwen3ASR17BInt8' "$ROOT_DIR/Sources/VoicePanelApp/Models/LocalONNX/LocalONNXModelCatalog.swift" \
    || fail "the compatible Qwen3-ASR 1.7B option is missing"
grep -Fq 'case huggingFaceContentAddressed' "$ROOT_DIR/Sources/VoicePanelApp/Models/LocalONNX/LocalONNXModelCatalog.swift" \
    || fail "community Hugging Face model files must use content-addressed verification"
grep -Fq 'let maximumSampleDuration: TimeInterval = 30' "$MODEL_BENCHMARK_FILE" \
    || fail "the model performance sample must stop automatically at 30 seconds"
grep -Fq 'ModelBenchmarkProgress.recordingFraction' "$MODEL_BENCHMARK_FILE" \
    || fail "benchmark recording progress must use linear elapsed-time progress"
grep -Fq 'showsDeterminateProgress' "$MODEL_BENCHMARK_FILE" \
    || fail "benchmark loading and inference must not reuse recording progress"
if grep -Fq '0.10 + Double(step)' "$MODEL_BENCHMARK_FILE"; then
    fail "benchmark recording progress must not jump forward at startup"
fi
grep -Fq 'Picker("Qwen3-ASR model"' "$SETTINGS_VIEW_FILE" \
    || fail "Recognition settings must expose Qwen model selection"
grep -Fq 'runtime.transcribe' "$MODEL_BENCHMARK_FILE" \
    || fail "the model performance test must execute real local inference"
grep -Fq 'runCurrentSample' "$MODEL_BENCHMARK_FILE" \
    || fail "the same in-memory benchmark sample must be reusable across models"
grep -Fq 'PendingFeedbackTimingPolicy.appearanceDelay' "$COMPACT_VIEW_FILE" \
    || fail "pending feedback must suppress sub-300ms flashes"
grep -Fq 'usesAppleSpeechForLiveDraft ? .pulse' "$SETTINGS_FILE" \
    || fail "Apple Speech pending feedback must be constrained to Pulse"
grep -Fq 'Manage Installed Models…' "$SETTINGS_VIEW_FILE" \
    || fail "Recognition settings must expose installed-model management"
INSTALLED_MODELS_VIEW_FILE="$ROOT_DIR/Sources/VoicePanelApp/UI/InstalledModelsView.swift"
grep -Fq 'settings.effectiveWhisperDraftSource == .localWhisper' "$INSTALLED_MODELS_VIEW_FILE" \
    || fail "an inactive Whisper draft model must not be marked as selected"
grep -Fq 'settings.effectiveGigaAMDraftSource == .localGigaAM' "$INSTALLED_MODELS_VIEW_FILE" \
    || fail "an inactive GigaAM draft model must not be marked as selected"

HISTORY_KEY_FILE="$ROOT_DIR/Sources/VoicePanelApp/History/HistoryEncryptionKeyStore.swift"
HISTORY_AUTH_FILE="$ROOT_DIR/Sources/VoicePanelApp/History/HistoryAccessAuthenticator.swift"
HISTORY_MODEL_FILE="$ROOT_DIR/Sources/VoicePanelApp/History/HistoryModel.swift"
grep -Fq 'AESGCMCompat.seal' "$ROOT_DIR/Sources/VoicePanelCore/TranscriptHistory.swift" \
    || fail "transcript history must be encrypted at rest"
grep -Fq 'kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly' "$HISTORY_KEY_FILE" \
    || fail "the history encryption key must be stored in the device-only Keychain"
grep -Fq '.deviceOwnerAuthentication' "$HISTORY_AUTH_FILE" \
    || fail "opening transcript history must require system owner authentication"
grep -Fq 'try await authenticator.authenticate()' "$HISTORY_MODEL_FILE" \
    || fail "History Unlock must retry system authentication"
grep -Fq 'Self.openRepository(' "$HISTORY_MODEL_FILE" \
    || fail "History Unlock must retry the Keychain-backed repository after authentication"
grep -Fq 'canStartNewEncryptedHistory = true' "$HISTORY_MODEL_FILE" \
    || fail "destructive history recovery must be gated behind an authenticated open failure"
if grep -Fq 'guard repository != nil else' "$HISTORY_MODEL_FILE"; then
    fail "History Unlock must not stop before retrying Keychain access"
fi
HISTORY_AUTH_LINE="$(grep -n 'try await authenticator.authenticate()' "$HISTORY_MODEL_FILE" | head -n 1 | cut -d: -f1)"
HISTORY_REOPEN_LINE="$(grep -n 'repository = try Self.openRepository(' "$HISTORY_MODEL_FILE" | head -n 1 | cut -d: -f1)"
[[ -n "$HISTORY_AUTH_LINE" && -n "$HISTORY_REOPEN_LINE" && "$HISTORY_AUTH_LINE" -lt "$HISTORY_REOPEN_LINE" ]] \
    || fail "History must authenticate before retrying the encrypted repository"
grep -Fq 'static func rotated()' "$HISTORY_KEY_FILE" \
    || fail "inaccessible history keys must support rotating to a new Keychain account"
grep -Fq 'func resetEncryptedHistory()' "$HISTORY_MODEL_FILE" \
    || fail "encrypted history must support explicit destructive recovery"
grep -Fq 'recoveryArchiveStore.archive(' "$HISTORY_MODEL_FILE" \
    || fail "starting over must preserve inaccessible history for later recovery"
grep -Fq 'history.key-id' "$HISTORY_MODEL_FILE" \
    || fail "the active history file must persist its non-secret Keychain identifier"
grep -Fq 'TranscriptHistoryMergePolicy.merge' "$HISTORY_MODEL_FILE" \
    || fail "recovered transcripts must merge with the current encrypted history"
grep -Fq 'case none' "$SETTINGS_FILE" \
    || fail "history storage must support a no-storage mode"
grep -Fq ') ?? .sevenDays' "$SETTINGS_FILE" \
    || fail "encrypted history retention must default to seven days"
grep -Fq 'WhisperDraftSource' "$SETTINGS_FILE" \
    || fail "independent Whisper draft-source selection is missing"
grep -Fq 'GigaAMDraftSource' "$SETTINGS_FILE" \
    || fail "independent GigaAM draft-source selection is missing"
grep -Fq 'whisperDraftModelID' "$SETTINGS_FILE" \
    || fail "Whisper local draft-model selection is missing"
grep -Fq 'gigaAMDraftModelID' "$SETTINGS_FILE" \
    || fail "GigaAM local draft-model selection is missing"
grep -Fq 'Section("Live draft")' "$SETTINGS_VIEW_FILE" \
    || fail "General must expose live-draft configuration"
grep -Fq 'liveDraftEnabledForCurrentProfile' "$SETTINGS_FILE" \
    || fail "live draft enablement must follow the selected recognition profile"
grep -Fq 'return defaults.object(forKey: key) as? Bool ?? true' "$SETTINGS_FILE" \
    || fail "Live Draft must default to enabled for every recognition profile"
grep -Fq 'whisperDraftSource == .none ? .appleSpeech : whisperDraftSource' "$SETTINGS_FILE" \
    || fail "legacy Whisper no-draft state must default to Apple Speech under an enabled profile"
grep -Fq 'gigaAMDraftSource == .none ? .appleSpeech : gigaAMDraftSource' "$SETTINGS_FILE" \
    || fail "legacy GigaAM no-draft state must default to Apple Speech under an enabled profile"
grep -Fq 'effectiveWhisperDraftSource' "$COORDINATOR_FILE" \
    || fail "Whisper must use the profile-scoped effective draft source"
grep -Fq 'effectiveGigaAMDraftSource' "$COORDINATOR_FILE" \
    || fail "GigaAM must use the profile-scoped effective draft source"
grep -Fq 'effectiveLocalONNXDraftSource' "$COORDINATOR_FILE" \
    || fail "local ONNX engines must use the profile-scoped effective draft source"
grep -Fq 'Section("Live recognition feedback")' "$SETTINGS_VIEW_FILE" \
    || fail "Panel & Feedback must summarize live draft and pending feedback"
PROFILE_DEFINITION_FILE="$ROOT_DIR/Sources/VoicePanelCore/RecognitionProfiles.swift"
if grep -Eq 'WhisperModelID|GigaAMModelID|LocalONNXModelID|DraftSource' "$PROFILE_DEFINITION_FILE"; then
    fail "recognition profiles must tune the pipeline without selecting models or draft engines"
fi
grep -Fq 'case localWhisper' "$SETTINGS_FILE" \
    || fail "Whisper must support a same-family local draft source"
grep -Fq 'case localGigaAM' "$SETTINGS_FILE" \
    || fail "GigaAM must support a same-family local draft source"
grep -Fq 'case .localWhisper:' "$COORDINATOR_FILE" \
    || fail "Whisper local draft engine wiring is missing"
grep -Fq 'case .localGigaAM:' "$COORDINATOR_FILE" \
    || fail "GigaAM local draft engine wiring is missing"
if grep -Fq 'Whisper Draft → GigaAM' "$COORDINATOR_FILE" \
    || grep -Fq 'GigaAM Draft → Whisper' "$COORDINATOR_FILE"; then
    fail "draft models must stay within the selected final model family"
fi
grep -Fq 'case largeV3TurboQ5' "$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperModelCatalog.swift" \
    || fail "the complete verified Whisper model catalog is missing"
grep -Fq 'case smallEnglishDiarization' "$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperModelCatalog.swift" \
    || fail "Whisper diarization model variant is missing"
grep -Fq 'candidate.sizeMiB < finalModel.sizeMiB' "$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperModelCatalog.swift" \
    || fail "local Whisper drafts must be smaller than the final model"
grep -Fq 'candidate.relativeSpeed > finalModel.relativeSpeed' "$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperModelCatalog.swift" \
    || fail "local Whisper drafts must be faster than the final model"
grep -Fq 'showPendingWordShimmerV2' "$SETTINGS_FILE" \
    || fail "the legacy shimmer key must remain for preference migration"
grep -Fq 'pendingFeedbackStyleV1' "$SETTINGS_FILE" \
    || fail "pending-feedback style must use a versioned preference key"

# Final success is driven only by the engine-level completion callback after
# every queued chunk has finished. A session-final text callback may flush the
# coalesced UI buffer, but it must not complete the recognition session itself.
grep -Fq 'if update.segment.kind == .sessionFinal {' "$COORDINATOR_FILE" \
    || fail "session-final transcript updates must flush without UI delay"
grep -Fq 'flushRecognitionUpdates()' "$COORDINATOR_FILE" \
    || fail "session-final transcript updates must publish their coalesced text"
grep -Fq 'engine.onFinished' "$COORDINATOR_FILE" \
    || fail "recognition completion must wait for the engine queue-finished callback"
grep -Fq 'state.finishRecognitionEngine()' "$COORDINATOR_FILE" \
    || fail "engine completion must reconcile stale pending UI bookkeeping"
grep -Fq 'callbackCondition.wait()' "$ROOT_DIR/Sources/VoicePanelApp/Audio/AudioCaptureService.swift" \
    || fail "Stop must drain in-flight audio callbacks before closing the recognition queue"
grep -Fq 'suspendAudioEnginePreservingPipeline()' "$ROOT_DIR/Sources/VoicePanelApp/Audio/AudioCaptureService.swift" \
    || fail "input-device handoff must drain callbacks without resetting captured audio"
grep -Fq 'chunkPipeline.inputChanged()' "$ROOT_DIR/Sources/VoicePanelApp/Audio/AudioCaptureService.swift" \
    || fail "input-device handoff must flush the current recognition tail"
grep -Fq 'AudioInputDeviceMonitor' "$ROOT_DIR/Sources/VoicePanelApp/Audio/AudioInputDeviceManager.swift" \
    || fail "CoreAudio input-device changes must be monitored"
grep -Fq 'kAudioHardwarePropertyDefaultInputDevice' "$ROOT_DIR/Sources/VoicePanelApp/Audio/AudioInputDeviceManager.swift" \
    || fail "system default input changes must be observed"
grep -Fq 'Selected audio input disappeared' "$COORDINATOR_FILE" \
    || fail "a removed selected microphone must fall back without ending recognition"
grep -Fq 'Transcript recovery checkpoint saved' "$COORDINATOR_FILE" \
    || fail "device interruptions must checkpoint partial transcripts even while history is locked"
grep -Fq 'repositoryForWrite()' "$HISTORY_MODEL_FILE" \
    || fail "locked history writes must recover a temporarily unavailable repository"
grep -Fq 'guard history.upsert(record) else' "$COORDINATOR_FILE" \
    || fail "checkpoint bookkeeping must advance only after encrypted history confirms the write"
grep -Fq 'retryDelays: [Duration]' "$COORDINATOR_FILE" \
    || fail "temporary Core Audio topology failures must be retried"
grep -Fq 'private let inputDeviceMonitor = AudioInputDeviceMonitor()' "$ROOT_DIR/Sources/VoicePanelApp/Models/ModelBenchmarkRunner.swift" \
    || fail "benchmark sample capture must recover from input-device topology changes"
grep -Fq 'Recognition did not finish all queued audio in time' "$COORDINATOR_FILE" \
    || fail "finalization timeout must fail rather than copy a partial result as success"
grep -Fq 'A chunk failed; finishing the remaining recognition queue' "$COORDINATOR_FILE" \
    || fail "a failed final chunk must not cancel the remaining queued chunks"

# The transcript and waveform rows have stable heights, and completion uses a
# full-panel radial wash instead of a small corner-only indicator.
grep -Fq '.frame(height: transcriptRowHeight)' "$COMPACT_VIEW_FILE" \
    || fail "compact transcript row must keep a stable height"
grep -Fq 'RadialGradient(' "$COMPACT_VIEW_FILE" \
    || fail "full-panel completion wash is missing"
grep -Fq 'resultButtonLabelHeight' "$COMPACT_VIEW_FILE" \
    || fail "result action buttons must share an explicit height"
grep -Fq 'let centerY = size.height / 2' "$WAVEFORM_FILE" \
    || fail "waveform must retain a stable center line"

# Recording completion must use captured audio duration, flush the last chunk,
# and wait for every per-chunk outcome before presenting success.
grep -Fq 'RecordingStopPolicy.action' "$COORDINATOR_FILE" \
    || fail "recording duration policy is missing"
grep -Fq 'forceChunkIfDurationAtLeast: minimumAcceptedRecordingDuration' "$COORDINATOR_FILE" \
    || fail "the final unclosed audio chunk must be forced on Stop"
grep -Fq 'RecognitionStopHandoff.perform(' "$COORDINATOR_FILE" \
    || fail "final chunks and engine finish must use the tested ordering contract"
FINALIZING_LINE="$(grep -n 'state.phase = .finalizing' "$COORDINATOR_FILE" | head -n 1 | cut -d: -f1)"
ENGINE_FINISH_LINE="$(grep -n '^[[:space:]]*engine.finish()' "$COORDINATOR_FILE" | head -n 1 | cut -d: -f1)"
[[ -n "$FINALIZING_LINE" && -n "$ENGINE_FINISH_LINE" && "$FINALIZING_LINE" -lt "$ENGINE_FINISH_LINE" ]] \
    || fail "finalizing state must be visible before an engine can finish synchronously"
grep -Fq 'onChunkOutcome' "$COORDINATOR_FILE" \
    || fail "per-chunk completion tracking is missing"
grep -Fq 'minimumChunkDeliveryDuration:' "$COORDINATOR_FILE" \
    || fail "initial chunks must be deferred until the minimum recording duration"
grep -Fq 'configureStatusItem()' "$ROOT_DIR/Sources/VoicePanelApp/App/AppDelegate.swift" \
    || fail "the status item must be created during application startup"
grep -Fq 'button.image = statusSymbolImage(named: "waveform")' "$ROOT_DIR/Sources/VoicePanelApp/App/AppDelegate.swift" \
    || fail "the tray icon must be assigned before model preparation"
grep -Fq 'showTranscriptFromCompactPanel()' "$ROOT_DIR/Sources/VoicePanelApp/App/AppDelegate.swift" \
    || fail "opening a transcript from the panel must use the window handoff path"
grep -Fq 'compactPanel?.hide()' "$ROOT_DIR/Sources/VoicePanelApp/App/AppDelegate.swift" \
    || fail "the compact panel must hide when it hands off to the transcript window"
grep -Fq 'fullTranscriptReplacesCompactPanel && state.phase.isRecordingRelated' \
    "$ROOT_DIR/Sources/VoicePanelApp/App/AppDelegate.swift" \
    || fail "closing a live transcript must restore a compact panel it replaced"

STATUS_CONFIG_LINE="$(grep -n '^[[:space:]]*configureStatusItem()' "$ROOT_DIR/Sources/VoicePanelApp/App/AppDelegate.swift" | head -n 1 | cut -d: -f1)"
RUNTIME_INIT_LINE="$(grep -n 'whisperRuntime = WhisperRuntimeManager' "$ROOT_DIR/Sources/VoicePanelApp/App/AppDelegate.swift" | head -n 1 | cut -d: -f1)"
[[ -n "$STATUS_CONFIG_LINE" && -n "$RUNTIME_INIT_LINE" && "$STATUS_CONFIG_LINE" -lt "$RUNTIME_INIT_LINE" ]] \
    || fail "the tray icon must be configured before model runtime initialization"

# System-owned permission/authentication sheets may deactivate VoicePanel, but
# the initiating window must remain visible and return to front. File choosers
# and alerts must use the same centralized presentation path so accessory-app
# windows cannot be left behind another application.
SYSTEM_PROMPT_FILE="$ROOT_DIR/Sources/VoicePanelApp/UI/SystemPromptFocusCoordinator.swift"
WINDOW_FOCUS_FILE="$ROOT_DIR/Sources/VoicePanelApp/UI/WindowFocusCoordinator.swift"
HISTORY_WINDOW_FILE="$ROOT_DIR/Sources/VoicePanelApp/History/HistoryWindowController.swift"
FULL_TRANSCRIPT_WINDOW_FILE="$ROOT_DIR/Sources/VoicePanelApp/UI/FullTranscriptWindowController.swift"
for required in "$SYSTEM_PROMPT_FILE" "$WINDOW_FOCUS_FILE" "$HISTORY_WINDOW_FILE" "$FULL_TRANSCRIPT_WINDOW_FILE"; do
    [[ -f "$required" ]] || fail "missing window-focus coordination file: $required"
done
grep -Fq 'SystemPromptFocusCoordinator.willBegin()' "$AUDIO_CAPTURE_FILE" \
    || fail "microphone permission must announce its system prompt"
grep -Fq 'SystemPromptFocusCoordinator.willBegin()' "$HISTORY_AUTH_FILE" \
    || fail "history authentication must announce its system prompt"
grep -Fq 'DispatchQueue.main.sync(execute: notify)' "$SYSTEM_PROMPT_FILE" \
    || fail "system-prompt notifications must reach the main thread before the system dialog can deactivate the app"
grep -Fq 'WindowFocusCoordinator.shared.start()' "$APP_DELEGATE_FILE" \
    || fail "the centralized window-focus coordinator must start during application launch"
for controller in "$SETTINGS_CONTROLLER_FILE" "$HISTORY_WINDOW_FILE" "$FULL_TRANSCRIPT_WINDOW_FILE"; do
    grep -Fq 'WindowFocusCoordinator.shared.register(window)' "$controller" \
        || fail "every regular app window must register with the centralized focus coordinator: $controller"
    grep -Fq 'WindowFocusCoordinator.shared.show(window)' "$controller" \
        || fail "every regular app window must use the centralized frontmost presentation path: $controller"
done
grep -Fq 'schedulePromptRestoration' "$WINDOW_FOCUS_FILE" \
    || fail "system-prompt focus restoration must retry across the activation transition"
grep -Fq 'DispatchQueue.main.async { [weak panel] in' "$WINDOW_FOCUS_FILE" \
    || fail "standalone panel reassertion must use an inline main-actor closure under strict concurrency"
if grep -Fq 'let reassert =' "$WINDOW_FOCUS_FILE"; then
    fail "standalone panel reassertion must not pass a stored non-Sendable closure to DispatchQueue"
fi
grep -Fq 'panel.beginSheetModal(for: owner)' "$WINDOW_FOCUS_FILE" \
    || fail "file panels must attach to the active VoicePanel window when one is available"
grep -Fq 'WindowFocusCoordinator.shared.present(panel)' "$APP_DELEGATE_FILE" \
    || fail "audio file import must use centralized frontmost panel presentation"
grep -Fq 'WindowFocusCoordinator.shared.present(panel)' "$SETTINGS_VIEW_FILE" \
    || fail "benchmark report export must use centralized frontmost panel presentation"
grep -Fq 'testAudioFileChooserAutoDismissesAndRestoresSettings' \
    "$ROOT_DIR/UITests/VoicePanelUITests/VoicePanelUITests.swift" \
    || fail "XCUI regression coverage must verify that the audio file chooser cannot block the suite and restores Settings"
grep -Fq 'ui-test.open-audio-panel' "$SETTINGS_VIEW_FILE" \
    || fail "the file-chooser XCUI scenario must be triggered after the app reaches an idle Settings state"
grep -Fq '.voicePanelSystemPromptWillBegin' "$PANEL_CONTROLLER_FILE" \
    || fail "the compact panel must observe system-owned permission prompts"
grep -Fq 'panel.level = .floating' "$PANEL_CONTROLLER_FILE" \
    || fail "the compact panel must stay above application windows while a system prompt is visible"

# History uses a single native empty state instead of rendering two empty split
# columns, and every app window follows the selected system/light/dark theme.
HISTORY_VIEW_FILE="$ROOT_DIR/Sources/VoicePanelApp/History/HistoryView.swift"
APPEARANCE_FILE="$ROOT_DIR/Sources/VoicePanelApp/UI/AppAppearance.swift"
VISUAL_EFFECT_FILE="$ROOT_DIR/Sources/VoicePanelApp/UI/VisualEffectBackground.swift"
grep -Fq 'Label("No Transcripts Yet", systemImage: "quote.bubble")' "$HISTORY_VIEW_FILE" \
    || fail "History needs a native full-window empty state"
grep -Fq 'NavigationSplitView' "$HISTORY_VIEW_FILE" \
    || fail "populated History must use native split navigation"
grep -Fq 'HistorySearchField(' "$HISTORY_VIEW_FILE" \
    || fail "History search must stay in a fixed native sidebar header"
grep -Fq '.toolbar(removing: .sidebarToggle)' "$HISTORY_VIEW_FILE" \
    || fail "History must keep its sidebar visible without a collapse toolbar button"
grep -Fq 'Clear Current History and Start Over' "$HISTORY_VIEW_FILE" \
    || fail "locked History errors must offer a destructive start-over action"
grep -Fq 'without requiring access to the previous key' "$HISTORY_VIEW_FILE" \
    || fail "history reset must explain that the previous key is not needed immediately"
grep -Fq 'Recover Previous History…' "$HISTORY_VIEW_FILE" \
    || fail "History must expose recovery after the previous Keychain key becomes available"
grep -Fq '.frame(maxWidth: 480)' "$HISTORY_VIEW_FILE" \
    || fail "locked History actions must use a bounded vertical layout"
grep -Fq 'maxWidth: .infinity,' "$HISTORY_VIEW_FILE" \
    || fail "History root content must fill the complete window width"
grep -Fq 'maxHeight: .infinity' "$HISTORY_VIEW_FILE" \
    || fail "History root content must fill the complete window height"
if grep -Fq '.searchable(text: $history.searchText' "$HISTORY_VIEW_FILE"; then
    fail "History search must not be attached to the scrolling transcript list"
fi
grep -Fq 'enum AppearanceMode' "$SETTINGS_FILE" \
    || fail "system/light/dark appearance preference is missing"
grep -Fq 'Picker("Window theme", selection: $settings.windowAppearanceMode)' "$SETTINGS_VIEW_FILE" \
    || fail "Settings must expose a separate window appearance preference"
grep -Fq 'Picker("Transcription panel theme", selection: $settings.panelAppearanceMode)' "$SETTINGS_VIEW_FILE" \
    || fail "Settings must expose a separate compact-panel appearance preference"
grep -Fq 'settings.$windowAppearanceMode' "$ROOT_DIR/Sources/VoicePanelApp/UI/SettingsWindowController.swift" \
    || fail "Settings windows must observe the window appearance preference"
grep -Fq 'isActive: false' "$SLIDING_VIEW_FILE" \
    || fail "the Settings feedback preview must remain static while settings are idle"
grep -Fq 'paused: reduceMotion || !isActive' "$SLIDING_VIEW_FILE" \
    || fail "inactive pending-feedback timelines must be paused instead of polling"
grep -Fq 'settings.$panelAppearanceMode' "$PANEL_CONTROLLER_FILE" \
    || fail "The compact panel must observe its own appearance preference"
grep -Fq 'AppAppearance.apply(.system, to: NSApp)' "$ROOT_DIR/Sources/VoicePanelApp/App/AppDelegate.swift" \
    || fail "Application-level appearance must remain system-managed for independent window and panel themes"
if grep -Fq 'settings.windowAppearanceMode, to: NSApp' "$ROOT_DIR/Sources/VoicePanelApp/App/AppDelegate.swift"; then
    fail "Window appearance must not leak into a System-themed compact panel"
fi
grep -Fq 'case .system:' "$APPEARANCE_FILE" \
    || fail "window appearance must support following the system"
if grep -Fq '.darkAqua' "$VISUAL_EFFECT_FILE"; then
    fail "visual-effect backgrounds must inherit the selected appearance"
fi

# A borderline signal inside the VAD hysteresis band must not keep a ten-second
# Whisper chunk open indefinitely after the speaker stops.
VAD_FILE="$ROOT_DIR/Sources/VoicePanelCore/VoiceActivityDetector.swift"
grep -Fq 'maximumHysteresisHoldDuration' "$VAD_FILE" \
    || fail "VAD hysteresis must have a bounded hold duration"
grep -Fq 'Ten-second Whisper chunk closes after one-second pause' \
    "$ROOT_DIR/Tests/VoicePanelCoreChecks/RecognitionAudioChunkPipelineChecks.swift" \
    || fail "the Whisper silence-boundary regression test is missing"

# Whisper exposes every supported execution path and applies the same advanced
# configuration to normal recognition and the reusable model benchmark.
WHISPER_CATALOG_FILE="$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperModelCatalog.swift"
WHISPER_CONFIG_FILE="$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperRuntimeConfiguration.swift"
WHISPER_MANAGER_FILE="$ROOT_DIR/Sources/VoicePanelApp/Models/WhisperModelManager.swift"
WHISPER_BENCHMARK_FILE="$ROOT_DIR/Sources/VoicePanelApp/Models/ModelBenchmarkRunner.swift"
for mode in automatic coreMLMetal coreMLCPU metal cpu; do
    grep -Fq "case $mode" "$WHISPER_CONFIG_FILE" \
        || fail "Whisper compute mode $mode is missing"
done
grep -Fq 'case mediumQ5 = "medium-q5_0"' "$WHISPER_CATALOG_FILE" \
    || fail "Whisper Medium Q5 model is missing"
grep -Fq 'case mediumQ8 = "medium-q8_0"' "$WHISPER_CATALOG_FILE" \
    || fail "Whisper Medium Q8 model is missing"
grep -Fq 'installCoreMLEncoder' "$WHISPER_MANAGER_FILE" \
    || fail "Whisper Core ML encoder installation is missing"
grep -Fq 'runtimeAliasURL' "$WHISPER_MANAGER_FILE" \
    || fail "Whisper Metal/CPU modes must suppress adjacent Core ML packages"
grep -Fq 'whisperRuntimeConfiguration' "$WHISPER_BENCHMARK_FILE" \
    || fail "Whisper benchmark must apply the selected compute mode"
grep -Fq 'whisperInferenceConfiguration' "$WHISPER_BENCHMARK_FILE" \
    || fail "Whisper benchmark must apply the selected decoding configuration"
grep -Fq '.contentShape(Rectangle())' "$SETTINGS_VIEW_FILE" \
    || fail "engine tuning disclosure rows must be clickable across their full width"
