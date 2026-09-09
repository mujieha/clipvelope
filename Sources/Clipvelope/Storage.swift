import Foundation
import CryptoKit

enum StorageError: Error {
    case sealFailed
}

/// Lets tests supply a fixed key instead of reaching for the login Keychain,
/// which would otherwise prompt and make the suite non-hermetic.
protocol KeyProviding {
    func getOrCreateKey() throws -> SymmetricKey
}

extension KeychainKeyStore: KeyProviding {}

/// The on-disk vault.
///
/// ```
/// Clipvelope/
///   index.cvi          encrypted settings + item metadata (text lives here)
///   items/<uuid>.cvi   one encrypted payload per image
///   clipboard.db       pre-schema-4 single blob, migrated on first load
/// ```
///
/// The index was once the entire history, re-encrypted and rewritten on every
/// single copy. That is fine for text and hopeless for images: a few megabyte
/// screenshots would mean rewriting hundreds of megabytes per copy. Splitting
/// payloads out makes the cost of a copy proportional to the thing copied.
final class EncryptedStorage {
    /// The three outcomes must stay distinct. Collapsing `unreadable` into `fresh`
    /// is what let a single unreadable byte destroy the whole history: the caller
    /// started from empty state and the next save overwrote the file.
    enum LoadOutcome {
        case fresh
        case loaded(AppState)
        case unreadable(Error)
    }

    /// Exposed so backups encrypt against the same key as the vault. They used
    /// to use a separate KeychainKeyStore instance, which is two sources of
    /// truth for one key.
    let keyStore: KeyProviding
    let directory: URL

    var indexURL: URL { directory.appendingPathComponent("index.cvi") }
    var payloadsDirectory: URL { directory.appendingPathComponent("items", isDirectory: true) }
    var legacyBlobURL: URL { directory.appendingPathComponent("clipboard.db") }

    static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("Clipvelope", isDirectory: true)
    }

    init(directory: URL? = nil, keyStore: KeyProviding = KeychainKeyStore()) {
        self.keyStore = keyStore
        self.directory = directory ?? EncryptedStorage.defaultDirectory
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: - Index

    func saveIndex(_ state: AppState) throws {
        var state = state
        state.schemaVersion = AppState.currentSchemaVersion
        try writeSealed(try JSONEncoder().encode(state), to: indexURL)
    }

    func load() -> LoadOutcome {
        if FileManager.default.fileExists(atPath: indexURL.path) {
            do {
                return .loaded(try decodeState(try readSealed(at: indexURL)))
            } catch {
                return .unreadable(error)
            }
        }
        if FileManager.default.fileExists(atPath: legacyBlobURL.path) {
            return migrateLegacyBlob()
        }
        return .fresh
    }

    /// Reads the pre-schema-4 single blob and rewrites it as an index.
    ///
    /// The original is moved aside rather than deleted, and only after the new
    /// index is on disk, so a failure part-way through cannot lose history.
    private func migrateLegacyBlob() -> LoadOutcome {
        do {
            let state = try decodeState(try readSealed(at: legacyBlobURL))
            try saveIndex(state)
            try? FileManager.default.moveItem(
                at: legacyBlobURL,
                to: directory.appendingPathComponent("clipboard.db.migrated")
            )
            return .loaded(state)
        } catch {
            return .unreadable(error)
        }
    }

    private func decodeState(_ data: Data) throws -> AppState {
        if let state = try? JSONDecoder().decode(AppState.self, from: data) { return state }
        // Schema v1 stored a bare array of items with no surrounding object.
        let items = try JSONDecoder().decode([ClipboardItem].self, from: data)
        var state = AppState.empty
        state.schemaVersion = 1
        state.items = items
        return state
    }

    /// Moves an unreadable index aside rather than deleting it, so a user whose
    /// Keychain was merely locked can still recover the ciphertext later.
    @discardableResult
    func quarantineUnreadableIndex() -> URL? {
        let source = FileManager.default.fileExists(atPath: indexURL.path) ? indexURL : legacyBlobURL
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = directory.appendingPathComponent("\(source.lastPathComponent).unreadable-\(stamp)")
        do {
            try FileManager.default.moveItem(at: source, to: dest)
            return dest
        } catch {
            NSLog("Clipvelope quarantine error: \(error)")
            return nil
        }
    }

    // MARK: - Payloads

    func payloadURL(for id: UUID) -> URL {
        payloadsDirectory.appendingPathComponent("\(id.uuidString).cvi")
    }

    func writePayload(_ data: Data, for id: UUID) throws {
        try FileManager.default.createDirectory(at: payloadsDirectory, withIntermediateDirectories: true)
        try writeSealed(data, to: payloadURL(for: id))
    }

    func readPayload(for id: UUID) throws -> Data {
        try readSealed(at: payloadURL(for: id))
    }

    func deletePayload(for id: UUID) {
        try? FileManager.default.removeItem(at: payloadURL(for: id))
    }

    /// Drops payload files no item refers to any more -- the residue of a crash
    /// between writing a payload and saving the index, or of an item removed
    /// while writes were suspended.
    func deletePayloads(notIn ids: Set<UUID>) {
        let kept = Set(ids.map { "\($0.uuidString).cvi" })
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: payloadsDirectory, includingPropertiesForKeys: nil)) ?? []

        for url in existing where !kept.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }


    // MARK: - Whole vault

    func clear() {
        try? FileManager.default.removeItem(at: indexURL)
        try? FileManager.default.removeItem(at: payloadsDirectory)
        try? FileManager.default.removeItem(at: legacyBlobURL)
    }

    // MARK: - Sealing

    private func writeSealed(_ plaintext: Data, to url: URL) throws {
        let sealed = try AES.GCM.seal(plaintext, using: try keyStore.getOrCreateKey())
        guard let combined = sealed.combined else { throw StorageError.sealFailed }
        try combined.write(to: url, options: [.atomic])
    }

    private func readSealed(at url: URL) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: try Data(contentsOf: url))
        return try AES.GCM.open(box, using: try keyStore.getOrCreateKey())
    }
}
