import AppKit
import XCTest
@testable import ShotDrop

@MainActor
final class PinManagerWindowTests: XCTestCase {
    func testUnchangedItemsPreserveViewAndFocusedControl() throws {
        let manager = PinManagerWindow()
        let id = UUID()
        let items = [PinScreenshotCoordinator.Item(id: id, filename: "Screenshot.png")]
        manager.update(items)
        let window = manager.prepareWindow()
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let close = try button(in: content, title: "Close", id: id)
        XCTAssertTrue(window.makeFirstResponder(close))
        manager.update(items)
        XCTAssertTrue(window.contentView === content)
        XCTAssertTrue(window.firstResponder === close)
        XCTAssertFalse(window.isVisible)
    }

    func testChangedRowsRestoreSameActionAndRemovedRowFallsBackToShow() throws {
        let manager = PinManagerWindow()
        let first = UUID(), second = UUID()
        manager.update([.init(id: first, filename: "One.png"), .init(id: second, filename: "Two.png")])
        let window = manager.prepareWindow()
        defer { window.close() }
        let old = try button(in: try XCTUnwrap(window.contentView), title: "Close", id: second)
        XCTAssertTrue(window.makeFirstResponder(old))
        manager.update([.init(id: second, filename: "Renamed.png"), .init(id: first, filename: "One.png")])
        let replacement = try button(in: try XCTUnwrap(window.contentView), title: "Close", id: second)
        XCTAssertFalse(old === replacement)
        XCTAssertTrue(window.firstResponder === replacement)
        manager.update([.init(id: first, filename: "One.png")])
        let fallback = try button(in: try XCTUnwrap(window.contentView), title: "Show", id: first)
        XCTAssertTrue(window.firstResponder === fallback)
        manager.update([])
        XCTAssertFalse(window.firstResponder is NSButton)
        XCTAssertFalse(window.isVisible)
    }

    func testMinimumWindowProvidesVerticalOverflowForLongNamesAndCallbacksKeepIdentity() throws {
        let manager = PinManagerWindow()
        let ids = [UUID(), UUID(), UUID()]
        manager.update(ids.map { .init(id: $0, filename: String(repeating: "Long screenshot name with Unicode 界 ", count: 16) + ".png") })
        let window = manager.prepareWindow()
        defer { window.close() }
        window.setFrame(NSRect(x: 0, y: 0, width: 360, height: 240), display: false)
        let scroll = try XCTUnwrap(window.contentView as? NSScrollView)
        window.contentView?.layoutSubtreeIfNeeded()
        let document = try XCTUnwrap(scroll.documentView)
        document.layoutSubtreeIfNeeded()
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertEqual(document.frame.width, scroll.contentView.bounds.width, accuracy: 1)
        XCTAssertGreaterThan(document.fittingSize.height, scroll.contentView.bounds.height)
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height,
                             "Actual document extent, not merely fitting size, must permit scrolling")
        XCTAssertTrue(document.isFlipped)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
        let stack = try XCTUnwrap(document as? NSStackView)
        let header = try XCTUnwrap(stack.arrangedSubviews.first)
        let headerInDocument = header.convert(header.bounds, to: document)
        XCTAssertTrue(scroll.documentVisibleRect.contains(headerInDocument),
                      "The initial viewport must show the header rather than the bottom of the list")
        var shown: UUID?, closed: UUID?
        var closeAllCount = 0
        manager.onShow = { shown = $0 }
        manager.onClose = { closed = $0 }
        manager.onCloseAll = { closeAllCount += 1 }
        try button(in: document, title: "Show", id: ids[1]).performClick(nil)
        try button(in: document, title: "Close", id: ids[2]).performClick(nil)
        try button(in: document, title: "Close All Pins").performClick(nil)
        XCTAssertEqual(shown, ids[1])
        XCTAssertEqual(closed, ids[2])
        XCTAssertEqual(closeAllCount, 1)
        XCTAssertFalse(window.isVisible)
    }

    private func button(in view: NSView, title: String, id: UUID? = nil) throws -> NSButton {
        func locate(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title,
               id == nil || button.identifier?.rawValue == id?.uuidString { return button }
            return view.subviews.lazy.compactMap { locate($0) }.first
        }
        return try XCTUnwrap(locate(view))
    }
}
