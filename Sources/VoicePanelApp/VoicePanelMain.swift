import AppKit

private func voicePanelUncaughtExceptionHandler(_ exception: NSException) {
    DiagnosticLogger.shared.error(
        "Uncaught Objective-C exception",
        metadata: [
            "name": exception.name.rawValue,
            "reason": exception.reason ?? "unknown",
        ]
    )
}

@main
@MainActor
enum VoicePanelMain {
    static func main() {
        NSSetUncaughtExceptionHandler(voicePanelUncaughtExceptionHandler)

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate

        // NSApplication.delegate is not an owning reference. Keep the delegate
        // alive for the complete lifetime of the application event loop.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
