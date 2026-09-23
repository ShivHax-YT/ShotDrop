import AppKit
import Foundation
import ImageIO
import XCTest
@testable import ShotDrop

@MainActor
final class ScreenshotClipboardPublisherTests: XCTestCase {
    func testEveryModePublishesExactlyOneItemWithExactTypesAndReadback() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        for mode in CopyMode.allCases {
            let board = privateBoard()
            defer { board.releaseGlobally() }
            let publisher = ScreenshotClipboardPublisher(writer: AppKitScreenshotPasteboardWriter(pasteboard: board))
            let prepared = try await ScreenshotClipboardPreparer().prepare(fixture.request(mode))
            let receipt = try await publisher.publish(prepared)
            XCTAssertEqual(receipt.mode, mode)
            XCTAssertEqual(receipt.changeCount, board.changeCount)
            let items = try XCTUnwrap(board.pasteboardItems)
            XCTAssertEqual(items.count, 1)
            let item = try XCTUnwrap(items.first)
            let expected: Set<NSPasteboard.PasteboardType> = mode == .image ? [.png] : mode == .file ? [.fileURL] : [.png, .fileURL]
            XCTAssertEqual(Set(item.types), expected)
            if mode != .file {
                let data = try XCTUnwrap(item.data(forType: .png))
                XCTAssertEqual(data, fixture.png)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(image.width, 16)
                XCTAssertEqual(image.height, 16)
            }
            if mode != .image {
                let reference = try XCTUnwrap(item.string(forType: .fileURL))
                XCTAssertEqual(URL(string: reference), fixture.saved)
                XCTAssertEqual(try Data(contentsOf: XCTUnwrap(URL(string: reference))), fixture.png)
            }
        }
    }

    func testImageAndFileSetupFailuresNeverChangeOwnership() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        for failingType: NSPasteboard.PasteboardType in [.png, .fileURL] {
            let board = privateBoard()
            defer { board.releaseGlobally() }
            seed(board)
            let count = board.changeCount
            let writer = TestClipboardWriter(board: board)
            writer.failingType = failingType
            let publisher = ScreenshotClipboardPublisher(writer: writer)
            let prepared = try await ScreenshotClipboardPreparer().prepare(fixture.request(.both))
            await assertFailure(.representationSetupFailed) { _ = try await publisher.publish(prepared) }
            XCTAssertFalse(writer.events.contains("prepare"))
            XCTAssertFalse(writer.events.contains("write"))
            XCTAssertEqual(board.changeCount, count)
            XCTAssertEqual(board.string(forType: .string), "private prior contents")
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.png)
        }
    }

    func testWriteFailureIsReportedAfterOwnershipWithoutRollback() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        let board = privateBoard()
        defer { board.releaseGlobally() }
        seed(board)
        let writer = TestClipboardWriter(board: board)
        writer.failWrite = true
        let publisher = ScreenshotClipboardPublisher(writer: writer)
        let prepared = try await ScreenshotClipboardPreparer().prepare(fixture.request(.both))
        await assertFailure(.writeFailed) { _ = try await publisher.publish(prepared) }
        XCTAssertEqual(writer.events, ["make", "png", "file", "prepare", "write"])
        XCTAssertNil(board.string(forType: .string))
        XCTAssertTrue(board.pasteboardItems?.isEmpty ?? true)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.png)
        XCTAssertEqual(try Data(contentsOf: fixture.saved), fixture.png)
    }

    func testMissingSavedFileRejectsBeforeOwnershipAndPreservesPrivateBoard() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        let prepared = try await ScreenshotClipboardPreparer().prepare(fixture.request(.both))
        try FileManager.default.moveItem(at: fixture.saved, to: fixture.root.appendingPathComponent("moved.png"))
        let board = privateBoard()
        defer { board.releaseGlobally() }
        seed(board)
        let writer = TestClipboardWriter(board: board)
        let publisher = ScreenshotClipboardPublisher(writer: writer)
        await assertFailure(.fileUnavailable) { _ = try await publisher.publish(prepared) }
        XCTAssertTrue(writer.events.isEmpty)
        XCTAssertEqual(board.string(forType: .string), "private prior contents")
    }

    func testPublishedPNGSurvivesSourceMoveAndFileURLRemainsAnExplicitPathReference() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        let board = privateBoard()
        defer { board.releaseGlobally() }
        let publisher = ScreenshotClipboardPublisher(writer: AppKitScreenshotPasteboardWriter(pasteboard: board))
        let prepared = try await ScreenshotClipboardPreparer().prepare(fixture.request(.both))
        _ = try await publisher.publish(prepared)
        try FileManager.default.moveItem(at: fixture.source, to: fixture.root.appendingPathComponent("renamed-source.png"))
        try FileManager.default.moveItem(at: fixture.saved, to: fixture.root.appendingPathComponent("renamed-saved.png"))
        let item = try XCTUnwrap(board.pasteboardItems?.first)
        XCTAssertEqual(item.data(forType: .png), fixture.png)
        XCTAssertEqual(item.string(forType: .fileURL), fixture.saved.absoluteString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.saved.path))
    }

    func testEveryPublicationCreatesFreshItemAndUsesItsOwnPreparedBytes() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        let board = privateBoard()
        defer { board.releaseGlobally() }
        let writer = TestClipboardWriter(board: board)
        let publisher = ScreenshotClipboardPublisher(writer: writer)
        let first = try await ScreenshotClipboardPreparer().prepare(fixture.request(.image))
        _ = try await publisher.publish(first)
        _ = try await publisher.publish(first)
        XCTAssertEqual(writer.created.count, 2)
        XCTAssertFalse(writer.created[0] === writer.created[1])
        XCTAssertEqual(board.pasteboardItems?.count, 1)
        XCTAssertEqual(board.data(forType: .png), fixture.png)
    }

    func testPreflightRunsAfterValidationAndCanRejectWithoutOwnershipChange() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        let board = privateBoard()
        defer { board.releaseGlobally() }
        seed(board)
        let writer = TestClipboardWriter(board: board)
        let publisher = ScreenshotClipboardPublisher(writer: writer)
        let prepared = try await ScreenshotClipboardPreparer().prepare(fixture.request(.both))
        var checked = false
        do {
            _ = try await publisher.publish(prepared) {
                checked = true
                XCTAssertTrue(writer.events.isEmpty)
                throw CancellationError()
            }
            XCTFail("Preflight rejection must not return a copied receipt")
        } catch is CancellationError { }
        XCTAssertTrue(checked)
        XCTAssertTrue(writer.events.isEmpty)
        XCTAssertEqual(board.string(forType: .string), "private prior contents")
    }

    func testCancelledPublicationDoesNotChangeOwnership() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        let board = privateBoard()
        defer { board.releaseGlobally() }
        seed(board)
        let writer = TestClipboardWriter(board: board)
        let publisher = ScreenshotClipboardPublisher(writer: writer)
        let prepared = try await ScreenshotClipboardPreparer().prepare(fixture.request(.image))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await publisher.publish(prepared)
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must not return a receipt")
        } catch is CancellationError { }
        XCTAssertTrue(writer.events.isEmpty)
        XCTAssertEqual(board.string(forType: .string), "private prior contents")
    }

    private func privateBoard() -> NSPasteboard {
        NSPasteboard(name: .init("com.macfleet.shotdrop.tests.\(UUID().uuidString)"))
    }

    private func seed(_ board: NSPasteboard) {
        board.clearContents()
        XCTAssertTrue(board.setString("private prior contents", forType: .string))
    }

    private func assertFailure(
        _ code: ScreenshotClipboardFailure.Code, operation: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(code)", file: file, line: line)
        } catch let error as ScreenshotClipboardFailure {
            XCTAssertEqual(error.code, code, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }
}

@MainActor
private final class TestClipboardWriter: ScreenshotPasteboardWriting {
    let board: NSPasteboard
    var failingType: NSPasteboard.PasteboardType?
    var failWrite = false
    var events: [String] = []
    var created: [NSPasteboardItem] = []
    init(board: NSPasteboard) { self.board = board }
    var changeCount: Int { board.changeCount }
    func makeItem() -> NSPasteboardItem {
        events.append("make")
        let item = NSPasteboardItem()
        created.append(item)
        return item
    }
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType, on item: NSPasteboardItem) -> Bool {
        events.append("png")
        return failingType == type ? false : item.setData(data, forType: type)
    }
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType, on item: NSPasteboardItem) -> Bool {
        events.append("file")
        return failingType == type ? false : item.setString(string, forType: type)
    }
    func prepareForNewContents() {
        events.append("prepare")
        board.prepareForNewContents(with: .currentHostOnly)
    }
    func write(_ item: NSPasteboardItem) -> Bool {
        events.append("write")
        return failWrite ? false : board.writeObjects([item])
    }
}
