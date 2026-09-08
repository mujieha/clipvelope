import Foundation
import CryptoKit
import CommonCrypto

// MARK: - Backup Format

/// Reads and writes `.cvb` backup files.
///
/// Two things were wrong with the original format. It had no header, so the
/// layout could never change without breaking existing files; and password
/// backups derived their key with a single unsalted-iteration SHA-256, which a
/// GPU can brute-force at enormous rates. Both are fixed here, and both legacy
/// layouts are still readable so existing backups are not stranded.
enum BackupCodec {
    static let magic = Data("CVB1".utf8)
    static let defaultIterations: UInt32 = 600_000
    /// Files carry their own iteration count so the cost can be raised later.
    /// That number is attacker-controlled for a file the user did not write, so
    /// it needs a floor: a backup claiming 1 iteration must not be honoured.
    static let minimumIterations: UInt32 = 100_000
    private static let saltLength = 16
    private static let pbkdf2SHA256: UInt8 = 1

    enum Mode: UInt8 {
        case keychain = 0
        case password = 1
    }

    enum CodecError: LocalizedError, Equatable {
        case malformed
        case unsupportedKDF(UInt8)
        case wrongMode
        case weakKDF(UInt32)

        var errorDescription: String? {
            switch self {
            case .malformed: return "The backup file is not readable."
            case .unsupportedKDF(let id): return "Unsupported key derivation (id \(id))."
            case .wrongMode: return "This backup was not saved in that mode."
            case .weakKDF(let rounds):
                return "This backup asks for only \(rounds) key-derivation rounds, "
                    + "far below the \(minimumIterations) required. Refusing to open it."
            }
        }
    }

    // MARK: Key derivation

    static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { out -> Int32 in
            salt.withUnsafeBytes { saltBytes -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password, password.utf8.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                    out.bindMemory(to: UInt8.self).baseAddress, 32
                )
            }
        }
        guard status == kCCSuccess else { throw CodecError.malformed }
        return SymmetricKey(data: derived)
    }

    /// The original scheme, kept only so old backups can still be opened.
    private static func legacyDeriveKey(password: String, salt: Data) -> SymmetricKey {
        var data = Data()
        data.append(salt)
        data.append(Data(password.utf8))
        return SymmetricKey(data: Data(SHA256.hash(data: data)))
    }

    // MARK: Writing

    static func seal(_ plaintext: Data, keychainKey: SymmetricKey) throws -> Data {
        var header = magic
        header.append(Mode.keychain.rawValue)
        return header + (try sealed(plaintext, using: keychainKey, authenticating: header))
    }

    static func seal(_ plaintext: Data,
                     password: String,
                     iterations: UInt32 = defaultIterations) throws -> Data {
        let salt = Data((0..<saltLength).map { _ in UInt8.random(in: 0...255) })
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)

        // The header sits outside the sealed box, so it is authenticated as
        // associated data. Otherwise the KDF parameters the reader obeys could
        // be edited without invalidating the ciphertext.
        var header = magic
        header.append(Mode.password.rawValue)
        header.append(pbkdf2SHA256)
        header.append(contentsOf: withUnsafeBytes(of: iterations.bigEndian, Array.init))
        header.append(salt)

        return header + (try sealed(plaintext, using: key, authenticating: header))
    }

    private static func sealed(_ plaintext: Data,
                               using key: SymmetricKey,
                               authenticating header: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: header)
        guard let combined = box.combined else { throw StorageError.sealFailed }
        return combined
    }

    // MARK: Reading

    /// True for a backup written before the CVB1 header existed. Those used a
    /// single unsalted-iteration SHA-256 to derive the password key, so a file
    /// that opens this way is far weaker than the user is likely to assume.
    static func isLegacyFormat(_ file: Data) -> Bool {
        header(of: file) == nil
    }

    static func open(_ file: Data, keychainKey: SymmetricKey) throws -> Data {
        guard let (mode, body) = header(of: file) else {
            // Legacy keychain export: the whole file is the sealed box.
            return try decrypt(file, using: keychainKey, authenticating: nil)
        }
        guard mode == .keychain else { throw CodecError.wrongMode }
        return try decrypt(body, using: keychainKey,
                           authenticating: Data(file.prefix(magic.count + 1)))
    }

    static func open(_ file: Data, password: String) throws -> Data {
        guard let (mode, body) = header(of: file) else {
            // Legacy password export: salt || sealed box, weak SHA-256 derivation.
            guard file.count > saltLength else { throw CodecError.malformed }
            let salt = Data(file.prefix(saltLength))
            let key = legacyDeriveKey(password: password, salt: salt)
            return try decrypt(Data(file.dropFirst(saltLength)), using: key,
                               authenticating: nil)
        }
        guard mode == .password else { throw CodecError.wrongMode }
        guard body.count > 1 + 4 + saltLength else { throw CodecError.malformed }

        let kdfID = body[body.startIndex]
        guard kdfID == pbkdf2SHA256 else { throw CodecError.unsupportedKDF(kdfID) }

        var rest = body.dropFirst()
        let iterations = UInt32(bigEndian: Data(rest.prefix(4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        rest = rest.dropFirst(4)
        let salt = Data(rest.prefix(saltLength))
        let ciphertext = Data(rest.dropFirst(saltLength))

        guard iterations >= minimumIterations else { throw CodecError.weakKDF(iterations) }

        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let headerLength = magic.count + 1 + 1 + 4 + saltLength
        return try decrypt(ciphertext, using: key,
                           authenticating: Data(file.prefix(headerLength)))
    }

    private static func header(of file: Data) -> (Mode, Data)? {
        guard file.count > magic.count,
              file.prefix(magic.count) == magic,
              let mode = Mode(rawValue: file[file.index(file.startIndex, offsetBy: magic.count)])
        else { return nil }
        return (mode, Data(file.dropFirst(magic.count + 1)))
    }

    private static func decrypt(_ ciphertext: Data,
                                using key: SymmetricKey,
                                authenticating header: Data?) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        if let header {
            return try AES.GCM.open(box, using: key, authenticating: header)
        }
        return try AES.GCM.open(box, using: key)
    }
}
