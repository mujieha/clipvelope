import SwiftUI
import AppKit

/// The real entry point.
///
/// `--status` has to be handled before SwiftUI starts, because the App's stored
/// properties -- including the delegate, which owns the store, which starts
/// clipboard capture and registers global hotkeys -- are initialised before its
/// `init()` body runs. That is also why the single-instance guard runs second
/// and not first: `--status`, `--open` and `--preferences` are all things you
/// ask a *running* instance, and a guard placed ahead of them would quit before
/// answering.
@main
enum ClipvelopeEntryPoint {
    static func main() {
        Diagnostics.runIfRequested()
        SingleInstance.handOverIfAlreadyRunning()
        ClipvelopeApp.main()
    }
}

/// One Clipvelope per login session -- and deliberately no fewer than one per
/// login session.
///
/// Two copies running for one person fought over the global hotkeys, and
/// Preferences then blamed another app for taking them. 0.2.0 fixed that with
/// `LSMultipleInstancesProhibited` in Info.plist, which was too blunt a tool:
/// Launch Services enforces that key per *machine*, so while one user had
/// Clipvelope running a second logged-in user could not launch it at all --
/// `-10829`, `kLSMultipleSessionsNotSupportedErr`, measured on a CI job running
/// as a second account. Two people sharing a Mac have separate logins, separate
/// keychains and separate vaults, and each of them is entitled to their own
/// Clipvelope. The key is gone; the rule is enforced here instead, where it can
/// be drawn at the session boundary the problem actually had.
///
/// `NSRunningApplication.runningApplications(withBundleIdentifier:)` is the
/// right primitive because it only ever reports applications in the caller's
/// own login session. Nothing here reads the Keychain: `RemoteControl`'s token
/// would be the friendlier way to hand the launch over -- the second copy could
/// ask the first to show the history -- but a Keychain read can block on a
/// system dialog, and a launch that hangs is worse than the problem being
/// fixed. So this quits, which is what Launch Services did with the key, and
/// what `--open` is for when someone wants the panel.
enum SingleInstance {
    /// Quits this process if another copy is already running in this login
    /// session, leaving the older one owning the hotkeys and the vault.
    static func handOverIfAlreadyRunning() {
        guard let first = otherInstances().first else { return }
        // stdout goes nowhere for a Finder or Launch Services launch, so this
        // is NSLog rather than print: Console is where anyone would look.
        NSLog("%@", "Clipvelope is already running in this login session as pid \(first); this launch is handing over to it and quitting.")
        exit(0)
    }

    /// Every other Clipvelope process in this login session, by pid.
    static func otherInstances() -> [pid_t] {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.mujieha.Clipvelope"
        return others(
            in: NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .map(\.processIdentifier),
            excluding: ProcessInfo.processInfo.processIdentifier)
    }

    /// Pure, so the one subtle part -- that this process is in the list it is
    /// asking about, and must not count itself as a reason to quit -- can be
    /// tested without a second process.
    static func others(in running: [pid_t], excluding me: pid_t) -> [pid_t] {
        running.filter { $0 != me }
    }
}

/// Everything the app owns outside SwiftUI's scenes.
///
/// The store used to be a `@StateObject` on `ClipvelopeApp` and the status item
/// used to be a `MenuBarExtra`. Both moved here when the app took ownership of
/// its menu bar item -- see `MenuBarController` for why it had to. The status
/// item is created in `applicationDidFinishLaunching` because that is the first
/// moment `NSStatusBar` will hand one out; the store is a stored property
/// because capture should start as early as it used to.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = ClipboardStore()
    let updater = UpdaterController()

    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(store: store)

        GlobalHotkeyCenter.shared.onOpen = { PanelOpener.toggle() }
        RemoteControl.arm()
        DistributedNotificationCenter.default().addObserver(
            forName: RemoteControl.openNotification, object: nil, queue: .main
        ) { notification in
            guard RemoteControl.isAuthentic(notification) else {
                NSLog("Clipvelope: ignored an --open request that did not carry this launch's token")
                return
            }
            PanelOpener.open()
        }
    }
}

struct ClipvelopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Settings is the app's only scene. The history panel is an NSPanel the
        // app owns rather than a MenuBarExtra, because on macOS 27 a
        // MenuBarExtra can only be opened by a real mouse click -- which leaves
        // ⌃⌥V and `--open`, the two ways anyone actually opens this app, doing
        // nothing. MenuBarController has the measurements.
        //
        // The theme is applied through NSApplication.appearance, not through the
        // colorScheme environment, so no per-view override or .id() re-render
        // hack is needed here. See AppearanceController.
        Settings {
            PreferencesView(store: delegate.store, updater: delegate.updater)
        }
    }
}
