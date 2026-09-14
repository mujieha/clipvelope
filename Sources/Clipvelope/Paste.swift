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
    /// Several situations, not two, because the remedies differ: grant a
    /// permission, try again, or press Command + V yourself. A `Bool` here would
    /// collapse "you have not allowed this yet" into "it did not work", and the
    /// user would have no way to tell which they were looking at.
    enum Outcome: Equatable {
        /// Command + V was posted. Whether the app underneath honoured it is
        /// that app's business and cannot be observed from here.
        case pasted
        /// Accessibility access has not been granted, so nothing was posted.
        case notTrusted
        case failed(Reason)

        /// Why a trusted paste still did not happen. Five genuinely different
        /// faults that must not be reported with one message.
        enum Reason: Equatable {
            /// CoreGraphics would not hand over an event to post.
            case noEvent
            /// Clipvelope still had keyboard focus when the wait ran out.
            /// Posting anyway would have typed Command + V into the panel the
            /// user just closed rather than into their document.
            case focusDidNotReturn
            /// Too long passed between the user choosing the entry and the
            /// keystroke being ready to go out. Not the same fault as the one
            /// above: there the panel would not let go, here the user has had
            /// time to move somewhere else, and posting would type the entry
            /// into whatever they moved to.
            case tookTooLong
            /// The application in front when the user chose the entry is not
            /// the one in front now -- or there was none to record. Not the
            /// same fault as `tookTooLong`, which only infers from elapsed time
            /// that the user *may* have moved: this is the move itself,
            /// observed. A paste inside the deadline still lands in the wrong
            /// application if the user switched during it, and a switch takes
            /// about 300ms against a two-second window.
            case destinationNotConfirmed
            /// Something replaced the entry on the clipboard between the copy
            /// and the keystroke -- a Quick Slot command finishing, or any
            /// other application writing to the pasteboard. Posting now would
            /// paste that other thing while the app reported success by saying
            /// nothing. Its own case because its remedy is the only one that
            /// differs: Command + V will not help, the entry has to be chosen
            /// again.
            case clipboardChanged
        }

        /// What to tell the user, or `nil` when there is nothing to say.
        ///
        /// Here rather than in the store so that adding a case to `Reason`
        /// cannot compile until someone has written the sentence for it. A
        /// silent outcome has to be chosen, not forgotten.
        ///
        /// A paste that worked says nothing, because the text appearing where
        /// the user was typing is the message. Every other message says the
        /// entry *was* copied where that is still true, because a user who
        /// thinks the copy failed as well would go back and choose it again --
        /// and `clipboardChanged` is exactly the case where it is no longer
        /// true, so it says the opposite.
        var message: String? {
            switch self {
            case .pasted:
                return nil
            case .notTrusted:
                return "Clipvelope has not been allowed to paste for you yet. The entry was "
                    + "copied, so Command + V will paste it. Preferences explains the rest."
            case .failed(.noEvent):
                return "The entry was copied, but the keystroke that pastes it could not be "
                    + "sent. Press Command + V to paste it."
            case .failed(.focusDidNotReturn):
                return "The entry was copied, but the window you were in did not take focus "
                    + "back, so nothing was pasted. Press Command + V to paste it."
            case .failed(.tookTooLong):
                return "The entry was copied, but it took long enough that pasting it might "
                    + "have put it somewhere you had moved on to, so nothing was pasted. "
                    + "Press Command + V to paste it where you want it."
            case .failed(.destinationNotConfirmed):
                return "The entry was copied, but Clipvelope could not confirm you were still "
                    + "in the application you started in, so nothing was pasted. Press "
                    + "Command + V to paste it where you want it."
            case .failed(.clipboardChanged):
                return "The entry was copied, but something else replaced it on the clipboard "
                    + "before it could be pasted, so nothing was pasted and the clipboard now "
                    + "holds that other thing. Choose the entry again."
            }
        }
    }

    /// Virtual key code for V, the same one `KeyCombo.defaultOpen` uses.
    static let virtualKeyV: CGKeyCode = 9

    /// How long to wait for the panel to hand the keyboard back before giving
    /// up. Dismissing a window is a matter of milliseconds; anything past this
    /// is not slowness but something actually wrong, and a paste half a second
    /// late would land in whatever the user has started doing since.
    static let focusTimeout: TimeInterval = 0.5

    /// How long after the user chose an entry the keystroke may still go out.
    ///
    /// `focusTimeout` bounds only the wait for the panel to let go. It does not
    /// bound the gap between the user pressing Return and this code being asked
    /// to post, because the copy happens in between and an image or a formatted
    /// entry reads its payload on a serial queue shared with index saves, vault
    /// clears, and a backup that may serialise every payload in the vault. With
    /// that queue busy the copy can complete seconds late, and by then the
    /// frontmost application is whatever the user turned to in the meantime --
    /// so posting would type a history entry, which this app's own premise says
    /// may be a password, into an application they never chose.
    ///
    /// Two seconds: comfortably longer than `focusTimeout` plus an ordinary
    /// payload read, comfortably shorter than the point at which someone has
    /// moved on. Past it the entry is still on the clipboard and the user is
    /// told to press Command + V themselves, which puts the choice of where it
    /// lands back with them.
    static let postWindow: TimeInterval = 2

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
        // `.privateState`, not `.combinedSessionState`, and the difference
        // matters for exactly one key: the one the user may still be holding.
        //
        // A combined-session source carries the session's live modifier state,
        // which includes whatever is physically down right now. "Copy as Plain
        // Text" is Option + Return, and for a formatted entry the copy is
        // synchronous, so the post happens roughly `settleDelay` after the
        // key-down -- 50ms, far inside the time anyone holds a modifier. The
        // event would then go out as Command + Option + V, which in Finder is
        // Move Item Here, and the `.files` content case really does put file
        // URLs on the pasteboard. A private state table starts empty and is
        // changed only by events this source posts, so nothing the user's own
        // hands are doing can be folded in. The explicit `flags` assignments
        // below then say exactly which modifiers this keystroke carries.
        guard let source = CGEventSource(stateID: .privateState),
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
    /// `postBy` is the moment after which this must not post at all. It is a
    /// `Date` rather than a duration so that the caller can stamp it when the
    /// *user* acted, which is earlier than this call and is the only clock that
    /// answers "has the user moved on since". `ClipboardStore` stamps it before
    /// the copy it hangs this off.
    ///
    /// `destination` is the process the user was in when they acted, from
    /// `frontmostProcess`, and bounds *where* the keystroke may go in the same
    /// way `postBy` bounds when. `clipboard` is `NSPasteboard.changeCount`
    /// sampled once the copy had landed, and bounds *what* is pasted; it is
    /// compared against the general pasteboard, because that is the one a
    /// keystroke pastes from whatever the store was handed. Neither has a
    /// default, for the same reason `postBy` no longer has one: the old default
    /// was `Date().addingTimeInterval(postWindow)` evaluated at call time, which
    /// quietly rebuilt the bug it was added to fix for any caller that omitted
    /// it.
    ///
    /// `completion` runs on the main queue.
    static func pasteWhenFocusReturns(postBy postDeadline: Date,
                                      destination: pid_t?,
                                      clipboard clipboardAtCopy: Int,
                                      timeout: TimeInterval = focusTimeout,
                                      completion: @escaping (Outcome) -> Void) {
        // Checked before the wait as well as inside `paste()`, so an ungranted
        // permission -- or a deadline already gone -- is reported at once
        // instead of after half a second of watching for a focus change that
        // would not have helped.
        if let refusal = refusalNow(postBy: postDeadline, destination: destination,
                                    clipboard: clipboardAtCopy) {
            return completion(refusal)
        }
        waitForFocus(until: Date().addingTimeInterval(timeout), postBy: postDeadline,
                     destination: destination, clipboard: clipboardAtCopy,
                     completion: completion)
    }

    /// Everything that has to be true for a keystroke to go out, in one place
    /// and with no clock, window server or event of its own: `nil` to post, or
    /// the outcome to report instead.
    ///
    /// Pure on purpose. `paste()` synthesises a real Command + V into whatever
    /// the machine is doing, so a test may not call it -- and the deadline, the
    /// destination and the clipboard are exactly the parts that most need
    /// testing. Keeping the decision here means the production path has one gate
    /// rather than several scattered checks, and the test drives the same code
    /// the app does.
    ///
    /// The order is the order of the sentences the user would get.
    /// `notTrusted` comes first because it is a statement about how the app is
    /// set up rather than about this attempt, and no deadline or destination
    /// would have made that paste happen. Then the clipboard, because every
    /// remaining message ends "press Command + V", which is only sound advice
    /// while the clipboard still holds the entry. Then the destination, which
    /// is a move that was *observed*, ahead of the deadline, which only infers
    /// from elapsed time that a move may have happened.
    ///
    /// - Parameters:
    ///   - destination: the frontmost process when the user chose the entry,
    ///     `nil` if there was none to record.
    ///   - frontmost: the frontmost process now, `nil` if there is none.
    ///   - clipboardWas: `NSPasteboard.changeCount` just after the copy landed.
    ///   - clipboardIs: `NSPasteboard.changeCount` now.
    static func refusal(trusted: Bool,
                        now: Date,
                        postBy postDeadline: Date,
                        destination: pid_t?,
                        frontmost: pid_t?,
                        clipboardWas: Int,
                        clipboardIs: Int) -> Outcome? {
        guard trusted else { return .notTrusted }
        guard clipboardWas == clipboardIs else { return .failed(.clipboardChanged) }
        // Three situations collapse into this one guard, deliberately.
        //
        // The user switched applications: the identifiers differ, which is the
        // case the whole check exists for. The application they were in quit:
        // `frontmost` is some other process or `nil`, and either way it is not
        // the one they chose the entry from, so refusing is right. And there
        // was no frontmost application to record at all: `destination` is nil,
        // so there is nothing to confirm against and posting would be a guess.
        // The message is worded for all three -- "could not confirm" is true of
        // each, where "you switched applications" would be a lie in the last
        // two.
        //
        // The case this guard deliberately lets through is the same application
        // with a different window in front. `NSWorkspace` names a process, not
        // a window, and asking which window has focus means an Accessibility
        // round trip into that application's main thread, which can block on an
        // application that is busy -- the very failure mode the rest of this
        // file is built to avoid. It is also much the smaller mistake: the
        // user's own Command + V would land in that same window.
        guard let destination, destination == frontmost else {
            return .failed(.destinationNotConfirmed)
        }
        guard now < postDeadline else { return .failed(.tookTooLong) }
        return nil
    }

    /// The same decision against the machine as it is right now. The one place
    /// the live readings are taken, so every gate on the path asks the same
    /// questions.
    private static func refusalNow(postBy postDeadline: Date,
                                   destination: pid_t?,
                                   clipboard clipboardAtCopy: Int) -> Outcome? {
        refusal(trusted: isTrusted,
                now: Date(),
                postBy: postDeadline,
                destination: destination,
                frontmost: frontmostProcess,
                clipboardWas: clipboardAtCopy,
                clipboardIs: NSPasteboard.general.changeCount)
    }

    /// Which process is in front, for stamping and for checking.
    ///
    /// Sound as a record of where the *user* is even while the panel has the
    /// keyboard: Clipvelope is `LSUIElement` and never becomes frontmost, which
    /// is the measurement `stillHasFocus` records below.
    static var frontmostProcess: pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private static func waitForFocus(until focusDeadline: Date, postBy postDeadline: Date,
                                     destination: pid_t?, clipboard clipboardAtCopy: Int,
                                     completion: @escaping (Outcome) -> Void) {
        guard stillHasFocus else {
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
                // Asked again here, not only on the way in: the focus wait and
                // the settle delay are themselves time, and this is the last
                // instant before the keystroke becomes irretrievable.
                if let refusal = refusalNow(postBy: postDeadline, destination: destination,
                                            clipboard: clipboardAtCopy) {
                    return completion(refusal)
                }
                // And focus again, which the first version of this block did
                // not do -- it called this the last instant before the keystroke
                // becomes irretrievable and then checked two of its three
                // conditions. Clipvelope can take the keyboard back inside these
                // 50 milliseconds: the open-history hotkey pressed a second
                // time, or Preferences coming forward. Command + V would then
                // type the chosen entry, which this app's own premise says may
                // be a password, into the panel's search field, where it is
                // visible on screen and used as a filter.
                guard !stillHasFocus else { return completion(.failed(.focusDidNotReturn)) }
                completion(paste())
            }
            return
        }
        guard Date() < focusDeadline else {
            // The deadline before the focus failure. This branch used to return
            // without consulting `postBy` at all, so a copy that landed at 1.8s
            // and a panel that never let go reported "the window did not take
            // focus back" at 2.3s, when what had actually run out was the
            // window in which posting anywhere was still safe.
            if let refusal = refusalNow(postBy: postDeadline, destination: destination,
                                        clipboard: clipboardAtCopy) {
                return completion(refusal)
            }
            return completion(.failed(.focusDidNotReturn))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            waitForFocus(until: focusDeadline, postBy: postDeadline,
                         destination: destination, clipboard: clipboardAtCopy,
                         completion: completion)
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
