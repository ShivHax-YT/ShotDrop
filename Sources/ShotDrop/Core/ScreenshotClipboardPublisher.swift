import AppKit
import Foundation
import OSLog

struct ScreenshotClipboardReceipt: Sendable {
    let mode: CopyMode
    let changeCount: Int
}

/// A narrow boundary permits failure tests without reading or changing the user's board.
@MainActor
protocol ScreenshotPasteboardWriting: AnyObject {
    var changeCount: Int { get }
    func makeItem() -> NSPasteboardItem
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType, on item: NSPasteboardItem) -> Bool
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType, on item: NSPasteboardItem) -> Bool
    func prepareForNewContents()
    func write(_ item: NSPasteboardItem) -> Bool
}

@MainActor
final class AppKitScreenshotPasteboardWriter: ScreenshotPasteboardWriting {
    private let pasteboard: NSPasteboard

    /// The integration coordinator must explicitly select the board. Tests use private boards.
    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }
    func makeItem() -> NSPasteboardItem { NSPasteboardItem() }
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType, on item: NSPasteboardItem) -> Bool {
        item.setData(data, forType: type)
    }
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType, on item: NSPasteboardItem) -> Bool {
        item.setString(string, forType: type)
    }
    func prepareForNewContents() {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
    }
    func write(_ item: NSPasteboardItem) -> Bool { pasteboard.writeObjects([item]) }
}

@MainActor
final class ScreenshotClipboardPublisher {
    private let writer: any ScreenshotPasteboardWriting
    private let logger = Logger(subsystem: "com.macfleet.shotdrop", category: "Clipboard")

    init(writer: any ScreenshotPasteboardWriting) {
        self.writer = writer
    }

    var changeCount: Int { writer.changeCount }

    /// The coordinator's ordering/cancellation preflight runs after file revalidation.
    /// From preflight through ownership and write there is no actor suspension point.
    func publish(
        _ prepared: PreparedScreenshotClipboard,
        beforeOwnership: @MainActor () throws -> Void = {}
    ) async throws -> ScreenshotClipboardReceipt {
        try await prepared.validateFileForPublication()
        try Task.checkCancellation()
        try beforeOwnership()
        let item = writer.makeItem()
        if prepared.mode != .file {
            guard let png = prepared.pngData, writer.setData(png, forType: .png, on: item) else {
                throw ScreenshotClipboardFailure(.representationSetupFailed, "The PNG clipboard representation could not be prepared. The clipboard has not been changed.")
            }
        }
        if prepared.mode != .image {
            guard let fileURL = prepared.fileURL,
                  writer.setString(fileURL.absoluteString, forType: .fileURL, on: item) else {
                throw ScreenshotClipboardFailure(.representationSetupFailed, "The file clipboard representation could not be prepared. The clipboard has not been changed.")
            }
        }
        writer.prepareForNewContents()
        guard writer.write(item) else {
            logger.error("Screenshot clipboard write failed after ownership changed.")
            throw ScreenshotClipboardFailure(.writeFailed, "The screenshot could not be added to the clipboard. Previous clipboard contents may have been cleared; the screenshot file is unchanged.")
        }
        logger.info("Screenshot representations written to pasteboard.")
        return ScreenshotClipboardReceipt(mode: prepared.mode, changeCount: writer.changeCount)
    }
}
