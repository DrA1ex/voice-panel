import AppKit
import Combine
import UniformTypeIdentifiers
import VoicePanelCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let state = AppState()
    private lazy var settings = AppSettings(defaults: Self.makeSettingsDefaults())
    private let hotKey = GlobalHotKey()
    private let whisperModels = WhisperModelManager()
    private let gigaAMModels = GigaAMModelManager()
    private let localONNXModels = LocalONNXModelManager()
    private let sileroVADModels = SileroVADModelManager()
    private let russianCorrectionModels = RussianCorrectionModelManager()
    private let diagnostics = DiagnosticLogger.shared
    private var whisperRuntime: WhisperRuntimeManager?
    private var whisperDraftRuntime: WhisperRuntimeManager?
    private var gigaAMRuntime: GigaAMRuntimeManager?
    private var gigaAMDraftRuntime: GigaAMRuntimeManager?
    private var localONNXRuntime: LocalONNXRuntimeManager?
    private var russianCorrectionRuntime: RussianTextCorrectionRuntimeManager?

    private var history: HistoryModel?
    private var coordinator: TranscriptionCoordinator?
    private var compactPanel: CompactPanelController?
    private var transcriptWindow: FullTranscriptWindowController?
    private var historyWindow: HistoryWindowController?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var statusMenuAdvancedItemsRequested = false
    private var recordingMenuItem: NSMenuItem!
    private var audioImportMenuItem: NSMenuItem!
    private var modelStatusMenuItem: NSMenuItem!
    private var recoveryResetMenuItem: NSMenuItem!
    private var advancedMenuSeparator: NSMenuItem!
    private var logsMenuItem: NSMenuItem!
    private var resetSettingsMenuItem: NSMenuItem!
    private var transcriptMenuItem: NSMenuItem!
    private var historyMenuItem: NSMenuItem!
    private var cancellables = Set<AnyCancellable>()
    private var coreServicesInitializationInProgress = false
    private var coreObserversInstalled = false
    private var isReconcilingRecognitionSelection = false
    private var startupInitializationScheduled = false
    private var architectureWarningScheduled = false
    private var fullTranscriptReplacesCompactPanel = false
    private var uiTestRecognitionAttempt = 0
    private let uiTestTranscript = "This is a deterministic VoicePanel UI test."

    private var safeModeEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--safe-mode")
            || ProcessInfo.processInfo.environment["VOICEPANEL_SAFE_MODE"] == "1"
    }

    private var uiTestingEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
            || ProcessInfo.processInfo.environment["VOICEPANEL_UI_TESTING"] == "1"
    }

    private static func makeSettingsDefaults() -> UserDefaults {
        let environment = ProcessInfo.processInfo.environment
        guard
            environment["VOICEPANEL_UI_TESTING"] == "1"
                || ProcessInfo.processInfo.arguments.contains("--ui-testing")
        else {
            return .standard
        }

        let suiteName = "io.github.dra1ex.VoicePanel.UITests"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        if environment["VOICEPANEL_UI_TEST_RESET_SETTINGS"] == "1" {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(uiTestingEnabled ? .regular : .accessory)
        WindowFocusCoordinator.shared.start()
        configureAppearance()
        if configurePanelPreviewIfRequested() { return }
        diagnostics.beginApplicationSession(version: applicationVersion)
        diagnostics.info("Startup stage", metadata: ["stage": "applicationDidFinishLaunching.begin"])

        configureStatusItem()
        diagnostics.info("Menu bar item configured")

        observeState()
        scheduleArchitectureCompatibilityWarningIfNeeded()

        if uiTestingEnabled {
            diagnostics.info("UI test launch mode enabled")
            configureUITestingDefaults()
            guard ensureCoreServicesInitialized(reason: "UI testing", preloadSelectedBackend: false) else {
                diagnostics.error("UI test bootstrap could not initialize core services")
                NSApp.terminate(nil)
                return
            }
            ensureSettingsWindowController().show()
            return
        }

        registerHotKey()

        if safeModeEnabled || diagnostics.previousRunWasUnclean {
            diagnostics.warning(
                "Recovery startup active; heavy services are deferred until user action",
                metadata: [
                    "safeMode": String(safeModeEnabled),
                    "previousRunUnclean": String(diagnostics.previousRunWasUnclean),
                ]
            )
            modelStatusMenuItem.title = "Recovery mode · services deferred"
            modelStatusMenuItem.image = NSImage(
                systemSymbolName: "shield.lefthalf.filled",
                accessibilityDescription: nil
            )
            return
        }

        scheduleCoreServicesInitialization()
    }

    private func scheduleArchitectureCompatibilityWarningIfNeeded() {
        guard !uiTestingEnabled,
            !architectureWarningScheduled,
            RuntimeArchitectureCompatibility.shouldWarnAboutRosetta
        else { return }

        architectureWarningScheduled = true
        diagnostics.warning(
            "Intel application build is running through Rosetta on Apple Silicon",
            metadata: [
                "executableArchitecture": "x86_64",
                "nativeArchitecture": "arm64",
            ]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "Intel version on an Apple Silicon Mac"
            alert.informativeText =
                "This copy of VoicePanel was built for Intel and is running through Rosetta. Microphone recording may be unstable. Install VoicePanel-\(self.applicationVersion)-arm64.dmg for this Mac."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Continue Anyway")
            alert.addButton(withTitle: "Quit VoicePanel")
            WindowFocusCoordinator.shared.present(alert) { response in
                if response == .alertSecondButtonReturn {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func configureAppearance() {
        // Keep the application-level appearance system-managed. Individual windows
        // and the compact panel apply their own preferences, so either one can use
        // System without inheriting the other preference.
        AppAppearance.apply(.system, to: NSApp)
    }

    private func configureUITestingDefaults() {
        guard uiTestingEnabled else { return }
        let shouldResetSettings =
            ProcessInfo.processInfo.environment["VOICEPANEL_UI_TEST_RESET_SETTINGS"] == "1"
        guard shouldResetSettings else { return }
        settings.recognitionBackend = .whisper
        settings.recognitionProfile = .recommended
        settings.microphoneEnvironmentProfile = .balanced
        settings.hotKeyReleaseTailEnabled = true
        settings.hotKeyReleaseTailDuration = 0.3
        settings.includeAudioCapturedWhilePreparing = true
        settings.historyStorageMode = .encrypted
        settings.historyRetentionPreset = .thirtyDays
        settings.windowAppearanceMode = .light
        settings.panelAppearanceMode = .dark
    }

    private func configurePanelPreviewIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let previewState = environment["VOICEPANEL_PANEL_PREVIEW"] else { return false }

        state.resetForNewSession(source: .menu)
        state.activeEngineName = "Whisper · Whisper Large v3 Turbo · Q5"
        state.recordingDuration = 8
        for index in 0..<state.audioLevels.count {
            let wave = abs(sin(Double(index) * 0.61))
            let envelope = index.isMultiple(of: 7) ? 0.82 : 0.10 + wave * 0.20
            state.appendAudioLevel(Float(envelope), peakDB: -18)
        }

        let previewText =
            "I’m going to go to the next one. Then maybe we should try a different route. Let me explain what I mean."
        let update = RecognitionUpdate(
            segment: TranscriptSegmentUpdate(
                segmentID: UUID(),
                sequence: 0,
                stableText: previewText,
                partialText: "",
                kind: .segmentFinal
            ),
            shouldDimPartialText: false
        )

        switch previewState {
        case "processing":
            state.phase = .finalizing
        case "success":
            state.applyRecognitionUpdate(update)
            state.finalizeResult()
            state.completionPresentation = .interactive
        case "error":
            state.fail("The recording could not be completed. Please try again.")
        default:
            state.phase = .listening
            state.applyRecognitionUpdate(update)
        }

        let controller = CompactPanelController(
            state: state,
            settings: settings,
            onLatchHotKey: {},
            onStop: {},
            onCancel: {},
            onOpenTranscript: {},
            onImportAudioFile: { _ in },
            onCopy: {},
            onRetry: {},
            onClose: {}
        )
        compactPanel = controller
        controller.show()

        if let previewPath = environment["VOICEPANEL_PANEL_PREVIEW_PATH"] {
            controller.writePreview(to: URL(fileURLWithPath: previewPath)) {
                NSApp.terminate(nil)
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if state.phase == .result || state.phase == .failed {
            coordinator?.dismissResult()
        } else if state.phase.isRecordingRelated || state.phase == .monitoring {
            coordinator?.cancelCurrentSession()
        }
        hotKey.unregister()
        whisperRuntime?.unload()
        whisperDraftRuntime?.unload()
        gigaAMRuntime?.unload()
        gigaAMDraftRuntime?.unload()
        localONNXRuntime?.unload()
        russianCorrectionRuntime?.unload()
        diagnostics.finishApplicationSession()
    }

    private func scheduleCoreServicesInitialization() {
        guard !startupInitializationScheduled else { return }
        startupInitializationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = self.ensureCoreServicesInitialized(
                reason: "automatic startup",
                preloadSelectedBackend: true
            )
        }
    }

    @discardableResult
    private func ensureCoreServicesInitialized(
        reason: String,
        preloadSelectedBackend: Bool = false
    ) -> Bool {
        if coordinator != nil {
            if preloadSelectedBackend {
                prepareSelectedBackendIfNeeded(isStartup: true)
            }
            return true
        }
        guard !coreServicesInitializationInProgress else { return false }
        coreServicesInitializationInProgress = true
        defer { coreServicesInitializationInProgress = false }

        diagnostics.info("Core services bootstrap started", metadata: ["reason": reason])

        diagnostics.info("Startup stage", metadata: ["stage": "whisperRuntime.begin"])
        let whisperRuntime = WhisperRuntimeManager(models: whisperModels)
        self.whisperRuntime = whisperRuntime
        diagnostics.info("Startup stage", metadata: ["stage": "whisperRuntime.ready"])

        diagnostics.info("Startup stage", metadata: ["stage": "whisperDraftRuntime.begin"])
        let whisperDraftRuntime = WhisperRuntimeManager(models: whisperModels)
        self.whisperDraftRuntime = whisperDraftRuntime
        diagnostics.info("Startup stage", metadata: ["stage": "whisperDraftRuntime.ready"])

        diagnostics.info("Startup stage", metadata: ["stage": "gigaAMRuntime.begin"])
        let gigaAMRuntime = GigaAMRuntimeManager(models: gigaAMModels)
        self.gigaAMRuntime = gigaAMRuntime
        diagnostics.info("Startup stage", metadata: ["stage": "gigaAMRuntime.ready"])

        diagnostics.info("Startup stage", metadata: ["stage": "gigaAMDraftRuntime.begin"])
        let gigaAMDraftRuntime = GigaAMRuntimeManager(models: gigaAMModels)
        self.gigaAMDraftRuntime = gigaAMDraftRuntime
        diagnostics.info("Startup stage", metadata: ["stage": "gigaAMDraftRuntime.ready"])

        diagnostics.info("Startup stage", metadata: ["stage": "localONNXRuntime.begin"])
        let localONNXRuntime = LocalONNXRuntimeManager(models: localONNXModels)
        self.localONNXRuntime = localONNXRuntime
        diagnostics.info("Startup stage", metadata: ["stage": "localONNXRuntime.ready"])

        diagnostics.info("Startup stage", metadata: ["stage": "russianCorrectionRuntime.begin"])
        let russianCorrectionRuntime = RussianTextCorrectionRuntimeManager(models: russianCorrectionModels)
        self.russianCorrectionRuntime = russianCorrectionRuntime
        diagnostics.info("Startup stage", metadata: ["stage": "russianCorrectionRuntime.ready"])

        diagnostics.info("Startup stage", metadata: ["stage": "history.begin"])
        let history: HistoryModel
        #if DEBUG
            if uiTestingEnabled {
                let environment = ProcessInfo.processInfo.environment
                let fallbackDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("VoicePanel-UITests-\(UUID().uuidString)", isDirectory: true)
                let directoryURL =
                    environment["VOICEPANEL_UI_TEST_HISTORY_DIRECTORY"]
                    .map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? fallbackDirectory
                history = HistoryModel(uiTestSettings: settings, directoryURL: directoryURL)
            } else {
                history = HistoryModel(settings: settings)
            }
        #else
            history = HistoryModel(settings: settings)
        #endif
        self.history = history
        diagnostics.info("Startup stage", metadata: ["stage": "history.ready"])

        diagnostics.info("Startup stage", metadata: ["stage": "coordinator.begin"])
        let coordinator = TranscriptionCoordinator(
            state: state,
            settings: settings,
            history: history,
            whisperModels: whisperModels,
            whisperRuntime: whisperRuntime,
            whisperDraftRuntime: whisperDraftRuntime,
            gigaAMModels: gigaAMModels,
            gigaAMRuntime: gigaAMRuntime,
            gigaAMDraftRuntime: gigaAMDraftRuntime,
            localONNXModels: localONNXModels,
            localONNXRuntime: localONNXRuntime,
            sileroVADModels: sileroVADModels,
            russianCorrectionModels: russianCorrectionModels,
            russianCorrectionRuntime: russianCorrectionRuntime
        )
        self.coordinator = coordinator
        diagnostics.info("Startup stage", metadata: ["stage": "coordinator.ready"])

        coordinator.onShowCompactPanel = { [weak self] in
            self?.ensureCompactPanelController().show()
        }
        coordinator.onHideCompactPanel = { [weak self] in self?.compactPanel?.hide() }
        coordinator.onShowFullTranscript = { [weak self] in self?.showTranscript() }
        coordinator.onHideFullTranscript = { [weak self] in self?.hideTranscript() }

        installCoreObserversIfNeeded()
        updateModelStatusMenu()
        updateStatusIcon(for: state.phase)
        diagnostics.info("Core services bootstrap completed", metadata: ["reason": reason])

        if preloadSelectedBackend {
            prepareSelectedBackendIfNeeded(isStartup: true)
        }
        return true
    }

    private func installCoreObserversIfNeeded() {
        guard !coreObserversInstalled else { return }
        coreObserversInstalled = true
        observeWhisperRuntime()
        observeWhisperDraftRuntime()
        observeGigaAMRuntime()
        observeGigaAMDraftRuntime()
        observeLocalONNXRuntime()
        observeRecognitionSelection()
        observeSystemWake()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = statusSymbolImage(named: "waveform")
            button.toolTip = "VoicePanel"
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.setAccessibilityLabel("VoicePanel")
            button.target = self
            button.action = #selector(showStatusMenu(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        let menu = NSMenu()
        menu.delegate = self

        recordingMenuItem = NSMenuItem(
            title: "Start Recording",
            action: #selector(toggleMenuRecording),
            keyEquivalent: ""
        )
        recordingMenuItem.target = self
        menu.addItem(recordingMenuItem)

        audioImportMenuItem = NSMenuItem(
            title: "Transcribe Audio File…",
            action: #selector(transcribeAudioFileAction),
            keyEquivalent: ""
        )
        audioImportMenuItem.target = self
        menu.addItem(audioImportMenuItem)

        modelStatusMenuItem = NSMenuItem(title: "Apple Speech · Ready", action: nil, keyEquivalent: "")
        modelStatusMenuItem.isEnabled = false
        menu.addItem(modelStatusMenuItem)

        menu.addItem(.separator())

        transcriptMenuItem = NSMenuItem(
            title: "Show Transcript",
            action: #selector(showTranscriptAction),
            keyEquivalent: ""
        )
        transcriptMenuItem.target = self
        menu.addItem(transcriptMenuItem)

        historyMenuItem = NSMenuItem(
            title: "History…",
            action: #selector(showHistoryAction),
            keyEquivalent: ""
        )
        historyMenuItem.target = self
        historyMenuItem.setAccessibilityIdentifier("status-menu.history")
        historyMenuItem.setAccessibilityLabel(historyMenuItem.title)
        menu.addItem(historyMenuItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettingsAction),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        advancedMenuSeparator = .separator()
        advancedMenuSeparator.isHidden = true
        menu.addItem(advancedMenuSeparator)

        recoveryResetMenuItem = NSMenuItem(
            title: "Use Apple Speech (Recovery)",
            action: #selector(resetRecognitionToAppleSpeech),
            keyEquivalent: ""
        )
        recoveryResetMenuItem.target = self
        recoveryResetMenuItem.isHidden = true
        menu.addItem(recoveryResetMenuItem)

        logsMenuItem = NSMenuItem(
            title: "Open Logs Folder",
            action: #selector(openLogsFolder),
            keyEquivalent: ""
        )
        logsMenuItem.target = self
        logsMenuItem.isHidden = true
        menu.addItem(logsMenuItem)

        resetSettingsMenuItem = NSMenuItem(
            title: "Reset Settings and Quit…",
            action: #selector(resetSettingsAndQuit),
            keyEquivalent: ""
        )
        resetSettingsMenuItem.target = self
        resetSettingsMenuItem.isHidden = true
        menu.addItem(resetSettingsMenuItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit VoicePanel",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusMenu = menu
        updateModelStatusMenu()
        updateStatusIcon(for: state.phase)
    }

    private func registerHotKey() {
        hotKey.register(
            preset: settings.hotKeyPreset,
            onPressed: { [weak self] in self?.handleHotKeyPressed() },
            onReleased: { [weak self] in self?.handleHotKeyReleased() }
        )
    }

    private func observeState() {
        state.$phase
            .sink { [weak self] phase in
                guard let self else { return }
                self.updateStatusIcon(for: phase)
                if phase == .idle || phase == .monitoring || phase == .cancelled {
                    self.compactPanel?.hide()
                }
            }
            .store(in: &cancellables)
    }

    private func observeWhisperRuntime() {
        guard let whisperRuntime else { return }
        whisperRuntime.$state
            .sink { [weak self] runtimeState in
                guard let self else { return }
                self.handleRuntimeStateChange(
                    title: runtimeState.menuTitle,
                    isRelevantWhilePreparing: self.settings.recognitionBackend == .whisper
                )
            }
            .store(in: &cancellables)
    }

    private func observeWhisperDraftRuntime() {
        guard let whisperDraftRuntime else { return }
        whisperDraftRuntime.$state
            .sink { [weak self] runtimeState in
                guard let self else { return }
                self.handleRuntimeStateChange(
                    title: runtimeState.menuTitle,
                    isRelevantWhilePreparing: self.settings.recognitionBackend == .whisper
                        && self.settings.whisperDraftSource == .localWhisper
                )
            }
            .store(in: &cancellables)
    }

    private func observeGigaAMRuntime() {
        guard let gigaAMRuntime else { return }
        gigaAMRuntime.$state
            .sink { [weak self] runtimeState in
                guard let self else { return }
                self.handleRuntimeStateChange(
                    title: runtimeState.menuTitle,
                    isRelevantWhilePreparing: self.settings.recognitionBackend == .gigaAM
                )
            }
            .store(in: &cancellables)
    }

    private func observeGigaAMDraftRuntime() {
        guard let gigaAMDraftRuntime else { return }
        gigaAMDraftRuntime.$state
            .sink { [weak self] runtimeState in
                guard let self else { return }
                self.handleRuntimeStateChange(
                    title: runtimeState.menuTitle,
                    isRelevantWhilePreparing: self.settings.recognitionBackend == .gigaAM
                        && self.settings.gigaAMDraftSource == .localGigaAM
                )
            }
            .store(in: &cancellables)
    }

    private func observeLocalONNXRuntime() {
        guard let localONNXRuntime else { return }
        localONNXRuntime.$state
            .sink { [weak self] runtimeState in
                guard let self else { return }
                self.handleRuntimeStateChange(
                    title: runtimeState.menuTitle,
                    isRelevantWhilePreparing: self.settings.recognitionBackend == .qwen3ASR
                        || self.settings.recognitionBackend == .parakeet
                )
            }
            .store(in: &cancellables)
    }

    private func handleRuntimeStateChange(
        title: String,
        isRelevantWhilePreparing: Bool
    ) {
        updateModelStatusMenu()
        updateStatusIcon(for: state.phase)
        if isRelevantWhilePreparing, state.phase == .preparing {
            state.statusMessage = title
        }
    }

    private func observeRecognitionSelection() {
        settings.$recognitionBackend
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.recognitionSelectionDidChange() }
            .store(in: &cancellables)
        settings.$whisperModelID
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.recognitionSelectionDidChange(reconcileDrafts: true) }
            .store(in: &cancellables)
        settings.$whisperDraftSource
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.recognitionSelectionDidChange(reconcileDrafts: true) }
            .store(in: &cancellables)
        settings.$whisperDraftModelID
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.recognitionSelectionDidChange() }
            .store(in: &cancellables)
        settings.$whisperLanguageCode
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.recognitionSelectionDidChange(reconcileDrafts: true) }
            .store(in: &cancellables)
        settings.$whisperComputeMode
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.recognitionSelectionDidChange() }
            .store(in: &cancellables)
        settings.$whisperFlashAttention
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.recognitionSelectionDidChange() }
            .store(in: &cancellables)
        settings.$gigaAMModelID
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.recognitionSelectionDidChange(reconcileDrafts: true) }
            .store(in: &cancellables)
        settings.$gigaAMDraftSource
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.recognitionSelectionDidChange(reconcileDrafts: true) }
            .store(in: &cancellables)
        settings.$gigaAMDraftModelID
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.recognitionSelectionDidChange() }
            .store(in: &cancellables)
        settings.$gigaAMThreadCount
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.recognitionSelectionDidChange() }
            .store(in: &cancellables)
        settings.$gigaAMExecutionProvider
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.recognitionSelectionDidChange() }
            .store(in: &cancellables)
        settings.$qwen3ASRModelID
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.recognitionSelectionDidChange() }
            .store(in: &cancellables)
        settings.$localONNXDraftSource
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.recognitionSelectionDidChange() }
            .store(in: &cancellables)
        settings.$localONNXThreadCount
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.recognitionSelectionDidChange() }
            .store(in: &cancellables)
        settings.$localONNXExecutionProvider
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.recognitionSelectionDidChange() }
            .store(in: &cancellables)
    }

    private func recognitionSelectionDidChange(reconcileDrafts: Bool = false) {
        guard !state.phase.isRecordingRelated,
            !isReconcilingRecognitionSelection
        else { return }
        isReconcilingRecognitionSelection = true
        defer { isReconcilingRecognitionSelection = false }

        if reconcileDrafts {
            settings.reconcileDraftSelections()
        }
        diagnostics.clearPreviousModelLoadBreadcrumb()
        prepareSelectedBackendIfNeeded()
        updateModelStatusMenu()
        updateStatusIcon(for: state.phase)
    }

    private func prepareSelectedBackendIfNeeded(isStartup: Bool = false) {
        guard let whisperRuntime,
            let whisperDraftRuntime,
            let gigaAMRuntime,
            let gigaAMDraftRuntime,
            let localONNXRuntime
        else { return }
        if isStartup, safeModeEnabled {
            diagnostics.warning("Safe mode enabled; automatic model preload skipped")
            markSelectedBackendWithoutPreloading()
            return
        }

        if isStartup, let breadcrumb = diagnostics.previousModelLoadBreadcrumb {
            diagnostics.warning(
                "Automatic model preload skipped after previous model-load crash",
                metadata: ["engine": breadcrumb.engine, "model": breadcrumb.modelID]
            )
            markSelectedBackendWithoutPreloading(recoveryBreadcrumb: breadcrumb)
            return
        }

        switch settings.recognitionBackend {
        case .appleSpeech:
            whisperRuntime.unload()
            whisperDraftRuntime.unload()
            gigaAMRuntime.unload()
            gigaAMDraftRuntime.unload()
            localONNXRuntime.unload()

        case .whisper:
            gigaAMRuntime.unload()
            gigaAMDraftRuntime.unload()
            localONNXRuntime.unload()
            prepareWhisperRuntime(whisperRuntime, model: settings.whisperModelID)

            if settings.whisperDraftSource == .localWhisper {
                prepareWhisperRuntime(whisperDraftRuntime, model: settings.whisperDraftModelID)
            } else {
                whisperDraftRuntime.unload()
            }

        case .gigaAM:
            whisperRuntime.unload()
            whisperDraftRuntime.unload()
            localONNXRuntime.unload()
            prepareGigaAMRuntime(gigaAMRuntime, model: settings.gigaAMModelID)

            if settings.gigaAMDraftSource == .localGigaAM {
                prepareGigaAMRuntime(gigaAMDraftRuntime, model: settings.gigaAMDraftModelID)
            } else {
                gigaAMDraftRuntime.unload()
            }

        case .qwen3ASR, .parakeet:
            whisperRuntime.unload()
            whisperDraftRuntime.unload()
            gigaAMRuntime.unload()
            gigaAMDraftRuntime.unload()
            if let model = settings.selectedLocalONNXModel {
                prepareLocalONNXRuntime(localONNXRuntime, model: model)
            } else {
                localONNXRuntime.unload()
            }
        }
    }

    private func markSelectedBackendWithoutPreloading(
        recoveryBreadcrumb: ModelLoadBreadcrumb? = nil
    ) {
        guard let whisperRuntime,
            let whisperDraftRuntime,
            let gigaAMRuntime,
            let gigaAMDraftRuntime,
            let localONNXRuntime
        else { return }
        switch settings.recognitionBackend {
        case .appleSpeech:
            whisperRuntime.unload()
            whisperDraftRuntime.unload()
            gigaAMRuntime.unload()
            gigaAMDraftRuntime.unload()
            localONNXRuntime.unload()

        case .whisper:
            gigaAMRuntime.unload()
            gigaAMDraftRuntime.unload()
            localONNXRuntime.unload()
            markWhisperRuntimeWithoutPreloading(
                whisperRuntime,
                model: settings.whisperModelID,
                recoveryBreadcrumb: recoveryBreadcrumb
            )
            if settings.whisperDraftSource == .localWhisper {
                markWhisperRuntimeWithoutPreloading(
                    whisperDraftRuntime,
                    model: settings.whisperDraftModelID,
                    recoveryBreadcrumb: recoveryBreadcrumb
                )
            } else {
                whisperDraftRuntime.unload()
            }

        case .gigaAM:
            whisperRuntime.unload()
            whisperDraftRuntime.unload()
            localONNXRuntime.unload()
            markGigaAMRuntimeWithoutPreloading(
                gigaAMRuntime,
                model: settings.gigaAMModelID,
                recoveryBreadcrumb: recoveryBreadcrumb
            )
            if settings.gigaAMDraftSource == .localGigaAM {
                markGigaAMRuntimeWithoutPreloading(
                    gigaAMDraftRuntime,
                    model: settings.gigaAMDraftModelID,
                    recoveryBreadcrumb: recoveryBreadcrumb
                )
            } else {
                gigaAMDraftRuntime.unload()
            }

        case .qwen3ASR, .parakeet:
            whisperRuntime.unload()
            whisperDraftRuntime.unload()
            gigaAMRuntime.unload()
            gigaAMDraftRuntime.unload()
            if let model = settings.selectedLocalONNXModel {
                markLocalONNXRuntimeWithoutPreloading(
                    localONNXRuntime,
                    model: model,
                    recoveryBreadcrumb: recoveryBreadcrumb
                )
            } else {
                localONNXRuntime.unload()
            }
        }
    }

    private func markWhisperRuntimeWithoutPreloading(
        _ runtime: WhisperRuntimeManager,
        model: WhisperModelID,
        recoveryBreadcrumb: ModelLoadBreadcrumb?
    ) {
        if recoveryBreadcrumb?.engine == "whisper",
            recoveryBreadcrumb?.modelID == model.rawValue
        {
            runtime.markRecoveryBlocked(model)
        } else {
            runtime.markSelected(
                model,
                runtimeConfiguration: settings.whisperRuntimeConfiguration
            )
        }
    }

    private func markGigaAMRuntimeWithoutPreloading(
        _ runtime: GigaAMRuntimeManager,
        model: GigaAMModelID,
        recoveryBreadcrumb: ModelLoadBreadcrumb?
    ) {
        if recoveryBreadcrumb?.engine == "gigaam",
            recoveryBreadcrumb?.modelID == model.rawValue
        {
            runtime.markRecoveryBlocked(model)
        } else {
            runtime.markSelected(model)
        }
    }

    private func markLocalONNXRuntimeWithoutPreloading(
        _ runtime: LocalONNXRuntimeManager,
        model: LocalONNXModelID,
        recoveryBreadcrumb: ModelLoadBreadcrumb?
    ) {
        if recoveryBreadcrumb?.engine == model.family.rawValue,
            recoveryBreadcrumb?.modelID == model.rawValue
        {
            runtime.markRecoveryBlocked(model)
        } else {
            runtime.markSelected(model)
        }
    }

    private var applicationVersion: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return shortVersion ?? "development"
    }

    private func prepareWhisperRuntime(
        _ runtime: WhisperRuntimeManager,
        model: WhisperModelID
    ) {
        if whisperModels.isInstalled(model) {
            runtime.preloadIfInstalled(
                model,
                runtimeConfiguration: settings.whisperRuntimeConfiguration
            )
        } else {
            runtime.markSelected(
                model,
                runtimeConfiguration: settings.whisperRuntimeConfiguration
            )
        }
    }

    private func prepareGigaAMRuntime(
        _ runtime: GigaAMRuntimeManager,
        model: GigaAMModelID
    ) {
        if gigaAMModels.isInstalled(model) {
            runtime.preloadIfInstalled(
                model,
                numberOfThreads: settings.gigaAMThreadCount,
                provider: settings.gigaAMExecutionProvider.runtimeValue
            )
        } else {
            runtime.markSelected(model)
        }
    }

    private func prepareLocalONNXRuntime(
        _ runtime: LocalONNXRuntimeManager,
        model: LocalONNXModelID
    ) {
        if localONNXModels.isInstalled(model) {
            runtime.preloadIfInstalled(
                model,
                numberOfThreads: settings.localONNXThreadCount,
                provider: settings.localONNXExecutionProvider.runtimeValue
            )
        } else {
            runtime.markSelected(model)
        }
    }

    private func observeSystemWake() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                self?.history?.applyRetentionPolicy()
                self?.prepareSelectedBackendIfNeeded()
            }
            .store(in: &cancellables)
    }

    private func updateStatusIcon(for phase: AppState.Phase) {
        let symbol: String
        switch phase {
        case .preparing, .stopping, .finalizing:
            symbol = "waveform.badge.magnifyingglass"
        case .listening:
            symbol = "waveform.circle.fill"
        case .result:
            symbol = "checkmark.circle"
        case .failed:
            symbol = "exclamationmark.triangle"
        default:
            symbol = "waveform"
        }

        let loadingBadge: Bool
        switch settings.recognitionBackend {
        case .appleSpeech: loadingBadge = false
        case .whisper:
            loadingBadge =
                (whisperRuntime?.state.isPreparing ?? false)
                || (settings.whisperDraftSource == .localWhisper
                    && (whisperDraftRuntime?.state.isPreparing ?? false))
        case .gigaAM:
            loadingBadge =
                (gigaAMRuntime?.state.isPreparing ?? false)
                || (settings.gigaAMDraftSource == .localGigaAM
                    && (gigaAMDraftRuntime?.state.isPreparing ?? false))
        case .qwen3ASR, .parakeet:
            loadingBadge = localONNXRuntime?.state.isPreparing ?? false
        }
        guard let button = statusItem.button else { return }
        button.image = makeStatusImage(
            symbolName: symbol,
            badgeColor: loadingBadge ? .systemCyan : nil
        )
        button.title = ""
        statusItem.length = NSStatusItem.squareLength
    }

    private func makeStatusImage(symbolName: String, badgeColor: NSColor?) -> NSImage {
        let base = statusSymbolImage(named: symbolName)
        guard let badgeColor else {
            base.isTemplate = true
            return base
        }

        let size = NSSize(width: 19, height: 19)
        let image = NSImage(size: size)
        image.lockFocus()
        let baseRect = NSRect(x: 0.5, y: 0.5, width: 17, height: 17)
        base.draw(in: baseRect)
        badgeColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 12.5, y: 1, width: 5.5, height: 5.5)).fill()
        NSColor.windowBackgroundColor.setStroke()
        let border = NSBezierPath(ovalIn: NSRect(x: 12.5, y: 1, width: 5.5, height: 5.5))
        border.lineWidth = 1
        border.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func statusSymbolImage(named symbolName: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        if let symbol = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "VoicePanel"
        )?.withSymbolConfiguration(configuration) {
            return symbol
        }

        // Some SF Symbols are not present on every supported macOS release.
        // Always provide a visible template fallback instead of leaving a blank
        // square in the menu bar.
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.labelColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.7
        path.lineCapStyle = .round
        let xValues: [CGFloat] = [2, 5.5, 9, 12.5, 16]
        let halfHeights: [CGFloat] = [2.5, 5.5, 7.5, 4.5, 2]
        for (x, halfHeight) in zip(xValues, halfHeights) {
            path.move(to: NSPoint(x: x, y: 9 - halfHeight))
            path.line(to: NSPoint(x: x, y: 9 + halfHeight))
        }
        path.stroke()
        image.unlockFocus()
        image.isTemplate = true
        image.accessibilityDescription = "VoicePanel"
        return image
    }

    private func updateModelStatusMenu() {
        guard modelStatusMenuItem != nil else { return }
        switch settings.recognitionBackend {
        case .appleSpeech:
            modelStatusMenuItem.title = "Apple Speech · Ready"
            modelStatusMenuItem.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        case .whisper:
            guard let whisperRuntime else {
                modelStatusMenuItem.title = "Whisper · Starting…"
                modelStatusMenuItem.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)
                return
            }
            if settings.whisperDraftSource == .localWhisper,
                let whisperDraftRuntime,
                whisperDraftRuntime.state.isPreparing
            {
                modelStatusMenuItem.title =
                    "\(whisperRuntime.state.menuTitle) · Draft: \(whisperDraftRuntime.state.menuTitle)"
            } else {
                modelStatusMenuItem.title = whisperRuntime.state.menuTitle
            }
            modelStatusMenuItem.image = NSImage(
                systemSymbolName: modelStatusSymbol(for: whisperRuntime.state),
                accessibilityDescription: nil
            )
        case .gigaAM:
            guard let gigaAMRuntime else {
                modelStatusMenuItem.title = "GigaAM · Starting…"
                modelStatusMenuItem.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)
                return
            }
            if settings.gigaAMDraftSource == .localGigaAM,
                let gigaAMDraftRuntime,
                gigaAMDraftRuntime.state.isPreparing
            {
                modelStatusMenuItem.title =
                    "\(gigaAMRuntime.state.menuTitle) · Draft: \(gigaAMDraftRuntime.state.menuTitle)"
            } else {
                modelStatusMenuItem.title = gigaAMRuntime.state.menuTitle
            }
            modelStatusMenuItem.image = NSImage(
                systemSymbolName: modelStatusSymbol(for: gigaAMRuntime.state),
                accessibilityDescription: nil
            )
        case .qwen3ASR, .parakeet:
            guard let localONNXRuntime else {
                modelStatusMenuItem.title = "\(settings.recognitionBackend.title) · Starting…"
                modelStatusMenuItem.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)
                return
            }
            modelStatusMenuItem.title = localONNXRuntime.state.menuTitle
            modelStatusMenuItem.image = NSImage(
                systemSymbolName: modelStatusSymbol(for: localONNXRuntime.state),
                accessibilityDescription: nil
            )
        }
    }

    private func modelStatusSymbol(for state: WhisperRuntimeLoadState) -> String {
        switch state {
        case .downloading: return "arrow.down.circle"
        case .verifying, .loading: return "hourglass"
        case .ready: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .notInstalled: return "externaldrive.badge.plus"
        case .inactive: return "circle.dotted"
        }
    }

    private func modelStatusSymbol(for state: GigaAMRuntimeLoadState) -> String {
        switch state {
        case .downloading: return "arrow.down.circle"
        case .verifying, .loading: return "hourglass"
        case .ready: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .notInstalled: return "externaldrive.badge.plus"
        case .inactive: return "circle.dotted"
        }
    }

    private func modelStatusSymbol(for state: LocalONNXRuntimeLoadState) -> String {
        switch state {
        case .downloading: return "arrow.down.circle"
        case .verifying, .loading: return "hourglass"
        case .ready: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .notInstalled: return "externaldrive.badge.plus"
        case .inactive: return "circle.dotted"
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateAdvancedStatusMenuItems()
        guard let coordinator, let history else {
            recordingMenuItem.title = "Start Recording"
            recordingMenuItem.isEnabled = true
            audioImportMenuItem.isEnabled = true
            transcriptMenuItem.isEnabled = !state.combinedTranscript.isEmpty
            historyMenuItem.title = "History…"
            historyMenuItem.setAccessibilityLabel(historyMenuItem.title)
            updateModelStatusMenu()
            return
        }
        switch state.phase {
        case .listening:
            if coordinator.canToggleRecordingFromMenu {
                recordingMenuItem.title = "Stop Recording"
                recordingMenuItem.isEnabled = true
            } else {
                recordingMenuItem.title = "Recording via Hot Key…"
                recordingMenuItem.isEnabled = false
            }
        case .preparing:
            if coordinator.canToggleRecordingFromMenu {
                recordingMenuItem.title = "Cancel Starting"
                recordingMenuItem.isEnabled = true
            } else {
                recordingMenuItem.title =
                    state.isImportingAudioFile
                    ? "Importing Audio…"
                    : "Waiting for Model…"
                recordingMenuItem.isEnabled = false
            }
        case .stopping, .finalizing:
            recordingMenuItem.title = "Finalizing…"
            recordingMenuItem.isEnabled = false
        case .monitoring:
            recordingMenuItem.title = "Stop Input Test"
            recordingMenuItem.isEnabled = true
        default:
            recordingMenuItem.title = "Start Recording"
            recordingMenuItem.isEnabled = true
        }
        audioImportMenuItem.isEnabled = state.canStartRecording
        updateModelStatusMenu()
        transcriptMenuItem.isEnabled =
            !state.combinedTranscript.isEmpty || state.phase.isRecordingRelated || state.phase == .failed
        historyMenuItem.title = history.records.isEmpty ? "History…" : "History… (\(history.records.count))"
        historyMenuItem.setAccessibilityLabel(historyMenuItem.title)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusMenuAdvancedItemsRequested = false
        setAdvancedStatusMenuItemsVisible(false)
        statusItem.button?.highlight(false)
    }

    @objc private func showStatusMenu(_ sender: NSStatusBarButton) {
        let eventModifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        let optionPressed =
            eventModifiers
            .intersection(.deviceIndependentFlagsMask)
            .contains(.option)
        statusMenuAdvancedItemsRequested = StatusMenuAdvancedItemsPolicy.shouldShow(
            optionModifierIsPressed: optionPressed
        )
        setAdvancedStatusMenuItemsVisible(statusMenuAdvancedItemsRequested)

        sender.highlight(true)
        statusMenu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.bounds.minY - 2),
            in: sender
        )
    }

    private func updateAdvancedStatusMenuItems() {
        setAdvancedStatusMenuItemsVisible(statusMenuAdvancedItemsRequested)
        recoveryResetMenuItem.isEnabled = settings.recognitionBackend != .appleSpeech
    }

    private func setAdvancedStatusMenuItemsVisible(_ visible: Bool) {
        advancedMenuSeparator.isHidden = !visible
        recoveryResetMenuItem.isHidden = !visible
        logsMenuItem.isHidden = !visible
        resetSettingsMenuItem.isHidden = !visible
    }

    private func handleHotKeyPressed() {
        guard ensureCoreServicesInitialized(reason: "hot key pressed"), let coordinator else { return }
        coordinator.startHotKeyRecording()
    }

    private func handleHotKeyReleased() {
        guard let coordinator else { return }
        coordinator.stopHotKeyRecording()
    }

    @objc private func toggleMenuRecording() {
        if uiTestingEnabled {
            toggleUITestRecording()
            return
        }
        guard ensureCoreServicesInitialized(reason: "menu recording"), let coordinator else { return }
        if state.phase == .monitoring {
            coordinator.stopMonitoring()
        } else {
            coordinator.toggleMenuRecording()
        }
    }

    @objc private func transcribeAudioFileAction() {
        if uiTestingEnabled, ProcessInfo.processInfo.environment["VOICEPANEL_UI_TEST_IMPORT_FIXTURE"] == "1" {
            runUITestImportFixture()
            return
        }
        guard ensureCoreServicesInitialized(reason: "audio file import"), let coordinator else { return }
        let panel = NSOpenPanel()
        panel.title = "Transcribe Audio File"
        panel.prompt = "Transcribe"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        WindowFocusCoordinator.shared.present(panel) { [weak self, weak coordinator, weak panel] response in
            guard response == .OK, let url = panel?.url else { return }
            self?.fullTranscriptReplacesCompactPanel = false
            coordinator?.transcribeAudioFile(at: url)
        }
        scheduleUITestFilePanelDismissalIfNeeded(panel)
    }

    private func importDroppedAudioFile(_ url: URL) {
        guard ensureCoreServicesInitialized(reason: "dropped audio file"), let coordinator else { return }
        coordinator.transcribeAudioFile(at: url)
    }

    private func scheduleUITestFilePanelDismissalIfNeeded(_ panel: NSOpenPanel) {
        guard uiTestingEnabled,
            ProcessInfo.processInfo.environment["VOICEPANEL_UI_TEST_AUTO_DISMISS_FILE_PANEL"] == "1"
        else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak panel] in
            guard let panel, panel.isVisible else { return }
            panel.cancel(nil)
        }
    }

    @objc private func showTranscriptAction() {
        showTranscript()
    }

    private func showTranscript() {
        guard ensureCoreServicesInitialized(reason: "show transcript") else { return }
        ensureTranscriptWindowController().show()
    }

    private func showTranscriptFromCompactPanel() {
        guard ensureCoreServicesInitialized(reason: "show transcript from panel") else { return }
        fullTranscriptReplacesCompactPanel = true
        compactPanel?.hide()
        ensureTranscriptWindowController().show()
    }

    private func hideTranscript() {
        transcriptWindow?.hide()
        let shouldRestoreCompactPanel =
            fullTranscriptReplacesCompactPanel && state.phase.isRecordingRelated
        fullTranscriptReplacesCompactPanel = false
        if shouldRestoreCompactPanel {
            ensureCompactPanelController().show()
        }
    }

    @objc private func showHistoryAction() {
        guard ensureCoreServicesInitialized(reason: "show history") else { return }
        ensureHistoryWindowController().show()
    }

    @objc private func showSettingsAction() {
        guard ensureCoreServicesInitialized(reason: "show settings") else { return }
        let revealsDebugOptions = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        ensureSettingsWindowController().show(revealsDebugOptions: revealsDebugOptions)
    }

    private func ensureCompactPanelController() -> CompactPanelController {
        if let compactPanel { return compactPanel }
        diagnostics.info("Startup stage", metadata: ["stage": "compactPanel.begin"])
        let controller = CompactPanelController(
            state: state,
            settings: settings,
            onLatchHotKey: { [weak self] in self?.coordinator?.latchHotKeyRecording() },
            onStop: { [weak self] in
                if self?.uiTestingEnabled == true {
                    self?.finishUITestRecognition()
                } else {
                    self?.coordinator?.stopRecording()
                }
            },
            onCancel: { [weak self] in
                if self?.uiTestingEnabled == true {
                    self?.cancelUITestSession()
                } else {
                    self?.coordinator?.cancelCurrentSession()
                }
            },
            onOpenTranscript: { [weak self] in self?.showTranscriptFromCompactPanel() },
            onImportAudioFile: { [weak self] url in self?.importDroppedAudioFile(url) },
            onCopy: { [weak self] in self?.copyResultForCurrentRuntime() },
            onRetry: { [weak self] in self?.retryResultForCurrentRuntime() },
            onClose: { [weak self] in self?.closeResultForCurrentRuntime() },
            onDisplayFrame: { [weak self] in
                self?.coordinator?.flushCaptureMetricsForDisplay()
            }
        )
        compactPanel = controller
        diagnostics.info("Startup stage", metadata: ["stage": "compactPanel.ready"])
        return controller
    }

    private func ensureTranscriptWindowController() -> FullTranscriptWindowController {
        if let transcriptWindow { return transcriptWindow }
        diagnostics.info("Startup stage", metadata: ["stage": "transcriptWindow.begin"])
        let controller = FullTranscriptWindowController(
            state: state,
            settings: settings,
            onImportAudioFile: { [weak self] url in self?.importDroppedAudioFile(url) },
            onCancel: { [weak self] in self?.coordinator?.cancelCurrentSession() },
            onCopy: { [weak self] in self?.coordinator?.copyFromTranscriptWindow() },
            onClose: { [weak self] in self?.coordinator?.closeFullTranscript() },
            onDisplayFrame: { [weak self] in
                self?.coordinator?.flushCaptureMetricsForDisplay()
            }
        )
        transcriptWindow = controller
        diagnostics.info("Startup stage", metadata: ["stage": "transcriptWindow.ready"])
        return controller
    }

    private func ensureHistoryWindowController() -> HistoryWindowController {
        if let historyWindow { return historyWindow }
        precondition(history != nil)
        diagnostics.info("Startup stage", metadata: ["stage": "historyWindow.begin"])
        let controller = HistoryWindowController(history: history!, settings: settings)
        historyWindow = controller
        diagnostics.info("Startup stage", metadata: ["stage": "historyWindow.ready"])
        return controller
    }

    private func ensureSettingsWindowController() -> SettingsWindowController {
        if let settingsWindow { return settingsWindow }
        precondition(
            coordinator != nil
                && whisperRuntime != nil
                && whisperDraftRuntime != nil
                && gigaAMRuntime != nil
                && gigaAMDraftRuntime != nil
                && localONNXRuntime != nil
                && russianCorrectionRuntime != nil
                && history != nil
        )
        diagnostics.info("Startup stage", metadata: ["stage": "settingsWindow.begin"])
        let controller = SettingsWindowController(
            settings: settings,
            state: state,
            coordinator: coordinator!,
            whisperModels: whisperModels,
            whisperRuntime: whisperRuntime!,
            whisperDraftRuntime: whisperDraftRuntime!,
            gigaAMModels: gigaAMModels,
            gigaAMRuntime: gigaAMRuntime!,
            gigaAMDraftRuntime: gigaAMDraftRuntime!,
            localONNXModels: localONNXModels,
            localONNXRuntime: localONNXRuntime!,
            sileroVADModels: sileroVADModels,
            russianCorrectionModels: russianCorrectionModels,
            russianCorrectionRuntime: russianCorrectionRuntime!,
            history: history!,
            onHotKeyChanged: { [weak self] in self?.registerHotKey() },
            onOpenAudioFileChooser: { [weak self] in self?.transcribeAudioFileAction() }
        )
        settingsWindow = controller
        diagnostics.info("Startup stage", metadata: ["stage": "settingsWindow.ready"])
        return controller
    }

    private func toggleUITestRecording() {
        switch state.phase {
        case .idle, .result, .failed, .cancelled:
            beginUITestRecording()
        case .preparing, .listening:
            finishUITestRecognition()
        default:
            break
        }
    }

    private func beginUITestRecording() {
        uiTestRecognitionAttempt += 1
        state.resetForNewSession(source: .menu)
        state.activeEngineName = "Deterministic UI Test Recognizer"
        state.phase = .preparing
        state.updatePreparation(status: "Waiting for test audio…", waitingForRecognizer: true)
        ensureCompactPanelController().show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self, self.state.phase == .preparing else { return }
            self.state.clearPreparation()
            self.state.phase = .listening
            self.state.statusMessage = "Recording"
            self.state.recordingDuration = 1.25
            for index in 0..<self.state.audioLevels.count {
                self.state.appendAudioLevel(index.isMultiple(of: 3) ? 0.72 : 0.24, peakDB: -18)
            }
        }
    }

    private func finishUITestRecognition() {
        guard state.phase == .preparing || state.phase == .listening else { return }
        state.phase = .stopping
        state.statusMessage = "Stopping recording…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.state.phase = .finalizing
            self.state.statusMessage = "Processing"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                guard let self, self.state.phase == .finalizing else { return }
                if ProcessInfo.processInfo.environment["VOICEPANEL_UI_TEST_RECOGNIZER_FAILURE"] == "1",
                    self.uiTestRecognitionAttempt == 1
                {
                    self.state.fail("Deterministic recognizer failure")
                    return
                }
                self.completeUITestRecognition(imported: false)
            }
        }
    }

    private func completeUITestRecognition(imported: Bool) {
        let update = RecognitionUpdate(
            segment: TranscriptSegmentUpdate(
                segmentID: UUID(), sequence: 0, stableText: uiTestTranscript, partialText: "", kind: .sessionFinal
            ),
            shouldDimPartialText: false
        )
        state.applyRecognitionUpdate(update)
        state.finalizeResult()
        state.completionPresentation = .interactive
        _ = history?.upsert(
            TranscriptHistoryRecord(
                text: uiTestTranscript, duration: imported ? 2.0 : 1.25,
                languageIdentifier: "en-US", engineName: "Deterministic UI Test Recognizer"
            )
        )
    }

    private func cancelUITestSession() {
        state.discardTranscriptContent()
        state.phase = .cancelled
        state.statusMessage = "Cancelled"
        compactPanel?.hide()
    }

    private func retryResultForCurrentRuntime() {
        guard uiTestingEnabled else {
            coordinator?.startRecording(initiator: .menu)
            return
        }
        state.lastError = nil
        state.phase = .finalizing
        state.statusMessage = "Processing"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.completeUITestRecognition(imported: false)
        }
    }

    private func copyResultForCurrentRuntime() {
        if uiTestingEnabled { copyUITestTranscript() } else { coordinator?.copyResultWithFeedback() }
    }

    private func copyUITestTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.editableText, forType: .string)
    }

    private func closeResultForCurrentRuntime() {
        if uiTestingEnabled {
            state.phase = .idle
            state.discardTranscriptContent()
            compactPanel?.hide()
        } else {
            coordinator?.dismissResult()
        }
    }

    private func runUITestImportFixture() {
        state.resetForNewSession(source: .menu)
        state.activeEngineName = "Deterministic UI Test Recognizer"
        state.phase = .preparing
        state.updatePreparation(
            status: "Importing test audio…", progress: 0.25, waitingForRecognizer: false, importingAudioFile: true
        )
        ensureCompactPanelController().show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self else { return }
            self.state.phase = .finalizing
            self.state.statusMessage = "Processing imported audio"
            self.state.updateAudioImportProgress(
                AudioImportProgress(
                    stage: .transcribing, currentChunk: 1, completedChunks: 1, totalChunks: 2,
                    completedAudioDuration: 1, totalAudioDuration: 2, elapsedProcessingDuration: 0.2))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                self?.completeUITestRecognition(imported: true)
            }
        }
    }

    @objc private func resetRecognitionToAppleSpeech() {
        diagnostics.warning("Recognition backend reset to Apple Speech from recovery menu")
        settings.recognitionBackend = .appleSpeech
        diagnostics.clearPreviousModelLoadBreadcrumb()
        whisperRuntime?.unload()
        whisperDraftRuntime?.unload()
        gigaAMRuntime?.unload()
        gigaAMDraftRuntime?.unload()
        localONNXRuntime?.unload()
        updateModelStatusMenu()
        updateStatusIcon(for: state.phase)
    }

    @objc private func openLogsFolder() {
        NSWorkspace.shared.open(diagnostics.logsDirectory)
    }

    @objc private func resetSettingsAndQuit() {
        let alert = NSAlert()
        alert.messageText = "Reset VoicePanel settings?"
        alert.informativeText =
            "This resets preferences and recovery markers. Downloaded models and transcript history are preserved. VoicePanel will quit after the reset."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset and Quit")
        alert.addButton(withTitle: "Cancel")
        WindowFocusCoordinator.shared.present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let domain = Bundle.main.bundleIdentifier ?? "io.github.dra1ex.VoicePanel"
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard.removePersistentDomain(forName: "dev.voicepanel.prototype")
            UserDefaults.standard.synchronize()
            self.diagnostics.clearPreviousModelLoadBreadcrumb()
            self.diagnostics.info(
                "Settings reset requested from menu",
                metadata: ["domain": domain]
            )
            NSApp.terminate(nil)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
