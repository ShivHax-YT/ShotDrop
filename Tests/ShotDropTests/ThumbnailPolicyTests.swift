import CoreGraphics
import XCTest
@testable import ShotDrop

final class ThumbnailPolicyTests: XCTestCase {
    func testPlacementUsesNegativeOriginAndShrinksInsideSmallVisibleFrame() {
        let secondary = CGRect(x: -1920, y: -200, width: 1440, height: 900)
        XCTAssertEqual(ThumbnailPolicy.frame(in: secondary), CGRect(x: -748, y: -188, width: 256, height: 166))
        let tiny = CGRect(x: -300, y: 50, width: 180, height: 120)
        let card = ThumbnailPolicy.frame(in: tiny)
        XCTAssertGreaterThanOrEqual(card.minX, tiny.minX + 12)
        XCTAssertLessThanOrEqual(card.maxX, tiny.maxX - 12)
        XCTAssertGreaterThanOrEqual(card.minY, tiny.minY + 12)
        XCTAssertLessThanOrEqual(card.maxY, tiny.maxY - 12)
        XCTAssertEqual(card.width / card.height, 256.0 / 166.0, accuracy: 0.001)
    }

    func testSwipeRequiresTrailingHorizontalIntentAndDistanceOrVelocity() {
        XCTAssertTrue(ThumbnailPolicy.shouldDismissSwipe(translation: CGSize(width: 80, height: 2), velocity: .zero))
        XCTAssertTrue(ThumbnailPolicy.shouldDismissSwipe(translation: CGSize(width: 24, height: 2), velocity: CGSize(width: 600, height: 0)))
        XCTAssertFalse(ThumbnailPolicy.shouldDismissSwipe(translation: CGSize(width: 23, height: 0), velocity: CGSize(width: 900, height: 0)))
        XCTAssertFalse(ThumbnailPolicy.shouldDismissSwipe(translation: CGSize(width: 81, height: 90), velocity: .zero))
        XCTAssertFalse(ThumbnailPolicy.shouldDismissSwipe(translation: CGSize(width: -100, height: 0), velocity: CGSize(width: -1000, height: 0)))
    }

    func testBurstKeepsNewestPendingUntilLockedDragEnds() {
        let captures = (0..<3).map { index in
            ThumbnailCapture(id: UUID(), finalURL: URL(fileURLWithPath: "/tmp/\(index).png"), copyFailed: false)
        }
        var queue = ThumbnailQueue()
        queue.receive(captures[0])
        queue.lock(id: captures[0].id)
        queue.receive(captures[1])
        queue.receive(captures[2])
        XCTAssertEqual(queue.visible, captures[0])
        XCTAssertEqual(queue.pending, captures[2])
        queue.unlock(id: captures[0].id)
        XCTAssertEqual(queue.visible, captures[2])
        XCTAssertNil(queue.pending)
        queue.dismiss(id: captures[0].id)
        XCTAssertEqual(queue.visible, captures[2], "A stale callback cannot dismiss the replacement")
    }
}
