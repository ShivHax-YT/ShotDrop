import AppKit
import XCTest
@testable import ShotDrop

@MainActor
final class PinPanelPresentationTests: XCTestCase {
    func testPassiveDecodeCompletionOnlyOrdersFrontWithoutRequestingKey() {
        let panel = PinPresentationSpy()
        PinPanelPresentation.present(panel, intent: .passiveLoad)
        XCTAssertEqual(panel.calls, [.orderFront])
    }

    func testExplicitShowRequestsKeyOnTheSameRetainedPanel() {
        let panel = PinPresentationSpy()
        PinPanelPresentation.present(panel, intent: .passiveLoad)
        PinPanelPresentation.present(panel, intent: .explicitShow)
        PinPanelPresentation.present(panel, intent: .explicitShow)
        XCTAssertEqual(panel.calls, [.orderFront, .makeKeyAndOrderFront, .makeKeyAndOrderFront])
    }
}

/// Exercises the exact presentation helper used by passive load and coordinator Show,
/// without constructing, displaying, or activating a native window.
@MainActor
private final class PinPresentationSpy: PinPanelPresentationTarget {
    enum Call { case orderFront, makeKeyAndOrderFront }
    var calls: [Call] = []
    func orderFront(_ sender: Any?) { calls.append(.orderFront) }
    func makeKeyAndOrderFront(_ sender: Any?) { calls.append(.makeKeyAndOrderFront) }
}
