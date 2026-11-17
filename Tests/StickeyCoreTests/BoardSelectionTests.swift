import XCTest
@testable import StickeyCore

final class BoardSelectionTests: XCTestCase {
    func testMarqueeSelectsIntersectingCardsInEveryDirection() {
        let first = UUID(), second = UUID(), outside = UUID()
        let frames = [first: CGRect(x: 10, y: 10, width: 30, height: 30),
                      second: CGRect(x: 60, y: 60, width: 30, height: 30),
                      outside: CGRect(x: 130, y: 130, width: 30, height: 30)]
        for (start, end) in [(CGPoint(x: 0, y: 0), CGPoint(x: 70, y: 70)),
                             (CGPoint(x: 70, y: 70), CGPoint(x: 0, y: 0)),
                             (CGPoint(x: 0, y: 70), CGPoint(x: 70, y: 0)),
                             (CGPoint(x: 70, y: 0), CGPoint(x: 0, y: 70))] {
            var selection = BoardSelection()
            selection.begin(at: start, additive: false)
            selection.update(to: end, frames: frames)
            XCTAssertEqual(selection.marquee, CGRect(x: 0, y: 0, width: 70, height: 70))
            XCTAssertEqual(selection.selectedIDs, [first, second])
            selection.end()
            XCTAssertNil(selection.marquee)
            XCTAssertEqual(selection.selectedIDs, [first, second])
        }
    }

    func testShrinkingAdditiveMarqueeKeepsOriginalSelectionOnly() {
        let original = UUID(), near = UUID(), far = UUID()
        let frames = [near: CGRect(x: 10, y: 10, width: 20, height: 20),
                      far: CGRect(x: 60, y: 60, width: 20, height: 20)]
        var selection = BoardSelection(selectedIDs: [original])
        selection.begin(at: .zero, additive: true)
        selection.update(to: CGPoint(x: 90, y: 90), frames: frames)
        XCTAssertEqual(selection.selectedIDs, [original, near, far])
        selection.update(to: CGPoint(x: 35, y: 35), frames: frames)
        XCTAssertEqual(selection.selectedIDs, [original, near])
        selection.update(to: CGPoint(x: 5, y: 5), frames: frames)
        XCTAssertEqual(selection.selectedIDs, [original])
    }

    func testReplacementDragAndCancellationRestorePreviousSelection() {
        let original = UUID(), replacement = UUID()
        var selection = BoardSelection(selectedIDs: [original])
        selection.begin(at: .zero, additive: false)
        selection.update(to: CGPoint(x: 50, y: 50), frames: [replacement: CGRect(x: 10, y: 10, width: 20, height: 20)])
        XCTAssertEqual(selection.selectedIDs, [replacement])
        selection.cancel()
        XCTAssertEqual(selection.selectedIDs, [original])
        XCTAssertNil(selection.marquee)
        selection.update(to: CGPoint(x: 100, y: 100), frames: [:])
        XCTAssertEqual(selection.selectedIDs, [original])
    }

    func testStartingInsideCardSelectsItBeforeMovement() {
        let id = UUID()
        let point = CGPoint(x: 20, y: 20)
        var selection = BoardSelection()
        selection.begin(at: point, additive: false)
        selection.update(to: point, frames: [id: CGRect(x: 10, y: 10, width: 30, height: 30)])
        XCTAssertEqual(selection.selectedIDs, [id])
    }

    func testStraightDragSelectsRowsAndColumnsWithoutDiagonalMovement() {
        let start = UUID(), below = UUID(), right = UUID()
        let frames = [start: CGRect(x: 10, y: 10, width: 30, height: 30),
                      below: CGRect(x: 10, y: 60, width: 30, height: 30),
                      right: CGRect(x: 60, y: 10, width: 30, height: 30)]
        var selection = BoardSelection()
        selection.begin(at: CGPoint(x: 20, y: 20), additive: false)
        selection.update(to: CGPoint(x: 20, y: 80), frames: frames)
        XCTAssertEqual(selection.selectedIDs, [start, below])
        selection.end()
        selection.begin(at: CGPoint(x: 20, y: 20), additive: false)
        selection.update(to: CGPoint(x: 80, y: 20), frames: frames)
        XCTAssertEqual(selection.selectedIDs, [start, right])
    }

    func testResultChangesRemoveHiddenNotesAndInvalidateOldGesture() {
        let retained = UUID(), removed = UUID()
        var selection = BoardSelection(selectedIDs: [retained, removed])
        selection.begin(at: .zero, additive: true)
        selection.retainOnly([retained])
        XCTAssertEqual(selection.selectedIDs, [retained])
        XCTAssertNil(selection.marquee)
        selection.cancel()
        selection.update(to: CGPoint(x: 100, y: 100), frames: [removed: CGRect(x: 10, y: 10, width: 20, height: 20)])
        XCTAssertEqual(selection.selectedIDs, [retained])
    }

    func testClearDuringDragCannotRestoreStaleSelection() {
        let id = UUID()
        var selection = BoardSelection(selectedIDs: [id])
        selection.begin(at: .zero, additive: true)
        selection.clear()
        selection.cancel()
        XCTAssertTrue(selection.selectedIDs.isEmpty)
        XCTAssertNil(selection.marquee)
    }
}
