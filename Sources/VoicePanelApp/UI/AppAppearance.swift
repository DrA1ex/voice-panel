import AppKit
import SwiftUI

enum AppAppearance {
    static func apply(_ mode: AppSettings.AppearanceMode, to application: NSApplication) {
        application.appearance = appearance(for: mode)
    }

    static func apply(_ mode: AppSettings.AppearanceMode, to window: NSWindow) {
        window.appearance = appearance(for: mode)
    }

    static func colorScheme(for mode: AppSettings.AppearanceMode) -> ColorScheme? {
        switch mode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private static func appearance(for mode: AppSettings.AppearanceMode) -> NSAppearance? {
        switch mode {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}
