import XCTest
@testable import Clipvelope

/// Rich text and source attribution both change what an item carries, so the
/// things that must not break are decoding older items and the payload budget.
final class RichTextAndSourceTests: XCTestCase {
    private func richItem(bytes: Int = 512,
                          plain: String = "hello",
                          type: String = "public.rtf") -> ClipboardItem {
        ClipboardItem(id: UUID(), createdAt: Date(), isPinned: false,
                      content: .richText(.init(plainText: plain, byteCount: bytes,
                                               typeIdentifier: type)),
                      sourceBundleID: "com.apple.Safari")
    }

    // MARK: - Rich text

    func testRichTextSearchesOnItsPlainRendering() {
        XCTAssertEqual(richItem(plain: "the styled words").searchText, "the styled words")
    }

    /// Rich text is stored beside the index like an image, so it has to count
    /// against the payload budget or the budget silently stops meaning anything.
    func testRichTextCountsTowardsThePayloadBudget() {
        let item = richItem(bytes: 4096)
        XCTAssertEqual(item.payloadByteCount, 4096)
        XCTAssertTrue(item.hasPayloadFile)
    }

    func testPlainTextAndFilesHaveNoPayload() {
        XCTAssertEqual(ClipboardItem(text: "x").payloadByteCount, 0)
        let files = ClipboardItem(id: UUID(), createdAt: Date(), isPinned: false,
                                  content: .files([.init(path: "/tmp/a")]),
                                  sourceBundleID: nil)
        XCTAssertEqual(files.payloadByteCount, 0)
    }

    func testRichTextIsEvictedByTheByteBudgetLikeAnImage() {
        let items = [richItem(bytes: 100), richItem(bytes: 100, plain: "other")]
        let result = HistoryPolicy.trimmed(items, maxItems: 200, maxPayloadBytes: 150)
        XCTAssertEqual(result.count, 1)
    }

    func testRichTextRoundTripsThroughJSON() throws {
        let original = richItem(bytes: 77, plain: "styled", type: "public.html")
        let decoded = try JSONDecoder().decode(
            ClipboardItem.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    /// Same visible text, different formatting, is still two entries: dedup
    /// compares content, and the byte counts differ.
    func testFormattedAndPlainVersionsAreDistinctEntries() {
        let plain: [ClipboardItem] = [ClipboardItem(text: "hello")]
        let result = HistoryPolicy.inserting(
            .richText(.init(plainText: "hello", byteCount: 300, typeIdentifier: "public.rtf")),
            into: plain, maxItems: 200)
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - Source attribution

    func testInsertingRecordsTheSourceApp() {
        let result = HistoryPolicy.inserting(.text("copied"), into: [], maxItems: 200,
                                             source: "com.apple.Safari")
        XCTAssertEqual(result.first?.sourceBundleID, "com.apple.Safari")
    }

    func testSourceIsOptionalSoACopyWithNoFrontmostAppStillWorks() {
        let result = HistoryPolicy.inserting(.text("copied"), into: [], maxItems: 200)
        XCTAssertNil(result.first?.sourceBundleID)
    }

    /// Items written before attribution existed have no such key, and must keep
    /// decoding rather than routing into the corruption path.
    func testItemsSavedBeforeAttributionStillDecode() throws {
        let json = #"{"id":"\#(UUID().uuidString)","text":"older","createdAt":0}"#
        let item = try JSONDecoder().decode(ClipboardItem.self, from: Data(json.utf8))
        XCTAssertNil(item.sourceBundleID)
        XCTAssertEqual(item.content, .text("older"))
    }

    func testSourceSurvivesAJSONRoundTrip() throws {
        let decoded = try JSONDecoder().decode(
            ClipboardItem.self, from: JSONEncoder().encode(richItem()))
        XCTAssertEqual(decoded.sourceBundleID, "com.apple.Safari")
    }
}
