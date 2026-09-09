import XCTest
import CryptoKit
@testable import Clipvelope

/// A key held in memory, so the suite never touches the login Keychain.
private struct FixedKeyStore: KeyProviding {
    let key: SymmetricKey
    init(seed: UInt8 = 1) {
        self.key = SymmetricKey(data: Data(repeating: seed, count: 32))
    }
    func getOrCreateKey() throws -> SymmetricKey { key }
}

final class StorageTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipvelope-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStorage(seed: UInt8 = 1) -> EncryptedStorage {
        EncryptedStorage(directory: dir, keyStore: FixedKeyStore(seed: seed))
    }

    /// Writes a fixture encrypted with the same key the storage under test uses.
    private func writeSealed(_ plaintext: Data, to url: URL, seed: UInt8 = 1) throws {
        let sealed = try AES.GCM.seal(plaintext, using: FixedKeyStore(seed: seed).key)
        try XCTUnwrap(sealed.combined).write(to: url)
    }

    private func sampleState() -> AppState {
        var state = AppState.empty
        state.items = [ClipboardItem(id: UUID(), text: "hello", createdAt: Date())]
        state.folders = [CommandFolder(id: UUID(), name: "Deploy", items: [])]
        state.themeMode = .dark
        return state
    }

    // MARK: - Round trip

    func testSaveThenLoadReturnsTheSameState() throws {
        let storage = makeStorage()
        let state = sampleState()
        try storage.saveIndex( state)

        guard case .loaded(let loaded) = storage.load() else {
            return XCTFail("expected .loaded")
        }
        XCTAssertEqual(loaded.items.map(\.searchText), ["hello"])
        XCTAssertEqual(loaded.folders.map(\.name), ["Deploy"])
        XCTAssertEqual(loaded.themeMode, .dark)
    }

    func testSaveStampsTheCurrentSchemaVersion() throws {
        let storage = makeStorage()
        var state = sampleState()
        state.schemaVersion = 1

        try storage.saveIndex( state)
        guard case .loaded(let loaded) = storage.load() else {
            return XCTFail("expected .loaded")
        }
        XCTAssertEqual(loaded.schemaVersion, AppState.currentSchemaVersion)
    }

    func testContentsAreNotStoredInPlaintext() throws {
        let storage = makeStorage()
        var state = AppState.empty
        state.items = [ClipboardItem(id: UUID(), text: "correct-horse-battery", createdAt: Date())]
        try storage.saveIndex( state)

        let raw = try Data(contentsOf: storage.indexURL)
        XCTAssertNil(raw.range(of: Data("correct-horse-battery".utf8)),
                     "clipboard text must not appear in the file")
    }

    // MARK: - The three load outcomes must stay distinct

    func testMissingFileIsFreshNotUnreadable() {
        guard case .fresh = makeStorage().load() else {
            return XCTFail("a missing vault is a first run, not a failure")
        }
    }

    /// Regression test. `load()` used to swallow every error and return empty
    /// state; the next save then overwrote the vault, permanently destroying
    /// history that was only temporarily unreadable.
    func testCorruptedFileIsUnreadableSoCallersDoNotOverwriteIt() throws {
        let storage = makeStorage()
        try storage.saveIndex( sampleState())

        var bytes = try Data(contentsOf: storage.indexURL)
        bytes[30] ^= 0xFF
        try bytes.write(to: storage.indexURL)

        guard case .unreadable = storage.load() else {
            return XCTFail("a corrupted vault must report .unreadable, never .fresh")
        }
    }

    func testWrongKeyIsUnreadableNotFresh() throws {
        try makeStorage(seed: 1).saveIndex(sampleState())

        // Same file, different key -- what a broken Keychain ACL looks like.
        guard case .unreadable = makeStorage(seed: 2).load() else {
            return XCTFail("an undecryptable vault must report .unreadable")
        }
    }

    // MARK: - Migration from the pre-schema-4 single blob

    /// Schema v1 files hold a bare array of items with no surrounding object.
    func testLegacyV1BlobIsMigratedRatherThanTreatedAsCorrupt() throws {
        let storage = makeStorage()
        let items = [ClipboardItem(text: "legacy entry")]
        try writeSealed(try JSONEncoder().encode(items), to: storage.legacyBlobURL)

        guard case .loaded(let loaded) = storage.load() else {
            return XCTFail("a v1 vault must still load")
        }
        XCTAssertEqual(loaded.items.map(\.searchText), ["legacy entry"])
    }

    /// Schema 2-3 stored each item's text under a bare `text` key.
    func testLegacyTextItemsBecomeTextContent() throws {
        let storage = makeStorage()
        let json = #"""
        {"schemaVersion":3,"items":[{"id":"\#(UUID().uuidString)","text":"older entry",\#
        "createdAt":0,"isPinned":true}],"bindings":[],"folders":[]}
        """#
        try writeSealed(Data(json.utf8), to: storage.legacyBlobURL)

        guard case .loaded(let loaded) = storage.load() else {
            return XCTFail("a v3 vault must still load")
        }
        XCTAssertEqual(loaded.items.count, 1)
        XCTAssertEqual(loaded.items[0].content, .text("older entry"))
        XCTAssertTrue(loaded.items[0].isPinned)
    }

    func testMigrationWritesAnIndexAndKeepsTheOriginal() throws {
        let storage = makeStorage()
        try writeSealed(try JSONEncoder().encode([ClipboardItem(text: "x")]),
                        to: storage.legacyBlobURL)

        _ = storage.load()

        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.indexURL.path),
                      "migration must write the new index")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.legacyBlobURL.path),
                       "the original must be moved aside")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("clipboard.db.migrated").path),
                      "the original must be kept, not deleted")
    }

    func testAnIndexTakesPrecedenceOverAStaleLegacyBlob() throws {
        let storage = makeStorage()
        var state = AppState.empty
        state.items = [ClipboardItem(text: "current")]
        try storage.saveIndex(state)
        try writeSealed(try JSONEncoder().encode([ClipboardItem(text: "stale")]),
                        to: storage.legacyBlobURL)

        guard case .loaded(let loaded) = storage.load() else { return XCTFail("expected .loaded") }
        XCTAssertEqual(loaded.items.map(\.searchText), ["current"])
    }

    // MARK: - Payloads

    func testPayloadRoundTrip() throws {
        let storage = makeStorage()
        let id = UUID()
        let payload = Data(repeating: 0xAB, count: 4096)

        try storage.writePayload(payload, for: id)

        XCTAssertEqual(try storage.readPayload(for: id), payload)
    }

    func testPayloadsAreEncryptedOnDisk() throws {
        let storage = makeStorage()
        let id = UUID()
        let payload = Data("PNG-ish secret bytes".utf8)
        try storage.writePayload(payload, for: id)

        let raw = try Data(contentsOf: storage.payloadURL(for: id))
        XCTAssertNil(raw.range(of: payload), "payload bytes must not be readable on disk")
    }

    func testDeletingAPayloadRemovesTheFile() throws {
        let storage = makeStorage()
        let id = UUID()
        try storage.writePayload(Data([1, 2, 3]), for: id)

        storage.deletePayload(for: id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.payloadURL(for: id).path))
    }

    /// A crash between writing a payload and saving the index leaves a file
    /// nothing refers to; loading sweeps those.
    func testOrphanPayloadsAreSweptAndLiveOnesKept() throws {
        let storage = makeStorage()
        let live = UUID(), orphan = UUID()
        try storage.writePayload(Data([1]), for: live)
        try storage.writePayload(Data([2]), for: orphan)

        storage.deletePayloads(notIn: [live])

        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.payloadURL(for: live).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.payloadURL(for: orphan).path))
    }

    func testClearRemovesIndexAndPayloads() throws {
        let storage = makeStorage()
        let id = UUID()
        try storage.saveIndex(sampleState())
        try storage.writePayload(Data([1]), for: id)

        storage.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.indexURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.payloadURL(for: id).path))
    }

    // MARK: - Every file is bound to its role

    /// Same key, same format: without the role in the associated data, a
    /// payload written from bytes any app can choose (by copying them) would
    /// load as the vault's state.
    func testAPayloadCopiedOverTheIndexIsUnreadableNotLoaded() throws {
        let storage = makeStorage()
        let forged = try JSONEncoder().encode(sampleState())
        try storage.writePayload(forged, for: UUID())
        let payload = try XCTUnwrap(try FileManager.default
            .contentsOfDirectory(at: storage.payloadsDirectory, includingPropertiesForKeys: nil).first)

        try FileManager.default.copyItem(at: payload, to: storage.indexURL)

        guard case .unreadable = storage.load() else {
            return XCTFail("a payload must never open as the index")
        }
    }

    /// The other direction: the index copied over an image's payload would be
    /// decrypted and handed to the pasteboard as the "image".
    func testTheIndexCopiedOverAPayloadDoesNotOpen() throws {
        let storage = makeStorage()
        try storage.saveIndex(sampleState())
        let id = UUID()
        try storage.writePayload(Data([1, 2, 3]), for: id)

        try FileManager.default.removeItem(at: storage.payloadURL(for: id))
        try FileManager.default.copyItem(at: storage.indexURL, to: storage.payloadURL(for: id))

        XCTAssertThrowsError(try storage.readPayload(for: id))
    }

    func testOneItemsPayloadDoesNotOpenAsAnothers() throws {
        let storage = makeStorage()
        let a = UUID(), b = UUID()
        try storage.writePayload(Data("a's image".utf8), for: a)

        try FileManager.default.copyItem(at: storage.payloadURL(for: a), to: storage.payloadURL(for: b))

        XCTAssertEqual(try storage.readPayload(for: a), Data("a's image".utf8))
        XCTAssertThrowsError(try storage.readPayload(for: b))
    }

    /// Vaults written before roles existed are sealed with no associated data.
    /// They open once, come back bound, and the unbound form is never produced
    /// again.
    func testAnUnboundVaultIsMigratedAndReboundOnFirstLoad() throws {
        let storage = makeStorage()
        let id = UUID()
        var state = sampleState()
        state.items = [ClipboardItem(id: id, createdAt: Date(), isPinned: false,
                                     content: .image(.init(pixelWidth: 1, pixelHeight: 1,
                                                           byteCount: 3, typeIdentifier: "public.png")),
                                     sourceBundleID: nil)]
        try writeSealed(try JSONEncoder().encode(state), to: storage.indexURL)
        try FileManager.default.createDirectory(at: storage.payloadsDirectory, withIntermediateDirectories: true)
        try writeSealed(Data([9, 9, 9]), to: storage.payloadURL(for: id))

        guard case .loaded(let loaded) = storage.load() else {
            return XCTFail("a pre-role vault must still load")
        }
        XCTAssertEqual(loaded.items.map(\.id), [id])
        XCTAssertEqual(try storage.readPayload(for: id), Data([9, 9, 9]))

        // Bound now: the same bytes no longer open without their role.
        let key = FixedKeyStore().key
        let rawIndex = try AES.GCM.SealedBox(combined: try Data(contentsOf: storage.indexURL))
        XCTAssertThrowsError(try AES.GCM.open(rawIndex, using: key))
        let rawPayload = try AES.GCM.SealedBox(combined: try Data(contentsOf: storage.payloadURL(for: id)))
        XCTAssertThrowsError(try AES.GCM.open(rawPayload, using: key))
    }

    // MARK: - A vault that reads but cannot be written back

    /// The upgrade to role-bound files rewrites the vault. If that write fails,
    /// the history is still perfectly readable, and calling it "unreadable"
    /// steers the user to a repair that moves their whole vault aside.
    func testAVaultThatReadsButCannotBeRewrittenIsNotCalledUnreadable() throws {
        let storage = makeStorage()
        try writeSealed(try JSONEncoder().encode(sampleState()), to: storage.indexURL)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

        guard case .loadedButUnwritable(let state, _) = storage.load() else {
            return XCTFail("a readable vault whose rewrite fails must report .loadedButUnwritable")
        }
        XCTAssertEqual(state.items.map(\.searchText), ["hello"],
                       "and it must still hand back the history it read")
    }

    /// The index is written last on purpose: leaving it unbound means the next
    /// launch simply tries the upgrade again.
    func testAFailedUpgradeLeavesTheVaultReadableForTheNextLaunch() throws {
        let storage = makeStorage()
        try writeSealed(try JSONEncoder().encode(sampleState()), to: storage.indexURL)
        let before = try Data(contentsOf: storage.indexURL)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        _ = storage.load()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        XCTAssertEqual(try Data(contentsOf: storage.indexURL), before, "the vault must be untouched")
        guard case .loaded(let state) = storage.load() else {
            return XCTFail("with the directory writable again the upgrade must succeed")
        }
        XCTAssertEqual(state.items.map(\.searchText), ["hello"])
    }

    // MARK: - Quarantine

    func testQuarantinePreservesTheOriginalBytes() throws {
        let storage = makeStorage()
        try storage.saveIndex( sampleState())
        let original = try Data(contentsOf: storage.indexURL)

        let moved = try XCTUnwrap(storage.quarantineUnreadableIndex())

        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.indexURL.path))
        XCTAssertEqual(try Data(contentsOf: moved), original,
                       "the unreadable vault must be recoverable, not destroyed")
    }

    func testQuarantineWithNoFileIsANoOp() {
        XCTAssertNil(makeStorage().quarantineUnreadableIndex())
    }
}
