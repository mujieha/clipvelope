import SwiftUI
import AppKit

/// The real entry point.
///
/// `--status` has to be handled before SwiftUI starts, because the App's stored
/// properties -- including the store, which starts clipboard capture and
/// registers global hotkeys -- are initialised before its `init()` body runs.
@main
enum ClipvelopeEntryPoint {
    static func main() {
        Diagnostics.runIfRequested()
        ClipvelopeApp.main()
    }
}

struct ClipvelopeApp: App {
    @StateObject private var store = ClipboardStore()
    @StateObject private var updater = UpdaterController()

    init() {
        HotkeyCenter.shared.onCommandF = {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .clipvelopeOpen, object: nil)
            }
        }
        HotkeyCenter.shared.start()

        GlobalHotkeyCenter.shared.onOpen = { PanelOpener.toggle() }
        DistributedNotificationCenter.default().addObserver(
            forName: Diagnostics.openNotification, object: nil, queue: .main
        ) { _ in PanelOpener.open() }
    }

    var body: some Scene {
        // The theme is applied through NSApplication.appearance, not through the
        // colorScheme environment, so no per-view override or .id() re-render
        // hack is needed here. See AppearanceController.
        // lock.doc rather than doc.on.clipboard, so the menu bar echoes the app icon:
        // a document that is locked, not two sheets of paper.
        MenuBarExtra {
            ClipboardMenuView(store: store)
        } label: {
            StatusItemLabel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView(store: store, updater: updater)
        }
    }
}
