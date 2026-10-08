import Foundation

enum AppRuntimeEnvironment {
    static var isPreviewing: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    static var isUITesting: Bool {
        ProcessInfo.processInfo.environment["VOICEPANEL_UI_TESTING"] == "1"
    }

    static var suppressesLiveServices: Bool {
        isPreviewing || isUITesting
    }
}
