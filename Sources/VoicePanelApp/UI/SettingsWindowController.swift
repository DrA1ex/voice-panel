import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsPresentationContext: ObservableObject {
    @Published var showsDebugOptions = false
    @Published var isVisible = false
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private var cancellables = Set<AnyCancellable>()
    private let presentationContext = SettingsPresentationContext()
    private let coordinator: TranscriptionCoordinator
    private let displayLink: WindowDisplayLinkDriver

    init(
        settings: AppSettings,
        state: AppState,
        coordinator: TranscriptionCoordinator,
        whisperModels: WhisperModelManager,
        whisperRuntime: WhisperRuntimeManager,
        whisperDraftRuntime: WhisperRuntimeManager,
        gigaAMModels: GigaAMModelManager,
        gigaAMRuntime: GigaAMRuntimeManager,
        gigaAMDraftRuntime: GigaAMRuntimeManager,
        localONNXModels: LocalONNXModelManager,
        localONNXRuntime: LocalONNXRuntimeManager,
        sileroVADModels: SileroVADModelManager,
        russianCorrectionModels: RussianCorrectionModelManager,
        russianCorrectionRuntime: RussianTextCorrectionRuntimeManager,
        history: HistoryModel,
        onHotKeyChanged: @escaping () -> Void,
        onOpenAudioFileChooser: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoicePanel Settings"
        window.minSize = NSSize(width: 1120, height: 700)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.moveToActiveSpace]
        AppAppearance.apply(settings.windowAppearanceMode, to: window)

        let modelBenchmark: ModelBenchmarkRunner?
        #if DEBUG
            if AppRuntimeEnvironment.isUITesting {
                let runner = ModelBenchmarkRunner(monitorsAudioInputDevices: false)
                runner.configurePreview(
                    visualization: VoicePanelPreviewData.pipelineVisualization,
                    summary: VoicePanelPreviewData.pipelineSummary,
                    baseSettings: settings
                )
                modelBenchmark = runner
            } else {
                modelBenchmark = nil
            }
        #else
            modelBenchmark = nil
        #endif

        window.contentView = NSHostingView(
            rootView: SettingsView(
                settings: settings,
                state: state,
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
                russianCorrectionRuntime: russianCorrectionRuntime,
                history: history,
                coordinator: coordinator,
                presentationContext: presentationContext,
                initialPage: .uiTestingInitialPage,
                modelBenchmark: modelBenchmark,
                onHotKeyChanged: onHotKeyChanged,
                onOpenAudioFileChooser: onOpenAudioFileChooser
            ))
        displayLink = WindowDisplayLinkDriver(window: window) { [weak coordinator] in
            coordinator?.flushCaptureMetricsForDisplay()
        }
        super.init(window: window)
        window.delegate = self
        WindowFocusCoordinator.shared.register(window)
        settings.$windowAppearanceMode
            .dropFirst()
            .sink { [weak window] mode in
                guard let window else { return }
                AppAppearance.apply(mode, to: window)
            }
            .store(in: &cancellables)
        state.$phase
            .sink { [weak window, displayLink] phase in
                guard let window else {
                    displayLink.isActive = false
                    return
                }
                displayLink.isActive =
                    window.isVisible && !window.isMiniaturized
                    && phase == .monitoring
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show(revealsDebugOptions: Bool = false) {
        guard let window else { return }
        presentationContext.showsDebugOptions = revealsDebugOptions
        presentationContext.isVisible = true
        window.center()
        showWindow(nil)
        WindowFocusCoordinator.shared.show(window)
        updateDisplayLinkActivity()
    }

    func windowWillClose(_ notification: Notification) {
        presentationContext.isVisible = false
        displayLink.isActive = false
        if coordinator.state.phase == .monitoring {
            coordinator.stopMonitoring()
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        presentationContext.isVisible = false
        displayLink.isActive = false
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        presentationContext.isVisible = true
        updateDisplayLinkActivity()
    }

    private func updateDisplayLinkActivity() {
        guard let window else { return }
        displayLink.isActive =
            window.isVisible
            && !window.isMiniaturized
            && coordinator.state.phase == .monitoring
    }
}
