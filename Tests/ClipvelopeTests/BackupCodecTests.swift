import XCTest
import CryptoKit
@testable import Clipvelope

final class BackupCodecTests: XCTestCase {
    private let plaintext = Data(#"{"items":[]}"#.utf8)
    private let key = SymmetricKey(data: Data(repeating: 9, count: 32))

    // The cheapest count the codec will accept. Keeps the suite quick while
    // staying on the supported path; the 600k default is exercised separately.
    private let fastIterations = BackupCodec.minimumIterations

    // MARK: - Round trips

    func testPasswordRoundTrip() throws {
        let file = try BackupCodec.seal(plaintext, password: "hunter2", iterations: fastIterations)
        XCTAssertEqual(try BackupCodec.open(file, password: "hunter2"), plaintext)
    }

    func testKeychainRoundTrip() throws {
        let file = try BackupCodec.seal(plaintext, keychainKey: key)
        XCTAssertEqual(try BackupCodec.open(file, keychainKey: key), plaintext)
    }

    func testDefaultIterationCountRoundTrips() throws {
        let file = try BackupCodec.seal(plaintext, password: "hunter2")
        XCTAssertEqual(try BackupCodec.open(file, password: "hunter2"), plaintext)
    }

    // MARK: - Rejections

    func testWrongPasswordFails() throws {
        let file = try BackupCodec.seal(plaintext, password: "right", iterations: fastIterations)
        XCTAssertThrowsError(try BackupCodec.open(file, password: "wrong"))
    }

    func testTamperingIsDetected() throws {
        var file = try BackupCodec.seal(plaintext, password: "hunter2", iterations: fastIterations)
        file[file.count - 1] ^= 0xFF
        XCTAssertThrowsError(try BackupCodec.open(file, password: "hunter2"))
    }

    func testOpeningAKeychainFileWithAPasswordReportsTheWrongMode() throws {
        let file = try BackupCodec.seal(plaintext, keychainKey: key)
        XCTAssertThrowsError(try BackupCodec.open(file, password: "hunter2")) { error in
            XCTAssertEqual(error as? BackupCodec.CodecError, .wrongMode)
        }
    }

    func testOpeningAPasswordFileWithTheKeychainKeyReportsTheWrongMode() throws {
        let file = try BackupCodec.seal(plaintext, password: "hunter2", iterations: fastIterations)
        XCTAssertThrowsError(try BackupCodec.open(file, keychainKey: key)) { error in
            XCTAssertEqual(error as? BackupCodec.CodecError, .wrongMode)
        }
    }

    // MARK: - Format evolution

    func testIterationCountIsReadBackFromTheFile() throws {
        // A file written with a cost other than the current default must still
        // open: the count travels with the file rather than being assumed, which
        // is what lets the default be raised later.
        let raised = BackupCodec.defaultIterations + 1_000
        let file = try BackupCodec.seal(plaintext, password: "pw", iterations: raised)
        XCTAssertEqual(try BackupCodec.open(file, password: "pw"), plaintext)
    }

    func testDerivationIsSaltDependent() throws {
        let a = try BackupCodec.deriveKey(password: "pw", salt: Data(repeating: 1, count: 16), iterations: fastIterations)
        let b = try BackupCodec.deriveKey(password: "pw", salt: Data(repeating: 2, count: 16), iterations: fastIterations)
        XCTAssertNotEqual(a.withUnsafeBytes { Data($0) }, b.withUnsafeBytes { Data($0) })
    }

    func testTwoBackupsOfTheSameDataDifferBecauseTheSaltIsRandom() throws {
        let a = try BackupCodec.seal(plaintext, password: "pw", iterations: fastIterations)
        let b = try BackupCodec.seal(plaintext, password: "pw", iterations: fastIterations)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Legacy files must still open

    func testLegacyKeychainFileWithNoHeaderStillOpens() throws {
        // Original format: the file was just the sealed box.
        let legacy = try XCTUnwrap(AES.GCM.seal(plaintext, using: key).combined)
        XCTAssertEqual(try BackupCodec.open(legacy, keychainKey: key), plaintext)
    }

    func testLegacyPasswordFileWithTheOldWeakDerivationStillOpens() throws {
        // Original format: salt || sealed box, key = SHA256(salt || password).
        let salt = Data(repeating: 3, count: 16)
        var seed = Data()
        seed.append(salt)
        seed.append(Data("hunter2".utf8))
        let legacyKey = SymmetricKey(data: Data(SHA256.hash(data: seed)))

        var legacy = salt
        legacy.append(try XCTUnwrap(AES.GCM.seal(plaintext, using: legacyKey).combined))

        XCTAssertEqual(try BackupCodec.open(legacy, password: "hunter2"), plaintext)
    }
}
