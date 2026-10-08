import AppKit

extension Notification.Name {
    static let voicePanelSystemPromptWillBegin = Notification.Name(
        "VoicePanelSystemPromptWillBegin"
    )
    static let voicePanelSystemPromptDidEnd = Notification.Name(
        "VoicePanelSystemPromptDidEnd"
    )
}

enum SystemPromptFocusCoordinator {
    static func willBegin() {
        postOnMainSynchronously(.voicePanelSystemPromptWillBegin)
    }

    static func didEnd() {
        postOnMainSynchronously(.voicePanelSystemPromptDidEnd)
    }

    private static func postOnMainSynchronously(_ name: Notification.Name) {
        let notify = { NotificationCenter.default.post(name: name, object: nil) }
        if Thread.isMainThread {
            notify()
        } else {
            DispatchQueue.main.sync(execute: notify)
        }
    }
}
