import Foundation
import XCTest
@testable import ShotDrop

final class RecentMenuLayoutTests: XCTestCase {
    private func layout(_ count: Int, chrome: CGFloat = 160, empty: CGFloat = 170,
                        row: CGFloat = 64, measured: CGFloat? = nil,
                        screen: CGFloat = 900) -> RecentMenuLayout {
        .measure(rowCount: count, chromeHeight: chrome, emptyHeight: empty,
                 estimatedRowHeight: row, measuredTotalRowHeight: measured, availableHeight: screen)
    }

    func testEmptyAndSingleRowFitContentWhileTwentyRowsScroll() {
        let empty = layout(0)
        XCTAssertEqual(empty.bodyHeight, 170)
        XCTAssertEqual(empty.panelHeight, 330)
        XCTAssertFalse(empty.isBodyScrollable)
        let one = layout(1)
        XCTAssertEqual(one.bodyHeight, 64)
        XCTAssertEqual(one.panelHeight, 224)
        XCTAssertFalse(one.isBodyScrollable)
        let twenty = layout(20)
        XCTAssertEqual(twenty.bodyHeight, 400)
        XCTAssertEqual(twenty.panelHeight, 560)
        XCTAssertTrue(twenty.isBodyScrollable)
    }

    func testShortScreenCapsBothEmptyCopyAndRowsAfterChrome() {
        for count in [0, 1, 20] {
            let result = layout(count, screen: 230)
            XCTAssertEqual(result.panelHeight, 198)
            XCTAssertEqual(result.bodyHeight, 38)
            XCTAssertTrue(result.isBodyScrollable)
        }
    }

    func testLongEmptyCopyAndLargerTextRemainBounded() {
        let longCopy = layout(0, empty: 800)
        XCTAssertEqual(longCopy.panelHeight, 560)
        XCTAssertEqual(longCopy.bodyHeight, 400)
        XCTAssertTrue(longCopy.isBodyScrollable)
        let largerText = layout(3, chrome: 210, row: 110)
        XCTAssertEqual(largerText.panelHeight, 540)
        XCTAssertFalse(largerText.isBodyScrollable)
        let largerChrome = layout(3, chrome: 240, row: 110)
        XCTAssertEqual(largerChrome.panelHeight, 560)
        XCTAssertTrue(largerChrome.isBodyScrollable)
    }

    func testMeasuredTotalIncludesVariableRowsAndDividersWithoutDoubleCounting() {
        let measured = layout(3, measured: 241)
        XCTAssertEqual(measured.bodyHeight, 241)
        XCTAssertEqual(measured.panelHeight, 401)
        XCTAssertFalse(measured.isBodyScrollable)
        XCTAssertEqual(layout(20, measured: 900).bodyHeight, 400)
        XCTAssertTrue(layout(20, measured: 900).isBodyScrollable)
        XCTAssertEqual(layout(0, measured: 900).bodyHeight, 170, "Empty uses its own measurement")
    }

    func testContentTransitionsGrowAndShrinkWithoutRetainingPreviousCap() {
        let heights = [0, 1, 20, 1, 0].map { layout($0).panelHeight }
        XCTAssertEqual(heights, [330, 224, 560, 224, 330])
        XCTAssertEqual(layout(2, measured: 180).panelHeight, 340)
        XCTAssertEqual(layout(2, measured: 130).panelHeight, 290)
    }

    func testTinyAndInvalidScreensNeverProduceNegativeOrNonfiniteFrames() {
        for screen in [CGFloat(0), 16, 32, -10, .nan, .infinity, -.infinity] {
            let result = layout(20, screen: screen)
            XCTAssertEqual(result.panelHeight, 0)
            XCTAssertEqual(result.bodyHeight, 0)
        }
        let tiny = layout(1, screen: 90)
        XCTAssertEqual(tiny.panelHeight, 58)
        XCTAssertEqual(tiny.bodyHeight, 0)
        XCTAssertTrue(tiny.isBodyScrollable)
    }

    func testInvalidMeasurementsUseBoundedFallbackAndRowCountIsClamped() {
        XCTAssertEqual(layout(-1), layout(0))
        XCTAssertEqual(layout(Int.max), layout(20))
        for measured in [CGFloat.nan, .infinity, -1, 0] {
            XCTAssertEqual(layout(1, measured: measured), layout(1))
        }
        XCTAssertEqual(layout(1, row: .nan), layout(1))
        XCTAssertEqual(layout(1, row: -2), layout(1))
        XCTAssertEqual(layout(1, row: .greatestFiniteMagnitude).panelHeight, 560)
        XCTAssertEqual(layout(20, measured: .greatestFiniteMagnitude).panelHeight, 560)
        XCTAssertEqual(layout(20, chrome: .nan).bodyHeight, 0)
        XCTAssertEqual(layout(0, empty: .infinity).panelHeight, 560)
        XCTAssertEqual(layout(0, empty: -20).panelHeight, 160)
    }

    func testReduceMotionMakesPanelSizeTransitionImmediate() {
        XCTAssertEqual(RecentMenuLayout.transitionDuration(reduceMotion: true), 0)
        XCTAssertEqual(RecentMenuLayout.transitionDuration(reduceMotion: false), 0.16, accuracy: 0.0001)
    }
}
