import AppKit
import Foundation
import XCTest

final class VoicePanelUITests: XCTestCase {
    private var app: XCUIApplication!
    private var currentPageID = "general"
    private var uiTestHistoryDirectory: URL!
    private let deterministicTranscript = "This is a deterministic VoicePanel UI test."

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 60
        VoicePanelUITestProgress.report("\(name): setUp started")

        currentPageID = initialPageForCurrentTest
        uiTestHistoryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoicePanel-UITest-History-\(UUID().uuidString)", isDirectory: true)
        app = makeApplication(initialPage: currentPageID)
        VoicePanelUITestProgress.report("\(name): launching VoicePanel")
        app.launch()
        VoicePanelUITestProgress.report("\(name): launch returned")

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 10),
            "VoicePanel did not reach the foreground after launch."
        )
        XCTAssertTrue(
            existsOrWait(settingsWindow, timeout: 10),
            "VoicePanel did not open the Settings window in UI-test mode."
        )
        XCTAssertTrue(
            existsOrWait(element(identifier: "settings.root"), timeout: 5),
            "Settings appeared, but its SwiftUI accessibility tree never became ready."
        )
        VoicePanelUITestProgress.report("\(name): Settings accessibility tree ready")
    }

    override func tearDownWithError() throws {
        VoicePanelUITestProgress.report("\(name): tearDown started")
        if let app, app.state != .notRunning {
            dismissAnyPresentedSheet()
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 5)
        }
        app = nil
        if let uiTestHistoryDirectory {
            try? FileManager.default.removeItem(at: uiTestHistoryDirectory)
        }
        uiTestHistoryDirectory = nil
        VoicePanelUITestProgress.report("\(name): tearDown completed")
    }

    func testSettingsPagesAndCoreControls() {
        XCTContext.runActivity(named: "General settings and installed models") { _ in
            assertPage(name: "General", id: "general")
            XCTAssertGreaterThanOrEqual(settingsWindow.frame.width, 1_100)
            XCTAssertGreaterThanOrEqual(settingsWindow.frame.height, 690)
            XCTAssertTrue(element(identifier: "settings.root").exists)

            XCTAssertTrue(reveal(identifier: "general.input-device").exists)
            XCTAssertTrue(reveal(identifier: "general.environment").exists)
            XCTAssertTrue(reveal(identifier: "general.profile").exists)
            XCTAssertTrue(reveal(identifier: "general.engine").exists)
            XCTAssertTrue(reveal(identifier: "general.input-test").exists)

            let manageModels = reveal(identifier: "general.manage-models", requireHittable: true)
            XCTAssertTrue(manageModels.isHittable)
            manageModels.click()

            let sheetRoot = element(identifier: "installed-models.root")
            XCTAssertTrue(
                existsOrWait(sheetRoot, timeout: 4),
                "The installed-model manager sheet did not open."
            )
            let done = element(identifier: "installed-models.done")
            XCTAssertTrue(existsOrWait(done, timeout: 2))
            done.click()
            XCTAssertTrue(waitForDisappearance(sheetRoot, timeout: 3))
            XCTAssertTrue(settingsWindow.isHittable)

            // Keep the real sidebar navigation path covered without dedicating another app launch.
            openPage(name: "Performance Testing", id: "performance")
        }

        XCTContext.runActivity(named: "Workflow controls") { _ in
            openPage(name: "Workflow", id: "workflow")

            let releaseTail = reveal(identifier: "workflow.release-tail-toggle", requireHittable: true)
            XCTAssertTrue(releaseTail.isHittable)
            if !releaseTail.isOn {
                releaseTail.click()
                XCTAssertTrue(waitForToggleState(releaseTail, expectedOn: true, timeout: 2))
            }

            let releaseTailControls = reveal(identifier: "workflow.release-tail-controls")
            XCTAssertTrue(releaseTailControls.exists)
            XCTAssertTrue(reveal(identifier: "workflow.preparation-audio-toggle").exists)

            releaseTail.click()
            XCTAssertTrue(
                waitForDisappearance(releaseTailControls, timeout: 2),
                "Disabling the release tail must hide its duration controls."
            )
            releaseTail.click()
            XCTAssertTrue(reveal(identifier: "workflow.release-tail-controls").exists)

            let windowTheme = reveal(identifier: "appearance.window-theme", maxScrolls: 8)
            let panelTheme = reveal(identifier: "appearance.panel-theme", maxScrolls: 2)
            XCTAssertTrue(windowTheme.exists)
            XCTAssertTrue(panelTheme.exists)
            XCTAssertNotEqual(windowTheme.frame, panelTheme.frame)

            XCTAssertTrue(reveal(identifier: "appearance.transparent-panel", maxScrolls: 8).exists)
            XCTAssertTrue(reveal(identifier: "appearance.panel-blur", maxScrolls: 2).exists)
        }

        XCTContext.runActivity(named: "History settings") { _ in
            openPage(name: "History", id: "history")
            XCTAssertTrue(reveal(identifier: "history.storage").exists)
            XCTAssertTrue(reveal(identifier: "history.retention").exists)
            XCTAssertTrue(reveal(identifier: "history.encrypted-details").exists)
            XCTAssertTrue(element(identifier: "history.stored-data.encrypted").exists)
            XCTAssertTrue(element(identifier: "history.access.unlocked").exists)
        }

        XCTContext.runActivity(named: "Advanced recognition controls") { _ in
            openPage(name: "Advanced", id: "advanced")
            let customize = reveal(
                identifier: "advanced.customize-profile",
                maxScrolls: 8,
                requireHittable: true
            )
            XCTAssertTrue(customize.isHittable)
            customize.click()
            let boundary = reveal(identifier: "advanced.whisper-boundary-strategy", maxScrolls: 8)
            XCTAssertTrue(boundary.isEnabled)
            let initialBoundaryValue = boundary.value as? String
            boundary.click()
            app.menuItems["Boundary Bridge"].click()
            XCTAssertNotEqual(boundary.value as? String, initialBoundaryValue)
            let fileMode = reveal(identifier: "advanced.whisper-file-mode", maxScrolls: 4)
            fileMode.click()
            app.menuItems["Continuous Full Audio"].click()
            XCTAssertTrue(boundary.isEnabled)
            XCTAssertTrue(reveal(identifier: "advanced.hallucination-protection", maxScrolls: 8).exists)

            openPage(name: "General", id: "general")
            let engine = reveal(identifier: "general.engine", requireHittable: true)
            engine.click()
            app.menuItems["Apple Speech"].click()

            openPage(name: "Advanced", id: "advanced")
            let nonWhisperFileMode = reveal(
                identifier: "advanced.whisper-file-mode",
                maxScrolls: 8
            )
            XCTAssertTrue(nonWhisperFileMode.exists)
            XCTAssertFalse(nonWhisperFileMode.isEnabled)
        }
    }

    func testPerformanceVADComparisonShowsDiffAndTwoTimelines() {
        assertPage(name: "Performance Testing", id: "performance")

        let unselectedToggles = settingsWindow.buttons.matching(
            NSPredicate(format: "label == %@", "Select for comparison")
        )
        XCTAssertGreaterThanOrEqual(unselectedToggles.count, 2)
        unselectedToggles.firstMatch.click()

        let remainingToggle = settingsWindow.buttons.matching(
            NSPredicate(format: "label == %@", "Select for comparison")
        ).firstMatch
        XCTAssertTrue(remainingToggle.exists)
        remainingToggle.click()

        let compare = element(identifier: "performance.compare-selected")
        XCTAssertTrue(compare.isHittable)
        compare.click()

        XCTAssertTrue(
            existsOrWait(element(identifier: "performance.vad-comparison"), timeout: 3)
        )
        XCTAssertTrue(element(identifier: "performance.vad-comparison.transcript-diff").exists)
        XCTAssertTrue(element(identifier: "performance.vad-comparison.timeline-a").exists)
        XCTAssertTrue(element(identifier: "performance.vad-comparison.timeline-b").exists)

        settingsWindow.buttons["Done"].click()
        XCTAssertTrue(
            waitForDisappearance(element(identifier: "performance.vad-comparison"), timeout: 3)
        )
    }

    func testPerformanceWorkspaceHistoryReportAndPipeline() {
        assertPage(name: "Performance Testing", id: "performance")

        XCTContext.runActivity(named: "Workspace layout") { _ in
            let resultCard = element(identifier: "performance.result-card")
            let configurationAnchor = element(identifier: "performance.engine-picker")
            let modePicker = element(identifier: "performance.mode-picker")

            XCTAssertTrue(existsOrWait(resultCard, timeout: 5))
            XCTAssertTrue(
                existsOrWait(configurationAnchor, timeout: 3),
                "The visible benchmark configuration section did not expose a stable anchor."
            )
            XCTAssertTrue(existsOrWait(modePicker, timeout: 3))
            XCTAssertLessThan(resultCard.frame.maxX, configurationAnchor.frame.minX)
            XCTAssertGreaterThan(
                min(resultCard.frame.maxY, configurationAnchor.frame.maxY)
                    - max(resultCard.frame.minY, configurationAnchor.frame.minY),
                0
            )
            XCTAssertLessThanOrEqual(configurationAnchor.frame.maxX, settingsWindow.frame.maxX + 1)
        }

        XCTContext.runActivity(named: "Whisper comparison controls") { _ in
            let importAudio = reveal(
                identifier: "performance.import-audio",
                maxScrolls: 3,
                requireHittable: true
            )
            importAudio.click()
            let sheet = settingsWindow.sheets.firstMatch
            if sheet.exists {
                XCTAssertTrue(waitForDisappearance(sheet, timeout: 3))
            }

            let advanced = reveal(
                identifier: "performance.whisper-comparison-advanced-toggle",
                maxScrolls: 5,
                requireHittable: true
            )
            advanced.click()
            let edgePadding = reveal(
                identifier: "performance.whisper-edge-padding",
                maxScrolls: 4,
                requireHittable: true
            )
            let forcedCutOffset = reveal(
                identifier: "performance.whisper-forced-cut-offset",
                maxScrolls: 3,
                requireHittable: true
            )
            edgePadding.click()
            edgePadding.typeKey("a", modifierFlags: .command)
            edgePadding.typeText("0.4")
            forcedCutOffset.click()
            forcedCutOffset.typeKey("a", modifierFlags: .command)
            forcedCutOffset.typeText("-1.0")

            let comparison = reveal(
                identifier: "performance.run-whisper-comparison",
                maxScrolls: 3,
                requireHittable: true
            )
            comparison.click()
            XCTAssertTrue(
                existsOrWait(element(identifier: "performance.whisper-comparison-status"), timeout: 3)
            )
        }

        XCTContext.runActivity(named: "History snapshot restoration") { _ in
            let current = element(identifier: "performance.history.current")
            let previous = element(identifier: "performance.history.previous")
            XCTAssertTrue(existsOrWait(current, timeout: 4))
            XCTAssertTrue(existsOrWait(previous, timeout: 4))
            previous.click()

            let setupLoaded = element(identifier: "performance.setup-loaded")
            XCTAssertTrue(existsOrWait(setupLoaded, timeout: 3))
            let setupSummary = setupLoaded.accessibilityText
            XCTAssertTrue(setupSummary.contains("profile=custom"))
            XCTAssertTrue(setupSummary.contains("base-profile=recommended"))
            XCTAssertTrue(setupSummary.contains("boundary=standard"))
            XCTAssertTrue(setupSummary.contains("vad=energy"))
            XCTAssertTrue(existsOrWait(element(identifier: "performance.pipeline-profile"), timeout: 3))
            XCTAssertTrue(element(identifier: "performance.result-card").exists)
        }

        XCTContext.runActivity(named: "Pipeline visualization") { _ in
            selectPerformanceMode(label: "2. Pipeline Validation")
            let summary = reveal(identifier: "performance.pipeline-summary", maxScrolls: 8)
            let legend = reveal(identifier: "performance.pipeline-legend", maxScrolls: 4)
            XCTAssertTrue(summary.exists)
            XCTAssertTrue(legend.exists)

            let firstChunk = reveal(identifier: "performance.pipeline.chunk.1", maxScrolls: 3)
            XCTAssertTrue(firstChunk.isHittable)
            firstChunk.click()

            let heading = reveal(identifier: "performance.pipeline.chunk-heading", maxScrolls: 4)
            XCTAssertTrue(heading.exists)
            XCTAssertLessThan(legend.frame.minY, heading.frame.minY)
            let recognizedText = element(identifier: "performance.pipeline.chunk-text")
            XCTAssertTrue(existsOrWait(recognizedText, timeout: 3))
            XCTAssertTrue(recognizedText.accessibilityText.contains("exact text"))
        }

        XCTContext.runActivity(named: "Scoring report disclosure") { _ in
            selectPerformanceMode(label: "1. Model Benchmark")
            let disclosure = revealPerformanceScoringReportDisclosure()
            XCTAssertTrue(disclosure.isHittable)
            disclosure.click()
            XCTAssertTrue(reveal(identifier: "performance.inference-passes", maxScrolls: 4).exists)
            XCTAssertTrue(reveal(identifier: "performance.reference-transcript", maxScrolls: 2).exists)
        }
    }

    func testAudioFileChooserAutoDismissesAndRestoresSettings() {
        assertPage(name: "General", id: "general")
        let trigger = element(identifier: "ui-test.open-audio-panel")
        XCTAssertTrue(existsOrWait(trigger, timeout: 3))
        trigger.click()

        let sheet = settingsWindow.sheets.firstMatch
        defer {
            if sheet.exists {
                app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            }
        }

        XCTAssertTrue(existsOrWait(sheet, timeout: 3))
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(
            waitForDisappearance(sheet, timeout: 3),
            "The UI-test file chooser did not auto-dismiss."
        )
        XCTAssertTrue(existsOrWait(settingsWindow, timeout: 3))
        XCTAssertTrue(settingsWindow.isHittable)
    }

    func testRecordingHappyPathProducesTranscriptActionsAndHistory() {
        closeSettingsForScenario()
        completeDeterministicRecording()

        let copy = app.descendants(matching: .any)["transcription-panel.copy"]
        XCTAssertTrue(existsOrWait(copy, timeout: 3))
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), deterministicTranscript)

        let open = app.descendants(matching: .any)["transcription-panel.open-transcript"]
        XCTAssertTrue(existsOrWait(open, timeout: 2))
        open.click()
        let transcriptWindow = app.windows
            .matching(NSPredicate(format: "title CONTAINS[c] %@", "Transcript"))
            .firstMatch
        XCTAssertTrue(existsOrWait(transcriptWindow, timeout: 3))
        let editor = transcriptWindow.descendants(matching: .any)["transcript-window.editor"]
        XCTAssertTrue(existsOrWait(editor, timeout: 2))
        XCTAssertEqual(editor.value as? String, deterministicTranscript)

        let transcriptCloseButton = transcriptWindow.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(existsOrWait(transcriptCloseButton, timeout: 2))
        transcriptCloseButton.click()
        XCTAssertTrue(waitForDisappearance(transcriptWindow, timeout: 2))
        XCTAssertTrue(
            waitForDisappearance(app.descendants(matching: .any)["transcription-panel.root"], timeout: 2)
        )

        assertHistoryContainsDeterministicTranscript()

        completeDeterministicRecording()
        let close = app.descendants(matching: .any)["transcription-panel.close"]
        XCTAssertTrue(existsOrWait(close, timeout: 2))
        close.click()
        XCTAssertTrue(
            waitForDisappearance(app.descendants(matching: .any)["transcription-panel.root"], timeout: 2)
        )
        clickStatusMenuItem("Start Recording")
        let stop = app.descendants(matching: .any)["transcription-panel.stop"]
        XCTAssertTrue(existsOrWait(stop, timeout: 3))
        let cancel = app.descendants(matching: .any)["transcription-panel.cancel"]
        XCTAssertTrue(existsOrWait(cancel, timeout: 2))
        cancel.click()
    }

    func testRecordingFailureCanBeRetriedAndRecordingCanBeCancelled() {
        closeSettingsForScenario()
        clickStatusMenuItem("Start Recording")
        let stop = app.descendants(matching: .any)["transcription-panel.stop"]
        XCTAssertTrue(existsOrWait(stop, timeout: 3))
        stop.click()

        let retry = app.descendants(matching: .any)["transcription-panel.retry"]
        XCTAssertTrue(existsOrWait(retry, timeout: 4))
        let failureSummary = app.descendants(matching: .any)["transcription-panel.summary"]
        XCTAssertTrue(existsOrWait(failureSummary, timeout: 3))
        XCTAssertTrue(failureSummary.accessibilityText.contains("deterministic recognizer failure"))
        retry.click()
        _ = waitForDeterministicResult(timeout: 4)

        let close = app.descendants(matching: .any)["transcription-panel.close"]
        XCTAssertTrue(existsOrWait(close, timeout: 2))
        close.click()
        XCTAssertTrue(waitForDisappearance(app.descendants(matching: .any)["transcription-panel.root"], timeout: 2))

        clickStatusMenuItem("Start Recording")
        let cancel = app.descendants(matching: .any)["transcription-panel.cancel"]
        XCTAssertTrue(existsOrWait(cancel, timeout: 3))
        cancel.click()
        XCTAssertTrue(waitForDisappearance(app.descendants(matching: .any)["transcription-panel.root"], timeout: 2))

        assertHistoryContainsDeterministicTranscript()
    }

    func testAudioImportFixtureCompletesSuccessfully() {
        closeSettingsForScenario()
        clickStatusMenuItem("Transcribe Audio File…")
        _ = waitForDeterministicResult(timeout: 4)
        assertHistoryContainsDeterministicTranscript()
    }

    func testStatusMenuAndRepresentativeSettingsPersistAcrossRelaunch() {
        closeSettingsForScenario()

        openStatusMenu()
        XCTAssertTrue(app.menuItems["Start Recording"].exists)
        XCTAssertTrue(app.menuItems["Settings…"].exists)
        XCTAssertFalse(app.menuItems["Open Logs Folder"].isHittable)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        let statusItem = app.menuBars.statusItems["VoicePanel"]
        XCUIElement.perform(withKeyModifiers: .option) { statusItem.click() }
        XCTAssertTrue(waitUntil(timeout: 2) { self.app.menuItems["Open Logs Folder"].isHittable })
        XCTAssertTrue(app.menuItems["Reset Settings and Quit…"].isHittable)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(
            waitUntil(timeout: 1) { !self.app.menuItems["Reset Settings and Quit…"].isHittable },
            "The advanced status menu did not close after Escape."
        )

        openStatusMenu()
        XCTAssertFalse(app.menuItems["Open Logs Folder"].isHittable)
        let settingsItem = app.menuItems["Settings…"]
        XCTAssertTrue(existsOrWait(settingsItem, timeout: 2))
        settingsItem.click()
        XCTAssertTrue(existsOrWait(settingsWindow, timeout: 4))

        openPage(name: "Workflow", id: "workflow")
        let toggle = reveal(identifier: "workflow.release-tail-toggle", requireHittable: true)
        if toggle.isOn { toggle.click() }
        XCTAssertTrue(waitForToggleState(toggle, expectedOn: false, timeout: 2))

        app.terminate()
        app = makeApplication(initialPage: "workflow")
        app.launchEnvironment["VOICEPANEL_UI_TEST_RESET_SETTINGS"] = "0"
        app.launch()
        XCTAssertTrue(existsOrWait(settingsWindow, timeout: 7))
        let restored = element(identifier: "workflow.release-tail-toggle")
        XCTAssertTrue(existsOrWait(restored, timeout: 3))
        XCTAssertTrue(waitForToggleState(restored, expectedOn: false, timeout: 2))
        XCTAssertFalse(element(identifier: "workflow.release-tail-controls").exists)
    }

    private func assertHistoryContainsDeterministicTranscript() {
        closeCompletedPanelBeforeOpeningHistory()
        openStatusMenu()
        let historyItem = historyMenuItem()
        XCTAssertTrue(
            waitUntil(timeout: 3) { historyItem.isHittable },
            "The status menu did not expose a hittable History item after creating a transcript."
        )
        historyItem.click()

        let historyWindow = app.windows["VoicePanel History"]
        XCTAssertTrue(existsOrWait(historyWindow, timeout: 4))
        let historyRoot = historyWindow.descendants(matching: .any)["history-window.root"]
        XCTAssertTrue(existsOrWait(historyRoot, timeout: 3))
        let transcript = historyWindow.descendants(matching: .any)["history-window.transcript"]
        XCTAssertTrue(existsOrWait(transcript, timeout: 3))
        XCTAssertTrue(transcript.accessibilityText.contains(deterministicTranscript.lowercased()))
        let count = historyWindow.descendants(matching: .any)["history-window.count"]
        XCTAssertTrue(existsOrWait(count, timeout: 2))
        XCTAssertTrue(count.accessibilityText.contains("1 saved"))

        let close = historyWindow.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(existsOrWait(close, timeout: 2))
        close.click()
        XCTAssertTrue(waitForDisappearance(historyWindow, timeout: 2))
    }

    private func closeCompletedPanelBeforeOpeningHistory() {
        let panel = app.descendants(matching: .any)["transcription-panel.root"]
        let close = app.descendants(matching: .any)["transcription-panel.close"]
        if existsOrWait(close, timeout: 1) {
            close.click()
            XCTAssertTrue(waitForDisappearance(panel, timeout: 2))
        }
    }

    private func historyMenuItem() -> XCUIElement {
        app.menuItems["status-menu.history"]
    }

    private func waitForToggleState(
        _ toggle: XCUIElement,
        expectedOn: Bool,
        timeout: TimeInterval
    ) -> Bool {
        waitUntil(timeout: timeout) { toggle.isOn == expectedOn }
    }

    private func completeDeterministicRecording() {
        clickStatusMenuItem("Start Recording")
        let stop = app.descendants(matching: .any)["transcription-panel.stop"]
        XCTAssertTrue(existsOrWait(stop, timeout: 3))
        stop.click()
        _ = waitForDeterministicResult()
    }

    @discardableResult
    private func waitForDeterministicResult(timeout: TimeInterval = 6) -> XCUIElement {
        let summary = app.descendants(matching: .any)["transcription-panel.summary"]
        XCTAssertTrue(
            existsOrWait(summary, timeout: timeout),
            "The deterministic recognition result did not appear."
        )
        XCTAssertTrue(
            summary.accessibilityText.contains("transcript ready"),
            "The compact panel did not expose the completed transcript state."
        )
        XCTAssertTrue(
            existsOrWait(app.descendants(matching: .any)["transcription-panel.copy"], timeout: 2),
            "Transcript actions did not become available after recognition."
        )
        return summary
    }

    private func closeSettingsForScenario() {
        if settingsWindow.exists { settingsWindow.buttons[XCUIIdentifierCloseWindow].click() }
    }

    private func openStatusMenu() {
        let statusItem = app.menuBars.statusItems["VoicePanel"]
        XCTAssertTrue(existsOrWait(statusItem, timeout: 3))

        // Do not infer that an NSMenu is open from stale menu-item accessibility nodes.
        // Always click the status item and verify a visible, hittable anchor. If a menu was
        // already open, the first click closes it and the second click opens a fresh menu.
        app.activate()
        _ = waitUntil(timeout: 0.4) { self.app.state == .runningForeground }
        let anchor = app.menuItems["Start Recording"]
        for _ in 0..<2 {
            statusItem.click()
            if waitUntil(timeout: 0.7) { anchor.isHittable } { return }
            app.activate()
        }

        XCTFail("VoicePanel status menu did not open after activation and retry.")
    }

    private func clickStatusMenuItem(_ title: String) {
        openStatusMenu()
        let item = app.menuItems[title]
        XCTAssertTrue(existsOrWait(item, timeout: 2), "Missing status-menu item: \(title)")
        item.click()
    }

    private var settingsWindow: XCUIElement {
        app.windows["VoicePanel Settings"]
    }

    private var initialPageForCurrentTest: String {
        if name.contains("Performance") || name.contains("Pipeline") { return "performance" }
        if name.contains("Workflow") { return "workflow" }
        if name.contains("History") { return "history" }
        if name.contains("Advanced") { return "advanced" }
        return "general"
    }

    private func makeApplication(initialPage: String) -> XCUIApplication {
        let application = XCUIApplication(url: applicationURL)
        application.launchArguments = ["--ui-testing"]
        application.launchEnvironment = [
            "VOICEPANEL_UI_TESTING": "1",
            "VOICEPANEL_UI_TEST_RESET_SETTINGS": "1",
            "VOICEPANEL_UI_TEST_INITIAL_PAGE": initialPage,
            "VOICEPANEL_UI_TEST_AUTO_DISMISS_FILE_PANEL": "1",
            "VOICEPANEL_UI_TEST_HISTORY_DIRECTORY": uiTestHistoryDirectory.path,
            "NSUnbufferedIO": "YES",
        ]
        for (key, value) in scenarioEnvironmentForCurrentTest {
            application.launchEnvironment[key] = value
        }
        return application
    }

    private var scenarioEnvironmentForCurrentTest: [String: String] {
        var environment: [String: String] = [:]
        if name.contains("AudioImportFixture") {
            environment["VOICEPANEL_UI_TEST_IMPORT_FIXTURE"] = "1"
        }
        if name.contains("FailureCanBeRetried") {
            environment["VOICEPANEL_UI_TEST_RECOGNIZER_FAILURE"] = "1"
        }
        return environment
    }

    private func openPage(name: String, id: String) {
        let tab = element(identifier: "settings.tab.\(id)")
        if tab.exists {
            tab.click()
        } else {
            clickElement(label: name)
        }
        assertPage(name: name, id: id)
        currentPageID = id
    }

    private func assertPage(name: String, id: String) {
        XCTAssertTrue(
            existsOrWait(element(identifier: "settings.page.\(id)"), timeout: 3),
            "The \(name) settings page did not become visible."
        )
    }

    private func selectPerformanceMode(label: String) {
        let radioButton = settingsWindow.radioButtons[label]
        let button = settingsWindow.buttons[label]

        for _ in 0..<8 {
            if radioButton.exists && radioButton.isHittable {
                radioButton.click()
                return
            }
            if button.exists && button.isHittable {
                button.click()
                return
            }
            _ = scrollPerformanceConfiguration(byDeltaY: 520)
        }

        for _ in 0..<8 {
            if radioButton.exists && radioButton.isHittable {
                radioButton.click()
                return
            }
            if button.exists && button.isHittable {
                button.click()
                return
            }
            _ = scrollPerformanceConfiguration(byDeltaY: -520)
        }

        clickElement(label: label)
    }

    private func clickElement(label: String) {
        let candidate = element(label: label)
        XCTAssertTrue(existsOrWait(candidate, timeout: 3), "Missing UI element: \(label)")
        candidate.click()
    }

    private func reveal(
        identifier: String,
        maxScrolls: Int = 6,
        requireHittable: Bool = false
    ) -> XCUIElement {
        let candidate = element(identifier: identifier)
        if candidate.exists, !requireHittable || candidate.isHittable {
            return candidate
        }

        bringIntoView(candidate, maxScrolls: maxScrolls)
        return candidate
    }

    private func revealPerformanceScoringReportDisclosure() -> XCUIElement {
        let identified = element(identifier: "performance.scoring-report-toggle")
        if identified.exists, identified.isHittable {
            return identified
        }

        for _ in 0..<8 {
            _ = scrollPerformanceConfigurationDown()

            if identified.exists && identified.isHittable {
                return identified
            }

            let labeledButton = settingsWindow.buttons["Scoring & Report"]
            if labeledButton.exists && labeledButton.isHittable {
                return labeledButton
            }
        }

        return identified
    }

    private func bringIntoView(_ candidate: XCUIElement, maxScrolls: Int) {
        if candidate.exists && candidate.isHittable {
            return
        }

        for _ in 0..<maxScrolls {
            if !scrollPreferredContainerDown() {
                scrollLargestVisibleContainerDown()
            }
            if candidate.exists && candidate.isHittable {
                return
            }
        }
    }

    private func scrollPreferredContainerDown() -> Bool {
        if currentPageID == "performance" {
            return scrollPerformanceConfigurationDown()
        }

        for identifier in ["settings.form.\(currentPageID)", "settings.page.\(currentPageID)"] {
            let typedContainer = settingsWindow.scrollViews[identifier]
            if typedContainer.exists && typedContainer.isHittable {
                typedContainer.scroll(byDeltaX: 0, deltaY: -420)
                return true
            }

            let genericContainer = element(identifier: identifier)
            if genericContainer.exists && genericContainer.isHittable {
                genericContainer.scroll(byDeltaX: 0, deltaY: -420)
                return true
            }
        }
        return false
    }

    private func scrollPerformanceConfigurationDown() -> Bool {
        scrollPerformanceConfiguration(byDeltaY: -420)
    }

    private func scrollPerformanceConfiguration(byDeltaY deltaY: CGFloat) -> Bool {
        let explicitContainer = settingsWindow.scrollViews["performance.configuration-scroll"]
        if explicitContainer.exists && explicitContainer.isHittable {
            explicitContainer.scroll(byDeltaX: 0, deltaY: deltaY)
            return true
        }

        // SwiftUI's macOS Form can inherit the identifier of an enclosing page instead of
        // exposing its own. Choose the right-most visible scroll view so the independent
        // history list in the left column is never scrolled by mistake.
        let candidates = settingsWindow.scrollViews.allElementsBoundByIndex
            .filter {
                $0.exists && $0.isHittable
                    && $0.identifier != "performance.history-scroll"
                    && $0.frame.width > 240
                    && $0.frame.height > 180
            }
            .sorted {
                if abs($0.frame.minX - $1.frame.minX) > 1 {
                    return $0.frame.minX > $1.frame.minX
                }
                return ($0.frame.width * $0.frame.height) > ($1.frame.width * $1.frame.height)
            }

        guard let container = candidates.first else { return false }
        container.scroll(byDeltaX: 0, deltaY: deltaY)
        return true
    }

    private func scrollLargestVisibleContainerDown() {
        let scrollViews = settingsWindow.scrollViews.allElementsBoundByIndex
            .filter {
                $0.exists && $0.isHittable
                    && $0.identifier != "performance.history-scroll"
            }
            .sorted {
                ($0.frame.width * $0.frame.height) > ($1.frame.width * $1.frame.height)
            }

        if let scrollView = scrollViews.first {
            scrollView.scroll(byDeltaX: 0, deltaY: -420)
        } else {
            settingsWindow.scroll(byDeltaX: 0, deltaY: -420)
        }
    }

    private func existsOrWait(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        if element.exists { return true }
        return element.waitForExistence(timeout: timeout)
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { !element.exists }
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        if condition() { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            if condition() { return true }
        }
        return condition()
    }

    private func dismissAnyPresentedSheet() {
        guard settingsWindow.exists else { return }
        let sheet = settingsWindow.sheets.firstMatch
        if sheet.exists {
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            _ = waitForDisappearance(sheet, timeout: 2)
        }
    }

    private func element(identifier: String) -> XCUIElement {
        settingsWindow.descendants(matching: .any)[identifier]
    }

    private func element(label: String) -> XCUIElement {
        settingsWindow.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }

    private var applicationURL: URL {
        let environment = ProcessInfo.processInfo.environment
        let configuredPath = environment["VOICEPANEL_UI_TEST_APP_PATH"]
            .flatMap { $0.isEmpty ? nil : $0 }

        let appURL: URL
        if let configuredPath {
            appURL = URL(fileURLWithPath: configuredPath)
        } else {
            let sourceFile = URL(fileURLWithPath: #filePath)
            let repositoryRoot =
                sourceFile
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            appURL = repositoryRoot.appendingPathComponent(".build/app/VoicePanel.app")
        }

        precondition(
            FileManager.default.fileExists(atPath: appURL.path),
            "Build VoicePanel.app with scripts/build-app.sh before running UI tests."
        )
        return appURL
    }
}

extension XCUIElement {
    fileprivate var stringValue: String {
        switch value {
        case let value as String:
            return value.lowercased()
        case let value as NSNumber:
            return value.boolValue ? "1" : "0"
        default:
            return ""
        }
    }

    fileprivate var isOn: Bool {
        stringValue == "1" || stringValue == "true"
    }

    fileprivate var accessibilityText: String {
        [label.lowercased(), stringValue]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
