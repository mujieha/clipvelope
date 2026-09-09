import AppKit
import Combine

// Sparkle is opt-in at build time; see the comment in Package.swift for why.
// Both shapes below present the same surface, so nothing else in the app has to
// know which build it is in.
#if SPARKLE
import Sparkle

/// Wraps Sparkle so nothing else in the app imports it.
///
/// The awkward part is that Clipvelope is an LSUIElement app. Sparkle wants to
/// show windows, and an agent application cannot bring itself forward, so its
/// windows land behind whatever the user is looking at — the same failure the
/// Settings window had. Every path that shows UI activates first.
final class UpdaterController: ObservableObject {
    let isAvailable = true
    @Published private(set) var canCheckForUpdates = false

    private let updaterController: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        observation = updaterController.updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            DispatchQueue.main.async { self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() {
        activate()
        updaterController.updater.checkForUpdates()
    }

    /// Raises whatever Sparkle puts on screen. `orderFrontRegardless` is the only
    /// thing that works for an app that cannot become active by itself.
    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            for window in NSApplication.shared.windows where window.canBecomeMain {
                window.orderFrontRegardless()
            }
        }
    }
}

#else

/// Stand-in for a build without the updater. Preferences hides its Updates
/// section when `isAvailable` is false rather than offering a button that
/// cannot do anything.
final class UpdaterController: ObservableObject {
    let isAvailable = false
    @Published private(set) var canCheckForUpdates = false

    func checkForUpdates() {}
}

#endif
