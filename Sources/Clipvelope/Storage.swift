import Foundation
import CryptoKit

enum StorageError: LocalizedError {
    case sealFailed
    /// A vault sealed by a build from before files carried their role.
    case preReleaseVault

    var errorDescription: String? {
        switch self {
        case .sealFailed:
            return "The vault could not be encrypted."
        case .preReleaseVault:
            return "This vault was written by a pre-release version of Clipvelope and "
                + "cannot be opened by this one. Choose Start Fresh to begin a new vault; "
                + "the old one is kept alongside it and is not deleted."
        }
    }
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
        try writeSealed(try JSONEncoder().encode(state), to: indexURL, role: Self.indexRole)
    }

    func load() -> LoadOutcome {
        if FileManager.default.fileExists(atPath: indexURL.path) {
            do {
                return .loaded(try decodeState(try readSealed(at: indexURL, role: Self.indexRole)))
            } catch {
                return isPreRelease(indexURL) ? .unreadable(StorageError.preReleaseVault)
                                              : .unreadable(error)
            }
        }
        // The pre-schema-4 blob predates roles by definition, so its mere
        // existence is the answer; there is nothing to probe.
        if FileManager.default.fileExists(atPath: legacyBlobURL.path) {
            return .unreadable(StorageError.preReleaseVault)
        }
        return .fresh
    }

    /// Whether a file opens under the vault key with no role, which is what a
    /// build from before 1.0 wrote.
    ///
    /// It is recognised only so the app can say precisely what is wrong. The
    /// plaintext is deliberately **never decoded or applied**, and this is the
    /// single most important line in the file. Those builds sealed clipboard
    /// payloads with no role either, and a payload's plaintext is chosen by
    /// whoever writes the pasteboard: rich-text capture stores `public.html`
    /// bytes verbatim, so any process could have had bytes of its choosing
    /// sealed under this key. Parsing an unbound file here would let one of
    /// those be copied over `index.cvi` and applied as vault state through the
    /// load path, which does no disarming at all -- arming shell Quick Slots
    /// and switching password-skipping off, permanently.
    private func isPreRelease(_ url: URL) -> Bool {
        (try? readSealed(at: url, role: nil)) != nil
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

    /// Moves an unreadable vault aside rather than deleting it, so a user whose
    /// Keychain was merely locked can still recover the ciphertext later.
    ///
    /// The payload files go with it. The index holds metadata and inline text
    /// and not one byte of any image or formatted-text entry, so leaving
    /// `items/` behind means the next launch's orphan sweep deletes every one of
    /// them -- moments after the app promised the vault had been kept.
    @discardableResult
    func quarantineUnreadableVault() -> URL? {
        let source = FileManager.default.fileExists(atPath: indexURL.path) ? indexURL : legacyBlobURL
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = directory.appendingPathComponent("\(source.lastPathComponent).unreadable-\(stamp)")
        do {
            try FileManager.default.moveItem(at: source, to: dest)
        } catch {
            NSLog("%@", "Clipvelope quarantine error: \(error)")
            return nil
        }
        if FileManager.default.fileExists(atPath: payloadsDirectory.path) {
            let payloads = directory.appendingPathComponent("items.unreadable-\(stamp)")
            do {
                try FileManager.default.moveItem(at: payloadsDirectory, to: payloads)
            } catch {
                NSLog("%@", "Clipvelope: kept the index but could not move its payloads aside: \(error)")
            }
        }
        return dest
    }

    // MARK: - Payloads

    func payloadURL(for id: UUID) -> URL {
        payloadsDirectory.appendingPathComponent("\(id.uuidString).cvi")
    }

    func writePayload(_ data: Data, for id: UUID) throws {
        try FileManager.default.createDirectory(at: payloadsDirectory, withIntermediateDirectories: true)
        try writeSealed(data, to: payloadURL(for: id), role: Self.payloadRole(for: id))
    }

    func readPayload(for id: UUID) throws -> Data {
        try readSealed(at: payloadURL(for: id), role: Self.payloadRole(for: id))
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

    /// Every file is sealed under the one key, so the key alone cannot tell an
    /// index from a payload: without more, a payload copied over `index.cvi`
    /// would load as state, and `index.cvi` copied over a payload would be
    /// decrypted and put on the pasteboard as if it were an image. The role is
    /// authenticated as GCM associated data, so a box opens only in the role it
    /// was written for -- and a payload only as the payload of its own item.
    static let indexRole = Data("clipvelope/index/v1".utf8)

    static func payloadRole(for id: UUID) -> Data {
        Data("clipvelope/payload/v1/\(id.uuidString)".utf8)
    }


    private func writeSealed(_ plaintext: Data, to url: URL, role: Data) throws {
        let sealed = try AES.GCM.seal(plaintext, using: try keyStore.getOrCreateKey(),
                                      authenticating: role)
        guard let combined = sealed.combined else { throw StorageError.sealFailed }
        try combined.write(to: url, options: [.atomic])
    }

    /// `role: nil` opens a file written before roles existed. Only
    /// `isPreRelease` passes it, and it discards the plaintext.
    private func readSealed(at url: URL, role: Data?) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: try Data(contentsOf: url))
        let key = try keyStore.getOrCreateKey()
        if let role {
            return try AES.GCM.open(box, using: key, authenticating: role)
        }
        return try AES.GCM.open(box, using: key)
    }
}
