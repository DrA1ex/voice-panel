import AppKit
import QuartzCore

@MainActor
final class WindowDisplayLinkDriver {
    private final class Target: NSObject {
        let onFrame: @MainActor () -> Void

        init(onFrame: @escaping @MainActor () -> Void) {
            self.onFrame = onFrame
        }

        @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
            MainActor.assumeIsolated {
                onFrame()
            }
        }
    }

    private let target: Target
    private let displayLink: CADisplayLink

    var isActive: Bool {
        didSet { displayLink.isPaused = !isActive }
    }

    init(
        window: NSWindow,
        isActive: Bool = false,
        onFrame: @escaping @MainActor () -> Void
    ) {
        let target = Target(onFrame: onFrame)
        self.target = target
        displayLink = window.displayLink(
            target: target,
            selector: #selector(Target.displayLinkDidFire(_:))
        )
        self.isActive = isActive
        displayLink.isPaused = !isActive
        displayLink.add(to: .main, forMode: .common)
    }

    deinit {
        displayLink.invalidate()
    }
}
