import AppKit
import Combine

@MainActor
final class WindowFocusCoordinator {
    static let shared = WindowFocusCoordinator()

    private let registeredWindows = NSHashTable<NSWindow>.weakObjects()
    private var cancellables = Set<AnyCancellable>()
    private weak var lastKeyWindow: NSWindow?
    private weak var promptRestorationWindow: NSWindow?
    private var promptDepth = 0
    private var restorationGeneration = 0
    private var isStarted = false

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true

        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .compactMap { $0.object as? NSWindow }
            .sink { [weak self] window in
                guard let self, self.isRegistered(window) else { return }
                self.lastKeyWindow = window
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .voicePanelSystemPromptWillBegin)
            .sink { [weak self] _ in self?.systemPromptWillBegin() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .voicePanelSystemPromptDidEnd)
            .sink { [weak self] _ in self?.systemPromptDidEnd() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.applicationDidBecomeActive() }
            .store(in: &cancellables)
    }

    func register(_ window: NSWindow) {
        start()
        registeredWindows.add(window)
        window.hidesOnDeactivate = false
        if window.isKeyWindow {
            lastKeyWindow = window
        }
    }

    func show(_ window: NSWindow, centerIfNeeded: Bool = true) {
        register(window)
        if centerIfNeeded, !window.isVisible {
            window.center()
        }
        bringToFront(window)
        scheduleReassertion(of: window, delays: [0.05, 0.18])
    }

    func present(
        _ panel: NSSavePanel,
        attachedTo preferredWindow: NSWindow? = nil,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        start()
        panel.hidesOnDeactivate = false
        panel.collectionBehavior.insert(.moveToActiveSpace)

        if let owner = eligibleOwner(preferredWindow) ?? frontmostRegisteredWindow() {
            bringToFront(owner)
            panel.beginSheetModal(for: owner) { [weak self, weak owner] response in
                if let owner, owner.isVisible {
                    self?.bringToFront(owner)
                }
                completion(response)
            }
            return
        }

        panel.level = .floating
        activateApplication()
        panel.begin { response in completion(response) }
        bringStandalonePanelToFront(panel)
    }

    func present(
        _ alert: NSAlert,
        attachedTo preferredWindow: NSWindow? = nil,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        start()
        if let owner = eligibleOwner(preferredWindow) ?? frontmostRegisteredWindow() {
            bringToFront(owner)
            alert.beginSheetModal(for: owner) { [weak self, weak owner] response in
                if let owner, owner.isVisible {
                    self?.bringToFront(owner)
                }
                completion(response)
            }
            return
        }

        alert.window.hidesOnDeactivate = false
        alert.window.level = .floating
        alert.window.collectionBehavior.insert(.moveToActiveSpace)
        activateApplication()
        alert.window.center()
        alert.window.makeKeyAndOrderFront(nil)
        alert.window.orderFrontRegardless()
        completion(alert.runModal())
    }

    private func systemPromptWillBegin() {
        if promptDepth == 0 {
            promptRestorationWindow = frontmostRegisteredWindow()
            restorationGeneration += 1
        }
        promptDepth += 1
    }

    private func systemPromptDidEnd() {
        promptDepth = max(0, promptDepth - 1)
        guard promptDepth == 0 else { return }
        schedulePromptRestoration()
    }

    private func applicationDidBecomeActive() {
        guard promptDepth == 0, promptRestorationWindow != nil else { return }
        schedulePromptRestoration(delays: [0.02, 0.12])
    }

    private func schedulePromptRestoration(
        delays: [TimeInterval] = [0.05, 0.18, 0.45]
    ) {
        guard let window = promptRestorationWindow else { return }
        restorationGeneration += 1
        let generation = restorationGeneration

        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                guard let self, let window,
                    self.promptDepth == 0,
                    self.restorationGeneration == generation,
                    window.isVisible
                else { return }
                self.bringToFront(window)
            }
        }

        let clearDelay = (delays.max() ?? 0) + 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + clearDelay) { [weak self, weak window] in
            guard let self,
                self.restorationGeneration == generation,
                self.promptDepth == 0,
                self.promptRestorationWindow === window
            else { return }
            self.promptRestorationWindow = nil
        }
    }

    private func scheduleReassertion(of window: NSWindow, delays: [TimeInterval]) {
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                guard let self, let window,
                    self.promptDepth == 0,
                    window.isVisible
                else { return }
                self.bringToFront(window)
            }
        }
    }

    private func bringStandalonePanelToFront(_ panel: NSSavePanel) {
        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak panel] in
            guard let panel, panel.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        }
    }

    private func bringToFront(_ window: NSWindow) {
        guard window.isVisible || window.windowController != nil else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        activateApplication()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        lastKeyWindow = window
    }

    private func activateApplication() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func eligibleOwner(_ window: NSWindow?) -> NSWindow? {
        guard let window,
            isRegistered(window),
            window.isVisible,
            !window.isMiniaturized,
            window.canBecomeKey
        else { return nil }
        return window
    }

    private func frontmostRegisteredWindow() -> NSWindow? {
        if let keyWindow = eligibleOwner(NSApp.keyWindow) {
            return keyWindow
        }
        if let mainWindow = eligibleOwner(NSApp.mainWindow) {
            return mainWindow
        }
        if let lastKeyWindow = eligibleOwner(lastKeyWindow) {
            return lastKeyWindow
        }
        return NSApp.orderedWindows.first(where: { eligibleOwner($0) != nil })
    }

    private func isRegistered(_ window: NSWindow) -> Bool {
        registeredWindows.allObjects.contains(where: { $0 === window })
    }
}
