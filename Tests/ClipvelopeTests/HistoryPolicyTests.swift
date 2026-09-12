import XCTest
@testable import Clipvelope

final class HistoryPolicyTests: XCTestCase {
    private func item(_ text: String, pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(id: UUID(), createdAt: Date(), isPinned: pinned, content: .text(text))
    }

    private func texts(_ items: [ClipboardItem]) -> [String] { items.map(\.searchText) }

    // MARK: - Insertion

    func testNewTextGoesToTheTop() {
        let result = HistoryPolicy.inserting("b", into: [item("a")], maxItems: 200)
        XCTAssertEqual(texts(result), ["b", "a"])
    }

    func testRecopyingTheNewestItemOnlyRefreshesItsTime() {
        let items = [item("b"), item("a")]
        let later = Date().addingTimeInterval(120)
        let result = HistoryPolicy.inserting("b", into: items, maxItems: 10, now: later)
        XCTAssertEqual(texts(result), ["b", "a"])
        XCTAssertEqual(result.map(\.id), items.map(\.id))
        XCTAssertEqual(result[0].createdAt, later)
        XCTAssertEqual(result[1].createdAt, items[1].createdAt)
    }

    /// Copying A, B, A used to leave three entries, because dedup only ever
    /// compared against the newest one.
    func testRecopyingAnOlderItemMovesItUpRatherThanDuplicating() {
        let result = HistoryPolicy.inserting("a", into: [item("b"), item("a"), item("c")],
                                             maxItems: 200)
        XCTAssertEqual(texts(result), ["a", "b", "c"])
    }

    // MARK: - Capacity

    func testRecopyingRefreshesTheTimestampSoSectionsMatchTheOrder() {
        let old = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 2_000_000)
        var items = [ClipboardItem(id: UUID(), createdAt: old, content: .text("a")),
                     ClipboardItem(id: UUID(), createdAt: old, content: .text("b"))]
        items = HistoryPolicy.inserting("b", into: items, maxItems: 10, now: now)
        XCTAssertEqual(texts(items), ["b", "a"])
        XCTAssertEqual(items[0].createdAt, now)
        XCTAssertEqual(items.count, 2)

        // The newest entry too: copying the same thing twice is still "just now".
        items = HistoryPolicy.inserting("b", into: items, maxItems: 10,
                                        now: now.addingTimeInterval(60))
        XCTAssertEqual(items[0].createdAt, now.addingTimeInterval(60))
        XCTAssertEqual(items.count, 2)
    }

    func testTrimsToCapacityFromTheOldestEnd() {
        let items = [item("new"), item("mid"), item("old")]
        XCTAssertEqual(texts(HistoryPolicy.trimmed(items, maxItems: 2)), ["new", "mid"])
    }

    func testPinnedItemsSurviveTrimming() {
        let items = [item("new"), item("mid"), item("pinned", pinned: true)]
        let result = HistoryPolicy.trimmed(items, maxItems: 2)
        XCTAssertEqual(texts(result), ["new", "pinned"])
    }

    func testAListOfOnlyPinnedItemsIsNeverTrimmed() {
        let items = [item("a", pinned: true), item("b", pinned: true), item("c", pinned: true)]
        XCTAssertEqual(HistoryPolicy.trimmed(items, maxItems: 1), items)
    }

    func testInsertingRespectsCapacityAndPins() {
        let items = [item("x"), item("keep", pinned: true)]
        let result = HistoryPolicy.inserting("new", into: items, maxItems: 2)
        XCTAssertEqual(texts(result), ["new", "keep"])
    }

    // MARK: - Byte budget

    private func image(_ bytes: Int, pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(
            id: UUID(), createdAt: Date(), isPinned: pinned,
            content: .image(.init(pixelWidth: 10, pixelHeight: 10,
                                  byteCount: bytes, typeIdentifier: "public.png"))
        )
    }

    /// A count-based cap alone would happily hold 200 screenshots.
    func testOldestImagesAreEvictedWhenTheByteBudgetIsExceeded() {
        let items = [image(100), image(100), image(100)]
        let result = HistoryPolicy.trimmed(items, maxItems: 200, maxPayloadBytes: 250)
        XCTAssertEqual(result.count, 2)
    }

    func testTextIsNeverEvictedByTheByteBudgetAlone() {
        let items = [item("a"), item("b"), item("c")]
        XCTAssertEqual(HistoryPolicy.trimmed(items, maxItems: 200, maxPayloadBytes: 0), items)
    }

    func testPinnedImagesSurviveTheByteBudget() {
        let items = [image(100), image(100, pinned: true)]
        let result = HistoryPolicy.trimmed(items, maxItems: 200, maxPayloadBytes: 50)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].isPinned)
    }

    func testTrimmingStopsWhenOnlyPinnedItemsRemainRatherThanLooping() {
        let items = [image(100, pinned: true), image(100, pinned: true)]
        XCTAssertEqual(HistoryPolicy.trimmed(items, maxItems: 1, maxPayloadBytes: 1), items)
    }

    // MARK: - Telling two pictures apart

    private func imageContent(hash: String?) -> ClipboardContent {
        .image(.init(pixelWidth: 1920, pixelHeight: 1080, byteCount: 40_000,
                     typeIdentifier: "public.png", contentHash: hash))
    }

    private func imageItem(hash: String?, at date: Date = Date()) -> ClipboardItem {
        ClipboardItem(id: UUID(), createdAt: date, isPinned: false,
                      content: imageContent(hash: hash), sourceBundleID: nil)
    }

    /// Two screenshots of the same window share their size, type and often their
    /// compressed byte count. Before the digest, the second was discarded and the
    /// user was shown the first one's pixels under a fresh timestamp.
    func testTwoDifferentImagesWithIdenticalMetadataStayTwoEntries() {
        let first = imageItem(hash: ClipboardContent.digest(compressiblePNG(width: 4, height: 4)))
        let second = imageContent(hash: ClipboardContent.digest(compressiblePNG(width: 4, height: 5)))
        let result = HistoryPolicy.inserting(second, into: [first], maxItems: 200)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].content, second)
        XCTAssertEqual(result[1].id, first.id)
    }

    func testRecopyingTheSameImageStillDeduplicatesAndRefreshesItsTime() {
        let hash = ClipboardContent.digest(compressiblePNG(width: 4, height: 4))
        let old = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let existing = imageItem(hash: hash, at: old)
        let result = HistoryPolicy.inserting(imageContent(hash: hash), into: [existing],
                                             maxItems: 200, now: now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, existing.id)
        XCTAssertEqual(result[0].createdAt, now)
    }

    /// The old-vault fallback, and the reason for it: entries already on disk
    /// have no hash and are never given one, so without this they would each gain
    /// a duplicate the first time the user re-copied them after upgrading.
    func testAnImageFromAnOldVaultStillDeduplicatesAgainstItsRecopy() {
        let legacy = imageItem(hash: nil, at: Date(timeIntervalSince1970: 1_000))
        let now = Date(timeIntervalSince1970: 2_000_000)
        let recopied = imageContent(hash: ClipboardContent.digest(compressiblePNG(width: 4, height: 4)))
        let result = HistoryPolicy.inserting(recopied, into: [legacy], maxItems: 200, now: now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, legacy.id)
        XCTAssertEqual(result[0].createdAt, now)
    }

    func testDifferentContentKindsAreNotTreatedAsDuplicates() {
        let existing = [item("photo.png")]
        let files = ClipboardContent.files([.init(path: "/tmp/photo.png")])
        let result = HistoryPolicy.inserting(files, into: existing, maxItems: 200)
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - Display order

    func testPinnedItemsAreShownFirstWithoutLosingRecencyWithinEachGroup() {
        let items = [item("n1"), item("p1", pinned: true), item("n2"), item("p2", pinned: true)]
        XCTAssertEqual(texts(HistoryPolicy.displayOrder(items)), ["p1", "p2", "n1", "n2"])
    }

    func testDisplayOrderIsUnchangedWhenNothingIsPinned() {
        let items = [item("a"), item("b")]
        XCTAssertEqual(HistoryPolicy.displayOrder(items), items)
    }
}
