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
    /// Whether Sparkle checks on its own schedule. Sparkle persists this in
    /// `UserDefaults` itself, so it is read back from the updater rather than
    /// stored anywhere of ours — one fact, one place that owns it.
    @Published private(set) var automaticallyChecksForUpdates = false

    private let updaterController: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?
    private var automaticChecksObservation: NSKeyValueObservation?

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
        automaticChecksObservation = updaterController.updater.observe(
            \.automaticallyChecksForUpdates, options: [.initial, .new]
        ) { [weak self] updater, _ in
            let value = updater.automaticallyChecksForUpdates
            DispatchQueue.main.async { self?.automaticallyChecksForUpdates = value }
        }
    }

    /// Sparkle requires this to be set on the main thread; the observation above
    /// is what puts the new value back on the published property.
    @MainActor
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updaterController.updater.automaticallyChecksForUpdates = enabled
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
    /// Constant here: with no updater there is no schedule to switch on, and the
    /// Updates section that would show the toggle is hidden anyway.
    @Published private(set) var automaticallyChecksForUpdates = false

    @MainActor
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {}

    func checkForUpdates() {}
}

#endif
