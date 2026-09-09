import Foundation
import CryptoKit
import CommonCrypto

// MARK: - Backup Format

/// Reads and writes `.cvb` backup files.
///
/// Every file starts with the `CVB1` header, which is authenticated as GCM
/// associated data, so neither the mode byte nor the KDF parameters can be
/// edited without invalidating the ciphertext. A file without the header is
/// refused: pre-release builds wrote headerless files, and a headerless
/// keychain backup is byte-for-byte the same thing as a vault file, which is
/// exactly the confusion the header exists to prevent.
enum BackupCodec {
    static let magic = Data("CVB1".utf8)
    static let defaultIterations: UInt32 = 600_000
    /// Files carry their own iteration count so the cost can be raised later.
    /// That number is attacker-controlled for a file the user did not write, so
    /// it is bounded both ways: a backup claiming 1 round must not be honoured,
    /// and one claiming four billion must not be allowed to peg a core for
    /// hours -- on the vault's serial I/O queue -- before its password is even
    /// checked.
    static let minimumIterations: UInt32 = 100_000
    static let maximumIterations: UInt32 = 10_000_000
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
        case excessiveKDF(UInt32)

        var errorDescription: String? {
            switch self {
            case .malformed: return "The backup file is not readable."
            case .unsupportedKDF(let id): return "Unsupported key derivation (id \(id))."
            case .wrongMode: return "This backup was not saved in that mode."
            case .weakKDF(let rounds):
                return "This backup asks for only \(rounds) key-derivation rounds, "
                    + "far below the \(minimumIterations) required. Refusing to open it."
            case .excessiveKDF(let rounds):
                return "This backup asks for \(rounds) key-derivation rounds, "
                    + "above the \(maximumIterations) this app will perform. Refusing to open it."
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

    /// True for a file written before the CVB1 header existed. Those can no
    /// longer be opened; recognising them exists only to say exactly that
    /// instead of blaming the password.
    static func isPreReleaseFormat(_ file: Data) -> Bool {
        header(of: file) == nil
    }

    static func open(_ file: Data, keychainKey: SymmetricKey) throws -> Data {
        guard let (mode, body) = header(of: file) else { throw CodecError.malformed }
        guard mode == .keychain else { throw CodecError.wrongMode }
        return try decrypt(body, using: keychainKey,
                           authenticating: Data(file.prefix(magic.count + 1)))
    }

    static func open(_ file: Data, password: String) throws -> Data {
        guard let (mode, body) = header(of: file) else { throw CodecError.malformed }
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
        guard iterations <= maximumIterations else { throw CodecError.excessiveKDF(iterations) }

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
                                authenticating header: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key, authenticating: header)
    }
}
