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

    // MARK: - What `--open` presses
    //
    // An authentic --open ends at PanelOpener, which presses the menu bar item.
    // Whether that item can be found is not testable here -- it needs a running
    // SwiftUI app -- but what the app *says* about it is, and saying it wrongly
    // is the failure this is guarding against.

    /// In a process that never starts the UI -- this test runner, and `--status`
    /// -- the honest answer is that nobody looked, not that the item is gone.
    func testAProcessWithNoRunningUISaysNobodyLooked() {
        XCTAssertEqual(PanelOpener.availability, .notChecked)
    }

    /// Two different situations must never read the same in `--status`.
    func testEachMenuBarItemAnswerReadsDifferently() {
        let answers: [PanelOpener.Availability] = [.found, .missing, .notChecked]
        let summaries = answers.map(\.summary)
        XCTAssertEqual(Set(summaries).count, answers.count)
        XCTAssertFalse(summaries.contains { $0.isEmpty })
    }

    /// Only the case where the item was actually pressable may read as found;
    /// the other two must not let a skimming eye take them for it.
    func testOnlyAFoundItemReadsAsFound() {
        XCTAssertEqual(PanelOpener.Availability.found.summary, "found")
        XCTAssertFalse(PanelOpener.Availability.missing.summary.contains("found"))
        XCTAssertFalse(PanelOpener.Availability.notChecked.summary.contains("found"))
        XCTAssertTrue(PanelOpener.Availability.missing.summary.hasPrefix("NOT FOUND"))
    }

    // MARK: - Who counts as another instance
    //
    // `--open` and the single-instance guard ask the same question of the same
    // list, and the list always contains the process doing the asking. Counting
    // itself would make `--open` claim an instance that is not there and make
    // every launch quit on the spot.

    func testAProcessDoesNotCountItselfAsAnotherInstance() {
        XCTAssertEqual(SingleInstance.others(in: [4242], excluding: 4242), [])
        XCTAssertEqual(SingleInstance.others(in: [], excluding: 4242), [])
    }

    func testEveryOtherProcessInTheSessionCounts() {
        XCTAssertEqual(SingleInstance.others(in: [17, 4242, 31], excluding: 4242), [17, 31])
        XCTAssertEqual(SingleInstance.others(in: [17], excluding: 4242), [17])
    }
}
