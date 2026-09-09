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

    // MARK: - Headerless files are refused

    /// A headerless "keychain backup" is byte-for-byte a vault file sealed with
    /// no role. Accepting it would let a payload -- whose bytes any app can
    /// choose by copying them -- pass as a device-bound backup.
    func testAHeaderlessFileIsRefusedInKeychainMode() throws {
        let headerless = try XCTUnwrap(AES.GCM.seal(plaintext, using: key).combined)
        XCTAssertThrowsError(try BackupCodec.open(headerless, keychainKey: key)) { error in
            XCTAssertEqual(error as? BackupCodec.CodecError, .malformed)
        }
    }

    func testAHeaderlessFileIsRefusedInPasswordMode() throws {
        var headerless = Data(repeating: 3, count: 16)
        headerless.append(try XCTUnwrap(AES.GCM.seal(plaintext, using: key).combined))
        XCTAssertThrowsError(try BackupCodec.open(headerless, password: "hunter2")) { error in
            XCTAssertEqual(error as? BackupCodec.CodecError, .malformed)
        }
    }

    // MARK: - The file does not get to choose the derivation cost

    func testABackupDemandingTooManyRoundsIsRefusedBeforeDeriving() throws {
        // Written cheaply, then the header's iteration count is overwritten with
        // the maximum -- which is what a hostile file is: a header that says
        // whatever it likes. The check has to fire before the KDF runs.
        var file = try BackupCodec.seal(plaintext, password: "pw", iterations: fastIterations)
        let iterationOffset = BackupCodec.magic.count + 1 + 1
        file.replaceSubrange(iterationOffset..<iterationOffset + 4, with: [0xFF, 0xFF, 0xFF, 0xFF])

        let started = Date()
        XCTAssertThrowsError(try BackupCodec.open(file, password: "pw")) { error in
            XCTAssertEqual(error as? BackupCodec.CodecError, .excessiveKDF(.max))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1,
                          "the refusal must come from the header, not from running the KDF")
    }

    func testTheCeilingIsWellAboveTheDefault() {
        XCTAssertGreaterThanOrEqual(BackupCodec.maximumIterations, BackupCodec.defaultIterations * 4,
                                    "the default must be able to rise without stranding files")
    }
}
