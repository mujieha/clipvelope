import AppKit
import Combine

// MARK: - Gentle reminders

/// Who shows a scheduled update, and whether the menu bar carries a mark.
///
/// Pure, and kept out of the delegate callbacks for the same reason
/// `PasteService.refusal` and `PollingPolicy.interval` are pure: the rule is the
/// fix, and a test can call a rule but cannot arrange for a signed Sparkle build
/// to find a newer version on a served feed.
///
/// Outside the `#if` deliberately. The rule is the same whichever build this is,
/// and a build without an updater never asks it anything.
///
/// The problem it exists for, measured during a 0.1.0 → 0.2.0 rehearsal: Sparkle
/// found the update, opened its "Software Update" window, and the window landed
/// *behind every other window on the screen*. It had to be raised through the
/// accessibility API to be read at all. Sparkle says so itself in the log —
/// "Background app automatically schedules for update checks but does not
/// implement gentle reminders" — and it is right. An `LSUIElement` app cannot
/// bring its own window forward, which is the same root cause as the Control +
/// Option + V bug this release fixes. So the release mechanism worked and the
/// notification of it could be missed entirely.
enum UpdateReminderPolicy {
    /// What to do when a scheduled check has found a new version.
    enum Handling: Equatable {
        /// Let Sparkle open its window now. Only when the user is already
        /// looking at Clipvelope, which is the one case where the window lands
        /// in front of them rather than behind their work.
        case sparkleShowsIt
        /// Open nothing. The menu bar item carries the news, quietly, until the
        /// user chooses to act on it.
        case markTheMenuBar
    }

    /// `appHasUserAttention` is whether the user is looking at this app right
    /// now — it is active, or the history panel is open in front of them.
    ///
    /// `sparkleProposesImmediateFocus` is Sparkle's own `immediateFocus` flag,
    /// which it sets when it means to show the update in utmost focus. When it
    /// is false Sparkle has told us plainly that for a background app it will
    /// show the alert immediately but *behind* other applications — the measured
    /// failure — so that alone is enough to take the job over.
    ///
    /// Both conditions are required, and the reason is that neither is
    /// sufficient. Sparkle offering immediate focus does not mean it can achieve
    /// it here: an agent app cannot activate itself on macOS 26, so an alert
    /// raised while the user is in another application still opens behind it.
    /// And the app having attention is not licence to interrupt when Sparkle was
    /// never going to show the alert in focus anyway.
    ///
    /// Never steal focus. A window thrown over whatever someone is doing because
    /// a background timer fired is worse than the problem being fixed. The whole
    /// point is a quiet, persistent signal they can act on when they choose.
    static func handling(appHasUserAttention: Bool,
                         sparkleProposesImmediateFocus: Bool) -> Handling {
        appHasUserAttention && sparkleProposesImmediateFocus ? .sparkleShowsIt : .markTheMenuBar
    }

    /// The moments at which the mark on the menu bar can change.
    enum Event: Equatable {
        /// Sparkle is about to show an update. `handledBySparkle` is its
        /// `handleShowingUpdate`; `userInitiated` is `state.userInitiated`.
        case willShowUpdate(handledBySparkle: Bool, userInitiated: Bool)
        /// The user brought the update alert into focus, or chose to install,
        /// skip or dismiss it.
        case userGaveAttention
        /// Sparkle finished the session — dismissed, skipped, or failed.
        case sessionFinished
    }

    /// Whether the menu bar item should carry the mark after `event`.
    ///
    /// The app tells the truth about its own state: a mark that outlives the
    /// update it announced is the same class of defect as no mark at all, so
    /// every event that ends the app's responsibility for telling the user
    /// clears it. `sessionFinished` is in here and not only `userGaveAttention`
    /// because a session can end on an error, with nobody having looked.
    static func isMarked(after event: Event) -> Bool {
        switch event {
        case let .willShowUpdate(handledBySparkle, userInitiated):
            // Only an update this app took responsibility for leaves a mark.
            // If Sparkle is showing it, the window is the signal and a second
            // one would be noise; if the user pressed Check for Updates, they
            // are already looking at the answer.
            return !handledBySparkle && !userInitiated
        case .userGaveAttention, .sessionFinished:
            return false
        }
    }
}

/// The one place that knows an update is waiting to be acted on.
///
/// Outside the `#if` deliberately: `MenuBarController` puts the mark on the
/// status item and the history panel's footer draws a line to act on it, and
/// neither should have to know which build it is in — that rule is the opening
/// comment of this file. In a build without Sparkle nothing ever sets this, so
/// `isWaiting` stays false and `bringUpdateForward` stays nil: no mark, no line.
final class UpdateReminder: ObservableObject {
    static let shared = UpdateReminder()

    /// Read by the history panel's footer line. The menu bar item is told
    /// directly rather than observing, because it is an `NSStatusItem` and not
    /// a SwiftUI view.
    @Published private(set) var isWaiting = false

    /// Brings Sparkle's update window forward, activating first so it does not
    /// land behind the panel the user just clicked in. Set once by
    /// `UpdaterController` in a build that has one; nil otherwise, which is what
    /// keeps the footer line out of a build with no updater.
    var bringUpdateForward: (() -> Void)?

    private init() {}

    func setWaiting(_ waiting: Bool) {
        // Sparkle calls its user driver delegate on the main thread, and this
        // touches a published property and a status item. It makes sure rather
        // than asserting: a `dispatchPrecondition` here would turn a change in
        // Sparkle's threading into a crash in a shipped app.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.setWaiting(waiting) }
            return
        }
        guard isWaiting != waiting else { return }
        isWaiting = waiting
        MenuBarController.shared?.setUpdateWaiting(waiting)
    }
}

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
    /// Sparkle holds its user driver delegate weakly, so this owns it.
    private let driverDelegate: GentleReminderDelegate
    private var observation: NSKeyValueObservation?
    private var automaticChecksObservation: NSKeyValueObservation?

    init() {
        // A local, not `self.driverDelegate`: `self` is not usable until every
        // stored property is initialised, and `updaterController` is not yet.
        let driverDelegate = GentleReminderDelegate()
        self.driverDelegate = driverDelegate
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: driverDelegate
        )
        // The history panel's footer line calls this. `checkForUpdates`
        // activates first, which is what raises Sparkle's window; that path was
        // always fine and is the one the gentle reminder steers people into.
        UpdateReminder.shared.bringUpdateForward = { [weak self] in
            self?.checkForUpdates()
        }
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

/// Sparkle's gentle-reminders contract.
///
/// Separate from `UpdaterController` rather than a conformance on it, for one
/// mundane reason: this protocol inherits `NSObject`, and making
/// `UpdaterController` an `NSObject` subclass would mean it could not pass
/// itself as the user driver delegate in its own initialiser — the delegate has
/// to exist before the updater controller does. A second object costs nothing
/// and keeps the ordering honest.
///
/// `UpdateReminderPolicy` holds every decision made here. What is left is the
/// part a test cannot reach: asking AppKit whether the user is looking at this
/// app, and telling `UpdateReminder` the answer.
private final class GentleReminderDelegate: NSObject, SPUStandardUserDriverDelegate {
    /// Without this, Sparkle logs the warning that started all of this and uses
    /// its own behaviour regardless of the callbacks below.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Whether the user is looking at Clipvelope at this moment.
    ///
    /// Two conditions, because the app has two ways of being in front of
    /// someone. `NSApp.isActive` covers Preferences being open and frontmost.
    /// The history panel is a `.nonactivatingPanel` and is deliberately visible
    /// while the app is *not* active — that is the whole design in `Panel.swift`
    /// — so `isActive` alone would report "no attention" with the panel open on
    /// screen in front of the user.
    private var appHasUserAttention: Bool {
        NSApp.isActive || (MenuBarController.shared?.isPanelOpen ?? false)
    }

    /// Sparkle asks this before showing a scheduled update. Its documentation
    /// asks for no side effects here, and there are none: it reads two flags and
    /// returns. Sparkle does not call it for a user-initiated check.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        UpdateReminderPolicy.handling(appHasUserAttention: appHasUserAttention,
                                      sparkleProposesImmediateFocus: immediateFocus)
            == .sparkleShowsIt
    }

    /// Where the mark goes on. `handleShowingUpdate` is false exactly when the
    /// call above returned false, which is when this app has taken on the job of
    /// telling the user.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        UpdateReminder.shared.setWaiting(
            UpdateReminderPolicy.isMarked(after: .willShowUpdate(
                handledBySparkle: handleShowingUpdate,
                userInitiated: state.userInitiated)))
    }

    /// Where it goes off: the user brought the alert into focus, or answered it.
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        UpdateReminder.shared.setWaiting(
            UpdateReminderPolicy.isMarked(after: .userGaveAttention))
    }

    /// And where it goes off when nobody ever looked: a session that ends
    /// because the update was skipped, dismissed, or failed. Without this the
    /// menu bar would keep announcing an update that is no longer on offer.
    func standardUserDriverWillFinishUpdateSession() {
        UpdateReminder.shared.setWaiting(
            UpdateReminderPolicy.isMarked(after: .sessionFinished))
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
