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
