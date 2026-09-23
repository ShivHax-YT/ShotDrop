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
}
