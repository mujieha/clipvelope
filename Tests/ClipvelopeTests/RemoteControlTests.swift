import XCTest
@testable import Clipvelope

/// The `--open` / `--preferences` channel is a distributed notification that any
/// process can post. Only the token decides whether a request is acted on.
final class RemoteControlTests: XCTestCase {
    private let token = Data((0..<32).map { UInt8($0) })

    func testARequestCarryingThisLaunchsTokenIsAuthentic() {
        XCTAssertTrue(RemoteControl.isAuthentic(
            userInfo: [RemoteControl.tokenKey: token.hexString], expected: token))
    }

    func testABareNotificationIsRefused() {
        XCTAssertFalse(RemoteControl.isAuthentic(userInfo: nil, expected: token))
        XCTAssertFalse(RemoteControl.isAuthentic(userInfo: [:], expected: token))
    }

    func testAWrongOrTruncatedTokenIsRefused() {
        var wrong = token
        wrong[5] ^= 0x01
        XCTAssertFalse(RemoteControl.isAuthentic(
            userInfo: [RemoteControl.tokenKey: wrong.hexString], expected: token))
        XCTAssertFalse(RemoteControl.isAuthentic(
            userInfo: [RemoteControl.tokenKey: token.prefix(16).hexString], expected: token))
        XCTAssertFalse(RemoteControl.isAuthentic(
            userInfo: [RemoteControl.tokenKey: "not hex"], expected: token))
    }

    /// No token means arming failed, and the answer is to accept nothing, not
    /// to accept everything.
    func testNothingIsAuthenticWhileUnarmed() {
        XCTAssertFalse(RemoteControl.isAuthentic(
            userInfo: [RemoteControl.tokenKey: token.hexString], expected: nil))
        XCTAssertFalse(RemoteControl.isAuthentic(userInfo: nil, expected: nil))
    }

    func testHexRoundTrip() {
        XCTAssertEqual(Data(hexString: token.hexString), token)
        XCTAssertNil(Data(hexString: "abc"))
        XCTAssertNil(Data(hexString: "zz"))
    }
}
