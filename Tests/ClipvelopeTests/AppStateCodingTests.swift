import XCTest
@testable import Clipvelope

/// AppState decodes field-by-field with defaults on purpose: a decode failure is
/// indistinguishable from real corruption, and corruption is handled destructively.
/// Adding or removing a field must never make an existing vault unreadable.
final class AppStateCodingTests: XCTestCase {
    private func decode(_ json: String) throws -> AppState {
        try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
    }

    func testDecodesAnEmptyObjectToDefaults() throws {
        let state = try decode("{}")
        XCTAssertEqual(state.items, [])
        XCTAssertEqual(state.themeMode, .system)
        XCTAssertEqual(state.autoBackupMode, .keychain)
        XCTAssertFalse(state.autoBackupEnabled)
    }

    func testAbsentSchemaVersionMeansVersionOne() throws {
        XCTAssertEqual(try decode("{}").schemaVersion, 1)
    }

    func testUnknownFieldsFromANewerVersionAreIgnored() throws {
        let state = try decode(#"{"schemaVersion":99,"themeMode":"dark","somethingNew":[1,2,3]}"#)
        XCTAssertEqual(state.themeMode, .dark)
        XCTAssertEqual(state.schemaVersion, 99)
    }

    func testAPartialObjectKeepsTheFieldsItHas() throws {
        let state = try decode(#"{"autoBackupEnabled":true}"#)
        XCTAssertTrue(state.autoBackupEnabled)
        XCTAssertEqual(state.items, [])
    }

    func testRoundTripsThroughJSON() throws {
        var original = AppState.empty
        original.items = [ClipboardItem(id: UUID(), text: "x", createdAt: Date(timeIntervalSince1970: 0))]
        original.bindings = [ClipboardBinding(id: UUID(), title: "t", content: "c", isShell: true)]
        original.themeMode = .light

        let decoded = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded.items, original.items)
        XCTAssertEqual(decoded.bindings, original.bindings)
        XCTAssertEqual(decoded.themeMode, .light)
    }
}
