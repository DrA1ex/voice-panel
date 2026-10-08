#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

required_files=(
    "$ROOT_DIR/UITests/VoicePanelUITestHarness.xcodeproj/project.pbxproj"
    "$ROOT_DIR/UITests/VoicePanelUITestHarness.xcodeproj/xcshareddata/xcschemes/VoicePanelUITests.xcscheme"
    "$ROOT_DIR/UITests/Host/VoicePanelUITestHostApp.swift"
    "$ROOT_DIR/UITests/VoicePanelUITests/VoicePanelUITests.swift"
    "$ROOT_DIR/UITests/VoicePanelUITests/VoicePanelUITestBootstrapTests.swift"
    "$ROOT_DIR/UITests/VoicePanelUITests/VoicePanelUITestProgress.swift"
    "$ROOT_DIR/scripts/test-ui.sh"
)

for file in "${required_files[@]}"; do
    if [[ ! -f "$file" ]]; then
        echo "Missing UI-test file: ${file#$ROOT_DIR/}" >&2
        exit 1
    fi
done

if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$ROOT_DIR/UITests/VoicePanelUITestHarness.xcodeproj/project.pbxproj" >/dev/null
fi

python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

root = Path(sys.argv[1])
app_delegate = (root / "Sources/VoicePanelApp/App/AppDelegate.swift").read_text()
history_model = (root / "Sources/VoicePanelApp/History/HistoryModel.swift").read_text()
history_view = (root / "Sources/VoicePanelApp/History/HistoryView.swift").read_text()
settings_view = (root / "Sources/VoicePanelApp/UI/SettingsView.swift").read_text()
compact_panel = (root / "Sources/VoicePanelApp/UI/CompactPanelView.swift").read_text()
full_transcript = (root / "Sources/VoicePanelApp/UI/FullTranscriptView.swift").read_text()
benchmark = (root / "Sources/VoicePanelApp/Models/ModelBenchmarkRunner.swift").read_text()
coordinator = (root / "Sources/VoicePanelApp/Recognition/TranscriptionCoordinator.swift").read_text()
ui_tests = (root / "UITests/VoicePanelUITests/VoicePanelUITests.swift").read_text()
ui_bootstrap = (root / "UITests/VoicePanelUITests/VoicePanelUITestBootstrapTests.swift").read_text()
ui_progress = (root / "UITests/VoicePanelUITests/VoicePanelUITestProgress.swift").read_text()
project = (root / "UITests/VoicePanelUITestHarness.xcodeproj/project.pbxproj").read_text()
scheme_path = root / "UITests/VoicePanelUITestHarness.xcodeproj/xcshareddata/xcschemes/VoicePanelUITests.xcscheme"
scheme = scheme_path.read_text()
ET.parse(scheme_path)
test_ui_script = (root / "scripts/test-ui.sh").read_text()

checks = {
    "isolated UI-test preferences": 'VoicePanel.UITests' in app_delegate,
    "UI-test launch mode": '--ui-testing' in app_delegate and 'ensureSettingsWindowController().show()' in app_delegate,
    "Option-click status menu is captured from the actual status-item event": (
        'button.action = #selector(showStatusMenu(_:))' in app_delegate
        and 'button.sendAction(on: [.leftMouseDown, .rightMouseDown])' in app_delegate
        and 'statusMenuAdvancedItemsRequested' in app_delegate
        and 'statusItem.menu = menu' not in app_delegate
    ),
    "file chooser is triggered after app launch and cannot block the suite": (
        'ui-test.open-audio-panel' in settings_view
        and 'VOICEPANEL_UI_TEST_AUTO_DISMISS_FILE_PANEL' in ui_tests
        and 'scheduleUITestFilePanelDismissalIfNeeded' in app_delegate
        and 'waitForDisappearance(sheet, timeout: 3)' in ui_tests
    ),
    "UI-test file chooser auto-dismisses without a multi-second artificial pause": (
        'DispatchQueue.main.asyncAfter(deadline: .now() + 0.25)' in app_delegate
    ),
    "settings root accessibility identifier": 'settings.root' in settings_view,
    "benchmark panel accessibility identifiers": all(token in settings_view for token in (
        'performance.sample-sidebar',
        'performance.configuration-panel',
        'performance.mode-picker',
        'performance.configuration-heading',
    )),
    "real app XCUI launch": 'XCUIApplication(url: applicationURL)' in ui_tests,
    "benchmark layout scenario": 'testPerformanceWorkspaceHistoryReportAndPipeline' in ui_tests,
    "benchmark snapshot scenario": 'testPerformanceWorkspaceHistoryReportAndPipeline' in ui_tests,
    "pipeline visualization scenario": (
        'testPerformanceWorkspaceHistoryReportAndPipeline' in ui_tests
        and 'performance.pipeline.chunk-text' in settings_view
        and 'performance.pipeline.chunk-text' in ui_tests
    ),
    "VAD comparison presents transcript diff above two stacked pipeline timelines": (
        all(token in settings_view for token in (
            'performance.vad-comparison',
            'performance.vad-comparison.transcript-diff',
            'performance.vad-comparison.timeline-a',
            'performance.vad-comparison.timeline-b',
            'PerformancePipelineComparisonSheet',
            'allowsZoom: false',
        ))
        and all(token in ui_tests for token in (
            'testPerformanceVADComparisonShowsDiffAndTwoTimelines',
            'performance.compare-selected',
            'performance.vad-comparison.transcript-diff',
            'performance.vad-comparison.timeline-a',
            'performance.vad-comparison.timeline-b',
        ))
    ),
    "workflow release-tail scenario": 'testSettingsPagesAndCoreControls' in ui_tests,
    "history settings scenario": 'testSettingsPagesAndCoreControls' in ui_tests,
    "advanced context scenario": 'testSettingsPagesAndCoreControls' in ui_tests,
    "installed-model manager scenario": 'testSettingsPagesAndCoreControls' in ui_tests,
    "Xcode UI-test target": 'com.apple.product-type.bundle.ui-testing' in project,
    "UI-test Info.plist generation": project.count('GENERATE_INFOPLIST_FILE = YES') >= 2,
    "UI-test sources use stable project-relative paths": all(token in project for token in (
        'path = Host;',
        'path = VoicePanelUITests;',
    )),
    "UI-test app path can be derived without generated scheme environment": (
        '#filePath' in ui_tests and 'VOICEPANEL_UI_TEST_APP_PATH' in ui_tests
    ),
    "UI-test progress path can be derived without generated scheme environment": (
        '#filePath' in ui_progress and 'VoicePanelUITests.progress.log' in ui_progress
    ),
    "UI-test host debug dylib disabled": 'ENABLE_DEBUG_DYLIB = NO' in project,
    "checked-in UI-test project is used": (
        'PROJECT_PATH="$ROOT_DIR/UITests/VoicePanelUITestHarness.xcodeproj"' in test_ui_script
        and 'xcodegen' not in test_ui_script.lower()
        and 'BlueprintName = "VoicePanelUITests"' in scheme
    ),
    "stale UI-test build output is removed without deleting the checked-in project": (
        'preserve incremental DerivedData' in test_ui_script
        and 'chflags -R nouchg,noschg' in test_ui_script
        and 'chmod -RN' in test_ui_script
        and 'PROJECT_PATH="$ROOT_DIR/UITests/VoicePanelUITestHarness.xcodeproj"' in test_ui_script
    ),
    "UI-test transcript history avoids Keychain and uses temporary storage": (
        'HistoryModel(uiTestSettings: settings, directoryURL: directoryURL)' in app_delegate
        and 'VOICEPANEL_UI_TEST_HISTORY_DIRECTORY' in app_delegate
        and 'VOICEPANEL_UI_TEST_HISTORY_DIRECTORY' in ui_tests
        and 'history.test-key' in history_model
        and 'cleanup_ui_test_history' in test_ui_script
        and "VoicePanel-UITest-History-*" in test_ui_script
    ),
    "compact panel exposes deterministic controls and state to XCUI": (
        '.accessibilityElement(children: .contain)' in compact_panel
        and 'transcription-panel.stop' in compact_panel
        and 'transcription-panel.cancel' in compact_panel
        and 'transcription-panel.summary' in compact_panel
        and 'transcription-panel.copy' in compact_panel
        and 'transcription-panel.retry' in compact_panel
    ),
    "full transcript exposes stable XCUI anchors": (
        'transcript-window.root' in full_transcript
        and 'transcript-window.editor' in full_transcript
        and 'transcript-window.editor' in ui_tests
    ),
    "scenario tests assert the rendered result state instead of hidden transcript text": (
        'private func waitForDeterministicResult' in ui_tests
        and 'app.staticTexts["This is a deterministic VoicePanel UI test."]' not in ui_tests
    ),
    "settings persistence scenario explicitly opens Workflow": (
        'testStatusMenuAndRepresentativeSettingsPersistAcrossRelaunch' in ui_tests
        and 'openPage(name: "Workflow", id: "workflow")' in ui_tests
    ),
    "UI-test defaults do not overwrite persisted settings on relaunch": (
        'VOICEPANEL_UI_TEST_RESET_SETTINGS' in app_delegate
        and 'guard shouldResetSettings else { return }' in app_delegate
    ),
    "recording scenarios validate the real history window": (
        'history-window.root' in history_view
        and 'history-window.transcript' in history_view
        and 'history-window.count' in history_view
        and 'assertHistoryContainsDeterministicTranscript' in ui_tests
        and 'closeCompletedPanelBeforeOpeningHistory' in ui_tests
    ),
    "status-menu helper ignores stale closed-menu accessibility nodes": (
        'private func statusMenuIsOpen() -> Bool' not in ui_tests
        and 'Do not infer that an NSMenu is open from stale menu-item accessibility nodes.' in ui_tests
        and 'let anchor = app.menuItems["Start Recording"]' in ui_tests
        and 'app.activate()' in ui_tests
        and 'for _ in 0..<2' in ui_tests
        and 'waitUntil(timeout: 0.7) { anchor.isHittable }' in ui_tests
    ),
    "history menu uses a stable accessibility identifier": (
        'historyMenuItem.setAccessibilityIdentifier("status-menu.history")' in app_delegate
        and 'historyMenuItem.setAccessibilityLabel(historyMenuItem.title)' in app_delegate
        and 'app.menuItems["status-menu.history"]' in ui_tests
        and 'historyItem.label.contains("(1)")' not in ui_tests
        and 'history-window.count' in ui_tests
        and 'label BEGINSWITH[c]' not in ui_tests
    ),
    "hidden Option-menu items are not treated as an open normal menu": (
        'XCTAssertFalse(app.menuItems["Open Logs Folder"].isHittable)' in ui_tests
        and 'XCTAssertFalse(app.menuItems["Open Logs Folder"].exists)' not in ui_tests
        and 'The advanced status menu did not close after Escape.' in ui_tests
    ),
    "transcript scenario closes the actual transcript window": (
        'transcriptWindow.buttons[XCUIIdentifierCloseWindow]' in ui_tests
        and 'app.typeKey("w", modifierFlags: .command)' not in ui_tests
    ),
    "settings persistence waits for the switch state before relaunch": (
        'waitForToggleState' in ui_tests
        and 'expectedOn: false' in ui_tests
    ),
    "Option-click UI test uses the XCTest class modifier API": (
        'XCUIElement.perform(withKeyModifiers: .option)' in ui_tests
        and 'statusItem.perform(withKeyModifiers:' not in ui_tests
    ),
    "stale UI-test processes are terminated": 'cleanup_ui_processes' in test_ui_script and 'pkill -x VoicePanel' in test_ui_script,
    "UI tests have finite execution time": all(token in test_ui_script for token in (
        '-test-timeouts-enabled YES',
        '-default-test-execution-time-allowance 60',
        '-maximum-test-execution-time-allowance 90',
    )) and 'executionTimeAllowance = 60' in ui_tests,
    "UI tests are consolidated into eight user-level scenarios": (
        ui_tests.count("    func test") == 8
        and 'testSettingsPagesAndCoreControls' in ui_tests
        and 'testPerformanceWorkspaceHistoryReportAndPipeline' in ui_tests
        and 'testRecordingHappyPathProducesTranscriptActionsAndHistory' in ui_tests
        and 'testRecordingFailureCanBeRetriedAndRecordingCanBeCancelled' in ui_tests
    ),
    "UI tests avoid redundant relaunches": (
        'private func relaunch(' not in ui_tests
        and 'scenarioEnvironmentForCurrentTest' in ui_tests
        and 'relaunchScenario(extraEnvironment:' not in ui_tests
    ),
    "UI tests avoid XCTest waits for already visible elements": (
        'private func existsOrWait' in ui_tests
        and ui_tests.count('waitForExistence(timeout:') == 1
        and 'private func waitUntil' in ui_tests
    ),
    "UI tests provide reusable scrolling and modal cleanup": (
        'private func reveal(' in ui_tests
        and 'private func scrollPreferredContainerDown' in ui_tests
        and 'private func scrollLargestVisibleContainerDown' in ui_tests
        and 'private func dismissAnyPresentedSheet()' in ui_tests
        and 'defer {' in ui_tests
    ),
    "UI tests use compile-safe bounded scrolling": (
        'private func bringIntoView(' in ui_tests
        and 'private func scrollPerformanceConfigurationDown()' in ui_tests
        and 'scroll(byDeltaX: 0, deltaY: -420)' in ui_tests
        and 'requireHittable: Bool = false' in ui_tests
        and 'if candidate.exists && candidate.isHittable' in ui_tests
        and 'scrollToVisible()' not in ui_tests
    ),
    "performance UI tests use unique rendered control anchors": (
        'element(identifier: "performance.engine-picker")' in ui_tests
        and 'element(identifier: "performance.pipeline-profile")' in ui_tests
        and 'performance.mode.model-benchmark' not in ui_tests
        and 'performance.configuration-heading' not in ui_tests
    ),
    "performance UI tests validate real reusable snapshots": (
        'performance.setup-loaded' in ui_tests
        and 'base-profile=recommended' in ui_tests
        and 'performanceConfigurationAccessibilitySummary' in settings_view
        and 'recognitionProfile.rawValue' in settings_view
        and 'performanceSetupSnapshot' in settings_view
    ),
    "pipeline and history values expose stable accessibility identifiers": all(token in settings_view for token in (
        'history.stored-data.encrypted',
        'performance.pipeline-summary',
        'performance.pipeline.chunk-heading',
        'performance.pipeline-profile',
        'performance.inference-passes',
        'performance.reference-transcript',
        'chunkRecognitionAccessibilityText',
    )),
    "UI-test runner distinguishes assertion failures from harness startup failures": all(token in test_ui_script for token in (
        'suite_log_shows_xctest_activity',
        'XCTest started normally and reported test/assertion failures; bootstrap diagnostic skipped.',
        'The suite stopped before any XCTest activity was observed',
    )),
    "UI-test runner preserves cache and supports focused modes": all(token in test_ui_script for token in (
        'Normal runs preserve incremental DerivedData',
        'Incremental UI-test build failed; retrying once with clean DerivedData.',
        '--quick',
        '--test NAME',
        '--clean',
    )),
    "quick UI-test mode excludes the slow file-panel scenario and xcresult finalization": (
        'testAudioFileChooserAutoDismissesAndRestoresSettings' not in test_ui_script.split('QUICK_TESTS=(')[1].split(')')[0]
        and 'if [[ "$RUN_MODE" != "quick" || -n "$TARGET_TEST" ]]' in test_ui_script
    ),
    "UI tests split build from execution": all(token in test_ui_script for token in (
        'build-for-testing',
        'test-without-building',
        '01-build-for-testing',
        '03-ui-test-suite',
        '--quick',
        '--clean',
    )),
    "UI-test infrastructure bootstrap": (
        'VoicePanelUITestBootstrapTests' in ui_bootstrap
        and 'testHarnessStarts' in ui_bootstrap
        and 'run_bootstrap_diagnostic' in test_ui_script
    ),
    "UI-test live progress markers": (
        'VoicePanelUITestProgress.report' in ui_tests
        and 'VoicePanelUITestProgress.report' in ui_bootstrap
        and 'XCTest progress' in test_ui_script
    ),
    "UI-test failures surface compiler diagnostics": all(token in test_ui_script for token in (
        'Compiler and test diagnostics:',
        'SwiftCompile',
        'fatal error:',
        'last 40 log lines:',
    )),
    "UI-test external watchdog": all(token in test_ui_script for token in (
        'run_xcodebuild_stage',
        'BOOTSTRAP_TIMEOUT_SECONDS',
        'SUITE_TIMEOUT_SECONDS',
        'timed out after',
    )),
    "UI-test permission diagnosis": (
        'Privacy & Security > Accessibility' in test_ui_script
        and 'Xcode Helper' in test_ui_script
    ),
    "UI-test runner has no XcodeGen dependency": (
        'xcodegen' not in test_ui_script.lower()
        and (root / 'UITests/VoicePanelUITestHarness.xcodeproj/project.pbxproj').is_file()
    ),
    "full Xcode is required": 'ACTIVE_DEVELOPER_DIR=' in test_ui_script and '/CommandLineTools' in test_ui_script,
    "benchmark recovery decision isolated from async body": 'private func makeInputRecoveryDecision(' in benchmark,
    "coordinator recovery decision isolated from async body": 'private func makeInputRecoveryDecision(' in coordinator,
}

failed = [name for name, passed in checks.items() if not passed]
if failed:
    for name in failed:
        print(f"UI-test/source contract failed: {name}", file=sys.stderr)
    raise SystemExit(1)

for source in (benchmark, coordinator):
    if '.map(UInt32.init)' in source:
        print('Audio input recovery must not use Optional.map(UInt32.init) in app call sites.', file=sys.stderr)
        raise SystemExit(1)

print('UI test source contracts passed.')
PY
