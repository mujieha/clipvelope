import Foundation
import AppKit
import SwiftUI
import CryptoKit

// MARK: - Store

/// Surfaced in the menu when the store refuses to write, so an unreadable
/// vault is a visible, recoverable condition rather than a silent empty list.
struct StorageFailure: Identifiable {
    let id = UUID()
    let message: String
}

final class ClipboardStore: ObservableObject {
    /// True until the vault has been read. The menu must not claim the history
    /// is empty before it knows: reading the key can take seconds the first time
    /// a newly signed build runs, while macOS validates its signature.
    @Published private(set) var isLoading = true
    /// Set when an import changed what it was given. Shown in the Backup tab,
    /// because a silent adjustment is indistinguishable from a silent failure.
    @Published private(set) var importNotice: String?
    /// The vault could not be read, or the last save failed. Which one is
    /// `writesSuspended`; the two must never be offered the same remedy.
    @Published private(set) var storageFailure: StorageFailure?
    /// True while the vault on disk could not be read and every write is refused.
    /// Only this state may offer "Start Fresh": a failed save or a failed backup
    /// must never lead to a readable vault being quarantined.
    @Published private(set) var writesSuspended = false
    /// The last backup operation that failed, shown next to the button that ran it.
    @Published private(set) var backupFailure: String?
    @Published private(set) var items: [ClipboardItem] = []
    @Published var bindings: [ClipboardBinding] = []
    @Published var folders: [CommandFolder] = []
    @Published var autoBackupEnabled: Bool = false
    @Published var autoBackupMode: BackupMode = .keychain
    @Published var themeMode: ThemeMode = .system { didSet { AppearanceController.apply(themeMode) } }
    @Published var skipConcealedContent: Bool = true { didSet { syncMonitorPolicy() } }
    @Published var ignoredAppBundleIDs: [String] = [] { didSet { syncMonitorPolicy() } }
    @Published var captureSuspended: Bool = false { didSet { syncMonitorPolicy() } }
    @Published private(set) var openHotkey: KeyCombo = .defaultOpen
    @Published private(set) var preferencesHotkey: KeyCombo = .defaultPreferences
    /// Whether choosing an entry also presses Command + V. Off until the user
    /// turns it on, and `disarming` keeps it that way through an import.
    @Published var pasteDirectly: Bool = false
    /// False when another app owns the open-history combination, so Preferences
    /// can say so instead of leaving a shortcut that silently does nothing.
    @Published private(set) var openHotkeyRegistered = true
    /// Quick Slot numbers another app already owns.
    @Published private(set) var unavailableSlots: [Int] = []
    /// A short-lived message for the state strip: something the user just did
    /// had a result they would not otherwise see.
    @Published private(set) var notice: String?

    private let storage: EncryptedStorage
    private let systemIntegrationEnabled: Bool
    /// Injected so a test can watch what gets copied without touching the
    /// pasteboard every other app on the machine shares.
    private let pasteboard: NSPasteboard
    private let monitor = ClipboardMonitor()
    /// Only for the auto-backup password. The encryption key comes from
    /// `storage.keyStore`, so the vault and its backups cannot diverge.
    private let autoBackupPasswordStore = KeychainKeyStore()
    /// How many entries the live history holds, pins aside.
    static let maxItems = 200
    /// A ceiling on what one untrusted backup may install, well above any vault
    /// this app produces and far below a file built to fill a disk.
    static let maxImportedItems = 1_000
    /// And a ceiling on how many of those may stay pinned, because a pinned
    /// entry is exempt from the live cap: one below it, so a copy made after the
    /// import still fits underneath. See `disarming` for the whole argument.
    static var maxImportedPinnedItems: Int { maxItems - 1 }
    /// And a ceiling on the total inline text it may install, because every byte
    /// of it is re-encrypted on every copy for as long as it stays in the vault.
    static let maxImportedInlineBytes = 32 * 1024 * 1024
    /// Ceiling on stored image bytes. A count-based cap alone would happily
    /// hold 200 screenshots.
    private let maxPayloadBytes = 512 * 1024 * 1024
    private static let autoBackupDelay: TimeInterval = 15

    private var autoBackupWork: DispatchWorkItem?
    private var noticeWork: DispatchWorkItem?
    /// Kept so the observer can be taken down again; see `flushPendingWork`.
    private var terminationObserver: NSObjectProtocol?
    private var thumbnailCache: [UUID: NSImage] = [:]

    private var autoBackupURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
            .appendingPathComponent("Clipvelope", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("clipvelope-backup.cvb")
    }

    private var hasLoaded = false

    /// Every vault operation runs here. Encryption and disk writes are merely slow,
    /// but Keychain access can *block*: if macOS decides to ask the user whether
    /// this binary may read the key, the call does not return until they answer.
    /// On the main thread that freezes the app behind a dialog a menu-bar-only app
    /// may not even surface.
    private let ioQueue = DispatchQueue(label: "com.mujieha.Clipvelope.io", qos: .utility)

    private static let shellTimeout: TimeInterval = 30

    /// - Parameter enableSystemIntegration: pasteboard polling, global hotkeys,
    ///   and closing the panel or posting a keystroke when pasting for the user.
    ///   Off in tests, which have no business installing a system-wide hotkey,
    ///   reacting to whatever the machine's clipboard happens to do, or typing
    ///   Command + V into whatever is frontmost on the machine running them.
    init(storage: EncryptedStorage = EncryptedStorage(),
         enableSystemIntegration: Bool = true,
         pasteboard: NSPasteboard = .general) {
        self.storage = storage
        self.systemIntegrationEnabled = enableSystemIntegration
        self.pasteboard = pasteboard
        self.noticePresenter = enableSystemIntegration
            ? { NoticeHUD.shared.show($0, for: ClipboardStore.noticeDuration) }
            : { _ in }

        monitor.onNewContent = { [weak self] captured in
            self?.add(captured.payload, source: captured.sourceBundleID)
        }
        if enableSystemIntegration {
            // Owned here rather than in the App's init: @StateObject is not
            // installed at that point, so reaching for the store there yields a
            // stray instance.
            GlobalHotkeyCenter.shared.onSlot = { [weak self] slot in
                self?.triggerBinding(slot: slot)
            }
            unavailableSlots = GlobalHotkeyCenter.shared.register()
            registerOpenHotkey()
            // Observed here rather than in an application delegate, because the
            // thing that has to be flushed is this object's queue and an
            // `NSApplicationDelegateAdaptor` is built before the store exists,
            // with no way to reach it. The Quit button calls
            // `NSApplication.terminate`, which posts this and then exits.
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.flushPendingWork()
            }
        }
        loadFromStorage()
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    // MARK: Notices

    /// How long a notice stays up, on either surface. One number so the strip
    /// and the panel cannot disagree about when a message expires. Eight rather
    /// than the old six because every one of these messages is two sentences and
    /// ends in an instruction.
    static let noticeDuration: TimeInterval = 8

    /// Where a notice goes when no window is on screen to carry it.
    ///
    /// A stored closure rather than a direct call to `NoticeHUD`, for two
    /// reasons. A test can watch it, which is the only way to hold the line that
    /// a failed paste reaches the user -- that is the exact thing that was
    /// broken. And a store built without system integration gets a closure that
    /// does nothing, so a unit test never puts a window on the screen of the
    /// machine running it, the same rule the pasteboard poller and the global
    /// hotkeys follow.
    var noticePresenter: (String) -> Void

    /// How many state strips are mounted. The strip is the other surface for a
    /// notice, and there is no point showing both.
    private var stripsOnScreen = 0

    /// Whether a notice needs the panel, given the two things that can be
    /// observed about the strip.
    ///
    /// Pure, because getting it wrong in one direction is invisible. Showing a
    /// panel while the strip is also up is a redundant message; *not* showing
    /// one when the strip is not really there is the original bug back again. So
    /// the rule demands both signals agree before it stays quiet, and the two
    /// fail in opposite directions: `stripOnScreen` comes from SwiftUI's
    /// `onAppear`/`onDisappear`, which can miss the disappearance, and
    /// `appHasKeyWindow` is the signal `PasteService.stillHasFocus` documents as
    /// the one that actually moves when the panel opens and closes.
    static func noticeNeedsHUD(stripOnScreen: Bool, appHasKeyWindow: Bool) -> Bool {
        !(stripOnScreen && appHasKeyWindow)
    }

    /// Called by `StateStrip` as it comes and goes.
    func stateStripAppeared() { stripsOnScreen += 1 }
    func stateStripDisappeared() { stripsOnScreen = max(0, stripsOnScreen - 1) }

    /// Shown for a few seconds: in the state strip if the history panel is open,
    /// and in a panel below the menu bar if it is not. Only for outcomes the
    /// user would otherwise never learn about.
    ///
    /// Both, not one. The strip is the better place when the user is already
    /// looking at the panel, and it is the only place a notice can be read at
    /// leisure; but the three callers that matter most -- a direct paste, which
    /// reports after the panel has been dismissed, a Quick Slot, which is a
    /// global hotkey used with the panel closed, and a missing payload on either
    /// path -- all speak to someone who is looking somewhere else entirely.
    func showNotice(_ text: String) {
        notice = text
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeDuration, execute: work)

        guard ClipboardStore.noticeNeedsHUD(stripOnScreen: stripsOnScreen > 0,
                                            appHasKeyWindow: NSApplication.shared.keyWindow != nil)
        else { return }
        noticePresenter(text)
    }

    // MARK: Shortcuts

    private func registerOpenHotkey() {
        guard systemIntegrationEnabled else { return }
        openHotkeyRegistered = GlobalHotkeyCenter.shared.setOpenHotkey(openHotkey)
    }

    func setOpenHotkey(_ combo: KeyCombo) {
        openHotkey = combo
        registerOpenHotkey()
        persist()
    }

    func setPreferencesHotkey(_ combo: KeyCombo) {
        preferencesHotkey = combo
        persist()
    }

    /// While the recorder listens, the current combination must not fire --
    /// and must be recordable again if the user presses the same keys.
    func suspendOpenHotkey(_ suspended: Bool) {
        guard systemIntegrationEnabled else { return }
        if suspended {
            GlobalHotkeyCenter.shared.setOpenHotkey(nil)
        } else {
            registerOpenHotkey()
        }
    }

    /// Whether the encryption key is private to this app.
    ///
    /// False for an unsigned build, where the key sits in the file keychain and
    /// any application running as the same user can read it. Surfaced in
    /// Preferences because it is the one security property of this app that the
    /// user cannot infer from anything they can see.
    var isKeyIsolated: Bool { KeychainKeyStore.usesDataProtectionKeychain }

    /// Blocks until queued vault I/O has drained. Test support.
    func drainPendingWork() {
        ioQueue.sync {}
    }

    /// The longest quitting may wait for the vault to finish being written.
    ///
    /// Long enough for an index save and a payload write, which are milliseconds
    /// each, plus room for an auto-backup that happened to be in flight; short
    /// enough that a queue wedged on a Keychain prompt cannot turn Quit into a
    /// hang. Missing the deadline costs the last copy, which is what this exists
    /// to prevent -- but a Quit button that does nothing is worse, and the
    /// timeout is the only thing that rules it out.
    static let quitFlushTimeout: TimeInterval = 3

    /// Waits, briefly, for queued vault writes to reach the disk.
    ///
    /// `add` enqueues the payload and `persist` enqueues the index onto a
    /// `.utility` queue that can be seconds behind under load, and
    /// `NSApplication.terminate` does not wait for either: copy something, quit
    /// from the footer, and the index write died with the process while the
    /// strip had already said the vault held it. Nothing in the app called this
    /// before.
    ///
    /// Returns false if the deadline passed with work still queued, which is
    /// logged rather than shown: by then the app is a moment from exiting and
    /// there is no surface left to show anything on.
    @discardableResult
    func flushPendingWork(timeout: TimeInterval = ClipboardStore.quitFlushTimeout) -> Bool {
        let drained = DispatchSemaphore(value: 0)
        // The queue is serial, so a block enqueued now runs behind everything
        // already on it. `.userInitiated` promotes what is waiting in front of
        // it: the user asked for this and is watching the app fail to quit.
        ioQueue.async(qos: .userInitiated) { drained.signal() }
        guard drained.wait(timeout: .now() + timeout) == .success else {
            NSLog("%@", "Clipvelope: vault writes had not finished \(timeout)s after quitting "
                  + "was requested; exiting without them.")
            return false
        }
        return true
    }

    private func loadFromStorage() {
        // Elevated above the queue's default: nothing can be shown until this
        // finishes, so it is user-initiated latency, not background work.
        ioQueue.async(qos: .userInitiated) { [weak self] in
            guard let self else { return }
            let outcome = storage.load()
            DispatchQueue.main.async { self.applyLoadOutcome(outcome) }
        }
    }

    private func applyLoadOutcome(_ outcome: EncryptedStorage.LoadOutcome) {
        switch outcome {
        case .fresh:
            apply(.empty)
            writesSuspended = false
            storageFailure = nil
        case .loaded(let state):
            apply(state)
            writesSuspended = false
            storageFailure = nil
        case .unreadable(let error):
            writesSuspended = true
            // A pre-release vault explains itself; anything else is almost
            // always the Keychain, and guessing that out loud has been more
            // useful to people than the underlying CryptoKit message.
            let reason: String
            if case StorageError.preReleaseVault = error {
                reason = error.localizedDescription
            } else {
                reason = "This usually means the Keychain was locked or access was "
                    + "denied. (\(error.localizedDescription))"
            }
            storageFailure = StorageFailure(
                message: "Your vault could not be read, so saving is paused to protect it. "
                    + reason
            )
            NSLog("%@", "Clipvelope: vault unreadable, writes suspended: \(error)")
        }
        hasLoaded = true
        isLoading = false
        // Sweep payload files nothing refers to any more -- the residue of a crash
        // between writing a payload and saving the index.
        if !writesSuspended {
            let live = Set(items.map(\.id))
            ioQueue.async { [weak self] in self?.storage.deletePayloads(notIn: live) }
        }
        // Capture starts only now: anything copied earlier would be discarded when
        // the loaded state replaces the in-memory arrays.
        if systemIntegrationEnabled { monitor.start() }
    }

    private func apply(_ state: AppState) {
        items = state.items.removingDuplicateIDs()
        bindings = state.bindings.removingDuplicateIDs()
        folders = state.folders.removingDuplicateIDs().map {
            var folder = $0
            folder.items = folder.items.removingDuplicateIDs()
            return folder
        }
        autoBackupEnabled = state.autoBackupEnabled
        autoBackupMode = state.autoBackupMode
        themeMode = state.themeMode
        skipConcealedContent = state.skipConcealedContent
        ignoredAppBundleIDs = state.ignoredAppBundleIDs
        captureSuspended = state.captureSuspended
        preferencesHotkey = state.preferencesHotkey
        pasteDirectly = state.pasteDirectly
        if openHotkey != state.openHotkey {
            openHotkey = state.openHotkey
            registerOpenHotkey()
        }
        syncMonitorPolicy()
    }

    private func syncMonitorPolicy() {
        monitor.isPaused = captureSuspended
        monitor.skipConcealed = skipConcealedContent
        monitor.ignoredBundleIDs = Set(ignoredAppBundleIDs)
    }

    private var currentState: AppState {
        AppState(
            items: items,
            bindings: bindings,
            folders: folders,
            autoBackupEnabled: autoBackupEnabled,
            autoBackupMode: autoBackupMode,
            themeMode: themeMode,
            skipConcealedContent: skipConcealedContent,
            ignoredAppBundleIDs: ignoredAppBundleIDs,
            captureSuspended: captureSuspended,
            openHotkey: openHotkey,
            preferencesHotkey: preferencesHotkey,
            pasteDirectly: pasteDirectly
        )
    }

    // MARK: Privacy

    func setCaptureSuspended(_ suspended: Bool) {
        captureSuspended = suspended
        persistState()
    }

    func setSkipConcealedContent(_ skip: Bool) {
        skipConcealedContent = skip
        persistState()
    }

    /// Turns pasting for the user on or off. Granting Accessibility access is a
    /// separate step and stays the user's: this only records that they want the
    /// feature, and `PasteService` reports honestly when the permission is
    /// missing rather than pasting nothing and saying nothing.
    func setPasteDirectly(_ on: Bool) {
        pasteDirectly = on
        persistState()
    }

    func ignoreApp(bundleID: String) {
        guard !bundleID.isEmpty, !ignoredAppBundleIDs.contains(bundleID) else { return }
        ignoredAppBundleIDs.append(bundleID)
        persistState()
    }

    func stopIgnoringApp(bundleID: String) {
        ignoredAppBundleIDs.removeAll { $0 == bundleID }
        persistState()
    }

    /// Retry after the user has unlocked the Keychain or granted access.
    func retryLoadingVault() {
        guard writesSuspended else { return }
        loadFromStorage()
    }

    /// Give up on the unreadable file: move it aside (not delete it) and resume writing.
    /// Refused unless the vault really is unreadable: called against a readable
    /// vault this would quarantine the user's whole history.
    func discardUnreadableVault() {
        guard writesSuspended else { return }
        apply(.empty)
        ioQueue.async { [weak self] in
            guard let self else { return }
            storage.quarantineUnreadableVault()
            DispatchQueue.main.async {
                self.writesSuspended = false
                self.storageFailure = nil
                self.persist()
            }
        }
    }

    private func persist() {
        guard hasLoaded, !writesSuspended else { return }
        let snapshot = currentState
        let shouldBackUp = autoBackupEnabled
        ioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try storage.saveIndex(snapshot)
            } catch {
                NSLog("%@", "Clipvelope save error: \(error)")
                DispatchQueue.main.async {
                    self.storageFailure = StorageFailure(
                        message: "Could not save to your vault. (\(error.localizedDescription))"
                    )
                }
                return
            }
            DispatchQueue.main.async {
                if self.storageFailure != nil { self.storageFailure = nil }
                // Coalesced: an auto-backup serialises every payload, which is far
                // too expensive to redo on every single copy.
                if shouldBackUp { self.scheduleAutoBackup() }
            }
        }
    }

    private func scheduleAutoBackup() {
        autoBackupWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autoBackup() }
        autoBackupWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoBackupDelay, execute: work)
    }

    func add(_ payload: CapturedPayload, source: String? = nil) {
        let id = UUID()
        let content: ClipboardContent
        var payloadBytes: Data?

        switch payload {
        case .text(let value):
            content = .text(value)
        // The digest is taken here, the one place the payload bytes are already
        // in hand, and never recomputed afterwards: hashing an item that is
        // already in the vault would mean reading and decrypting its payload
        // file, and doing that for the whole history at launch is exactly the
        // cost the per-item payload layout exists to avoid. Entries written
        // before this field existed keep a nil hash for good; see
        // `ClipboardContent.ImageInfo.==` for how they de-duplicate.
        case .richText(let data, let plain, let type):
            content = .richText(.init(plainText: plain, byteCount: data.count,
                                      typeIdentifier: type,
                                      contentHash: ClipboardContent.digest(data)))
            payloadBytes = data
        case .image(let data, let type, let width, let height):
            content = .image(.init(pixelWidth: width, pixelHeight: height,
                                   byteCount: data.count, typeIdentifier: type,
                                   contentHash: ClipboardContent.digest(data)))
            payloadBytes = data
        case .files(let urls):
            content = .files(urls.map { .init(path: $0.path) })
        }

        let updated = HistoryPolicy.inserting(content, into: items, maxItems: Self.maxItems,
                                              maxPayloadBytes: maxPayloadBytes,
                                              id: id, source: source)
        // Unreachable now that `inserting` protects the entry it adds, and left
        // here as the tripwire for it ever becoming reachable again: this
        // returning quietly is exactly how a vault saturated with pinned rows
        // swallowed every copy the user made without a word.
        guard updated != items else {
            NSLog("%@", "Clipvelope: a copy was not recorded -- the history policy returned "
                  + "the list unchanged for a new entry. This should not happen.")
            return
        }

        // Write the payload before the index that names it. ioQueue is serial and
        // persist() enqueues onto it, so this ordering holds.
        if let payloadBytes, updated.contains(where: { $0.id == id }) {
            ioQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try storage.writePayload(payloadBytes, for: id)
                } catch {
                    NSLog("%@", "Clipvelope: could not write payload for \(id): \(error)")
                }
            }
        }

        replaceItems(with: updated)
    }

    /// Applies a new item list and deletes the payload files of anything dropped.
    private func replaceItems(with updated: [ClipboardItem]) {
        let evicted = Set(items.filter(\.hasPayloadFile).map(\.id))
            .subtracting(updated.map(\.id))
        items = updated
        for id in evicted {
            thumbnailCache[id] = nil
            ioQueue.async { [weak self] in self?.storage.deletePayload(for: id) }
        }
        persist()
    }

    func add(text: String) {
        add(.text(text))
    }

    func remove(_ item: ClipboardItem) {
        replaceItems(with: items.filter { $0.id != item.id })
    }

    func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = items
        updated[index].isPinned.toggle()
        // Unpinning can put the list back over either cap.
        replaceItems(with: HistoryPolicy.trimmed(updated, maxItems: Self.maxItems,
                                                 maxPayloadBytes: maxPayloadBytes))
    }

    /// Puts `item` back on the pasteboard.
    ///
    /// `then` runs on the main queue once the pasteboard actually holds the
    /// entry -- which is *not* when this function returns. An image and a
    /// formatted paste both have to read their payload off `ioQueue` first, and
    /// anything that acts on the copy having happened -- pasting it, above all
    /// -- would otherwise act while the clipboard still held the previous
    /// entry. Existing callers pass nothing and are unaffected.
    ///
    /// It fires on every path that ends with something on the pasteboard,
    /// including the one where a formatted entry has lost its payload and falls
    /// back to plain text. The single path it does not fire on is a missing
    /// image payload, which copies nothing at all and deletes the row instead:
    /// there is nothing there to paste.
    func copyToPasteboard(_ item: ClipboardItem, then: (() -> Void)? = nil) {
        switch item.content {
        case .text(let value):
            copyText(value)
            then?()

        case .richText(let info):
            // Put both renderings back, so a rich target keeps the formatting
            // and a plain one still gets sensible text.
            ioQueue.async { [weak self] in
                guard let self else { return }
                guard let data = try? storage.readPayload(for: item.id) else {
                    NSLog("%@", "Clipvelope: payload missing for \(item.id)")
                    DispatchQueue.main.async {
                        self.copyText(info.plainText)
                        self.showNotice("The formatting for that entry was missing, so plain text was copied.")
                        then?()
                    }
                    return
                }
                let type: NSPasteboard.PasteboardType =
                    info.typeIdentifier == "public.html" ? .html : .rtf
                DispatchQueue.main.async {
                    self.pasteboard.clearContents()
                    self.pasteboard.setData(data, forType: type)
                    self.pasteboard.setString(info.plainText, forType: .string)
                    then?()
                }
            }

        case .files(let refs):
            pasteboard.clearContents()
            pasteboard.writeObjects(refs.map { URL(fileURLWithPath: $0.path) as NSURL })
            then?()

        case .image:
            // The payload is a file now, so reading it is I/O.
            ioQueue.async { [weak self] in
                guard let self else { return }
                // The role binding already guarantees these bytes were written as
                // this item's payload; checking the signature as well means nothing
                // that is not a PNG is ever offered to other apps as one.
                guard let data = try? storage.readPayload(for: item.id),
                      data.starts(with: ClipboardMonitor.pngSignature) else {
                    // A row that looks like an image but cannot produce one is
                    // worse than no row: take it out and say why.
                    NSLog("%@", "Clipvelope: payload missing or not a PNG for \(item.id)")
                    DispatchQueue.main.async {
                        self.remove(item)
                        self.showNotice("That image's file was missing, so the entry was removed.")
                    }
                    return
                }
                DispatchQueue.main.async {
                    self.pasteboard.clearContents()
                    self.pasteboard.setData(data, forType: .png)
                    then?()
                }
            }
        }
    }

    /// Copies `item` with any formatting dropped.
    ///
    /// For a formatted entry that means the plain rendering already held in the
    /// index, so the payload file is never read and nothing styled reaches the
    /// pasteboard -- which is the point: pasting into a document that honours
    /// RTF should be able to arrive as the document's own text. Every other
    /// kind of entry has no formatting to drop and is copied exactly as usual.
    ///
    /// `then` has the same contract as `copyToPasteboard`'s.
    func copyPlainText(_ item: ClipboardItem, then: (() -> Void)? = nil) {
        guard case .richText(let info) = item.content else {
            return copyToPasteboard(item, then: then)
        }
        copyText(info.plainText)
        then?()
    }

    // MARK: Paste

    /// Copies `item`, closes the history panel, and -- only if the user has
    /// turned Paste Directly on -- pastes it into whatever they were doing.
    ///
    /// This is what the panel's Return key should call. With the setting off it
    /// does exactly what choosing an entry has always done: copy, and close.
    func copyAndMaybePaste(_ item: ClipboardItem) {
        closePanelThenPaste({ self.copyToPasteboard(item, then: $0) })
    }

    /// The same, for a "Copy as Plain Text" action on a formatted entry.
    func copyPlainTextAndMaybePaste(_ item: ClipboardItem) {
        closePanelThenPaste({ self.copyPlainText(item, then: $0) })
    }

    /// The shared tail of both: dismiss the panel, run `copy`, and paste when
    /// the copy has landed.
    ///
    /// The order is deliberate. The panel is closed *first*, before the copy,
    /// because a formatted or image entry takes a trip to `ioQueue` and back
    /// and the dismissal should be under way during it rather than after it.
    /// The paste itself is hung off the copy's completion, so it can never
    /// arrive while the clipboard still holds the previous entry.
    ///
    /// That completion is the reason the deadline is stamped *here*, before the
    /// copy rather than inside `PasteService`. For a text entry the completion
    /// is synchronous and the paste follows the keystroke at once; for an image
    /// or a formatted entry it waits on `ioQueue`, which is serial and also
    /// carries index saves, payload writes, `storage.clear()` and an auto-backup
    /// that may serialise every payload in the vault. So the gap being bounded
    /// is the one between the user pressing Return and the keystroke going out,
    /// and only a clock started at the keystroke measures it. `PasteService`
    /// cannot start that clock: by the time it is called the gap has already
    /// happened.
    ///
    /// Closing the panel is `keyWindow.close()`, the same call the view makes,
    /// and the wait for focus to come back lives in `PasteService`.
    ///
    /// Gated on `systemIntegrationEnabled` for the same reason the pasteboard
    /// poller and the global hotkeys are: a unit test has no business closing
    /// windows or posting keystrokes into the machine running it.
    private func closePanelThenPaste(_ copy: ((() -> Void)?) -> Void) {
        guard systemIntegrationEnabled else { return copy(nil) }

        // Both stamps are taken here, before anything else happens, because both
        // describe the same instant: the one the user acted in. `postBy` bounds
        // when the keystroke may still go out; `destination` bounds where. The
        // deadline alone never bounded the destination -- inside those two
        // seconds the keystroke went to whatever was frontmost at post time, and
        // switching applications takes a person about 300 milliseconds.
        //
        // Read before `close()` rather than after, though the panel does not
        // move it: an LSUIElement app never becomes frontmost, so this already
        // names the user's own application while the panel has the keyboard.
        let postBy = Date().addingTimeInterval(PasteService.postWindow)
        let destination = PasteService.frontmostProcess

        NSApplication.shared.keyWindow?.close()
        guard pasteDirectly else { return copy(nil) }
        copy({ [weak self] in
            guard let self else { return }
            // Sampled here, in the completion, because here is where the
            // pasteboard is known to hold the entry. Anything that writes to it
            // between now and the keystroke -- a Quick Slot command finishing
            // with `copyText`, or any other application -- moves the count, and
            // the paste is refused rather than pasting that other thing and
            // reporting success by saying nothing.
            let clipboard = pasteboard.changeCount
            PasteService.pasteWhenFocusReturns(postBy: postBy,
                                               destination: destination,
                                               clipboard: clipboard) { outcome in
                self.report(outcome)
            }
        })
    }

    /// Six outcomes, six answers -- and `PasteService.Outcome` holds the
    /// sentences, so a new case cannot compile until someone has written one.
    ///
    /// The message goes wherever the user is: the state strip if the history
    /// panel is open, a panel below the menu bar if it is not. The second is the
    /// one that matters here, because this always runs after the panel has been
    /// dismissed.
    func report(_ outcome: PasteService.Outcome) {
        guard let message = outcome.message else { return }
        showNotice(message)
    }

    /// Loads and caches a small preview for an image item.
    func thumbnail(for item: ClipboardItem, completion: @escaping (NSImage?) -> Void) {
        if let cached = thumbnailCache[item.id] {
            return completion(cached)
        }
        guard case .image = item.content else { return completion(nil) }

        ioQueue.async { [weak self] in
            // The same signature check `copyToPasteboard` makes, for the same
            // reason and one line of it: `NSImage(data:)` hands the bytes to
            // ImageIO, which will parse a great many formats, so an image row
            // whose payload is not a PNG must not be decoded here either. It
            // closes the class of problem rather than any one route to it.
            guard let self,
                  let data = try? storage.readPayload(for: item.id),
                  data.starts(with: ClipboardMonitor.pngSignature),
                  let image = NSImage(data: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let thumb = ClipboardStore.thumbnail(from: image, fitting: 44)
            DispatchQueue.main.async {
                self.thumbnailCache[item.id] = thumb
                completion(thumb)
            }
        }
    }

    private static func thumbnail(from image: NSImage, fitting maxEdge: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(maxEdge / size.width, maxEdge / size.height, 1)
        let target = NSSize(width: size.width * scale, height: size.height * scale)

        let thumb = NSImage(size: target)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target))
        thumb.unlockFocus()
        return thumb
    }

    func copyText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Runs off the main thread: this used to call waitUntilExit() on the main
    /// thread, so a slow or hanging Quick Slot froze the whole UI.
    func runShellAndCopy(_ command: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = ["-lc", command]
            let pipe = Pipe()
            task.standardOutput = pipe
            // Discarded rather than piped: an unread pipe fills at 64 KB and then
            // blocks the command until the timeout kills it.
            task.standardError = FileHandle.nullDevice

            func fail(_ reason: String) {
                DispatchQueue.main.async {
                    self.showNotice("Quick Slot command \(reason); the clipboard was left alone.")
                }
            }

            do {
                try task.run()
            } catch {
                NSLog("%@", "Shell command error: \(error)")
                fail("could not start")
                return
            }

            var timedOut = false
            let timeout = DispatchWorkItem {
                if task.isRunning {
                    timedOut = true
                    task.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.shellTimeout,
                                              execute: timeout)

            // Drain before waiting: a command that fills the pipe buffer would
            // otherwise block forever waiting for someone to read it.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            timeout.cancel()

            // A failed command must not replace the clipboard with its silence.
            if timedOut {
                fail("did not finish within \(Int(Self.shellTimeout)) seconds")
                return
            }
            guard task.terminationStatus == 0 else {
                fail("failed (exit \(task.terminationStatus))")
                return
            }
            guard let output = String(data: data, encoding: .utf8) else {
                fail("produced output that is not text")
                return
            }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { self.copyText(trimmed) }
        }
    }

    func triggerBinding(slot: Int) {
        let index = slot - 1
        guard index >= 0, index < bindings.count else { return }
        let binding = bindings[index]
        if binding.isShell {
            runShellAndCopy(binding.content)
        } else {
            copyText(binding.content)
        }
    }

    func addBinding() {
        bindings.append(ClipboardBinding(id: UUID(), title: "", content: "", isShell: false))
        persist()
    }

    func removeBinding(_ binding: ClipboardBinding) {
        bindings.removeAll { $0.id == binding.id }
        persist()
    }

    /// State is written atomically as a whole, so every editor uses this one call.
    func persistState() {
        persist()
    }

    func addFolder() {
        folders.append(CommandFolder(id: UUID(), name: "New Folder", items: []))
        persist()
    }

    func removeFolder(_ folder: CommandFolder) {
        folders.removeAll { $0.id == folder.id }
        persist()
    }

    func addCommand(to folder: CommandFolder) {
        guard let idx = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[idx].items.append(CommandItem(id: UUID(), title: "", content: "", isShell: false))
        persist()
    }

    func removeCommand(folder: CommandFolder, item: CommandItem) {
        guard let idx = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[idx].items.removeAll { $0.id == item.id }
        persist()
    }

    func clearAll() {
        items = []
        bindings = []
        folders = []
        thumbnailCache.removeAll()
        autoBackupWork?.cancel()
        writesSuspended = false
        storageFailure = nil
        backupFailure = nil
        // On the I/O queue, behind any payload write still in flight. Done on the
        // main thread this raced a queued write, which recreated the payload
        // directory and left the last copied image on disk after "Delete Everything".
        ioQueue.async { [weak self] in
            guard let self else { return }
            storage.clear()
            try? FileManager.default.removeItem(at: autoBackupURL)
            DispatchQueue.main.async { self.persist() }
        }
    }

    // MARK: Backup

    static func decodeSnapshot(_ data: Data) throws -> VaultSnapshot {
        // AppState decodes every field with a default, deliberately, so that a
        // vault from any version stays readable. The flip side is that any JSON
        // object "decodes" -- `{}` becomes an empty vault -- and an import applies
        // what it decodes. So a backup must carry the one field every vault has
        // had since the first version before it is accepted as one.
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Not a backup"))
        }
        if let state = object["state"] as? [String: Any], state["items"] != nil {
            return try JSONDecoder().decode(VaultSnapshot.self, from: data)
        }
        // Backups written before payloads existed were a bare AppState.
        guard object["items"] != nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                    debugDescription: "Not a Clipvelope backup: no items"))
        }
        return VaultSnapshot(state: try JSONDecoder().decode(AppState.self, from: data),
                             payloads: [:])
    }

    private func exportState(_ state: AppState, to url: URL, password: String?) {
        do {
            var payloads: [String: Data] = [:]
            for item in state.items where item.hasPayloadFile {
                guard let data = try? storage.readPayload(for: item.id) else {
                    NSLog("%@", "Clipvelope: payload missing for \(item.id), excluded from backup")
                    continue
                }
                payloads[item.id.uuidString] = data
            }

            let json = try JSONEncoder().encode(VaultSnapshot(state: state, payloads: payloads))
            let sealed: Data
            if let password {
                sealed = try BackupCodec.seal(json, password: password)
            } else {
                sealed = try BackupCodec.seal(json, keychainKey: try storage.keyStore.getOrCreateKey())
            }
            try sealed.write(to: url, options: [.atomic])
            DispatchQueue.main.async { self.backupFailure = nil }
        } catch {
            NSLog("%@", "Export error: \(error)")
            DispatchQueue.main.async {
                self.backupFailure = "Could not write that backup. (\(error.localizedDescription))"
            }
        }
    }

    /// How far a backup is trusted.
    ///
    /// A keychain-mode backup can only have been produced by something holding
    /// this Mac's Keychain key, which in practice means the user. That holds
    /// because every box the app seals under that key is bound to its role:
    /// a vault payload -- whose plaintext any app can choose by putting it on
    /// the pasteboard -- cannot be presented as a backup. A password backup is
    /// portable by design and can come from anyone, so everything in it is
    /// untrusted input.
    private enum BackupTrust {
        case deviceBound
        case portable
    }

    /// Removes the parts of an untrusted backup that can act on their own.
    ///
    /// `isShell` is just a boolean in the file. Left alone, importing a backup
    /// someone sent you is enough to put `/bin/zsh -lc <anything>` behind a
    /// system-wide Quick Slot hotkey -- which also swallows the keystroke, so
    /// pressing it looks like the shortcut simply did not work.
    private func disarming(_ state: AppState) -> (AppState, [String]) {
        var state = state
        var notes: [String] = []

        let shellCount = state.bindings.filter(\.isShell).count
            + state.folders.reduce(0) { $0 + $1.items.filter(\.isShell).count }
        if shellCount > 0 {
            for index in state.bindings.indices {
                state.bindings[index].isShell = false
            }
            for folder in state.folders.indices {
                for item in state.folders[folder].items.indices {
                    state.folders[folder].items[item].isShell = false
                }
            }
            notes.append("\(shellCount) shell command\(shellCount == 1 ? "" : "s") "
                         + "imported as plain text. Turn Shell back on by hand for any "
                         + "you recognise.")
        }

        // An import must never weaken privacy. A backup carrying
        // skipConcealedContent = false would quietly start recording the
        // passwords this app exists to skip.
        if !state.skipConcealedContent, skipConcealedContent {
            state.skipConcealedContent = true
            notes.append("The backup had password-skipping switched off; it was left on.")
        }
        // Union, so an import can add apps to ignore but never remove them.
        // Adding is the safe direction for privacy but stops capture, so it is
        // still a change the user should hear about.
        let newlyIgnored = Set(state.ignoredAppBundleIDs).subtracting(ignoredAppBundleIDs)
        state.ignoredAppBundleIDs = Array(Set(state.ignoredAppBundleIDs)
            .union(ignoredAppBundleIDs)).sorted()
        if !newlyIgnored.isEmpty {
            notes.append("\(newlyIgnored.count) app\(newlyIgnored.count == 1 ? "" : "s") "
                         + "the backup listed will now be skipped when you copy from "
                         + "\(newlyIgnored.count == 1 ? "it" : "them").")
        }
        state.captureSuspended = captureSuspended
        // Shortcuts are this Mac's business, not the backup's.
        state.openHotkey = openHotkey
        state.preferencesHotkey = preferencesHotkey

        // Pasting for the user means synthesising keystrokes into whatever they
        // are doing, and it is the only feature here that needs Accessibility
        // access. A backup that could switch it on would be arranging for that
        // -- silently, on a Mac whose owner never asked for it, and on any Mac
        // the file reaches. So the imported value is discarded outright and
        // this Mac's own answer is kept, in both directions: a file may not
        // turn it on, and may not turn off someone else's.
        state.pasteDirectly = pasteDirectly

        // Where and whether this Mac writes its own backups is the user's
        // choice, not a setting a file gets to carry. A backup asking for
        // auto-backup would start mirroring the whole vault into ~/Documents
        // after every copy; one that merely omits the fields decodes them as
        // off, which would silently retire a backup the user relies on.
        state.autoBackupEnabled = autoBackupEnabled
        state.autoBackupMode = autoBackupMode

        // A file row holds a path, and pasting it hands the target that file.
        // The paths in someone else's backup describe their machine, so at
        // best they are dead and at worst they name something worth stealing
        // on this one -- ~/.ssh/id_rsa under a row labelled like a report.
        // Everything below is one budget rather than a set of separate caps,
        // because a per-entry limit does not bound a total: a thousand entries
        // each just under it is still gigabytes. All of this text lives inline
        // in the index, which is re-encrypted and rewritten on every single
        // copy, and no policy ever trims it -- so whatever an import installs
        // here is a tax on every copy the user makes from now on. Pinned rows
        // are exempt from the history cap by design, which is exactly why a
        // file may not choose how many there are.
        var remaining = Self.maxImportedInlineBytes
        func affordable(_ text: String) -> Bool {
            let cost = text.utf8.count
            guard cost <= ClipboardMonitor.maxTextBytes, cost <= remaining else { return false }
            remaining -= cost
            return true
        }

        let itemsBefore = state.items.count
        state.items = Array(state.items.prefix(Self.maxImportedItems))
            .filter { affordable($0.searchText) }
        if state.items.count < itemsBefore {
            let dropped = itemsBefore - state.items.count
            notes.append("\(dropped) entr\(dropped == 1 ? "y was" : "ies were") left out for "
                         + "being oversized, or beyond the \(Self.maxImportedItems) an import "
                         + "may bring.")
        }

        let bindingsBefore = state.bindings.count
        state.bindings = Array(state.bindings.prefix(Self.maxImportedItems))
            .filter { affordable($0.title + $0.content) }
        let foldersBefore = state.folders.reduce(state.folders.count) { $0 + $1.items.count }
        state.folders = Array(state.folders.prefix(Self.maxImportedItems))
            .filter { affordable($0.name) }
            .map { folder in
                var folder = folder
                folder.items = Array(folder.items.prefix(Self.maxImportedItems))
                    .filter { affordable($0.title + $0.content) }
                return folder
            }
        let foldersAfter = state.folders.reduce(state.folders.count) { $0 + $1.items.count }
        let commandsDropped = (bindingsBefore - state.bindings.count) + (foldersBefore - foldersAfter)
        if commandsDropped > 0 {
            // Losing a Quick Slot without being told is indistinguishable from
            // the feature quietly breaking.
            notes.append("\(commandsDropped) Quick Slot\(commandsDropped == 1 ? " or folder command was" : "s or folder commands were") "
                         + "left out for the same reason.")
        }

        let fileItems = state.items.filter { if case .files = $0.content { return true } else { return false } }
        if !fileItems.isEmpty {
            state.items.removeAll { if case .files = $0.content { return true } else { return false } }
            notes.append("\(fileItems.count) file reference\(fileItems.count == 1 ? " was" : "s were") "
                         + "left out: they point at files on the machine that wrote the backup.")
        }

        // Last, so the rows already left out do not spend a pin.
        //
        // A pinned row is exempt from the history cap, so how many of them a file
        // may install is not a matter of taste: at `maxItems` pinned rows the
        // vault sits at its ceiling with nothing the cap is allowed to evict, and
        // `HistoryPolicy`'s protection of the newest entry is then the only thing
        // between the user and a copy that goes nowhere. `maxItems - 1` is the
        // largest count that leaves the ordinary rule working unaided -- one copy
        // still fits under the cap without displacing anything -- so that is the
        // number, reached by arithmetic rather than by picking a round one.
        //
        // The surplus is imported *unpinned* rather than dropped. A restore that
        // silently deletes entries is the failure this file is full of fixes for;
        // unpinning keeps every entry the backup carried and merely returns them
        // to the cap that governs everything else, which is where a
        // thousand-entry import has always left them.
        let pinnable = Self.maxImportedPinnedItems
        let pinned = state.items.indices.filter { state.items[$0].isPinned }
        if pinned.count > pinnable {
            for index in pinned.dropFirst(pinnable) {
                state.items[index].isPinned = false
            }
            let unpinned = pinned.count - pinnable
            notes.append("\(unpinned) entr\(unpinned == 1 ? "y was" : "ies were") pinned beyond "
                         + "the \(pinnable) a backup may pin, so \(unpinned == 1 ? "it was" : "they were") "
                         + "imported unpinned. Pinned entries are never trimmed, and a history "
                         + "made of nothing else has no room for what you copy next.")
        }

        return (state, notes)
    }

    /// Whether a payload out of a backup is really the thing its item claims,
    /// and stays inside the limits capture enforces.
    ///
    /// A declared `contentHash` is part of that claim, and the strongest part of
    /// it: everything else an item says about its payload is a property many
    /// different payloads share, while the digest names one. An item whose hash
    /// does not match the bytes filed under its id is not describing them, so
    /// the payload is refused and the caller tells the user which entries went.
    /// A backup written before the field existed declares no hash and is judged
    /// exactly as it was before.
    ///
    /// The declared `byteCount` is part of the claim too, and unlike the hash it
    /// is never absent -- every version of this app has written it, straight from
    /// the length of the bytes it stored. It is only clamped on decode, so
    /// nothing else stopped a backup filing a real 32 MB picture under an item
    /// declaring `byteCount: 0`, and three separate things downstream believe
    /// that number: `hasPayloadFile`, which decides whether the payload is
    /// carried in the backups the user makes from then on; the byte budget in
    /// `HistoryPolicy.trimmed`, which cannot evict weight it cannot see; and
    /// `replaceItems`, which leaves the file on disk when the row goes. A claim
    /// that does not match its bytes is refused here like any other.
    static func payloadIsAcceptable(_ data: Data, for content: ClipboardContent) -> Bool {
        switch content {
        case .image(let info):
            guard data.count <= ClipboardMonitor.maxImageBytes,
                  info.byteCount == data.count,
                  data.starts(with: ClipboardMonitor.pngSignature),
                  let size = ClipboardMonitor.declaredPixelSize(of: data),
                  ClipboardMonitor.acceptsImage(pixelWidth: size.0, pixelHeight: size.1),
                  hashMatches(data, declared: info.contentHash)
            else { return false }
            return true
        case .richText(let info):
            return data.count <= ClipboardMonitor.maxRichTextBytes
                && info.byteCount == data.count
                && hashMatches(data, declared: info.contentHash)
        case .text, .files:
            // Neither keeps a payload file, so a payload claiming to be one is
            // not something this app wrote.
            return false
        }
    }

    /// True when no hash is declared, or the declared one is these bytes'.
    /// Case-insensitive because the comparison is of a hex rendering, not of a
    /// string this app is the only writer of.
    private static func hashMatches(_ data: Data, declared: String?) -> Bool {
        guard let declared else { return true }
        return declared.lowercased() == ClipboardContent.digest(data)
    }

    private func importState(from url: URL, password: String?) {
        do {
            let data = try Data(contentsOf: url)
            // Pre-release builds wrote headerless files. Those are refused now,
            // and saying so beats the generic "check the password".
            guard !BackupCodec.isPreReleaseFormat(data) else {
                DispatchQueue.main.async {
                    self.backupFailure = "That file was written by a pre-release version of "
                        + "Clipvelope, whose backup format is no longer accepted. Export a "
                        + "fresh backup from a vault you can still open."
                }
                return
            }
            let decrypted: Data
            if let password {
                decrypted = try BackupCodec.open(data, password: password)
            } else {
                decrypted = try BackupCodec.open(data, keychainKey: try storage.keyStore.getOrCreateKey())
            }
            let trust: BackupTrust = password == nil ? .deviceBound : .portable
            let snapshot = try Self.decodeSnapshot(decrypted)

            // Two entries under one id make "the item claiming this id"
            // ambiguous, and the two places that resolve it need not resolve it
            // the same way: the payload check below keeps the first item with
            // that id, while `disarming` afterwards drops items independently --
            // for being oversized -- and `apply` keeps the first *survivor*. A
            // file pairing an oversized rich-text item with an image under one
            // id therefore has its payload judged against the rich-text claim,
            // which only looks at a size ceiling, and the image is the one that
            // reaches the vault: an image row whose bytes never faced the PNG
            // signature, the declared pixel size, or `acceptsImage`.
            //
            // Refusing the whole file is the answer rather than re-checking
            // after the filtering, because it is one rule to be sure of instead
            // of an ordering to keep true forever. Nothing legitimate is lost: a
            // vault is deduplicated before it is saved, so no backup this app
            // has ever written has two items under one id.
            let ids = snapshot.state.items.map(\.id)
            guard Set(ids).count == ids.count else {
                DispatchQueue.main.async {
                    self.backupFailure = "That backup lists two entries under one identifier, "
                        + "which no backup Clipvelope writes does, so none of it was imported. "
                        + "Export a fresh backup from a vault you can still open."
                }
                return
            }

            // Payload bytes come out of the file, and an image payload is decoded
            // later to draw a thumbnail. Capture checks a picture's declared size
            // before decoding it precisely so a small file cannot demand an
            // enormous raster; a backup is the same hostile input and gets the
            // same check, against what its own item claims to be.
            //
            // Judged here and written further down, after the main queue has had
            // its say. They used to be written on the spot, which put them in
            // `items/` moments before an import into a suspended vault moved
            // `items/` aside: `quarantineUnreadableVault` takes the payload
            // directory with the index, deliberately and correctly, so the
            // pictures the import had just restored went into
            // `items.unreadable-<stamp>` and the rows installed a breath later
            // pointed at nothing. That is the recovery path failing at the one
            // moment it is needed.
            let declared = Dictionary(snapshot.state.items.map { ($0.id, $0.content) },
                                      uniquingKeysWith: { first, _ in first })
            var rejected: Set<UUID> = []
            var accepted: [UUID: Data] = [:]
            for (key, data) in snapshot.payloads {
                guard let id = UUID(uuidString: key) else { continue }
                guard let content = declared[id],
                      Self.payloadIsAcceptable(data, for: content) else {
                    rejected.insert(id)
                    continue
                }
                accepted[id] = data
            }

            let imported = snapshot.state
            DispatchQueue.main.async {
                var notes: [String] = []
                var state: AppState
                switch trust {
                case .deviceBound:
                    state = imported
                case .portable:
                    (state, notes) = self.disarming(imported)
                }
                if !rejected.isEmpty {
                    let before = state.items.count
                    state.items.removeAll { rejected.contains($0.id) }
                    let dropped = before - state.items.count
                    if dropped > 0 {
                        notes.append("\(dropped) entr\(dropped == 1 ? "y was" : "ies were") left "
                                     + "out: what the backup stored for \(dropped == 1 ? "it" : "them") "
                                     + "did not match what it said \(dropped == 1 ? "it" : "they") "
                                     + "contained.")
                    }
                }

                if self.writesSuspended {
                    // The unreadable index is ciphertext that may still decrypt once
                    // the right key is back. A successful import replaces the vault,
                    // but it must not write over that file.
                    self.storage.quarantineUnreadableVault()
                }
                // Only now, with whatever was there already moved aside, and on
                // the queue that owns the vault. `ioQueue` is serial and the
                // `persist()` below enqueues the index behind these, so the
                // payloads are on disk before anything names them -- the same
                // ordering `add` keeps.
                //
                // Only the payloads of rows that actually reached the vault: an
                // entry `disarming` left out has no row to be read through, so
                // its bytes would sit in `items/` until some later launch swept
                // them.
                let live = Set(state.items.map(\.id))
                let payloads = accepted.filter { live.contains($0.key) }
                self.ioQueue.async {
                    for (id, data) in payloads {
                        do {
                            try self.storage.writePayload(data, for: id)
                        } catch {
                            NSLog("%@", "Clipvelope: could not write imported payload for \(id): \(error)")
                        }
                    }
                }
                self.apply(state)
                // A successful import is authoritative: it clears a suspended vault.
                self.writesSuspended = false
                self.storageFailure = nil
                self.backupFailure = nil
                self.hasLoaded = true
                self.importNotice = notes.isEmpty ? nil : notes.joined(separator: " ")
                self.persist()
            }
        } catch {
            NSLog("%@", "Import error: \(error)")
            DispatchQueue.main.async {
                self.backupFailure = "Could not read that backup. If it was exported with a "
                    + "password, check the password. (\(error.localizedDescription))"
            }
        }
    }

    /// Writes a backup to `url`. The Export buttons are this plus a save panel.
    func exportBackup(to url: URL, password: String?) {
        let snapshot = currentState
        ioQueue.async { [weak self] in
            self?.exportState(snapshot, to: url, password: password)
        }
    }

    /// Replaces the vault contents from a backup. The Import buttons are this
    /// plus an open panel.
    func importBackup(from url: URL, password: String?) {
        ioQueue.async { [weak self] in
            self?.importState(from: url, password: password)
        }
    }

    func manualExportKeychain() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clipvelope-backup.cvb"
        panel.begin { result in
            if result == .OK, let url = panel.url {
                self.exportBackup(to: url, password: nil)
            }
        }
    }

    func manualExportPassword(_ password: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clipvelope-backup.cvb"
        panel.begin { result in
            if result == .OK, let url = panel.url {
                self.exportBackup(to: url, password: password)
            }
        }
    }

    func manualImportKeychain() {
        let panel = NSOpenPanel()
        panel.begin { result in
            if result == .OK, let url = panel.url {
                self.importBackup(from: url, password: nil)
            }
        }
    }

    func manualImportPassword(_ password: String) {
        let panel = NSOpenPanel()
        panel.begin { result in
            if result == .OK, let url = panel.url {
                self.importBackup(from: url, password: password)
            }
        }
    }

    func autoBackup() {
        let snapshot = currentState
        ioQueue.async { [weak self] in
            guard let self else { return }
            var password: String?
            if snapshot.autoBackupMode == .password {
                guard let saved = autoBackupPasswordStore.loadAutoBackupPassword() else {
                    // Falling back to the keychain key would write a file the user
                    // believes is portable and cannot open anywhere else. Say so instead.
                    DispatchQueue.main.async {
                        self.backupFailure = "Auto backup is set to Password, but no password is "
                            + "saved. Enter one and click Use the Password Above."
                    }
                    return
                }
                password = saved
            }
            exportState(snapshot, to: autoBackupURL, password: password)
        }
    }

    func restoreFromAutoBackup(password: String?) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            importState(from: autoBackupURL, password: password)
        }
    }

    /// False, with `backupFailure` set, when the Keychain refused the write.
    @discardableResult
    func saveAutoBackupPassword(_ password: String) -> Bool {
        if let error = autoBackupPasswordStore.saveAutoBackupPassword(password) {
            backupFailure = "Could not save the password to the Keychain. (\(error.localizedDescription))"
            return false
        }
        backupFailure = nil
        return true
    }
}
