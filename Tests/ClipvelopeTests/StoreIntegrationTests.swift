import XCTest
import CryptoKit
@testable import Clipvelope

/// Drives the code paths behind the buttons: the Folders tab, Quick Slots,
/// pinning and deleting rows, and Export/Import in the Backup tab. The UI layer
/// on top is a file picker and some SwiftUI bindings; everything that can
/// actually go wrong lives here.
private struct FixedKeyStore: KeyProviding {
    let key: SymmetricKey
    init(seed: UInt8 = 1) { key = SymmetricKey(data: Data(repeating: seed, count: 32)) }
    func getOrCreateKey() throws -> SymmetricKey { key }
}

final class StoreIntegrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipvelope-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(_ name: String = "vault", seed: UInt8 = 1,
                           pasteboard: NSPasteboard = .general) -> ClipboardStore {
        let storage = EncryptedStorage(directory: root.appendingPathComponent(name),
                                       keyStore: FixedKeyStore(seed: seed))
        let store = ClipboardStore(storage: storage, enableSystemIntegration: false,
                                   pasteboard: pasteboard)
        settle(store)
        return store
    }

    /// Loads and saves hop between a serial I/O queue and the main queue, so a
    /// test has to drain both before asserting.
    private func settle(_ store: ClipboardStore, rounds: Int = 4) {
        for _ in 0..<rounds {
            store.drainPendingWork()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - Folders tab

    func testAddingAFolderPersistsAcrossRelaunch() {
        let store = makeStore()
        store.addFolder()
        store.folders[0].name = "Deploy"
        store.persistState()
        settle(store)

        let reopened = makeStore()
        XCTAssertEqual(reopened.folders.map(\.name), ["Deploy"])
    }

    func testAddingCommandsToAFolderPersists() {
        let store = makeStore()
        store.addFolder()
        store.folders[0].name = "Deploy"
        store.addCommand(to: store.folders[0])
        store.folders[0].items[0].title = "Ship it"
        store.folders[0].items[0].content = "echo deploying"
        store.folders[0].items[0].isShell = true
        store.persistState()
        settle(store)

        let reopened = makeStore()
        XCTAssertEqual(reopened.folders.count, 1)
        XCTAssertEqual(reopened.folders[0].items.map(\.title), ["Ship it"])
        XCTAssertTrue(reopened.folders[0].items[0].isShell)
    }

    func testRemovingAFolderPersists() {
        let store = makeStore()
        store.addFolder()
        store.addFolder()
        store.folders[0].name = "Keep"
        store.folders[1].name = "Drop"
        store.persistState()
        settle(store)

        store.removeFolder(store.folders[1])
        settle(store)

        XCTAssertEqual(makeStore().folders.map(\.name), ["Keep"])
    }

    func testRemovingACommandLeavesTheFolder() {
        let store = makeStore()
        store.addFolder()
        store.addCommand(to: store.folders[0])
        store.addCommand(to: store.folders[0])
        store.folders[0].items[0].title = "first"
        store.folders[0].items[1].title = "second"
        store.persistState()
        settle(store)

        store.removeCommand(folder: store.folders[0], item: store.folders[0].items[0])
        settle(store)

        let reopened = makeStore()
        XCTAssertEqual(reopened.folders.count, 1)
        XCTAssertEqual(reopened.folders[0].items.map(\.title), ["second"])
    }

    // MARK: - Quick Slots

    func testQuickSlotCopiesItsTextToThePasteboard() {
        let store = makeStore()
        store.addBinding()
        store.bindings[0].title = "Signature"
        store.bindings[0].content = "sent from a test"
        store.persistState()
        settle(store)

        NSPasteboard.general.clearContents()
        store.triggerBinding(slot: 1)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "sent from a test")
    }

    func testTriggeringAnEmptySlotDoesNothingRatherThanCrashing() {
        let store = makeStore()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("untouched", forType: .string)

        store.triggerBinding(slot: 7)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "untouched")
    }

    // MARK: - History rows

    func testPinDeleteAndReopen() {
        let store = makeStore()
        store.add(text: "one")
        store.add(text: "two")
        store.add(text: "three")
        settle(store)

        store.togglePin(store.items.first { $0.searchText == "one" }!)
        store.remove(store.items.first { $0.searchText == "two" }!)
        settle(store)

        let reopened = makeStore()
        XCTAssertEqual(Set(reopened.items.map(\.searchText)), ["one", "three"])
        XCTAssertTrue(reopened.items.first { $0.searchText == "one" }!.isPinned)
    }

    func testClearAllEmptiesTheVaultButKeepsSettings() {
        let store = makeStore()
        store.add(text: "secret")
        store.addFolder()
        store.themeMode = .dark
        store.persistState()
        settle(store)

        store.clearAll()
        settle(store)

        let reopened = makeStore()
        XCTAssertTrue(reopened.items.isEmpty)
        XCTAssertTrue(reopened.folders.isEmpty)
        XCTAssertEqual(reopened.themeMode, .dark)
    }

    // MARK: - Backup tab

    func testKeychainBackupRoundTripsIntoAFreshVault() {
        let source = makeStore("source")
        source.add(text: "remember me")
        source.addFolder()
        source.folders[0].name = "Snippets"
        source.persistState()
        settle(source)

        let backup = root.appendingPathComponent("keychain.cvb")
        source.exportBackup(to: backup, password: nil)
        settle(source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))

        // Same key, empty vault: what Import does on a reinstalled Mac.
        let destination = makeStore("destination")
        XCTAssertTrue(destination.items.isEmpty)

        destination.importBackup(from: backup, password: nil)
        settle(destination)

        XCTAssertEqual(destination.items.map(\.searchText), ["remember me"])
        XCTAssertEqual(destination.folders.map(\.name), ["Snippets"])
    }

    func testPasswordBackupRoundTripsOntoADifferentKey() {
        let source = makeStore("source", seed: 1)
        source.add(text: "portable entry")
        source.persistState()
        settle(source)

        let backup = root.appendingPathComponent("portable.cvb")
        source.exportBackup(to: backup, password: "correct horse")
        settle(source)

        // seed 2: a different Keychain key, i.e. a different Mac.
        let destination = makeStore("destination", seed: 2)
        destination.importBackup(from: backup, password: "correct horse")
        settle(destination)

        XCTAssertEqual(destination.items.map(\.searchText), ["portable entry"])
    }

    func testImportingWithTheWrongPasswordFailsVisiblyAndChangesNothing() {
        let source = makeStore("source")
        source.add(text: "original")
        source.persistState()
        settle(source)

        let backup = root.appendingPathComponent("portable.cvb")
        source.exportBackup(to: backup, password: "right")
        settle(source)

        let destination = makeStore("destination", seed: 2)
        destination.add(text: "existing entry")
        settle(destination)

        destination.importBackup(from: backup, password: "wrong")
        settle(destination)

        XCTAssertEqual(destination.items.map(\.searchText), ["existing entry"],
                       "a failed import must not wipe what was already there")
        XCTAssertNotNil(destination.backupFailure,
                        "a failed import must say so rather than fail silently")
        XCTAssertNil(destination.storageFailure,
                     "and it must not look like the vault itself is broken")
        XCTAssertFalse(destination.writesSuspended)
    }

    func testStartFreshIsRefusedWhileTheVaultIsReadable() {
        let store = makeStore()
        store.add(text: "precious")
        settle(store)

        store.discardUnreadableVault()
        store.retryLoadingVault()
        settle(store)

        XCTAssertEqual(store.items.map(\.searchText), ["precious"])
        XCTAssertEqual(makeStore().items.map(\.searchText), ["precious"],
                       "nothing was quarantined or rewritten on disk")
    }

    func testAKeychainBackupCannotBeOpenedOnAnotherMachine() {
        let source = makeStore("source", seed: 1)
        source.add(text: "device bound")
        source.persistState()
        settle(source)

        let backup = root.appendingPathComponent("keychain.cvb")
        source.exportBackup(to: backup, password: nil)
        settle(source)

        let elsewhere = makeStore("elsewhere", seed: 2)
        elsewhere.importBackup(from: backup, password: nil)
        settle(elsewhere)

        XCTAssertTrue(elsewhere.items.isEmpty)
        XCTAssertNotNil(elsewhere.backupFailure)
    }

    // MARK: - Privacy tab

    func testPausingCaptureSurvivesRelaunch() {
        let store = makeStore()
        store.setCaptureSuspended(true)
        settle(store)

        XCTAssertTrue(makeStore().captureSuspended)
    }

    /// Capturing passwords is opt-in and must stay that way: a fresh vault, and
    /// one whose file predates the setting, both start with it off.
    func testSensitiveCaptureIsOffByDefaultAndPersistsWhenTurnedOn() {
        let store = makeStore()
        XCTAssertTrue(store.skipConcealedContent,
                      "a fresh vault must not capture passwords")

        store.setSkipConcealedContent(false)
        settle(store)
        XCTAssertFalse(makeStore().skipConcealedContent,
                       "the opt-in must survive a relaunch")

        store.setSkipConcealedContent(true)
        settle(store)
        XCTAssertTrue(makeStore().skipConcealedContent)
    }

    /// Whatever the answer is on this machine, the store must report the same
    /// thing the key store actually does - a Preferences panel that disagreed
    /// with reality would be worse than showing nothing.
    func testKeyIsolationIsReportedHonestly() {
        XCTAssertEqual(makeStore().isKeyIsolated,
                       KeychainKeyStore.usesDataProtectionKeychain)
    }

    // MARK: - Pasting for the user

    /// The setting is one more field in the vault, and a vault written by 0.1.0
    /// has no such field. Its absence has to decode as off: anything else would
    /// switch on keystroke synthesis for everyone who upgrades.
    func testPasteDirectlyRoundTripsAndIsOffWhenTheKeyIsAbsent() throws {
        var state = AppState.empty
        state.pasteDirectly = true
        let encoded = try JSONEncoder().encode(state)
        XCTAssertTrue(try JSONDecoder().decode(AppState.self, from: encoded).pasteDirectly)

        let asWrittenBy010 = Data(#"{"schemaVersion":4,"items":[],"bindings":[],"folders":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(AppState.self, from: asWrittenBy010)
        XCTAssertFalse(decoded.pasteDirectly,
                       "a vault written before the setting existed must not have it on")
    }

    func testPastingDirectlyIsOffByDefaultAndTheChoicePersists() {
        let store = makeStore()
        XCTAssertFalse(store.pasteDirectly, "a fresh vault must not synthesise keystrokes")

        store.setPasteDirectly(true)
        settle(store)
        XCTAssertTrue(makeStore().pasteDirectly, "the opt-in must survive a relaunch")

        store.setPasteDirectly(false)
        settle(store)
        XCTAssertFalse(makeStore().pasteDirectly)
    }

    /// The security-relevant one. A portable backup is a file anyone can send,
    /// and one that could switch this on would be arranging for the Mac that
    /// opens it to type into whatever its owner happens to be doing.
    func testAPortableBackupCannotTurnPastingDirectlyOn() {
        let source = makeStore("source", seed: 1)
        source.setPasteDirectly(true)
        source.add(text: "portable entry")
        settle(source)

        let backup = root.appendingPathComponent("portable.cvb")
        source.exportBackup(to: backup, password: "correct horse")
        settle(source)

        // seed 2: a different Keychain key, i.e. a different Mac.
        let destination = makeStore("destination", seed: 2)
        XCTAssertFalse(destination.pasteDirectly)

        destination.importBackup(from: backup, password: "correct horse")
        settle(destination)

        XCTAssertEqual(destination.items.map(\.searchText), ["portable entry"],
                       "the entries themselves still import")
        XCTAssertFalse(destination.pasteDirectly,
                       "a file must not be able to switch on keystroke synthesis")
        XCTAssertFalse(makeStore("destination", seed: 2).pasteDirectly,
                       "and must not have left it on in the vault either")
    }

    /// The same rule in the other direction: the imported value is discarded,
    /// so a file cannot revoke a choice the user made on this Mac.
    func testAPortableBackupCannotTurnPastingDirectlyOff() {
        let source = makeStore("source", seed: 1)
        source.add(text: "portable entry")
        settle(source)
        XCTAssertFalse(source.pasteDirectly)

        let backup = root.appendingPathComponent("portable.cvb")
        source.exportBackup(to: backup, password: "correct horse")
        settle(source)

        let destination = makeStore("destination", seed: 2)
        destination.setPasteDirectly(true)
        settle(destination)

        destination.importBackup(from: backup, password: "correct horse")
        settle(destination)

        XCTAssertTrue(destination.pasteDirectly,
                      "a file must not be able to undo a permission decision made here")
    }

    /// A keychain-mode backup can only have been written by this Mac, so it
    /// restores unchanged -- otherwise reinstalling would silently drop the
    /// setting and the feature would look broken.
    func testAKeychainBackupRestoresPastingDirectly() {
        let source = makeStore("source")
        source.setPasteDirectly(true)
        source.add(text: "device bound")
        settle(source)

        let backup = root.appendingPathComponent("keychain.cvb")
        source.exportBackup(to: backup, password: nil)
        settle(source)

        let destination = makeStore("destination")
        XCTAssertFalse(destination.pasteDirectly)

        destination.importBackup(from: backup, password: nil)
        settle(destination)

        XCTAssertTrue(destination.pasteDirectly)
    }

    /// "Copy as plain text" must not go near the payload file: the plain
    /// rendering it needs is already in the index. That it completes before the
    /// call returns is the proof -- a payload read is a round trip through the
    /// I/O queue and could not possibly have finished by then.
    func testCopyPlainTextUsesTheIndexAndNeverReadsThePayload() {
        let pb = NSPasteboard(name: NSPasteboard.Name("clipvelope-plain-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let store = makeStore(pasteboard: pb)

        let rtf = Data("{\\rtf1 bold}".utf8)
        store.add(.richText(data: rtf, plainText: "bold", typeIdentifier: "public.rtf"))
        settle(store)
        let item = store.items.first { $0.searchText == "bold" }!

        pb.clearContents()
        var finished = false
        store.copyPlainText(item, then: { finished = true })

        XCTAssertTrue(finished, "nothing was read from disk, so the copy finished on the spot")
        XCTAssertEqual(pb.string(forType: .string), "bold")
        XCTAssertNil(pb.data(forType: .rtf), "the formatting must not come along")
    }

    /// The completion is what a paste hangs off, so it has to fire only once the
    /// pasteboard really holds the entry -- on the synchronous text path, and on
    /// the formatted path, which reads its payload off the I/O queue first. A
    /// paste posted before that read landed would paste the previous clipboard.
    func testCopyCompletionFiresOnlyOnceThePasteboardHoldsTheEntry() {
        let pb = NSPasteboard(name: NSPasteboard.Name("clipvelope-copy-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let store = makeStore(pasteboard: pb)

        store.add(text: "plain entry")
        let rtf = Data("{\\rtf1 styled}".utf8)
        store.add(.richText(data: rtf, plainText: "styled", typeIdentifier: "public.rtf"))
        settle(store)

        let text = store.items.first { $0.searchText == "plain entry" }!
        pb.clearContents()
        var seenByCompletion: String?
        store.copyToPasteboard(text, then: { seenByCompletion = pb.string(forType: .string) })
        XCTAssertEqual(seenByCompletion, "plain entry")

        let rich = store.items.first { $0.searchText == "styled" }!
        pb.clearContents()
        var seenRTF: Data?
        var seenPlain: String?
        store.copyToPasteboard(rich, then: {
            seenRTF = pb.data(forType: .rtf)
            seenPlain = pb.string(forType: .string)
        })
        XCTAssertNil(seenRTF, "the formatted path reads its payload first, so it cannot be done yet")

        settle(store)
        XCTAssertEqual(seenRTF, rtf, "and when it is done, the pasteboard already holds the entry")
        XCTAssertEqual(seenPlain, "styled")
    }

    /// The copy a paste hangs off can be slow -- an image or a formatted entry
    /// reads its payload on a serial queue that also carries index saves and a
    /// backup of the whole vault -- and by the time it finishes the user may be
    /// somewhere else entirely. Posting then would type a history entry, which
    /// may be a password, into an application they never chose. So the keystroke
    /// is refused once the window that started when they pressed Return has run
    /// out, and refused with its own reason rather than as a focus failure,
    /// because the two say different things about what went wrong.
    ///
    /// Tested through `refusal`, never through `paste()`: that one posts a real
    /// Command + V into whatever this machine happens to be doing.
    func testAPasteIsRefusedOnceTheUserCanHaveMovedOn() {
        let chosen = Date()
        let postBy = chosen.addingTimeInterval(PasteService.postWindow)

        XCTAssertNil(refusal(now: chosen, postBy: postBy),
                     "the ordinary case: the user has only just pressed Return")
        XCTAssertNil(refusal(now: chosen.addingTimeInterval(PasteService.focusTimeout),
                             postBy: postBy),
                     "a full focus wait must still leave room to post")
        XCTAssertEqual(refusal(now: postBy.addingTimeInterval(0.001), postBy: postBy),
                       .failed(.tookTooLong))
        XCTAssertEqual(refusal(now: chosen.addingTimeInterval(30), postBy: postBy),
                       .failed(.tookTooLong),
                       "a copy held up for half a minute must never reach the keyboard")

        XCTAssertNotEqual(PasteService.Outcome.failed(.tookTooLong), .failed(.focusDidNotReturn),
                          "two different situations must not be reported identically")

        // A permission that was never granted is the more useful thing to say:
        // no deadline would have made that paste happen.
        XCTAssertEqual(refusal(trusted: false, now: chosen.addingTimeInterval(30), postBy: postBy),
                       .notTrusted)

        XCTAssertGreaterThan(PasteService.postWindow, PasteService.focusTimeout,
                             "the window has to outlast the wait it contains")
    }

    /// The deadline bounds *when* a keystroke goes out and never bounded
    /// *where*. Inside those two seconds the paste went to whatever was
    /// frontmost at post time, and a person switches applications in about 300
    /// milliseconds: pick an image while the I/O queue is busy, Command-Tab
    /// away, and the entry -- which this app's premise says may be a password --
    /// is typed into the application they moved to.
    func testAPasteIsRefusedWhenTheUserIsNoLongerWhereTheyStarted() {
        let chosen = Date()
        let postBy = chosen.addingTimeInterval(PasteService.postWindow)
        let started: pid_t = 501

        XCTAssertNil(refusal(now: chosen, postBy: postBy, destination: started, frontmost: started),
                     "still in the same application, well inside the window")

        // The case the check exists for: they moved, and the deadline has not
        // even run out yet, so nothing else would have stopped this.
        XCTAssertEqual(refusal(now: chosen.addingTimeInterval(0.4), postBy: postBy,
                               destination: started, frontmost: 777),
                       .failed(.destinationNotConfirmed))

        // The application they were in quit. Whatever is in front now, it is not
        // where they meant the entry to go.
        XCTAssertEqual(refusal(now: chosen, postBy: postBy, destination: started, frontmost: nil),
                       .failed(.destinationNotConfirmed))

        // Nothing was frontmost when they acted, so there is nothing to confirm
        // against and posting would be a guess.
        XCTAssertEqual(refusal(now: chosen, postBy: postBy, destination: nil, frontmost: started),
                       .failed(.destinationNotConfirmed))
        XCTAssertEqual(refusal(now: chosen, postBy: postBy, destination: nil, frontmost: nil),
                       .failed(.destinationNotConfirmed))

        // Same application, different window: allowed on purpose. NSWorkspace
        // names a process, not a window, and the user's own Command + V would
        // land in that same window anyway.
        XCTAssertNil(refusal(now: chosen, postBy: postBy, destination: started, frontmost: started))

        XCTAssertNotEqual(PasteService.Outcome.failed(.destinationNotConfirmed),
                          .failed(.tookTooLong),
                          "a move that was observed and a delay that merely suggests one "
                          + "are different situations and must not read the same")

        // The observed move is the more useful sentence when both are true: the
        // deadline only ever inferred what this one measured.
        XCTAssertEqual(refusal(now: chosen.addingTimeInterval(30), postBy: postBy,
                               destination: started, frontmost: 777),
                       .failed(.destinationNotConfirmed))
    }

    /// `closePanelThenPaste` stamps the frontmost process on the reasoning that
    /// an LSUIElement app never becomes frontmost. It does not become frontmost
    /// by showing a window -- but `Views.swift` calls
    /// `NSApp.activate(ignoringOtherApps: true)` in two places, for Preferences
    /// and for the Delete Everything alert, and that is precisely how an
    /// accessory app becomes frontmost. The plausible route is onboarding: open
    /// Preferences, switch Paste Directly on, close it, open the panel, press
    /// Return.
    ///
    /// Nothing was ever pasted into Clipvelope -- `stillHasFocus` refuses
    /// independently -- so this is about what the user is *told*. "Could not
    /// confirm you were still in the application you started in" is not merely
    /// unhelpful here, it is false: the application they started in was
    /// Clipvelope.
    func testAPasteStartedInsideClipvelopeSaysSoRatherThanBlamingTheUser() {
        let chosen = Date()
        let postBy = chosen.addingTimeInterval(PasteService.postWindow)
        let clipvelope: pid_t = 999

        XCTAssertEqual(refusal(now: chosen, postBy: postBy,
                               destination: clipvelope, frontmost: 501, own: clipvelope),
                       .failed(.startedInClipvelope))

        // Still its own answer when the destination happens to match, which is
        // the case where `frontmost == destination` would otherwise have let the
        // paste through and typed the entry into the panel's search field.
        XCTAssertEqual(refusal(now: chosen, postBy: postBy,
                               destination: clipvelope, frontmost: clipvelope, own: clipvelope),
                       .failed(.startedInClipvelope))

        XCTAssertNotEqual(PasteService.Outcome.failed(.startedInClipvelope),
                          .failed(.destinationNotConfirmed),
                          "an application the user never left and one they did are not "
                          + "the same situation and must not read the same")

        // Behind the clipboard check, like the other two, because its remedy is
        // also "press Command + V" and that is only sound while the clipboard
        // still holds the entry.
        XCTAssertEqual(refusal(now: chosen, postBy: postBy,
                               destination: clipvelope, frontmost: 501,
                               clipboardWas: 12, clipboardIs: 13, own: clipvelope),
                       .failed(.clipboardChanged))

        // And an ordinary destination is untouched by any of it.
        XCTAssertNil(refusal(now: chosen, postBy: postBy,
                             destination: 501, frontmost: 501, own: clipvelope))
    }

    /// Nothing checked that the pasteboard still held what was copied.
    /// `runShellAndCopy` finishes on the main queue at an arbitrary later
    /// moment, so a Quick Slot command completing inside the window replaced the
    /// chosen entry with its own output -- and the app reported success by
    /// saying nothing.
    func testAPasteIsRefusedWhenSomethingElseTookTheClipboard() {
        let chosen = Date()
        let postBy = chosen.addingTimeInterval(PasteService.postWindow)

        XCTAssertNil(refusal(now: chosen, postBy: postBy, clipboardWas: 12, clipboardIs: 12))
        XCTAssertEqual(refusal(now: chosen, postBy: postBy, clipboardWas: 12, clipboardIs: 13),
                       .failed(.clipboardChanged))

        // Ahead of the deadline and the destination, because both of their
        // messages end "press Command + V", and that is only sound advice while
        // the clipboard still holds the entry.
        XCTAssertEqual(refusal(now: chosen.addingTimeInterval(30), postBy: postBy,
                               destination: 501, frontmost: 777,
                               clipboardWas: 12, clipboardIs: 13),
                       .failed(.clipboardChanged))

        XCTAssertEqual(PasteService.Outcome.failed(.clipboardChanged).message?
            .contains("Choose the entry again"), true,
                       "the one outcome whose remedy is not Command + V has to say so")
    }

    /// Every outcome has to have something to say, or nothing at all as a
    /// choice rather than an oversight -- and no two of them may say the same
    /// thing, which is the rule the whole enum exists to keep.
    func testEveryPasteOutcomeHasItsOwnAnswer() {
        let silent = PasteService.Outcome.pasted
        XCTAssertNil(silent.message,
                     "a paste that worked says nothing: the text appearing is the message")

        let spoken: [PasteService.Outcome] = [
            .notTrusted, .failed(.noEvent), .failed(.focusDidNotReturn), .failed(.tookTooLong),
            .failed(.destinationNotConfirmed), .failed(.startedInClipvelope),
            .failed(.clipboardChanged)
        ]
        let messages = spoken.compactMap(\.message)
        XCTAssertEqual(messages.count, spoken.count, "every failure has to say something")
        XCTAssertEqual(Set(messages).count, spoken.count,
                       "two different situations must not look the same to the user")
        for message in messages {
            XCTAssertGreaterThan(message.count, 40, "a remedy takes a sentence: \(message)")
        }
    }

    /// The messages went to `ClipboardStore.notice`, which only the state strip
    /// inside the history panel reads -- and every one of them is written after
    /// that panel has been closed, or by a Quick Slot that is only ever used
    /// with it closed. So they were written to a view that did not exist.
    func testAFailedPasteReachesTheUserWithThePanelClosed() {
        let store = makeStore()
        var shown: [String] = []
        store.noticePresenter = { shown.append($0) }

        store.report(.pasted)
        XCTAssertEqual(shown, [], "success is quiet")

        store.report(.failed(.destinationNotConfirmed))
        XCTAssertEqual(shown.count, 1, "a failed paste has to reach a surface the user can see")
        XCTAssertEqual(shown.first, PasteService.Outcome.failed(.destinationNotConfirmed).message)
        XCTAssertEqual(store.notice, shown.first,
                       "and the strip still carries it for a user who does open the panel")

        // The two pre-existing messages that rode the same dead channel.
        store.showNotice("Quick Slot command could not start; the clipboard was left alone.")
        XCTAssertEqual(shown.count, 2)
    }

    /// The HUD's fade must not carry away the message that replaced it.
    ///
    /// `dismiss` runs a 250ms `NSAnimationContext` group whose completion
    /// handler orders the panel out. `show` sets the panel opaque again, but
    /// writing the property does not cancel an animation already in flight and
    /// the handler runs at the end of the group regardless. So a second notice
    /// arriving inside that quarter second -- within 250ms of the eight-second
    /// auto-dismiss, or of the user clicking the previous one away -- was
    /// ordered front, faded to nothing and ordered out; the new dismissal timer
    /// then found an invisible panel and did nothing, and the user never read
    /// it. That is the exact silent failure the HUD exists to remove.
    ///
    /// Only the decision is tested. The fade itself is a window-server
    /// animation on a real `NSPanel` and there is nothing here to run one
    /// against, so the rule was made a pure function -- the same shape as
    /// `PasteService.refusal` and for the same reason.
    func testTheNoticeHUDDoesNotOrderOutAMessageThatArrivedDuringTheFade() {
        XCTAssertTrue(NoticeHUD.mayOrderOut(started: 3, current: 3),
                      "nothing happened during the fade, so it finishes as asked")
        XCTAssertFalse(NoticeHUD.mayOrderOut(started: 3, current: 4),
                       "a message arrived during the fade and is on screen now")
        XCTAssertFalse(NoticeHUD.mayOrderOut(started: 3, current: 5),
                       "two did; the panel still belongs to the newest of them")
    }

    /// Which surface a notice goes to. Getting this wrong in one direction is a
    /// redundant message; in the other it is the silent failure back again, so
    /// the rule stays quiet only when both signals agree the strip is there.
    func testANoticeOnlySkipsThePanelWhenTheStripIsCertainlyOnScreen() {
        XCTAssertFalse(ClipboardStore.noticeNeedsHUD(stripOnScreen: true, appHasKeyWindow: true),
                       "the history panel is open and its strip is showing the message")
        XCTAssertTrue(ClipboardStore.noticeNeedsHUD(stripOnScreen: false, appHasKeyWindow: false),
                      "the ordinary failed paste: nothing of Clipvelope's is on screen")
        XCTAssertTrue(ClipboardStore.noticeNeedsHUD(stripOnScreen: true, appHasKeyWindow: false),
                      "SwiftUI missed the disappearance; the panel is gone all the same")
        XCTAssertTrue(ClipboardStore.noticeNeedsHUD(stripOnScreen: false, appHasKeyWindow: true),
                      "Preferences has the keyboard, and it has no strip to show anything in")
    }

    /// Named arguments with defaults, so each test says only what it is about.
    private func refusal(trusted: Bool = true,
                         now: Date,
                         postBy: Date,
                         destination: pid_t? = 501,
                         frontmost: pid_t? = 501,
                         clipboardWas: Int = 7,
                         clipboardIs: Int = 7,
                         own: pid_t = 999) -> PasteService.Outcome? {
        PasteService.refusal(trusted: trusted, now: now, postBy: postBy,
                             destination: destination, frontmost: frontmost,
                             clipboardWas: clipboardWas, clipboardIs: clipboardIs,
                             own: own)
    }

    func testIgnoredAppsPersistAndDeduplicate() {
        let store = makeStore()
        store.ignoreApp(bundleID: "com.1password.1password")
        store.ignoreApp(bundleID: "com.1password.1password")
        settle(store)

        XCTAssertEqual(makeStore().ignoredAppBundleIDs, ["com.1password.1password"])

        store.stopIgnoringApp(bundleID: "com.1password.1password")
        settle(store)
        XCTAssertTrue(makeStore().ignoredAppBundleIDs.isEmpty)
    }
}

/// The rule behind Sparkle's gentle reminders.
///
/// The path itself cannot be driven from a test: it needs a signed Sparkle
/// build, a served appcast and a version newer than the one running. What a test
/// *can* hold is the decision, which is why the decision is a pure function and
/// not four lines inside four delegate callbacks.
final class UpdateReminderPolicyTests: XCTestCase {
    func testSparkleShowsItOnlyWhenTheUserIsAlreadyLookingAtTheApp() {
        XCTAssertEqual(
            UpdateReminderPolicy.handling(appHasUserAttention: true,
                                          sparkleProposesImmediateFocus: true),
            .sparkleShowsIt)
    }

    func testWithoutAttentionTheMenuBarTakesTheJob() {
        // The measured failure: a scheduled check fires while the user is in
        // another application, and Sparkle's window opens behind their work.
        XCTAssertEqual(
            UpdateReminderPolicy.handling(appHasUserAttention: false,
                                          sparkleProposesImmediateFocus: true),
            .markTheMenuBar)
        XCTAssertEqual(
            UpdateReminderPolicy.handling(appHasUserAttention: false,
                                          sparkleProposesImmediateFocus: false),
            .markTheMenuBar)
    }

    func testAttentionAloneIsNotEnoughWhenSparkleWillNotShowItInFocus() {
        XCTAssertEqual(
            UpdateReminderPolicy.handling(appHasUserAttention: true,
                                          sparkleProposesImmediateFocus: false),
            .markTheMenuBar)
    }

    func testOnlyAnUpdateThisAppTookResponsibilityForLeavesAMark() {
        XCTAssertTrue(UpdateReminderPolicy.isMarked(
            after: .willShowUpdate(handledBySparkle: false, userInitiated: false)))
    }

    func testAnUpdateSparkleIsShowingNeedsNoMark() {
        XCTAssertFalse(UpdateReminderPolicy.isMarked(
            after: .willShowUpdate(handledBySparkle: true, userInitiated: false)))
    }

    func testACheckTheUserAskedForNeedsNoMark() {
        XCTAssertFalse(UpdateReminderPolicy.isMarked(
            after: .willShowUpdate(handledBySparkle: true, userInitiated: true)))
        XCTAssertFalse(UpdateReminderPolicy.isMarked(
            after: .willShowUpdate(handledBySparkle: false, userInitiated: true)))
    }

    /// A mark that outlives the update it announced is the same defect as no
    /// mark at all, so both ways an update stops waiting clear it -- including
    /// the one where nobody ever looked at it.
    func testTheMarkIsClearedWhenTheUpdateStopsWaiting() {
        XCTAssertFalse(UpdateReminderPolicy.isMarked(after: .userGaveAttention))
        XCTAssertFalse(UpdateReminderPolicy.isMarked(after: .sessionFinished))
    }
}
