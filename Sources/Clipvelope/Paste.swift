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
/// grants Accessibility, and nothing in this file runs on any other path.
///
/// What an imported file can do to that setting, stated exactly, because an
/// earlier version of this comment claimed more than the code keeps. A
/// *portable* backup -- one sealed with a password, which can come from anyone
/// -- cannot switch it on: `ClipboardStore.disarming` discards the imported
/// value and pins this Mac's own, in both directions. A *device-bound* backup
/// -- sealed with this Mac's Keychain key, which is the auto-backup file in
/// `~/Documents` as well as a keychain export -- skips `disarming` entirely and
/// reaches `apply`, which assigns `pasteDirectly` with no trust gate. That is
/// deliberate: such a file can only have been written by this app on this Mac,
/// so restoring it returns the user's own settings, and it can only put back a
/// state this Mac was once in -- it cannot invent an answer the user never
/// gave. `SECURITY.md` documents the same thing as a bounded rollback limit,
/// and the two must not drift apart again.
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

        /// Why a trusted paste still did not happen. Six genuinely different
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
            /// Clipvelope itself was the frontmost application when the user
            /// chose the entry, so there was never anywhere else for it to go.
            ///
            /// Its own case, and not `destinationNotConfirmed`, because that
            /// message says "you were not still in the application you started
            /// in" -- a sentence that is simply untrue here, since the
            /// application they started in *was* Clipvelope. Posting is refused
            /// either way; the point of the distinction is that the user is told
            /// something that matches what they did.
            case startedInClipvelope
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
            case .failed(.startedInClipvelope):
                return "The entry was copied, but Clipvelope itself was in front when you chose "
                    + "it, so there was nowhere to paste it. Click where you want it and press "
                    + "Command + V."
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
        //
        // **Measured**, which the change to this value originally was not, and
        // it is the half that could have broken direct paste for everyone: if a
        // private-state source did not work with `.cghidEventTap`, the only
        // symptom would have been the absence of text. Six posts into a scratch
        // TextEdit document -- this exact sequence, same tap, same suppression
        // filter, same explicit flags -- three from each source, alternating:
        //
        //     .privateState          arrived, three times out of three
        //     .combinedSessionState  arrived, three times out of three
        //
        // and the events went out carrying `maskCommand` and nothing else from
        // either source. So the known-working value was not traded for a guess;
        // both work, and this one additionally cannot fold in a held modifier
        // at creation time.
        //
        // **Open question, deliberately left open.** Whether a *physically*
        // held Option bleeds into a posted event at the window server, past the
        // explicit `flags` assignment, is not settled here. It cannot be: an
        // automated check cannot hold a key down, and the only API that reports
        // the session's live modifier state, `CGEventSourceFlagsState`,
        // deadlocked inside SkyLight when it was tried with a synthetic Option
        // outstanding -- which is a worse failure than the one being guarded
        // against. The defence costs nothing measurable and is kept on that
        // basis, not on a measurement it does not have.
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
    ///   - own: this process's identifier, so a destination that is Clipvelope
    ///     itself can be named rather than reported as a failure to confirm.
    static func refusal(trusted: Bool,
                        now: Date,
                        postBy postDeadline: Date,
                        destination: pid_t?,
                        frontmost: pid_t?,
                        clipboardWas: Int,
                        clipboardIs: Int,
                        own: pid_t) -> Outcome? {
        guard trusted else { return .notTrusted }
        guard clipboardWas == clipboardIs else { return .failed(.clipboardChanged) }
        // Before the guard below, because it is the one case in which that
        // guard's sentence would be false rather than merely unhelpful.
        //
        // `closePanelThenPaste` stamps the frontmost process on the reasoning
        // that an LSUIElement app never becomes frontmost -- which is true of
        // the history panel and of Preferences merely being open, and not true
        // at all once something calls `NSApp.activate(ignoringOtherApps: true)`.
        // `Views.swift` does exactly that in two places, and the plausible route
        // through them is onboarding: open Preferences, switch Paste Directly
        // on, close it, open the panel, press Return. The stamp is then
        // Clipvelope's own process.
        //
        // Refusing is right -- there is no document behind the panel to paste
        // into, and `stillHasFocus` would refuse independently -- but the right
        // thing to *say* is that the user was in Clipvelope, not that they left
        // the application they started in.
        if let destination, destination == own { return .failed(.startedInClipvelope) }
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
                clipboardIs: NSPasteboard.general.changeCount,
                own: ownProcess)
    }

    /// Which process is in front, for stamping and for checking.
    ///
    /// Sound as a record of where the *user* is while the history panel has the
    /// keyboard: an `LSUIElement` app does not become frontmost merely by
    /// showing a window, which is the measurement `stillHasFocus` records below.
    ///
    /// It can name Clipvelope all the same, because `NSApp.activate` overrides
    /// that -- `Views.swift` calls it when Preferences is brought forward and
    /// for the Delete Everything alert. Callers stamping a destination must
    /// therefore compare against `ownProcess`; `refusal` does.
    static var frontmostProcess: pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// This process. Named here so the rule about it reads as one thing.
    static var ownProcess: pid_t { ProcessInfo.processInfo.processIdentifier }

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
    /// LSUIElement app does not become frontmost by showing a window, which is
    /// the same fact `Views.swift` records about the Settings window. (It does
    /// become frontmost when something calls `NSApp.activate`, which is why the
    /// third check below is kept and why `refusal` compares a stamped
    /// destination against `ownProcess`.) So the only signal that
    /// moves when the panel opens and closes is whether the app has a key
    /// window. The other two stay for the cases this one does not cover: an
    /// ordinary window such as Preferences taking the keyboard back, which is a
    /// situation where pasting would be wrong anyway and the wait rightly times
    /// out. Any of the three being true is reason enough not to post yet.
    private static var stillHasFocus: Bool {
        if NSApplication.shared.keyWindow != nil { return true }
        if NSRunningApplication.current.isActive { return true }
        return frontmostProcess == ownProcess
    }
}
