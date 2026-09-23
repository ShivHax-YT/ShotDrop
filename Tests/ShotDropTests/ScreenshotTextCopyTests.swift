import AppKit
import XCTest
@testable import ShotDrop

@MainActor
final class ScreenshotTextCopyTests: XCTestCase {
    func testOneAdmissionPublishesOnlyPlainUnicodeTextForInvokedRecord() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let record = try savedRecord(fixture)
        let worker = ControlledTextRecognizer()
        let writer = TextTestWriter()
        let controller = ScreenshotTextCopyController(recognizer: worker, writer: writer)
        var validatedID: UUID?
        XCTAssertTrue(controller.start(record) { validatedID = $0.captureID; return true })
        await worker.waitForStart()
        XCTAssertFalse(controller.start(record) { _ in true })
        let other = try savedRecord(fixture)
        XCTAssertFalse(controller.start(other) { _ in true })
        await worker.finish(.success("Café 日本語\nمرحبا"))
        await controller.waitForIdle()
        XCTAssertEqual(validatedID, record.captureID)
        XCTAssertEqual(controller.states[record.captureID], .copied)
        XCTAssertEqual(writer.item?.types, [.string])
        XCTAssertEqual(writer.item?.string(forType: .string), "Café 日本語\nمرحبا")
        XCTAssertEqual(writer.events, ["prepare", "write"])
        XCTAssertNil(controller.activeID)
        XCTAssertEqual(try Data(contentsOf: fixture.saved), fixture.png)
    }

    func testPendingAndSourceOnlyNeverAdmit() throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        var record = try savedRecord(fixture)
        let writer = TextTestWriter()
        let controller = ScreenshotTextCopyController(recognizer: ControlledTextRecognizer(), writer: writer)
        record.saveOutcome = .pending
        XCTAssertFalse(controller.start(record) { _ in true })
        record.saveOutcome = .success
        record.savedReference = try RecentFileReference.capture(at: textFixtureURL(fixture.source), role: .source)
        XCTAssertFalse(controller.start(record) { _ in true })
        record.savedReference = nil
        XCTAssertFalse(controller.start(record) { _ in true })
        XCTAssertTrue(writer.events.isEmpty)
        XCTAssertTrue(controller.states.isEmpty)
    }

    func testNoTextAndRecognitionFailuresNeverTouchClipboard() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let record = try savedRecord(fixture)
        let cases: [(Result<String, ScreenshotTextFailure>, ScreenshotTextCopyState)] = [
            (.success(" \n\t"), .noText), (.failure(.recognitionFailed), .failed),
            (.failure(.fileUnavailable), .unavailable), (.failure(.inputTooLarge), .tooLarge),
            (.failure(.multipleFrames), .multipleFrames),
            (.success(String(repeating: "é", count: ScreenshotTextLimits.outputBytes)), .tooLarge)
        ]
        for (result, expected) in cases {
            let worker = ControlledTextRecognizer(); let writer = TextTestWriter()
            let controller = ScreenshotTextCopyController(recognizer: worker, writer: writer)
            controller.start(record) { _ in true }
            await worker.waitForStart(); await worker.finish(result); await controller.waitForIdle()
            XCTAssertEqual(controller.states[record.captureID], expected)
            XCTAssertTrue(writer.events.isEmpty)
            XCTAssertEqual(writer.changeCount, 0)
        }
    }

    func testCancelKeepsSlotUntilWorkerReturnsAndSuppressesLateResult() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let record = try savedRecord(fixture)
        let worker = ControlledTextRecognizer(); let writer = TextTestWriter()
        let controller = ScreenshotTextCopyController(recognizer: worker, writer: writer)
        controller.start(record) { _ in true }; await worker.waitForStart()
        controller.cancel()
        XCTAssertEqual(controller.activeID, record.captureID)
        XCTAssertFalse(controller.start(record) { _ in true })
        await worker.finish(.success("late")); await controller.waitForIdle()
        XCTAssertNil(controller.activeID)
        XCTAssertEqual(controller.states[record.captureID], .cancelled)
        XCTAssertTrue(writer.events.isEmpty)
        XCTAssertTrue(controller.start(record) { _ in true })
        await worker.waitForStart(); await worker.finish(.success("new")); await controller.waitForIdle()
        XCTAssertEqual(controller.states[record.captureID], .copied)
    }

    func testRowRevisionOrRemovalSuppressesCompletion() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let record = try savedRecord(fixture)
        for removed in [false, true] {
            let worker = ControlledTextRecognizer(); let writer = TextTestWriter()
            let controller = ScreenshotTextCopyController(recognizer: worker, writer: writer)
            var current = record
            controller.start(record) { $0 == current }
            await worker.waitForStart()
            current.revision += 1
            if removed { controller.retain([]) }
            await worker.finish(.success("stale")); await controller.waitForIdle()
            XCTAssertTrue(writer.events.isEmpty)
            XCTAssertNotEqual(controller.states[record.captureID], .copied)
        }
    }

    func testFileRevalidationAndClipboardOwnershipFencePublication() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let record = try savedRecord(fixture)
        for fileChanged in [false, true] {
            let worker = ControlledTextRecognizer(); let writer = TextTestWriter()
            let controller = ScreenshotTextCopyController(recognizer: worker, writer: writer)
            controller.start(record) { _ in true }; await worker.waitForStart()
            if fileChanged { await worker.failValidation() } else { writer.changeCount += 1 }
            await worker.finish(.success("text")); await controller.waitForIdle()
            XCTAssertEqual(controller.states[record.captureID], fileChanged ? .unavailable : .clipboardChanged)
            XCTAssertTrue(writer.events.isEmpty)
        }
    }

    func testRepresentationAndWriteFailuresHaveDifferentMutationBoundaries() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let record = try savedRecord(fixture)
        for failWrite in [false, true] {
            let worker = ControlledTextRecognizer(); let writer = TextTestWriter()
            writer.failRepresentation = !failWrite; writer.failWrite = failWrite
            let controller = ScreenshotTextCopyController(recognizer: worker, writer: writer)
            controller.start(record) { _ in true }; await worker.waitForStart()
            await worker.finish(.success("text")); await controller.waitForIdle()
            XCTAssertEqual(controller.states[record.captureID], failWrite ? .writeFailed : .copyFailed)
            XCTAssertEqual(writer.events, failWrite ? ["prepare", "write"] : [])
        }
    }

    func testRealPrivatePasteboardUsesPlainTextOnly() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let board = NSPasteboard(name: .init("ShotDrop-OCR-test-\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("prior fixture", forType: .string)
        let worker = ControlledTextRecognizer()
        let controller = ScreenshotTextCopyController(recognizer: worker,
            writer: AppKitScreenshotPasteboardWriter(pasteboard: board))
        let record = try savedRecord(fixture)
        controller.start(record) { _ in true }; await worker.waitForStart()
        await worker.finish(.success("")); await controller.waitForIdle()
        XCTAssertEqual(board.string(forType: .string), "prior fixture")
        controller.start(record) { _ in true }; await worker.waitForStart()
        await worker.finish(.success("First\nSecond")); await controller.waitForIdle()
        XCTAssertEqual(board.pasteboardItems?.count, 1)
        XCTAssertEqual(board.pasteboardItems?.first?.types, [.string])
        XCTAssertEqual(board.string(forType: .string), "First\nSecond")
    }

    private func savedRecord(_ fixture: ClipboardTestFixture) throws -> RecentHistoryRecord {
        RecentHistoryRecord(captureID: UUID(), pipelineSequence: 1, detectionDate: Date(), displayName: "fixture",
            sourceReference: nil,
            savedReference: try RecentFileReference.capture(at: textFixtureURL(fixture.saved), role: .savedCopy),
            copyOutcome: .failure, saveOutcome: .success, revision: 1)
    }
}

private actor ControlledTextRecognizer: ScreenshotTextRecognizing {
    private var continuation: CheckedContinuation<String, any Error>?
    private var started: [CheckedContinuation<Void, Never>] = []
    private var invalid = false
    func recognize(_ reference: RecentFileReference) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            for waiter in started { waiter.resume() }; started.removeAll()
        }
    }
    func revalidate(_ reference: RecentFileReference) async throws {
        if invalid { throw ScreenshotTextFailure.fileUnavailable }
    }
    func waitForStart() async {
        if continuation != nil { return }
        await withCheckedContinuation { started.append($0) }
    }
    func finish(_ result: Result<String, ScreenshotTextFailure>) {
        continuation?.resume(with: result.mapError { $0 as any Error }); continuation = nil
    }
    func failValidation() { invalid = true }
}

@MainActor
private final class TextTestWriter: ScreenshotPasteboardWriting {
    var changeCount = 0
    var events: [String] = []
    var item: NSPasteboardItem?
    var failRepresentation = false
    var failWrite = false
    func makeItem() -> NSPasteboardItem { NSPasteboardItem() }
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType, on item: NSPasteboardItem) -> Bool { false }
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType, on item: NSPasteboardItem) -> Bool {
        !failRepresentation && item.setString(string, forType: type)
    }
    func prepareForNewContents() { events.append("prepare"); changeCount += 1; item = nil }
    func write(_ item: NSPasteboardItem) -> Bool {
        events.append("write")
        if failWrite { return false }
        self.item = item; return true
    }
}
