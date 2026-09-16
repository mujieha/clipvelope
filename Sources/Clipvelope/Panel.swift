import AppKit
import SwiftUI

// MARK: - Why the app owns its own status item

/// The menu bar item and the history panel.
///
/// This used to be a SwiftUI `MenuBarExtra`, and on macOS 27 that stopped
/// working for everything except a real mouse click. Measured on 27.0: the
/// status item's `NSStatusBarButton` is still there and still findable, but
/// SwiftUI no longer sets its `target` or its `action` -- both are nil. A status
/// button's `performClick(nil)` works by invoking target/action, so with both
/// nil it does nothing at all, silently. Every programmatic way into this app
/// went through that call: the ⌃⌥V hotkey and `Clipvelope --open`, which is to
/// say the app's entire front door.
///
/// Nothing else reaches a `MenuBarExtra` window from code, either. Also
/// measured, so that nobody has to measure it again:
///
/// - `NSApp.activate(ignoringOtherApps:)` leaves `NSApp.isActive` false. macOS
///   has tightened self-activation and an `LSUIElement` app cannot raise itself
///   this way any more.
/// - `button.mouseDown(with:)` with a synthesised event enters a modal tracking
///   loop that never returns.
/// - `NSApp.postEvent` and `sendAction` do nothing.
/// - `CGEvent.post` would work, and is not allowed: it needs Accessibility
///   consent, and the README's promise is that out of the box Clipvelope needs
///   nothing from macOS. Making the *primary* entry point ask for a permission
///   to work at all would make that promise false.
///
/// So the app creates the status item itself and sets the button's own target
/// and action. That single change is what makes every path work again: the app
/// now owns the action rather than hoping SwiftUI wired one. The panel is an
/// `NSPanel` this class owns, hosting the same `ClipboardMenuView` as before --
/// the view was never the problem and is not rewritten here.
final class MenuBarController: NSObject, NSWindowDelegate {
    /// The one controller, for `PanelOpener` to reach. Set at the end of `init`.
    private(set) static var shared: MenuBarController?

    /// Between the bottom of the menu bar and the top of the panel.
    private static let gap: CGFloat = 4
    /// How close to the edge of the screen the panel may sit. The status item
    /// can be far enough right that a centred 380pt panel would hang off.
    private static let screenMargin: CGFloat = 8

    private let store: ClipboardStore
    private let statusItem: NSStatusItem
    private let panel: HistoryPanel
    /// Rebuilt on every open; see `show()`.
    private var content: NSHostingController<ClipboardMenuView>?
    private var preferencesHost: NSView?
    /// The screen point the panel's top-left corner is pinned to while it is
    /// open. Nil while it is closed.
    private var anchor: CGPoint?

    init(store: ClipboardStore) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        panel = HistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered,
                             defer: false)
        super.init()
        configureStatusItem()
        configurePanel()
        MenuBarController.shared = self
    }

    // MARK: The status item

    /// The sealed envelope from the app icon, as a template so macOS recolours
    /// it for light and dark menu bars. A bare `swift build` binary has no
    /// bundle resources; it falls back to a system symbol, which is why this is
    /// not simply a force-unwrapped bundle lookup.
    private static let icon: NSImage? = {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        let fallback = NSImage(systemSymbolName: "envelope.fill",
                               accessibilityDescription: "Clipvelope")
        fallback?.isTemplate = true
        return fallback
    }()

    /// The same icon with a small filled dot in its top-right corner, shown
    /// while a background update check has found a new version.
    ///
    /// Why a dot cut into the template image, rather than a coloured badge or a
    /// different glyph. It has to satisfy two constraints at once and this is
    /// the only signal that satisfies both without a second decision. A template
    /// image is recoloured by macOS to match the menu bar it is drawn in, so the
    /// dot reads on a light menu bar and on a dark one for free, and it keeps
    /// reading under Reduce Transparency, on a tinted desktop, and in the
    /// high-contrast appearances — none of which a hard-coded colour survives.
    /// And a plain dot is not an error: red, a badge count, or an exclamation
    /// mark would say something is wrong, and nothing is wrong. A new version
    /// being available is news, not a fault.
    ///
    /// The transparent moat is what makes it a mark rather than a lump on the
    /// envelope's corner: without it the dot merges into the glyph at the small
    /// sizes a menu bar uses, since both are painted the same colour.
    ///
    /// `NSImage(size:flipped:drawingHandler:)` rather than `lockFocus`, so it is
    /// redrawn at whatever scale the screen it lands on needs instead of being
    /// rasterised once at the scale of whichever display was attached at launch.
    private static func marked(_ base: NSImage) -> NSImage {
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let diameter = rect.width * 0.34
            let dot = NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter,
                             width: diameter, height: diameter)
            guard let context = NSGraphicsContext.current else { return true }
            context.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.25, dy: -1.25)).fill()
            context.compositingOperation = .sourceOver
            // Colour is irrelevant for a template image -- macOS masks it and
            // paints its own -- but something has to be filled.
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static let markedIcon: NSImage? = icon.map(marked)

    /// Whether the menu bar item says an update is waiting.
    ///
    /// Called by `UpdateReminder`, which is the only thing that knows. The
    /// tooltip and the accessibility label change with the image: a mark that
    /// VoiceOver cannot read is not a signal to everyone, and a dot with no
    /// explanation is a puzzle. Both go back to plain "Clipvelope" when the mark
    /// is cleared -- the app tells the truth about its own state.
    func setUpdateWaiting(_ waiting: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let button = statusItem.button else { return }
        button.image = waiting ? (Self.markedIcon ?? Self.icon) : Self.icon
        button.setAccessibilityLabel(waiting ? "Clipvelope, an update is ready" : "Clipvelope")
        button.toolTip = waiting ? "Clipvelope — an update is ready" : "Clipvelope"
    }

    private func configureStatusItem() {
        // Nil when the menu bar has no room left for another item. There is
        // nothing to be done about it here, but it is the one state in which the
        // app has no way in at all, so it is said out loud rather than left for
        // a user to discover. `PanelOpener.availability` reports it too.
        guard let button = statusItem.button else {
            NSLog("Clipvelope: the system would not give this app a menu bar item")
            return
        }
        button.image = Self.icon
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel("Clipvelope")
        button.toolTip = "Clipvelope"
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        installPreferencesObserver(in: button)
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        toggle()
    }

    /// Whether the menu bar item exists and could be pressed. Read by
    /// `PanelOpener.availability`, which `--status` prints.
    var hasStatusItemButton: Bool { statusItem.button != nil }

    // MARK: The panel

    private func configurePanel() {
        panel.delegate = self
        panel.isFloatingPanel = true
        // The panel dismisses itself on resigning key, which is a stricter rule
        // than hiding with the app and covers the app never being active at all.
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        // Closed and reopened many times in a session. Releasing it on close
        // would leave `PanelState` reading a dead object.
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The same level the MenuBarExtra window used, which is what
        // `scripts/smoke.sh` looks for: above ordinary windows and above the
        // menu bar, so it is never drawn behind what the user was reading.
        panel.level = .popUpMenu
        // Appears on whichever space the user is on, full screen included --
        // ⌃⌥V is a global hotkey and is pressed from everywhere.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.animationBehavior = .utilityWindow
    }

    var isPanelOpen: Bool { panel.isVisible }

    /// What the menu bar item does, and what ⌃⌥V does.
    func toggle() {
        dispatchPrecondition(condition: .onQueue(.main))
        if panel.isVisible { close() } else { show() }
    }

    func close() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func show() {
        // A fresh hosting controller each time, because the view expects it.
        // `ClipboardMenuView.onAppear` clears the search, resets the selection
        // and focuses the search field, and SwiftUI fires `onAppear` once per
        // view identity. Reusing one controller would open the panel on last
        // week's query with nothing focused. The MenuBarExtra window was rebuilt
        // on every open and the view was written for that.
        let controller = NSHostingController(rootView: ClipboardMenuView(store: store))
        // The list's height changes with the number of rows and with what is
        // typed in the search field, and the view has no fixed height to give a
        // window. This asks SwiftUI for the size it wants and keeps the window
        // that size as it changes; `windowDidResize` then keeps the top edge
        // where it was put.
        controller.sizingOptions = [.preferredContentSize]
        content = controller
        panel.contentViewController = controller
        // Rounded like the popover it replaces. Set after the content view
        // controller, which is what installs the view whose layer this is.
        if let contentView = panel.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 10
            contentView.layer?.masksToBounds = true
        }
        controller.view.layoutSubtreeIfNeeded()

        position()
        // `orderFrontRegardless`, because an LSUIElement app is not active and
        // `orderFront` from an inactive app is ignored -- the same reason
        // `bringSettingsWindowForward` uses it.
        panel.orderFrontRegardless()
        // And then key, which is the opposite decision from NoticeHUD and is
        // required, twice over: the search field cannot receive a keystroke in a
        // window that is not key, and `PasteService.stillHasFocus` reads
        // `NSApplication.shared.keyWindow` to know the panel still holds the
        // keyboard and that a Command + V posted now would land in it.
        // A `.nonactivatingPanel` can be key while its app is inactive, which is
        // what lets this happen without stealing the user's frontmost app.
        panel.makeKey()
    }

    /// Puts the panel's top-left corner just under the status item.
    private func position() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let itemFrame = buttonWindow.frame
        let size = panel.frame.size
        var x = itemFrame.midX - size.width / 2
        // `buttonWindow.screen` rather than `NSScreen.main`: main is the screen
        // with the key window, and at this moment the app has none.
        if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            let leftmost = visible.minX + Self.screenMargin
            let rightmost = visible.maxX - size.width - Self.screenMargin
            x = rightmost < leftmost ? leftmost : min(max(x, leftmost), rightmost)
        }
        let top = itemFrame.minY - Self.gap
        anchor = CGPoint(x: x, y: top)
        panel.setFrameOrigin(CGPoint(x: x, y: top - size.height))
    }

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        // A window grows and shrinks about its bottom-left corner. Left alone, a
        // search that narrowed the list to two rows would leave the panel's top
        // edge stranded in the middle of the screen, and one that lengthened it
        // would push the panel up through the menu bar. Keep the corner the
        // panel was opened at.
        guard let anchor else { return }
        panel.setFrameOrigin(CGPoint(x: anchor.x, y: anchor.y - panel.frame.height))
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere else takes the panel away, which is what the
        // MenuBarExtra window did and what every menu bar app does. It is also
        // what makes `PasteService` work: the panel must be gone, and the
        // keyboard back where the user was typing, before a keystroke is posted.
        close()
    }

    func windowWillClose(_ notification: Notification) {
        // `ClipboardMenuView.closeMenuBarWindow` and
        // `ClipboardStore.closePanelThenPaste` both dismiss the panel with
        // `NSApplication.shared.keyWindow?.close()`, which lands here rather
        // than in `close()`. The anchor is per-open and must not survive it.
        anchor = nil
    }

    // MARK: --preferences

    /// Hosts the one SwiftUI view that has to outlive every window.
    ///
    /// `--preferences` is answered by `PreferencesRemoteControl`, and that has
    /// to be a SwiftUI view because `openSettings` is a SwiftUI environment
    /// action and is the only supported way to open a `Settings` scene.
    /// `StatusItemLabel` used to be the app's long-lived view; with
    /// `MenuBarExtra` gone, the status item's button is the thing that lives
    /// from launch to quit, so the view is hosted inside it.
    ///
    /// One point across, and never the answer to a click: `PassthroughHostingView`
    /// refuses to hit-test, so pressing the menu bar icon still reaches the
    /// button's action and opens the panel.
    private func installPreferencesObserver(in button: NSStatusBarButton) {
        let host = PassthroughHostingView(rootView: PreferencesRemoteControl())
        host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        button.addSubview(host)
        preferencesHost = host
    }
}

// MARK: - The panel's window

/// The history panel's window.
///
/// Borderless, because it is a panel under the menu bar and not a document
/// window, and non-activating, because an `LSUIElement` app showing a window
/// must not take the user's frontmost application away from them.
///
/// It must become key, and that is stated here rather than left to a default: a
/// borderless window refuses key status unless `canBecomeKey` says otherwise,
/// and a panel that could not become key would look right and be useless -- the
/// search field would swallow no keystrokes, `MenuKeyHandler`'s monitor would
/// see no events for this window, and `PasteService.stillHasFocus` would report
/// that Clipvelope had already given the keyboard back while the panel was still
/// on screen, so a direct paste would fire into the panel's own search field.
///
/// The opposite decision from `NoticePanel`, deliberately, and for the same
/// reason: that one must never be key, this one must always be.
final class HistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// Main is for an app's principal window. Claiming it would make an agent
    /// app look active to things that ask.
    override var canBecomeMain: Bool { false }
}

/// A hosting view that is never what a click hits.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @objc required dynamic init?(coder: NSCoder) {
        fatalError("PassthroughHostingView is never loaded from a nib")
    }
}

// MARK: - --preferences

/// Answers `Clipvelope --preferences`. It draws nothing.
///
/// It exists as a view, rather than as a line in `MenuBarController`, because
/// `openSettings` is a SwiftUI environment action and only a view has an
/// environment. It is hosted in the status item's button so that it is alive
/// whenever the app is -- the request can arrive at any moment, and the panel,
/// which is the app's only other SwiftUI surface, is closed most of the time.
///
/// The token check is the whole of `--preferences`'s security: a distributed
/// notification can be posted by any process in the login session, so a request
/// that does not carry this launch's token is ignored. See `RemoteControl`. Do
/// not drop it and do not loosen it.
struct PreferencesRemoteControl: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onReceive(DistributedNotificationCenter.default()
                .publisher(for: RemoteControl.preferencesNotification)
                .filter { RemoteControl.isAuthentic($0) }) { _ in
                openSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    bringSettingsWindowForward()
                }
            }
    }
}
