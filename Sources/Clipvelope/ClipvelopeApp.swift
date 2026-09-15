import SwiftUI
import AppKit

/// The real entry point.
///
/// `--status` has to be handled before SwiftUI starts, because the App's stored
/// properties -- including the delegate, which owns the store, which starts
/// clipboard capture and registers global hotkeys -- are initialised before its
/// `init()` body runs.
@main
enum ClipvelopeEntryPoint {
    static func main() {
        Diagnostics.runIfRequested()
        ClipvelopeApp.main()
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
