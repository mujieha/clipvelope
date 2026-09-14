import AppKit

// MARK: - Telling the user something with no window open

/// A small panel below the menu bar that carries a message when there is no
/// Clipvelope window on screen to carry it.
///
/// Why this exists at all. Every message this app has for the user went to
/// `ClipboardStore.notice`, and that property has exactly one reader: the state
/// strip at the bottom of the history panel. Three of the places that write to
/// it only ever fire when that panel is **closed** -- a direct paste reports
/// after `closePanelThenPaste` has already dismissed the panel, and a Quick Slot
/// is a global hotkey, used with the panel closed, always. So the sentences that
/// tell someone their paste did not happen, and what to do instead, were written
/// into a view that did not exist and cleared again seconds later. A user who
/// turned the feature on, pressed Return and got no paste was told nothing.
///
/// Why a panel rather than a notification. `UNUserNotification` would ask for a
/// permission, and needing no permissions beyond the one Accessibility grant is
/// a property this app sells and `Hotkeys.swift` goes out of its way to keep. It
/// would also be silenced by a Focus mode and would sit in Notification Center
/// afterwards, where a message about an entry that may be a password does not
/// belong. A borderless panel needs nothing, appears at once, and is gone.
///
/// Why it is not enough to make the notice sticky until the panel is next
/// opened. Nothing gives the user a reason to open the panel: from where they
/// sit the paste simply did not happen, and the next thing they do is press
/// Command + V or type it again.
///
/// Quiet on success, always. A paste that worked says nothing, because the text
/// appearing where the user was typing is the message.
final class NoticeHUD {
    static let shared = NoticeHUD()

    /// Fixed width. Wide enough for the longest of the outcome messages in two
    /// or three lines, narrow enough not to cover what the user is reading.
    private static let width: CGFloat = 360
    /// Distance from the top-right of the usable screen, which already excludes
    /// the menu bar. Puts the panel under the status item the message is about.
    private static let inset = CGPoint(x: 14, y: 10)
    private static let fade: TimeInterval = 0.25

    private var panel: NoticePanel?
    private var label: NSTextField?
    private var dismissal: DispatchWorkItem?
    /// Bumped by every `show` and every `dismiss`, and captured by the fade's
    /// completion handler so a stale one can tell it has been superseded.
    ///
    /// Setting `alphaValue` directly does not cancel an `animator()` animation
    /// already in flight, and the animation group's completion handler runs at
    /// the end of the group whatever the property now says. Without this token a
    /// message arriving inside the 250ms fade -- within a quarter second of the
    /// auto-dismiss firing, or of the user clicking the previous one away -- is
    /// ordered front, faded to nothing by the animation that was already
    /// running, and then ordered out by a completion handler that belongs to the
    /// message it replaced. The dismissal timer afterwards sees an invisible
    /// panel and does nothing, so the user never reads it -- which is the exact
    /// failure this whole type exists to remove.
    private var generation = 0

    private init() {}

    /// Whether a fade that has just finished may take the window off screen.
    ///
    /// Pure, and separate from the animation, for the same reason
    /// `PasteService.refusal` is pure: the rule is the fix, and a test cannot
    /// run a 250ms window-server fade but can check the decision the fade's
    /// completion handler makes. `started` is the generation the fade captured
    /// when it began, `current` the one the HUD is on now.
    static func mayOrderOut(started: Int, current: Int) -> Bool { started == current }

    /// Shows `text` for `duration` seconds. A second call replaces the message
    /// and restarts the clock rather than stacking a second panel, so a burst of
    /// failures leaves one readable sentence instead of a pile.
    ///
    /// Main queue only: it makes a window.
    func show(_ text: String, for duration: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(.main))

        let panel = panel ?? makePanel()
        label?.stringValue = text
        layout(panel)

        dismissal?.cancel()
        generation += 1
        // Both halves are needed, and they fix different things.
        //
        // Animating to 1 over zero seconds, rather than assigning `alphaValue`,
        // because an assignment does not stop an `animator()` animation already
        // in flight: the fade keeps driving the property and the panel carries
        // on towards invisible with the new message in it. Starting a new
        // animation on the same property is what replaces the running one, and a
        // zero duration makes the replacement instantaneous.
        //
        // The token then handles the other half: a replaced animation still runs
        // its group's completion handler, and that handler orders the window
        // out.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        // `orderFrontRegardless`, not `makeKeyAndOrderFront`: taking the
        // keyboard is the one thing this must never do. It would put a key
        // window back under `PasteService.stillHasFocus`, which reads exactly
        // that, and the next paste would refuse itself.
        panel.orderFrontRegardless()

        // VoiceOver does not announce a panel that never becomes key, and a
        // message no one can hear is the failure this whole type exists to fix.
        NSAccessibility.post(element: NSApp as Any,
                             notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])

        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Fades the panel out. Kept rather than destroyed: the next message reuses
    /// it, and a window that is only ordered out costs nothing while it waits.
    func dismiss() {
        dispatchPrecondition(condition: .onQueue(.main))
        dismissal?.cancel()
        dismissal = nil
        generation += 1
        let token = generation
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fade
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Only if nothing has been asked of the HUD since this fade began.
            // A `show` inside the fade has already put a new message on screen
            // and made the panel opaque again; ordering out here would take that
            // message away a quarter second after it appeared, and the new
            // dismissal timer would then find an invisible panel and do nothing.
            guard let self, Self.mayOrderOut(started: token, current: self.generation) else {
                return
            }
            panel.orderOut(nil)
        })
    }

    private func makePanel() -> NoticePanel {
        let panel = NoticePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 64),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above ordinary windows, so it is not hidden by whatever the user
        // switched to, and it follows them across spaces and into full screen --
        // where a paste failure is just as likely and the menu bar is not even
        // visible to hint at where the app went.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false

        // The same symbol and the same orange the state strip uses for a
        // degraded state, so the two surfaces for one message look like one
        // thing rather than two.
        let symbol = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle.fill",
                                                accessibilityDescription: nil)
            ?? NSImage())
        symbol.contentTintColor = .systemOrange
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        symbol.setAccessibilityHidden(true)
        symbol.translatesAutoresizingMaskIntoConstraints = false

        let text = NSTextField(wrappingLabelWithString: "")
        text.font = .systemFont(ofSize: 12)
        text.textColor = .labelColor
        text.isSelectable = false
        text.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(symbol)
        background.addSubview(text)
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            symbol.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            text.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            text.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            text.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -11)
        ])

        // Clicking it takes it away. There is nothing else to do with it, and a
        // message that cannot be dismissed is in the way.
        background.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(clicked)))

        panel.contentView = background
        text.preferredMaxLayoutWidth = Self.width - 12 - 13 - 8 - 12
        self.panel = panel
        label = text
        return panel
    }

    @objc private func clicked() { dismiss() }

    /// Sizes the panel to the message and puts it under the right-hand end of
    /// the menu bar, where the status item it is speaking for lives.
    private func layout(_ panel: NoticePanel) {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = max(content.fittingSize.height, 44)

        // The screen the pointer is on, not `NSScreen.main`, which on a Mac with
        // more than one display is the screen with the key window -- and this
        // app has none at the moment it needs to say something.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: frame.maxX - Self.width - Self.inset.x,
                              y: frame.maxY - height - Self.inset.y,
                              width: Self.width,
                              height: height),
                       display: true)
    }
}

/// A panel that cannot take the keyboard.
///
/// A borderless panel already refuses to become key, but that is a default two
/// style-mask flags away from changing, and the consequence would be silent and
/// specific: `PasteService.stillHasFocus` treats any key window as Clipvelope
/// holding the keyboard, so a HUD that could become key would make the next
/// paste refuse itself and report a focus failure. Stated here so it cannot
/// drift.
private final class NoticePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
