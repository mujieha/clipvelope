import XCTest
@testable import Clipvelope

final class VaultSnapshotTests: XCTestCase {
    func testSnapshotRoundTripsWithPayloads() throws {
        var state = AppState.empty
        let id = UUID()
        state.items = [ClipboardItem(
            id: id, createdAt: Date(timeIntervalSince1970: 0), isPinned: false,
            content: .image(.init(pixelWidth: 2, pixelHeight: 2,
                                  byteCount: 3, typeIdentifier: "public.png")))]

        let original = VaultSnapshot(state: state, payloads: [id.uuidString: Data([1, 2, 3])])
        let decoded = try ClipboardStore.decodeSnapshot(try JSONEncoder().encode(original))

        XCTAssertEqual(decoded.state.items, state.items)
        XCTAssertEqual(decoded.payloads[id.uuidString], Data([1, 2, 3]))
    }

    /// Backups written before payloads existed were a bare AppState. Those must
    /// still import, or upgrading strands every existing backup file.
    func testABareAppStateBackupStillDecodes() throws {
        var state = AppState.empty
        state.items = [ClipboardItem(text: "from an old backup")]
        state.themeMode = .dark

        let decoded = try ClipboardStore.decodeSnapshot(try JSONEncoder().encode(state))

        XCTAssertEqual(decoded.state.items.map(\.searchText), ["from an old backup"])
        XCTAssertEqual(decoded.state.themeMode, .dark)
        XCTAssertTrue(decoded.payloads.isEmpty)
    }

    func testGarbageIsRejectedRatherThanDecodingToEmpty() {
        XCTAssertThrowsError(try ClipboardStore.decodeSnapshot(Data("not json".utf8)))
    }
}
