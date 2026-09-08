import XCTest
@testable import Clipvelope

final class ClipboardItemCodingTests: XCTestCase {
    private func decode(_ json: String) throws -> ClipboardItem {
        try JSONDecoder().decode(ClipboardItem.self, from: Data(json.utf8))
    }

    /// Schema 3 and earlier stored the text under a bare `text` key. Those items
    /// must keep decoding: the alternative is a decode failure, which the storage
    /// layer cannot distinguish from corruption.
    func testLegacyTextKeyBecomesTextContent() throws {
        let item = try decode(#"{"id":"\#(UUID().uuidString)","text":"hello","createdAt":0}"#)
        XCTAssertEqual(item.content, .text("hello"))
        XCTAssertFalse(item.isPinned)
    }

    func testLegacyItemsKeepTheirPinnedFlag() throws {
        let item = try decode(#"{"id":"\#(UUID().uuidString)","text":"x","createdAt":0,"isPinned":true}"#)
        XCTAssertTrue(item.isPinned)
    }

    func testTextItemRoundTrips() throws {
        let original = ClipboardItem(text: "round trip", isPinned: true)
        let decoded = try JSONDecoder().decode(
            ClipboardItem.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testImageItemRoundTrips() throws {
        let original = ClipboardItem(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 0), isPinned: false,
            content: .image(.init(pixelWidth: 800, pixelHeight: 600,
                                  byteCount: 12_345, typeIdentifier: "public.png"))
        )
        let decoded = try JSONDecoder().decode(
            ClipboardItem.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testFilesItemRoundTrips() throws {
        let original = ClipboardItem(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 0), isPinned: false,
            content: .files([.init(path: "/tmp/a.txt")])
        )
        let decoded = try JSONDecoder().decode(
            ClipboardItem.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Derived values

    func testSearchTextForEachKind() {
        XCTAssertEqual(ClipboardItem(text: "plain").searchText, "plain")

        let image = ClipboardItem(id: UUID(), createdAt: Date(), isPinned: false,
                                  content: .image(.init(pixelWidth: 4, pixelHeight: 3,
                                                        byteCount: 1, typeIdentifier: "public.png")))
        XCTAssertEqual(image.searchText, "Image 4×3")

        let files = ClipboardItem(id: UUID(), createdAt: Date(), isPinned: false,
                                  content: .files([.init(path: "/a/b.txt"),
                                                   .init(path: "/a/c.txt")]))
        XCTAssertEqual(files.searchText, "b.txt, c.txt")
    }

    func testOnlyImagesCostPayloadBytes() {
        XCTAssertEqual(ClipboardItem(text: "x").payloadByteCount, 0)
        XCTAssertFalse(ClipboardItem(text: "x").hasPayloadFile)

        let image = ClipboardItem(id: UUID(), createdAt: Date(), isPinned: false,
                                  content: .image(.init(pixelWidth: 1, pixelHeight: 1,
                                                        byteCount: 999, typeIdentifier: "public.png")))
        XCTAssertEqual(image.payloadByteCount, 999)
        XCTAssertTrue(image.hasPayloadFile)
    }
}
