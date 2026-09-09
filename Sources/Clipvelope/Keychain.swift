import Foundation
import CryptoKit
import Security

// MARK: - Keychain

enum KeychainError: Error {
    case unhandled(OSStatus)
    case invalidData
}

/// Stores the vault's encryption key and the auto-backup password.
///
/// Two keychains exist on macOS and the difference matters here:
///
/// - The **data protection keychain** scopes items to the app's keychain access
///   group, so no other application can read them. This is the only mechanism
///   that actually restricts access. It requires a `keychain-access-groups`
///   entitlement, which requires a real signing identity.
/// - The **file keychain** is the fallback. Its trusted-application ACLs read
///   like protection but are not enforced on current macOS: a foreign binary
///   reads the item silently and is then *appended* to the ACL by the system.
///   Measured directly; see docs/SIGNING.md.
///
/// So an ad-hoc build cannot keep its key from other apps running as the same
/// user. The code prefers the data protection keychain whenever the entitlement
/// is present, and migrates an existing key into it, so signing the app is all
/// that is needed to get real protection.
final class KeychainKeyStore {
    private let service = "com.mujieha.Clipvelope"
    private let account = "clipboard-key"
    private let autoBackupPasswordAccount = "auto-backup-password"
    private let remoteControlTokenAccount = "remote-control-token"

    /// Probed once, with a write.
    ///
    /// A *read* is not a valid probe: looking up a nonexistent item returns
    /// `errSecItemNotFound` whether or not the entitlement is present. Only a
    /// write reports `errSecMissingEntitlement`. The probe item is removed
    /// immediately.
    static let usesDataProtectionKeychain: Bool = {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.mujieha.Clipvelope.entitlement-probe",
            kSecAttrAccount as String: "probe",
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: Data([0]),
        ]
        SecItemDelete(probe as CFDictionary)
        let status = SecItemAdd(probe as CFDictionary, nil)
        SecItemDelete(probe as CFDictionary)
        let available = status == errSecSuccess
        NSLog("Clipvelope: using the %@ keychain%@",
              available ? "data protection" : "file",
              available ? "" : " - the key is readable by other apps, see docs/SIGNING.md")
        return available
    }()


    // MARK: - Encryption key

    func loadKey() throws -> SymmetricKey? {
        if Self.usesDataProtectionKeychain {
            if let data = try read(account: account, dataProtection: true) {
                return SymmetricKey(data: data)
            }
            // A key written before the app was signed lives in the file keychain.
            // Move it across rather than stranding the user's history.
            if let legacy = try read(account: account, dataProtection: false) {
                // Best effort, and verified before it destroys anything. The old
                // copy is only removed once the new one has been read back and
                // matches: deleting first and discovering afterwards that the
                // write did not take would leave the vault permanently
                // unreadable.
                do {
                    try write(legacy, account: account, dataProtection: true)
                    guard try read(account: account, dataProtection: true) == legacy else {
                        throw KeychainError.invalidData
                    }
                    delete(account: account, dataProtection: false)
                    NSLog("Clipvelope: migrated the encryption key to the data protection keychain")
                } catch {
                    NSLog("Clipvelope: key migration failed, continuing with the file keychain: \(error)")
                }
                return SymmetricKey(data: legacy)
            }
            return nil
        }

        return try read(account: account, dataProtection: false).map { SymmetricKey(data: $0) }
    }

    func saveKey(_ key: SymmetricKey) throws {
        let data = key.withUnsafeBytes { Data($0) }
        try write(data, account: account, dataProtection: Self.usesDataProtectionKeychain)
    }

    func getOrCreateKey() throws -> SymmetricKey {
        if let key = try loadKey() { return key }
        let key = SymmetricKey(size: .bits256)
        try saveKey(key)
        return key
    }

    // MARK: - Auto-backup password

    func loadAutoBackupPassword() -> String? {
        let data = try? read(account: autoBackupPasswordAccount,
                             dataProtection: Self.usesDataProtectionKeychain)
        return data.flatMap { $0 }.flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    func saveAutoBackupPassword(_ password: String) -> Error? {
        do {
            try write(Data(password.utf8),
                      account: autoBackupPasswordAccount,
                      dataProtection: Self.usesDataProtectionKeychain)
            return nil
        } catch {
            NSLog("Clipvelope: could not save the auto-backup password: \(error)")
            return error
        }
    }

    // MARK: - Remote-control token

    /// See RemoteControl. Overwritten on every launch, so it never outlives the
    /// instance it authenticates by more than one restart.
    func saveRemoteControlToken(_ token: Data) throws {
        try write(token, account: remoteControlTokenAccount,
                  dataProtection: Self.usesDataProtectionKeychain)
    }

    func loadRemoteControlToken() -> Data? {
        try? read(account: remoteControlTokenAccount,
                  dataProtection: Self.usesDataProtectionKeychain)
    }

    // MARK: - Primitives

    private func baseQuery(account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func read(account: String, dataProtection: Bool) throws -> Data? {
        var query = baseQuery(account: account, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        guard let data = item as? Data else { throw KeychainError.invalidData }
        return data
    }

    private func write(_ data: Data, account: String, dataProtection: Bool) throws {
        // Update in place when the item exists. Deleting first and then failing to
        // add would destroy the previous value, and for the vault key the previous
        // value is the only way to read the history.
        let query = baseQuery(account: account, dataProtection: dataProtection)
        let updated = SecItemUpdate(query as CFDictionary,
                                    [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError.unhandled(updated) }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
    }

    private func delete(account: String, dataProtection: Bool) {
        SecItemDelete(baseQuery(account: account, dataProtection: dataProtection) as CFDictionary)
    }
}
