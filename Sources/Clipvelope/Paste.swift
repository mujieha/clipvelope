import AppKit
import ApplicationServices

// MARK: - Pasting

/// Presses Command + V for the user, so choosing an entry puts it where they
/// were typing instead of only on the clipboard.
///
/// This is the one thing Clipvelope does that needs a permission, and the only
/// reason it is worth it is that the third keystroke is most of why people
/// install a clipboard manager at all. Synthesising a keystroke means posting a
/// `CGEvent`, and macOS gates that behind **Accessibility** access -- the same
/// grant that would let this app read every window on the machine.
///
/// `Hotkeys.swift` explains at length why the global shortcuts use Carbon's
/// `RegisterEventHotKey` rather than an `NSEvent` global monitor: precisely so
/// that the app needs no permission at all. That property is deliberately kept.
/// Everything here is inert until the user turns `pasteDirectly` on *and*
/// grants Accessibility, nothing in this file runs on any other path, and the
/// setting cannot be switched on by a file -- see `ClipboardStore.disarming`.
///
/// Free of SwiftUI on purpose: this is system plumbing, and the view layer only
/// ever sees the outcome.
enum PasteService {
    /// What an attempt to paste actually did.
    ///
    /// Three situations, not two, because the remedies are three different
    /// things: grant a permission, try again, or press Command + V yourself. A
    /// `Bool` here would collapse "you have not allowed this yet" into "it did
    /// not work", and the user would have no way to tell which they were
    /// looking at.
    enum Outcome: Equatable {
        /// Command + V was posted. Whether the app underneath honoured it is
        /// that app's business and cannot be observed from here.
        case pasted
        /// Accessibility access has not been granted, so nothing was posted.
        case notTrusted
        case failed(Reason)

        /// Why a trusted paste still did not happen. Two genuinely different
        /// faults that must not be reported with one message.
        enum Reason: Equatable {
            /// CoreGraphics would not hand over an event to post.
            case noEvent
            /// Clipvelope still had keyboard focus when the wait ran out.
            /// Posting anyway would have typed Command + V into the panel the
            /// user just closed rather than into their document.
            case focusDidNotReturn
        }
    }

    /// Virtual key code for V, the same one `KeyCombo.defaultOpen` uses.
    static let virtualKeyV: CGKeyCode = 9

    /// How long to wait for the panel to hand the keyboard back before giving
    /// up. Dismissing a window is a matter of milliseconds; anything past this
    /// is not slowness but something actually wrong, and a paste half a second
    /// late would land in whatever the user has started doing since.
    static let focusTimeout: TimeInterval = 0.5

    /// How long to wait *after* the panel has given up the keyboard, before
    /// posting.
    ///
    /// Measured, on an M-series Mac, by opening the real panel with its own
    /// hotkey, dismissing it with Escape -- which runs the same
    /// `keyWindow.close()` the store calls -- and posting Command + V a fixed
    /// number of milliseconds later into a scratch text window, then looking at
    /// whether the text arrived:
    ///
    ///     ~3ms   arrived once, swallowed once
    ///     10ms   swallowed
    ///     25ms   arrived, three times out of three
    ///     50ms   arrived, twice out of twice
    ///
    /// Swallowed means the panel still had the keyboard and the keystroke went
    /// to Clipvelope, where there is nothing to paste into: the entry simply
    /// never appears. Those timings are measured from the Escape *keystroke*,
    /// which is earlier than where this wait starts -- by then the app has
    /// already received the key, run the handler and closed the window -- so 50
    /// milliseconds is comfortably past the point where it became reliable, and
    /// is still well under what anyone notices.
    ///
    /// The window server, not AppKit, decides where a posted key goes, and
    /// nothing in-process reports when it has caught up. That is why this is a
    /// delay rather than another thing to wait for.
    private static let settleDelay: TimeInterval = 0.05

    /// How often the wait re-checks. Short enough not to add a perceptible
    /// delay of its own, long enough not to spin the main queue.
    private static let pollInterval: TimeInterval = 0.005

    /// Where the synthesised keystroke is injected.
    ///
    /// `.cghidEventTap` puts it in at the level the keyboard itself feeds, so
    /// every consumer sees it exactly as it sees a real Command + V. The
    /// alternative, `.cgAnnotatedSessionEventTap`, injects further downstream
    /// and is invisible to anything reading below that point -- which is not a
    /// theoretical difference: posting Clipvelope's own open-history hotkey
    /// through the session tap does not open the panel at all, because Carbon's
    /// `RegisterEventHotKey`, which `Hotkeys.swift` uses, never sees it. An app
    /// that implements paste through a hot key or a low-level tap would ignore
    /// a session-tap Command + V in the same silent way. Both taps delivered
    /// Command + V to an ordinary text view in testing; only this one reaches
    /// everything, so it is the one with nothing to quietly miss.
    private static let eventTap: CGEventTapLocation = .cghidEventTap

    /// Whether macOS will let this process post keyboard events. Asks without
    /// prompting, so it is safe to call while drawing a window.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system's own Accessibility prompt, which is the only honest
    /// way to ask: macOS, not Clipvelope, describes what is being granted, and
    /// the switch is thrown in System Settings rather than here.
    ///
    /// Returns nothing, because the answer does not arrive here either -- the
    /// user may take minutes over it, and `isTrusted` is what tells you how it
    /// went.
    static func requestTrust() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// Posts Command + V immediately, wherever focus happens to be.
    ///
    /// Callers dismissing a window first want `pasteWhenFocusReturns` instead;
    /// this one is the raw act.
    @discardableResult
    static func paste() -> Outcome {
        guard isTrusted else { return .notTrusted }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: false)
        else { return .failed(.noEvent) }

        // Posting an event otherwise suppresses the user's own keyboard and
        // mouse for the next quarter second. Someone who chose an entry and
        // kept typing would lose the characters they typed, which looks like
        // dropped input rather than like a paste.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents],
            state: .eventSuppressionStateSuppressionInterval)

        // The flag goes on *both* events. A key-up without it leaves some apps
        // believing Command is still held, and the next letter typed becomes a
        // menu shortcut.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: eventTap)
        up.post(tap: eventTap)
        return .pasted
    }

    /// Posts Command + V once Clipvelope has given the keyboard back, and
    /// reports what happened.
    ///
    /// The wait is the whole point. A Command + V posted while the history
    /// panel still holds the keyboard goes to Clipvelope, which has nothing to
    /// paste into: the entry never appears and nothing says why. Callers should
    /// close the panel first and then call this -- it does not close anything
    /// itself, it only refuses to post until the panel has gone.
    ///
    /// `focusTimeout` is a ceiling, not a schedule: in the ordinary case the
    /// first check already passes and only `settleDelay` is spent.
    ///
    /// `completion` runs on the main queue.
    static func pasteWhenFocusReturns(timeout: TimeInterval = focusTimeout,
                                      completion: @escaping (Outcome) -> Void) {
        // Checked before the wait as well as inside `paste()`, so an ungranted
        // permission is reported at once instead of after half a second of
        // watching for a focus change that would not have helped.
        guard isTrusted else { return completion(.notTrusted) }
        waitForFocus(deadline: Date().addingTimeInterval(timeout), completion: completion)
    }

    private static func waitForFocus(deadline: Date, completion: @escaping (Outcome) -> Void) {
        guard stillHasFocus else {
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
                completion(paste())
            }
            return
        }
        guard Date() < deadline else { return completion(.failed(.focusDidNotReturn)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            waitForFocus(deadline: deadline, completion: completion)
        }
    }

    /// True while a keystroke posted now would come back to Clipvelope.
    ///
    /// Three questions rather than one, because they disagree, and the one that
    /// actually answers it here is the first. Measured: with the history panel
    /// open and taking every keystroke the user types, Clipvelope is *not* the
    /// active application and *not* what `frontmostApplication` names -- an
    /// LSUIElement app does not become frontmost, which is the same fact
    /// `Views.swift` records about the Settings window. So the only signal that
    /// moves when the panel opens and closes is whether the app has a key
    /// window. The other two stay for the cases this one does not cover: an
    /// ordinary window such as Preferences taking the keyboard back, which is a
    /// situation where pasting would be wrong anyway and the wait rightly times
    /// out. Any of the three being true is reason enough not to post yet.
    private static var stillHasFocus: Bool {
        if NSApplication.shared.keyWindow != nil { return true }
        if NSRunningApplication.current.isActive { return true }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
    }
}
