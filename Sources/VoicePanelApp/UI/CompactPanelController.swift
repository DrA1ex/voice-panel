import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class CompactPanelController {
    private let panel: NSPanel
    private let state: AppState
    private let settings: AppSettings
    private let displayLink: WindowDisplayLinkDriver
    private var cancellables = Set<AnyCancellable>()
    private var restoresAfterSystemPrompt = false
    private var levelBeforeSystemPrompt: NSWindow.Level?
    private var systemPromptGeneration = 0

    init(
        state: AppState,
        settings: AppSettings,
        onLatchHotKey: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onOpenTranscript: @escaping () -> Void,
        onImportAudioFile: @escaping @MainActor (URL) -> Void,
        onCopy: @escaping () -> Void,
        onRetry: @escaping () -> Void = {},
        onClose: @escaping () -> Void,
        onDisplayFrame: @escaping @MainActor () -> Void = {}
    ) {
        self.state = state
        self.settings = settings
        let size = NSSize(
            width: settings.panelSizePreset.windowWidth,
            height: Self.windowHeight(for: state, settings: settings)
        )
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = settings.panelAlwaysOnTop ? .floating : .normal
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        AppAppearance.apply(settings.panelAppearanceMode, to: panel)
        panel.contentView = NSHostingView(
            rootView: CompactPanelView(
                state: state,
                settings: settings,
                onLatchHotKey: onLatchHotKey,
                onStop: onStop,
                onCancel: onCancel,
                onOpenTranscript: onOpenTranscript,
                onImportAudioFile: onImportAudioFile,
                onCopy: onCopy,
                onRetry: onRetry,
                onClose: onClose
            ))
        displayLink = WindowDisplayLinkDriver(window: panel, onFrame: onDisplayFrame)
        observeSystemPrompts()

        settings.$panelSizePreset
            .dropFirst()
            .sink { [weak self] _ in self?.resizeForCurrentPreset(preservePosition: true) }
            .store(in: &cancellables)

        settings.$panelPositionPreset
            .dropFirst()
            .sink { [weak self] _ in self?.resizeForCurrentPreset(preservePosition: false) }
            .store(in: &cancellables)

        settings.$panelAppearanceMode
            .dropFirst()
            .sink { [weak panel] mode in
                guard let panel else { return }
                AppAppearance.apply(mode, to: panel)
            }
            .store(in: &cancellables)

        settings.$panelAlwaysOnTop
            .dropFirst()
            .sink { [weak panel] alwaysOnTop in
                panel?.level = alwaysOnTop ? .floating : .normal
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(
            state.$phase,
            state.$completionPresentation,
            state.$recordingControlSource
        )
        .dropFirst()
        .sink { [weak self] _ in
            self?.resizeForCurrentPreset(preservePosition: true)
            self?.updateDisplayLinkActivity()
        }
        .store(in: &cancellables)
    }

    func show() {
        let targetFrame = targetFrameForCurrentScreen()
        var startFrame = targetFrame
        startFrame.origin.y -= 16
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        updateDisplayLinkActivity()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel = self.panel] in
            MainActor.assumeIsolated {
                panel?.orderOut(nil)
                self.displayLink.isActive = false
            }
        }
    }

    func writePreview(to url: URL, completion: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak panel] in
            defer { completion() }
            guard let view = panel?.contentView else { return }
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func observeSystemPrompts() {
        NotificationCenter.default.publisher(for: .voicePanelSystemPromptWillBegin)
            .sink { [weak self] _ in self?.keepVisibleDuringSystemPrompt() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .voicePanelSystemPromptDidEnd)
            .sink { [weak self] _ in self?.restoreAfterSystemPromptIfNeeded() }
            .store(in: &cancellables)
    }

    private func keepVisibleDuringSystemPrompt() {
        guard panel.isVisible else { return }
        if !restoresAfterSystemPrompt {
            levelBeforeSystemPrompt = panel.level
        }
        restoresAfterSystemPrompt = true
        systemPromptGeneration += 1
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.orderFrontRegardless()
    }

    private func restoreAfterSystemPromptIfNeeded() {
        guard restoresAfterSystemPrompt else { return }
        let generation = systemPromptGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self,
                self.restoresAfterSystemPrompt,
                self.systemPromptGeneration == generation
            else { return }
            self.restoresAfterSystemPrompt = false
            self.panel.level =
                self.levelBeforeSystemPrompt
                ?? (self.settings.panelAlwaysOnTop ? .floating : .normal)
            self.levelBeforeSystemPrompt = nil
            if self.panel.isVisible {
                self.panel.orderFrontRegardless()
            }
        }
    }

    private func resizeForCurrentPreset(preservePosition: Bool) {
        var targetFrame = targetFrameForCurrentScreen()
        if panel.isVisible {
            if preservePosition {
                targetFrame.origin = NSPoint(
                    x: panel.frame.midX - targetFrame.width / 2,
                    y: panel.frame.midY - targetFrame.height / 2
                )
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            panel.setFrame(targetFrame, display: false)
        }
    }

    private func updateDisplayLinkActivity() {
        displayLink.isActive =
            panel.isVisible
            && (state.phase == .preparing || state.phase == .listening)
    }

    private func targetFrameForCurrentScreen() -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen =
            NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = NSSize(
            width: settings.panelSizePreset.windowWidth,
            height: Self.windowHeight(for: state, settings: settings)
        )
        let originY: CGFloat
        switch settings.panelPositionPreset {
        case .aboveDock:
            let panelBottom = max(
                visible.minY + 12,
                screen.frame.minY + 78
            )
            originY = panelBottom - AppSettings.PanelSizePreset.visualEffectInset
        case .screenBottom:
            originY = visible.minY + 12 - AppSettings.PanelSizePreset.visualEffectInset
        case .center:
            originY = visible.midY - size.height / 2
        }
        return NSRect(
            x: visible.midX - size.width / 2,
            y: originY,
            width: size.width,
            height: size.height
        )
    }

    private static func windowHeight(for _: AppState, settings: AppSettings) -> CGFloat {
        settings.panelSizePreset.windowHeight
    }
}
