import XCTest
@testable import ShotDrop

final class PinPanelGeometryTests: XCTestCase {
    func testNegativeDisplayOriginStaysInsideInsetAndSeventyPercent() {
        let visible = CGRect(x: -1920, y: -400, width: 1920, height: 1080)
        let result = PinPanelGeometry.clamp(CGRect(x: 600, y: 700, width: 1800, height: 900), to: visible)
        XCTAssertTrue(visible.insetBy(dx: 12, dy: 12).contains(result))
        XCTAssertLessThanOrEqual(result.width, visible.width * 0.7)
        XCTAssertLessThanOrEqual(result.height, visible.height * 0.7)
    }
    func testPlacementStacksAboveExistingPin() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let first = PinPanelGeometry.placement(size: CGSize(width: 360, height: 340), visible: visible, occupied: [])
        let second = PinPanelGeometry.placement(size: first.size, visible: visible, occupied: [first])
        XCTAssertFalse(first.intersects(second))
        XCTAssertEqual(second.minY, first.maxY + 12)
    }
    func testActualSizeUsesBackingPixelsAndZoomClamps() {
        XCTAssertEqual(PinPanelGeometry.imageSize(width: 1600, height: 900, backingScale: 2, zoom: 1), CGSize(width: 800, height: 450))
        XCTAssertEqual(PinPanelGeometry.imageSize(width: 1600, height: 900, backingScale: 1, zoom: 9), CGSize(width: 6400, height: 3600))
        XCTAssertEqual(PinPanelGeometry.imageSize(width: 1600, height: 900, backingScale: 2, zoom: 0), CGSize(width: 200, height: 112.5))
    }
    func testUnrelatedDisplayRemovalAndWakePreserveReachablePlacement() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let userFrame = CGRect(x: 1200, y: 350, width: 360, height: 340)
        let first = try XCTUnwrap(PinPanelGeometry.recovery(frame: userFrame,
            visibleFrames: [screen, CGRect(x: -1440, y: 0, width: 1440, height: 900)], currentVisibleFrame: screen))
        let afterUnplug = try XCTUnwrap(PinPanelGeometry.recovery(frame: first.frame,
            visibleFrames: [screen], currentVisibleFrame: screen))
        XCTAssertEqual(first.frame, userFrame)
        XCTAssertEqual(afterUnplug.frame, userFrame, "A reachable title must not jump just because the body extends offscreen")
        XCTAssertEqual(afterUnplug.maximumSize.width, 1008, accuracy: 0.001)
        XCTAssertEqual(afterUnplug.maximumSize.height, 630, accuracy: 0.001)
    }

    func testSameScaleTransferToSmallerDisplayRefreshesCapAndKeepsTitleAnchor() throws {
        let small = CGRect(x: -1000, y: -200, width: 1000, height: 700)
        let large = CGRect(x: 0, y: 0, width: 2400, height: 1600)
        let moved = CGRect(x: -900, y: -200, width: 1200, height: 650)
        let result = try XCTUnwrap(PinPanelGeometry.recovery(frame: moved,
            visibleFrames: [small, large], currentVisibleFrame: small))
        XCTAssertEqual(result.maximumSize.width, 700, accuracy: 0.001)
        XCTAssertEqual(result.maximumSize.height, 490, accuracy: 0.001)
        XCTAssertEqual(result.frame.size, result.maximumSize)
        XCTAssertEqual(result.frame.minX, moved.minX)
        XCTAssertEqual(result.frame.maxY, moved.maxY)
    }

    func testWhollyUnreachablePinRecoversOnRemainingNegativeOriginScreen() throws {
        let screen = CGRect(x: -1800, y: -900, width: 1600, height: 900)
        let result = try XCTUnwrap(PinPanelGeometry.recovery(frame: CGRect(x: 2500, y: 200, width: 360, height: 340),
            visibleFrames: [screen], currentVisibleFrame: nil))
        XCTAssertTrue(screen.insetBy(dx: 12, dy: 12).contains(result.frame))
        XCTAssertTrue(screen.contains(PinPanelGeometry.titleControlRegion(result.frame)))
    }

    func testVisibleBodyWithHiddenTitleOrCloseControlsIsRecovered() throws {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        for frame in [CGRect(x: 100, y: 700, width: 360, height: 340),
                      CGRect(x: -120, y: 200, width: 360, height: 340)] {
            let result = try XCTUnwrap(PinPanelGeometry.recovery(frame: frame,
                visibleFrames: [screen], currentVisibleFrame: screen))
            XCTAssertNotEqual(result.frame, frame)
            XCTAssertTrue(screen.contains(PinPanelGeometry.titleControlRegion(result.frame)))
        }
    }

    func testTitleAcrossAdjacentDisplaysRemainsInPlaceButGapRequiresRecovery() throws {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let frame = CGRect(x: 940, y: 250, width: 360, height: 340)
        let adjacent = try XCTUnwrap(PinPanelGeometry.recovery(frame: frame,
            visibleFrames: [left, right], currentVisibleFrame: right))
        XCTAssertEqual(adjacent.frame, frame)
        let gap = CGRect(x: 1080, y: 0, width: 1000, height: 800)
        let separated = try XCTUnwrap(PinPanelGeometry.recovery(frame: frame,
            visibleFrames: [left, gap], currentVisibleFrame: gap))
        XCTAssertNotEqual(separated.frame, frame)
        XCTAssertTrue(gap.contains(PinPanelGeometry.titleControlRegion(separated.frame)))
    }

    func testNoScreensOrInvalidFrameCannotProduceRecoveryGeometry() {
        XCTAssertNil(PinPanelGeometry.recovery(frame: CGRect(x: 0, y: 0, width: 360, height: 340),
            visibleFrames: [], currentVisibleFrame: nil))
        XCTAssertNil(PinPanelGeometry.recovery(frame: .zero,
            visibleFrames: [CGRect(x: 0, y: 0, width: 1000, height: 800)], currentVisibleFrame: nil))
    }

}
