import AppKit
import Combine
import SwiftUI

@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private let history: HistoryModel
    private var cancellables = Set<AnyCancellable>()

    init(history: HistoryModel, settings: AppSettings) {
        self.history = history
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoicePanel History"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.titlebarSeparatorStyle = .line
        window.toolbarStyle = .unified
        AppAppearance.apply(settings.windowAppearanceMode, to: window)
        window.contentView = NSHostingView(rootView: HistoryView(history: history))
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
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        guard let window else { return }
        showWindow(nil)
        WindowFocusCoordinator.shared.show(window)
    }

    func windowWillClose(_ notification: Notification) {
        history.lock()
    }
}
