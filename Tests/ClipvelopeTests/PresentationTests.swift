import XCTest
@testable import Clipvelope

final class PreviewTextTests: XCTestCase {
    func testIndentationAndBlankLinesCollapseToOneSpace() {
        let raw = "  target:\n      kind: HelmRelease\n\n\n  name: x  "
        let summary = PreviewText.summary(of: raw)
        XCTAssertEqual(summary.text, "target: kind: HelmRelease name: x")
        XCTAssertEqual(summary.lineCount, 3, "blank lines are not lines")
    }

    func testASingleLineIsUnchanged() {
        let summary = PreviewText.summary(of: "kubectl get pods -A")
        XCTAssertEqual(summary.text, "kubectl get pods -A")
        XCTAssertEqual(summary.lineCount, 1)
    }

    func testLongTextIsCutWithAnEllipsis() {
        let summary = PreviewText.summary(of: String(repeating: "a", count: 300), maxCharacters: 10)
        XCTAssertEqual(summary.text, "aaaaaaaaaa…")
    }

    func testWhitespaceOnlyTextHasNoLines() {
        let summary = PreviewText.summary(of: " \n\t\n ")
        XCTAssertEqual(summary.text, "")
        XCTAssertEqual(summary.lineCount, 0)
    }
}

final class HistorySectionTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    // 2025-09-07 15:00 UTC, so the day boundaries below are unambiguous.
    private let now = Date(timeIntervalSince1970: 1_757_257_200)

    private func item(_ text: String, age: TimeInterval, pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(id: UUID(), createdAt: now.addingTimeInterval(-age),
                      isPinned: pinned, content: .text(text), sourceBundleID: nil)
    }

    func testEachBoundaryLandsInItsOwnSection() {
        let cases: [(TimeInterval, HistorySection)] = [
            (60, .lastHour),
            (3599, .lastHour),
            (3600, .today),          // 14:00 the same day
            (14 * 3600, .today),     // 01:00 the same day
            (16 * 3600, .yesterday), // 23:00 the day before
            (30 * 3600, .yesterday), // 09:00 the day before
            (3 * 86400, .thisWeek),
            (7 * 86400 - 1, .thisWeek),
            (7 * 86400, .older),
            (400 * 86400, .older),
        ]
        for (age, expected) in cases {
            XCTAssertEqual(HistorySection.section(for: item("x", age: age), now: now, calendar: calendar),
                           expected, "age \(age)s")
        }
    }

    func testPinnedComesFirstRegardlessOfAge() {
        let old = item("old", age: 30 * 86400, pinned: true)
        let fresh = item("fresh", age: 10)
        let groups = HistorySection.grouped([fresh, old], now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.section), [.pinned, .lastHour])
        XCTAssertEqual(groups[0].items, [old])
    }

    func testEmptySectionsAreOmittedAndOrderWithinAGroupIsKept() {
        let a = item("a", age: 10)
        let b = item("b", age: 20)
        let c = item("c", age: 2 * 86400)
        let groups = HistorySection.grouped([a, b, c], now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.section), [.lastHour, .thisWeek])
        XCTAssertEqual(groups[0].items, [a, b])
    }

    func testNoItemsMeansNoGroups() {
        XCTAssertEqual(HistorySection.grouped([], now: now, calendar: calendar), [])
    }
}

final class PanelModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_757_257_200)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func item(_ text: String, age: TimeInterval = 10, pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(id: UUID(), createdAt: now.addingTimeInterval(-age),
                      isPinned: pinned, content: .text(text), sourceBundleID: nil)
    }

    func testAnEmptyOrBlankQueryShowsEverything() {
        let items = [item("a"), item("b")]
        var panel = PanelModel()
        XCTAssertEqual(panel.matches(in: items), items)
        panel.setQuery("   ")
        XCTAssertEqual(panel.matches(in: items), items)
    }

    func testSearchIsCaseInsensitiveAndMatchesAnywhere() {
        let items = [item("kubectl get pods"), item("Deploy"), item("helm upgrade")]
        var panel = PanelModel()
        panel.setQuery("GET")
        XCTAssertEqual(panel.matches(in: items).map(\.searchText), ["kubectl get pods"])
    }

    func testVisibleOrderIsPinnedFirstThenByTimeAndSelectionIndexesIt() {
        let pinnedOld = item("pinned", age: 30 * 86400, pinned: true)
        let fresh = item("fresh", age: 5)
        let earlier = item("earlier", age: 5 * 3600)
        let items = [fresh, earlier, pinnedOld]
        let panel = PanelModel()
        let visible = panel.visibleItems(in: items, now: now, calendar: calendar)
        XCTAssertEqual(visible.map(\.searchText), ["pinned", "fresh", "earlier"])
        XCTAssertEqual(panel.selectedItem(in: items, now: now, calendar: calendar)?.searchText, "pinned")
    }

    func testNoMoreThanFiftyRowsAreShown() {
        let items = (0..<80).map { item("row \($0)") }
        XCTAssertEqual(PanelModel().visibleItems(in: items, now: now, calendar: calendar).count, 50)
    }

    func testMoveClampsToTheEnds() {
        var panel = PanelModel()
        panel.move(-1, rowCount: 3)
        XCTAssertEqual(panel.selection, 0)
        panel.move(5, rowCount: 3)
        XCTAssertEqual(panel.selection, 2)
        panel.move(-1, rowCount: 3)
        XCTAssertEqual(panel.selection, 1)
    }

    func testMoveWithNoRowsResetsTheSelection() {
        var panel = PanelModel(query: "", selection: 4)
        panel.move(1, rowCount: 0)
        XCTAssertEqual(panel.selection, 0)
    }

    func testTypingResetsTheSelectionToTheTop() {
        var panel = PanelModel()
        panel.move(2, rowCount: 5)
        panel.setQuery("k")
        XCTAssertEqual(panel.selection, 0)
    }

    func testEscapeClearsTheSearchFirstAndClosesSecond() {
        var panel = PanelModel()
        panel.setQuery("abc")
        XCTAssertEqual(panel.escape(), .clearedSearch)
        XCTAssertEqual(panel.query, "")
        XCTAssertEqual(panel.escape(), .close)
    }

    func testNothingIsSelectedWhenTheSearchHasNoMatches() {
        var panel = PanelModel()
        panel.setQuery("zzz")
        XCTAssertNil(panel.selectedItem(in: [item("a")], now: now, calendar: calendar))
    }

    func testSuggestionComesFromTheNewestTextEntryWithThatPrefix() {
        let image = ClipboardItem(id: UUID(), createdAt: now, isPinned: false,
                                  content: .image(.init(pixelWidth: 1, pixelHeight: 1, byteCount: 1,
                                                        typeIdentifier: "public.png")),
                                  sourceBundleID: nil)
        let items = [image, item("Kubectl apply"), item("kubectl get")]
        var panel = PanelModel()
        XCTAssertNil(panel.suggestion(in: items), "no query, no suggestion")
        panel.setQuery("kube")
        XCTAssertEqual(panel.suggestion(in: items), "Kubectl apply")
        panel.setQuery("image")
        XCTAssertNil(panel.suggestion(in: items), "images are never suggested")
    }
}

final class StripContentTests: XCTestCase {
    private func strip(isLoading: Bool = false, savingPaused: Bool = false, saveFailed: Bool = false,
                       capturePaused: Bool = false, recordingPasswords: Bool = false, itemCount: Int = 3,
                       notice: String? = nil) -> StripContent {
        StripContent.describe(isLoading: isLoading, savingPaused: savingPaused, saveFailed: saveFailed,
                              capturePaused: capturePaused, recordingPasswords: recordingPasswords,
                              itemCount: itemCount, notice: notice)
    }

    func testAFailedSaveIsNotCalledASuspendedVault() {
        XCTAssertEqual(strip(saveFailed: true).text, "The last change could not be saved.")
        XCTAssertEqual(strip(savingPaused: true, saveFailed: true).text, "Saving paused.")
        XCTAssertTrue(strip(saveFailed: true).degraded)
    }

    func testCountsAreSentencesWithCorrectPlurals() {
        XCTAssertEqual(strip(itemCount: 0).text, "Empty vault, encrypted on this Mac.")
        XCTAssertEqual(strip(itemCount: 1).text, "1 item, encrypted on this Mac.")
        XCTAssertEqual(strip(itemCount: 42).text, "42 items, encrypted on this Mac.")
        XCTAssertFalse(strip(itemCount: 42).degraded)
    }

    func testLoadingSaysNothingAboutTheData() {
        let s = strip(isLoading: true, savingPaused: true, itemCount: 0)
        XCTAssertEqual(s.text, "Opening vault…")
        XCTAssertFalse(s.degraded)
    }

    func testPriorityIsNoticeThenSavingThenPausedStates() {
        XCTAssertEqual(strip(savingPaused: true, capturePaused: true, notice: "Removed.").text, "Removed.")
        XCTAssertEqual(strip(savingPaused: true, capturePaused: true).text, "Saving paused.")
        XCTAssertEqual(strip(capturePaused: true, recordingPasswords: true).text,
                       "Capture paused. Recording passwords.")
        XCTAssertEqual(strip(recordingPasswords: true).symbol, "exclamationmark.shield.fill")
        XCTAssertTrue(strip(recordingPasswords: true).degraded)
    }
}
