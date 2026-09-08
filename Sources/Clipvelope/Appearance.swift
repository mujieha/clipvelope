import AppKit

/// Applies the chosen theme to the whole app.
///
/// Setting SwiftUI's `colorScheme` environment is not enough, and produced the
/// half-themed window this replaces. That environment value recolours
/// SwiftUI-drawn content, but window backgrounds, the menu bar popover's
/// material and the Settings window take their colours from the hosting
/// NSWindow's `NSAppearance`. So the search field and footer -- which paint
/// their own `Color(NSColor.controlBackgroundColor)` -- followed the theme,
/// while the list area between them showed the untouched window material, and
/// Preferences never received the environment at all because it lives in a
/// separate scene.
///
/// Setting `NSApplication.appearance` covers every window the app owns,
/// including ones it has not created yet.
enum AppearanceController {
    static func apply(_ mode: ThemeMode) {
        let appearance = appearance(for: mode)
        NSApplication.shared.appearance = appearance

        // The MenuBarExtra popover is a system-owned panel that does not inherit
        // the application appearance, so it has to be set on the window itself.
        for window in NSApplication.shared.windows {
            window.appearance = appearance
        }
    }

    private static func appearance(for mode: ThemeMode) -> NSAppearance? {
        switch mode {
        case .system:
            // nil means "inherit", which is what following the system setting is.
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }
}
