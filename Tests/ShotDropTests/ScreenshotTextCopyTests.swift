import AppKit
import XCTest
@testable import ShotDrop

@MainActor
final class ScreenshotTextCopyTests: XCTestCase {
    func testRetryMenuAndVoiceOverActionsUseTheSameIntentAndFullFilename() {
        let filename = "Screenshot 日本語 with a long filename.png"
        let retryStates: [ScreenshotTextCopyState] = [.failed, .copyFailed, .writeFailed, .clipboardChanged, .cancelled]
        for state in retryStates {
            XCTAssertEqual(ScreenshotTextCopyState.actionTitle(for: state), "Try Copying Text Again")
            XCTAssertEqual(ScreenshotTextCopyState.accessibilityActionTitle(for: state, filename: filename),
                           "Try Copying Text Again from \(filename)")
        }
        let otherStates: [ScreenshotTextCopyState?] = [nil, .recognizing, .copying, .copied, .noText, .unavailable, .multipleFrames, .tooLarge]
        for state in otherStates {
            XCTAssertEqual(ScreenshotTextCopyState.actionTitle(for: state), "Copy Text")
            XCTAssertEqual(ScreenshotTextCopyState.accessibilityActionTitle(for: state, filename: filename),
                           "Copy Text from \(filename)")
        }
    }

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
            var feedback: [ScreenshotTextCopyState] = []
            controller.start(record, onStateChange: { feedback.append($0) }) { _ in true }
            await worker.waitForStart()
            await worker.finish(.success("text")); await controller.waitForIdle()
            XCTAssertEqual(controller.states[record.captureID], failWrite ? .writeFailed : .copyFailed)
            XCTAssertEqual(writer.events, failWrite ? ["prepare", "write"] : [])
            let failure = try XCTUnwrap(controller.states[record.captureID])
            XCTAssertEqual(feedback.last, failure)
            XCTAssertEqual(failure.message, failWrite
                ? "Copy failed; the clipboard may have been cleared. Try copying text again."
                : "Couldn’t copy text · Try Copying Text Again")
            XCTAssertTrue(failure.offersRetry)
            XCTAssertEqual(ScreenshotTextCopyState.actionTitle(for: failure), "Try Copying Text Again")
            XCTAssertEqual(writer.changeCount, failWrite ? 1 : 0)
            writer.failRepresentation = false; writer.failWrite = false
            XCTAssertTrue(controller.start(record) { _ in true })
            await worker.waitForStart()
            await worker.finish(.success("retried text")); await controller.waitForIdle()
            XCTAssertEqual(controller.states[record.captureID], .copied)
            XCTAssertEqual(writer.item?.string(forType: .string), "retried text")
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

    func testBlankAndFailureFeedbackCannotDescribeChangedRevision() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let record = try savedRecord(fixture)
        let results: [Result<String, ScreenshotTextFailure>] = [
            .success(" \n"), .failure(.recognitionFailed), .failure(.fileUnavailable),
            .success(String(repeating: "x", count: ScreenshotTextLimits.outputBytes + 1))
        ]
        for result in results {
            let worker = ControlledTextRecognizer(); let writer = TextTestWriter()
            let controller = ScreenshotTextCopyController(recognizer: worker, writer: writer)
            var current = record
            XCTAssertTrue(controller.start(record) { $0 == current })
            await worker.waitForStart()
            current.revision += 1
            await worker.finish(result)
            await controller.waitForIdle()
            XCTAssertNil(controller.states[record.captureID])
            XCTAssertNil(controller.activeID)
            XCTAssertTrue(writer.events.isEmpty)
        }
    }

    func testCancellationDuringAsyncRevisionCheckRetainsSlotAndCannotRestoreFeedback() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let record = try savedRecord(fixture)
        let results: [Result<String, ScreenshotTextFailure>] = [
            .success(""), .failure(.recognitionFailed), .success("Recognized text")
        ]
        for result in results {
            for removeRow in [false, true] {
                let worker = ControlledTextRecognizer(); let writer = TextTestWriter()
                let controller = ScreenshotTextCopyController(recognizer: worker, writer: writer)
                let gate = TextRevisionGate()
                XCTAssertTrue(controller.start(record) { _ in await gate.check() })
                await worker.waitForStart()
                await worker.finish(result)
                await gate.waitUntilEntered()
                if removeRow { controller.retain([]) } else { controller.cancel() }
                XCTAssertEqual(controller.activeID, record.captureID)
                XCTAssertFalse(controller.start(record) { _ in true })
                await gate.release()
                await controller.waitForIdle()
                XCTAssertNil(controller.activeID)
                if removeRow { XCTAssertNil(controller.states[record.captureID]) }
                else { XCTAssertEqual(controller.states[record.captureID], .cancelled) }
                XCTAssertTrue(writer.events.isEmpty)
            }
        }
    }

    func testCancelAfterSuccessfulCopyClearsTransientFeedbackWithoutChangingClipboard() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let record = try savedRecord(fixture)
        let worker = ControlledTextRecognizer(); let writer = TextTestWriter()
        let controller = ScreenshotTextCopyController(recognizer: worker, writer: writer)
        XCTAssertTrue(controller.start(record) { _ in true })
        await worker.waitForStart()
        await worker.finish(.success("Copied text"))
        await controller.waitForIdle()
        XCTAssertEqual(controller.states[record.captureID], .copied)
        let count = writer.changeCount
        controller.cancel() // Menu closes before the transient feedback timer expires.
        controller.retain([record.captureID]) // Same record appears when menu reopens.
        XCTAssertNil(controller.states[record.captureID])
        XCTAssertEqual(writer.changeCount, count)
        XCTAssertEqual(writer.item?.string(forType: .string), "Copied text")
    }

    func testFeedbackCallbacksStayWithAdmittedOperationThroughCancellationAndDrain() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let first = try savedRecord(fixture)
        let second = try savedRecord(fixture)
        let worker = ControlledTextRecognizer(); let writer = TextTestWriter()
        let controller = ScreenshotTextCopyController(recognizer: worker, writer: writer)
        var firstFeedback: [ScreenshotTextCopyState] = []
        var rejectedFeedback: [ScreenshotTextCopyState] = []
        var secondFeedback: [ScreenshotTextCopyState] = []
        XCTAssertTrue(controller.start(first, onStateChange: { firstFeedback.append($0) }) { _ in true })
        XCTAssertEqual(firstFeedback, [.recognizing], "Start synchronously returns before worker execution")
        await worker.waitForStart()
        controller.cancel()
        XCTAssertFalse(controller.start(second, onStateChange: { rejectedFeedback.append($0) }) { _ in true })
        await worker.finish(.success("Discarded"))
        await controller.waitForIdle()
        XCTAssertEqual(firstFeedback, [.recognizing, .cancelled])
        XCTAssertTrue(rejectedFeedback.isEmpty)
        XCTAssertTrue(controller.start(second, onStateChange: { secondFeedback.append($0) }) { _ in true })
        await worker.waitForStart()
        await worker.finish(.success("Second operation"))
        await controller.waitForIdle()
        XCTAssertEqual(secondFeedback, [.recognizing, .copying, .copied])
        controller.cancel() // Completed callbacks must already be released.
        XCTAssertEqual(firstFeedback, [.recognizing, .cancelled])
        XCTAssertEqual(secondFeedback, [.recognizing, .copying, .copied])
        XCTAssertEqual(writer.item?.string(forType: .string), "Second operation")
    }

    func testStaleRevisionCancelsOperationCallbackWithoutRestoringRowState() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let record = try savedRecord(fixture)
        let results: [Result<String, ScreenshotTextFailure>] = [.success(""), .failure(.recognitionFailed)]
        for result in results {
            let worker = ControlledTextRecognizer(); let writer = TextTestWriter()
            let controller = ScreenshotTextCopyController(recognizer: worker, writer: writer)
            var feedback: [ScreenshotTextCopyState] = []
            XCTAssertTrue(controller.start(record, onStateChange: { feedback.append($0) }) { _ in false })
            await worker.waitForStart()
            await worker.finish(result)
            await controller.waitForIdle()
            XCTAssertEqual(feedback, [.recognizing, .cancelled])
            XCTAssertNil(controller.states[record.captureID])
            XCTAssertTrue(writer.events.isEmpty)
        }
    }

    func testFinishedOperationTokenCannotCancelOrWaitForNewWorkOnSameCapture() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let record = try savedRecord(fixture)
        let worker = ControlledTextRecognizer(); let writer = TextTestWriter()
        let controller = ScreenshotTextCopyController(recognizer: worker, writer: writer)
        let first = UUID(), second = UUID()
        XCTAssertTrue(controller.start(record, operationID: first) { _ in true })
        await worker.waitForStart()
        await worker.finish(.success("First"))
        await controller.waitForIdle(operationID: first)
        XCTAssertNil(controller.activeOperationID)
        XCTAssertTrue(controller.start(record, operationID: second) { _ in true })
        await worker.waitForStart()
        controller.cancel(operationID: first)
        await controller.waitForIdle(operationID: first) // Must return while second worker is still held.
        XCTAssertEqual(controller.activeOperationID, second)
        XCTAssertEqual(controller.states[record.captureID], .recognizing)
        XCTAssertFalse(controller.start(record) { _ in true })
        await worker.finish(.success("Second"))
        await controller.waitForIdle(operationID: second)
        XCTAssertEqual(controller.states[record.captureID], .copied)
        XCTAssertEqual(writer.item?.string(forType: .string), "Second")
    }

    func testThumbnailFeedbackNeverChangesExistingRowStateForSameCapture() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let record = try savedRecord(fixture)
        for scenario in 0..<5 {
            let worker = ControlledTextRecognizer(); let writer = TextTestWriter()
            let controller = ScreenshotTextCopyController(recognizer: worker, writer: writer)
            XCTAssertTrue(controller.start(record) { _ in true })
            await worker.waitForStart(); await worker.finish(.success("")); await controller.waitForIdle()
            XCTAssertEqual(controller.states[record.captureID], .noText)
            var thumbnailRecord = record
            thumbnailRecord.revision += 1
            let operation = UUID()
            var feedback: [ScreenshotTextCopyState] = []
            XCTAssertTrue(controller.start(thumbnailRecord, operationID: operation, publishRowFeedback: false,
                onStateChange: { feedback.append($0) }) { _ in scenario != 3 })
            XCTAssertEqual(controller.states[record.captureID], .noText)
            await worker.waitForStart()
            if scenario == 4 { controller.cancel(operationID: operation) }
            switch scenario {
            case 0: await worker.finish(.success("Thumbnail text"))
            case 1: await worker.finish(.success(""))
            case 2: await worker.finish(.failure(.recognitionFailed))
            default: await worker.finish(.success("Stale or cancelled"))
            }
            await controller.waitForIdle(operationID: operation)
            XCTAssertEqual(controller.states[record.captureID], .noText)
            let terminal: ScreenshotTextCopyState = switch scenario {
            case 0: .copied
            case 1: .noText
            case 2: .failed
            default: .cancelled
            }
            XCTAssertEqual(feedback.last, terminal)
        }
    }

    func testPruningRowFeedbackDoesNotCancelThumbnailOperationOrRestoreRowOnCompletion() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let record = try savedRecord(fixture)
        let worker = ControlledTextRecognizer(); let writer = TextTestWriter()
        let controller = ScreenshotTextCopyController(recognizer: worker, writer: writer)
        XCTAssertTrue(controller.start(record) { _ in true })
        await worker.waitForStart(); await worker.finish(.success("")); await controller.waitForIdle()
        let operation = UUID()
        var feedback: [ScreenshotTextCopyState] = []
        XCTAssertTrue(controller.start(record, operationID: operation, publishRowFeedback: false,
            onStateChange: { feedback.append($0) }) { _ in true })
        await worker.waitForStart()
        controller.retainFeedback([])
        XCTAssertTrue(controller.states.isEmpty)
        XCTAssertEqual(controller.activeOperationID, operation)
        XCTAssertEqual(feedback, [.recognizing])
        await worker.finish(.success("Thumbnail only"))
        await controller.waitForIdle(operationID: operation)
        XCTAssertTrue(controller.states.isEmpty)
        XCTAssertEqual(feedback, [.recognizing, .copying, .copied])
        XCTAssertEqual(writer.item?.string(forType: .string), "Thumbnail only")
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

private actor TextRevisionGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var held: CheckedContinuation<Bool, Never>?
    func check() async -> Bool {
        entered = true
        entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        return await withCheckedContinuation { held = $0 }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func release() { held?.resume(returning: true); held = nil }
}
