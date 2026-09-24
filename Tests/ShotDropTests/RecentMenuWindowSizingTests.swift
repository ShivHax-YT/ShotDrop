import AppKit
import SwiftUI
import XCTest
@testable import ShotDrop

@MainActor
final class RecentMenuWindowSizingTests: XCTestCase {
    func testHostedRecentPanelResizesItsAttachedHiddenWindowForZeroOneTwentyAndBack() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 352, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: panel(rowCount: 0))
        window.contentView = host
        var heights: [CGFloat] = []
        for count in [0, 1, 20, 1, 0] {
            host.rootView = panel(rowCount: count)
            host.layoutSubtreeIfNeeded()
            // Let SwiftUI preferences and the coalesced native resize complete.
            // This is an offscreen test window, never ordered on screen.
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let content = window.contentRect(forFrameRect: window.frame)
            heights.append(content.height)
            XCTAssertEqual(content.width, 352, accuracy: 1)
            XCTAssertLessThanOrEqual(content.height, 560)
            XCTAssertFalse(window.isVisible)
        }
        XCTAssertLessThan(heights[0], heights[2])
        XCTAssertLessThan(heights[1], heights[0])
        XCTAssertEqual(heights[1], heights[3], accuracy: 2)
        XCTAssertEqual(heights[0], heights[4], accuracy: 2)
    }

    private func panel(rowCount: Int) -> AnyView {
        let rows = (0..<rowCount).map { index in
            RecentMenuRow(id: UUID(), displayName: "Fixture \(index).png", detectedAt: Date(timeIntervalSince1970: 0),
                detail: "Checking saved copy…", availability: .checking, savedPath: nil,
                sourcePath: nil, previewImage: nil, copyConfirmation: nil)
        }
        return AnyView(RecentMenuPanel(rows: rows, status: "Saving paused · Developer review required",
            historyUnavailable: false, preferredCopyMode: .image, onAction: { _, _ in },
            onClearHistory: {}, onFinishSetup: {}, onOpenSettings: {}, onPanelVisible: { _ in },
            onRowVisible: { _, _ in }))
    }

    func testHiddenWindowActuallyShrinksAndGrowsWithoutPresentation() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 352, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for count in [0, 1, 20, 1, 0] {
            let layout = RecentMenuLayout.measure(rowCount: count, chromeHeight: 170,
                emptyHeight: 160, estimatedRowHeight: 64, availableHeight: 900)
            RecentMenuWindowSizing.apply(CGSize(width: 352, height: layout.panelHeight), to: window)
            let content = window.contentRect(forFrameRect: window.frame)
            XCTAssertEqual(content.width, 352, accuracy: 0.5)
            XCTAssertEqual(content.height, layout.panelHeight, accuracy: 0.5)
            XCTAssertFalse(window.isVisible, "Sizing must not present or activate the window")
        }
    }

    func testInvalidSizeCannotChangeWindowFrame() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 352, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let original = window.frame
        RecentMenuWindowSizing.apply(CGSize(width: 352, height: CGFloat.nan), to: window)
        RecentMenuWindowSizing.apply(CGSize(width: 352, height: 0), to: window)
        XCTAssertEqual(window.frame, original)
        XCTAssertFalse(window.isVisible)
    }
}
