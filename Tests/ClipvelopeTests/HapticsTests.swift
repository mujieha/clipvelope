import XCTest
import AppKit
@testable import Clipvelope

/// The trackpad tap produces nothing a test can observe -- no return value, no
/// state, and on a machine without a Force Touch trackpad no effect at all. So
/// what is checked here is the one thing that can be got wrong silently: which
/// pattern each action asks for. Feeling it is still the only way to judge
/// whether it is *right*; these only catch it changing by accident.
final class HapticsTests: XCTestCase {
    private final class Recorder: HapticFeedbackPerforming {
        var patterns: [NSHapticFeedbackManager.FeedbackPattern] = []
        func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
            patterns.append(pattern)
        }
    }

    private var recorder: Recorder!
    private var original: HapticFeedbackPerforming!

    override func setUp() {
        super.setUp()
        original = Haptics.performer
        recorder = Recorder()
        Haptics.performer = recorder
    }

    override func tearDown() {
        // Put the real one back, or every later test in this process would tap
        // the machine running the suite.
        Haptics.performer = original
        recorder = nil
        super.tearDown()
    }

    // levelChange is the pattern for moving between discrete states, which is
    // what pinning does. Reaching for generic here would still compile and
    // still vibrate, just wrongly.
    func testPinningAsksForALevelChange() {
        Haptics.rowPinned()
        XCTAssertEqual(recorder.patterns, [.levelChange])
    }

    // Deleting is neither an alignment nor a step on a scale, so generic is the
    // honest choice rather than a fallback.
    func testDeletingAsksForAGenericTap() {
        Haptics.rowDeleted()
        XCTAssertEqual(recorder.patterns, [.generic])
    }

    // One action, one tap. A repeated or doubled call is the kind of thing that
    // is inaudible in code review and unmistakable in the hand.
    func testEachActionTapsExactlyOnce() {
        Haptics.rowPinned()
        Haptics.rowDeleted()
        XCTAssertEqual(recorder.patterns, [.levelChange, .generic])
    }

    // The two actions must stay distinguishable. If they ever collapse onto one
    // pattern, the feedback stops carrying information and becomes noise.
    func testPinningAndDeletingDoNotFeelTheSame() {
        Haptics.rowPinned()
        Haptics.rowDeleted()
        XCTAssertNotEqual(recorder.patterns.first, recorder.patterns.last)
    }

    // The shipped performer must be the real one: a test that left its recorder
    // installed would silently disable the feature for everything after it.
    func testTheDefaultPerformerIsTheSystemOne() {
        XCTAssertTrue(original is SystemHaptics)
    }
}
