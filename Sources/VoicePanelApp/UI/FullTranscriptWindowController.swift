import AppKit
import Combine
import SwiftUI

@MainActor
final class FullTranscriptWindowController: NSWindowController, NSWindowDelegate {
    private var cancellables = Set<AnyCancellable>()
    private let state: AppState
    private let onClose: () -> Void
    private let displayLink: WindowDisplayLinkDriver

    init(
        state: AppState,
        settings: AppSettings,
        onImportAudioFile: @escaping @MainActor (URL) -> Void,
        onCancel: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onDisplayFrame: @escaping @MainActor () -> Void = {}
    ) {
        self.state = state
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 470),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoicePanel Transcript"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        AppAppearance.apply(settings.windowAppearanceMode, to: window)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(
            rootView: FullTranscriptView(
                state: state,
                onImportAudioFile: onImportAudioFile,
                onCancel: onCancel,
                onCopy: onCopy,
                onClose: onClose
            ))
        displayLink = WindowDisplayLinkDriver(window: window, onFrame: onDisplayFrame)
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
            .sink { [weak self] _ in
                self?.updateDisplayLinkActivity()
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        guard let window else { return }
        showWindow(nil)
        WindowFocusCoordinator.shared.show(window)
        updateDisplayLinkActivity()
    }

    func hide() {
        window?.orderOut(nil)
        displayLink.isActive = false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        displayLink.isActive = false
        onClose()
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        displayLink.isActive = false
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        updateDisplayLinkActivity()
    }

    private func updateDisplayLinkActivity() {
        guard let window else { return }
        displayLink.isActive =
            window.isVisible
            && !window.isMiniaturized
            && (state.phase == .preparing || state.phase == .listening)
    }
}
