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
    private let maxItems = 200
    /// Ceiling on stored image bytes. A count-based cap alone would happily
    /// hold 200 screenshots.
    private let maxPayloadBytes = 512 * 1024 * 1024
    private static let autoBackupDelay: TimeInterval = 15

    private var autoBackupWork: DispatchWorkItem?
    private var noticeWork: DispatchWorkItem?
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

    /// - Parameter enableSystemIntegration: pasteboard polling and global
    ///   hotkeys. Off in tests, which have no business installing a system-wide
    ///   hotkey or reacting to whatever the machine's clipboard happens to do.
    init(storage: EncryptedStorage = EncryptedStorage(),
         enableSystemIntegration: Bool = true,
         pasteboard: NSPasteboard = .general) {
        self.storage = storage
        self.systemIntegrationEnabled = enableSystemIntegration
        self.pasteboard = pasteboard

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
        }
        loadFromStorage()
    }

    // MARK: Notices

    /// Shown in the state strip for a few seconds. Only for outcomes the user
    /// would otherwise never learn about.
    func showNotice(_ text: String) {
        notice = text
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
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
            storageFailure = StorageFailure(
                message: "Your vault could not be decrypted, so saving is paused to "
                    + "protect it. This usually means the Keychain was locked or access "
                    + "was denied. (\(error.localizedDescription))"
            )
            NSLog("Clipvelope: vault unreadable, writes suspended: \(error)")
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
        items = state.items
        bindings = state.bindings
        folders = state.folders
        autoBackupEnabled = state.autoBackupEnabled
        autoBackupMode = state.autoBackupMode
        themeMode = state.themeMode
        skipConcealedContent = state.skipConcealedContent
        ignoredAppBundleIDs = state.ignoredAppBundleIDs
        captureSuspended = state.captureSuspended
        preferencesHotkey = state.preferencesHotkey
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
            preferencesHotkey: preferencesHotkey
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
            storage.quarantineUnreadableIndex()
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
                NSLog("Clipvelope save error: \(error)")
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
        case .richText(let data, let plain, let type):
            content = .richText(.init(plainText: plain, byteCount: data.count,
                                      typeIdentifier: type))
            payloadBytes = data
        case .image(let data, let type, let width, let height):
            content = .image(.init(pixelWidth: width, pixelHeight: height,
                                   byteCount: data.count, typeIdentifier: type))
            payloadBytes = data
        case .files(let urls):
            content = .files(urls.map { .init(path: $0.path) })
        }

        let updated = HistoryPolicy.inserting(content, into: items, maxItems: maxItems,
                                              maxPayloadBytes: maxPayloadBytes,
                                              id: id, source: source)
        guard updated != items else { return }

        // Write the payload before the index that names it. ioQueue is serial and
        // persist() enqueues onto it, so this ordering holds.
        if let payloadBytes, updated.contains(where: { $0.id == id }) {
            ioQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try storage.writePayload(payloadBytes, for: id)
                } catch {
                    NSLog("Clipvelope: could not write payload for \(id): \(error)")
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
        replaceItems(with: HistoryPolicy.trimmed(updated, maxItems: maxItems,
                                                 maxPayloadBytes: maxPayloadBytes))
    }

    func copyToPasteboard(_ item: ClipboardItem) {
        switch item.content {
        case .text(let value):
            copyText(value)

        case .richText(let info):
            // Put both renderings back, so a rich target keeps the formatting
            // and a plain one still gets sensible text.
            ioQueue.async { [weak self] in
                guard let self else { return }
                guard let data = try? storage.readPayload(for: item.id) else {
                    NSLog("Clipvelope: payload missing for \(item.id)")
                    DispatchQueue.main.async {
                        self.copyText(info.plainText)
                        self.showNotice("The formatting for that entry was missing, so plain text was copied.")
                    }
                    return
                }
                let type: NSPasteboard.PasteboardType =
                    info.typeIdentifier == "public.html" ? .html : .rtf
                DispatchQueue.main.async {
                    self.pasteboard.clearContents()
                    self.pasteboard.setData(data, forType: type)
                    self.pasteboard.setString(info.plainText, forType: .string)
                }
            }

        case .files(let refs):
            pasteboard.clearContents()
            pasteboard.writeObjects(refs.map { URL(fileURLWithPath: $0.path) as NSURL })

        case .image:
            // The payload is a file now, so reading it is I/O.
            ioQueue.async { [weak self] in
                guard let self else { return }
                guard let data = try? storage.readPayload(for: item.id) else {
                    // A row that looks like an image but cannot produce one is
                    // worse than no row: take it out and say why.
                    NSLog("Clipvelope: payload missing for \(item.id)")
                    DispatchQueue.main.async {
                        self.remove(item)
                        self.showNotice("That image's file was missing, so the entry was removed.")
                    }
                    return
                }
                DispatchQueue.main.async {
                    self.pasteboard.clearContents()
                    self.pasteboard.setData(data, forType: .png)
                }
            }
        }
    }

    /// Loads and caches a small preview for an image item.
    func thumbnail(for item: ClipboardItem, completion: @escaping (NSImage?) -> Void) {
        if let cached = thumbnailCache[item.id] {
            return completion(cached)
        }
        guard case .image = item.content else { return completion(nil) }

        ioQueue.async { [weak self] in
            guard let self,
                  let data = try? storage.readPayload(for: item.id),
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
                NSLog("Shell command error: \(error)")
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
                    NSLog("Clipvelope: payload missing for \(item.id), excluded from backup")
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
            NSLog("Export error: \(error)")
            DispatchQueue.main.async {
                self.backupFailure = "Could not write that backup. (\(error.localizedDescription))"
            }
        }
    }

    /// How far a backup is trusted.
    ///
    /// A keychain-mode backup can only have been produced by something holding
    /// this Mac's Keychain key, which in practice means the user. A password
    /// backup is portable by design and can come from anyone, so everything in
    /// it is untrusted input.
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
        state.ignoredAppBundleIDs = Array(Set(state.ignoredAppBundleIDs)
            .union(ignoredAppBundleIDs)).sorted()
        state.captureSuspended = captureSuspended
        // Shortcuts are this Mac's business, not the backup's.
        state.openHotkey = openHotkey
        state.preferencesHotkey = preferencesHotkey

        return (state, notes)
    }

    private func importState(from url: URL, password: String?) {
        do {
            let data = try Data(contentsOf: url)
            let decrypted: Data
            if let password {
                decrypted = try BackupCodec.open(data, password: password)
            } else {
                decrypted = try BackupCodec.open(data, keychainKey: try storage.keyStore.getOrCreateKey())
            }
            let trust: BackupTrust = password == nil ? .deviceBound : .portable
            let wasLegacy = BackupCodec.isLegacyFormat(data)
            let snapshot = try Self.decodeSnapshot(decrypted)
            for (key, data) in snapshot.payloads {
                guard let id = UUID(uuidString: key) else { continue }
                try? storage.writePayload(data, for: id)
            }
            let imported = snapshot.state
            DispatchQueue.main.async {
                var notes: [String] = []
                let state: AppState
                switch trust {
                case .deviceBound:
                    state = imported
                case .portable:
                    (state, notes) = self.disarming(imported)
                }
                // Only the password variant of the old format was weak; a legacy
                // keychain backup used the full 256-bit key.
                if wasLegacy && password != nil {
                    notes.append("This backup used the old format, whose password "
                                 + "protection is weak. Export it again to upgrade it.")
                }

                if self.writesSuspended {
                    // The unreadable index is ciphertext that may still decrypt once
                    // the right key is back. A successful import replaces the vault,
                    // but it must not write over that file.
                    self.storage.quarantineUnreadableIndex()
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
            NSLog("Import error: \(error)")
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
