import AppKit
import XCTest
@testable import ShotDrop

@MainActor
final class ThumbnailTextCopyTests: XCTestCase {
    func testExplicitStartUsesSavedReferenceAndSharedAdmissionOnly() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let identity = try identity(fixture)
        let history = try await history(fixture, identity: identity)
        let worker = ThumbnailTextWorker(); let writer = ThumbnailTextWriter()
        let shared = ScreenshotTextCopyController(recognizer: worker, writer: writer)
        var intents = 0
        let session = ThumbnailTextCopySession(controller: shared, history: history) { intents += 1 }
        session.bind(identity)
        XCTAssertNil(shared.activeID)
        XCTAssertNil(session.state)
        XCTAssertTrue(session.start())
        XCTAssertEqual(intents, 1)
        XCTAssertEqual(session.state, .recognizing)
        await worker.waitForStart()
        let received = await worker.reference
        XCTAssertEqual(received, identity.reference)
        XCTAssertFalse(session.start())
        XCTAssertFalse(shared.start(record(identity)) { _ in true })
        await worker.finish("Full saved image text 日本語")
        await session.waitForIdle()
        XCTAssertEqual(session.state, .copied)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(writer.item?.types, [.string])
        XCTAssertEqual(writer.item?.string(forType: .string), "Full saved image text 日本語")
        XCTAssertEqual(writer.writes, 1)
    }

    func testReplacementCancelsAndDrainsWithoutLateFeedbackOrCopy() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let first = try identity(fixture)
        let history = try await history(fixture, identity: first)
        let replacement = PinScreenshotIdentity(captureID: first.captureID, revision: first.revision + 1, reference: first.reference)
        let worker = ThumbnailTextWorker(); let writer = ThumbnailTextWriter()
        let shared = ScreenshotTextCopyController(recognizer: worker, writer: writer)
        let session = ThumbnailTextCopySession(controller: shared, history: history, manualCopyIntent: {})
        session.bind(first); XCTAssertTrue(session.start())
        await worker.waitForStart()
        session.bind(replacement)
        XCTAssertEqual(session.identity, replacement)
        XCTAssertNil(session.state)
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(shared.activeID, first.captureID)
        XCTAssertFalse(session.start())
        await worker.finish("Obsolete text")
        await session.waitForIdle()
        XCTAssertNil(session.state)
        XCTAssertNil(shared.activeID)
        XCTAssertEqual(writer.writes, 0)
        _ = try await history.update(captureID: first.captureID, expectedRevision: first.revision, change: .init(copyOutcome: .success))
        XCTAssertTrue(session.start())
        await worker.waitForStart(); await worker.finish("")
        await session.waitForIdle()
        XCTAssertEqual(session.state, .noText)
    }

    func testDismissalRetainsWorkerAdmissionAndRejectsFeedback() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let identity = try identity(fixture)
        let history = try await history(fixture, identity: identity)
        let worker = ThumbnailTextWorker(); let writer = ThumbnailTextWriter()
        let shared = ScreenshotTextCopyController(recognizer: worker, writer: writer)
        let session = ThumbnailTextCopySession(controller: shared, history: history, manualCopyIntent: {})
        session.bind(identity); XCTAssertTrue(session.start())
        await worker.waitForStart()
        session.bind(nil)
        XCTAssertNil(session.identity)
        XCTAssertNil(session.state)
        XCTAssertTrue(session.isRunning)
        XCTAssertFalse(shared.start(record(identity)) { _ in true })
        await worker.finish("Late text")
        await session.waitForIdle()
        XCTAssertNil(session.state)
        XCTAssertEqual(writer.writes, 0)
    }

    func testSharedBusyDoesNotInvalidateIntentOrCancelOtherSurface() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let identity = try identity(fixture)
        let history = try await history(fixture, identity: identity)
        let worker = ThumbnailTextWorker(); let writer = ThumbnailTextWriter()
        let shared = ScreenshotTextCopyController(recognizer: worker, writer: writer)
        XCTAssertTrue(shared.start(record(identity)) { _ in true })
        await worker.waitForStart()
        var intents = 0
        let session = ThumbnailTextCopySession(controller: shared, history: history) { intents += 1 }
        session.bind(identity)
        XCTAssertFalse(session.start())
        session.bind(nil)
        XCTAssertEqual(intents, 0)
        await worker.finish("Other surface text")
        await shared.waitForIdle()
        XCTAssertEqual(writer.writes, 1)
        XCTAssertNil(session.state)
    }

    func testSourceRoleNeverAdmitsAndExplicitCancelHasRetryLabel() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let saved = try identity(fixture)
        let history = try await history(fixture, identity: saved)
        let worker = ThumbnailTextWorker(); let writer = ThumbnailTextWriter()
        let shared = ScreenshotTextCopyController(recognizer: worker, writer: writer)
        let session = ThumbnailTextCopySession(controller: shared, history: history, manualCopyIntent: {})
        let source = try RecentFileReference.capture(at: textFixtureURL(fixture.source), role: .source)
        session.bind(PinScreenshotIdentity(captureID: UUID(), revision: 1, reference: source))
        XCTAssertFalse(session.start())
        session.bind(saved); XCTAssertTrue(session.start())
        await worker.waitForStart(); session.cancel()
        XCTAssertEqual(session.state, .cancelled)
        XCTAssertEqual(session.actionTitle, "Try Copying Text Again")
        XCTAssertFalse(session.canStart)
        await worker.finish("Cancelled")
        await session.waitForIdle()
        XCTAssertTrue(session.canStart)
        XCTAssertEqual(writer.writes, 0)
    }

    func testFinishedThumbnailCancellationCannotCancelNewSharedOperationForSameCapture() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let identity = try identity(fixture)
        let history = try await history(fixture, identity: identity)
        let worker = ThumbnailTextWorker(); let writer = ThumbnailTextWriter()
        let shared = ScreenshotTextCopyController(recognizer: worker, writer: writer)
        let session = ThumbnailTextCopySession(controller: shared, history: history, manualCopyIntent: {})
        session.bind(identity); XCTAssertTrue(session.start())
        await worker.waitForStart(); await worker.finish("First thumbnail text")
        await shared.waitForIdle()
        let nextOperation = UUID()
        XCTAssertTrue(shared.start(record(identity), operationID: nextOperation) { _ in true })
        session.cancel()
        session.bind(nil)
        await worker.waitForStart()
        XCTAssertEqual(shared.activeOperationID, nextOperation)
        await worker.finish("New Recents text")
        await shared.waitForIdle(operationID: nextOperation)
        await session.waitForIdle()
        XCTAssertEqual(writer.writes, 2)
        XCTAssertEqual(writer.item?.string(forType: .string), "New Recents text")
        XCTAssertNil(session.state)
    }

    func testClosingAndReloadingUnrelatedRecentsDoesNotCancelThumbnailOCR() async throws {
        for corruptHistory in [false, true] {
            let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
            let identity = try identity(fixture)
            let history = try await history(fixture, identity: identity)
            let worker = ThumbnailTextWorker(); let writer = ThumbnailTextWriter()
            let shared = ScreenshotTextCopyController(recognizer: worker, writer: writer)
            let session = ThumbnailTextCopySession(controller: shared, history: history, manualCopyIntent: {})
            let suite = "ShotDrop-thumbnail-ownership-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let historyURL = fixture.saved.deletingLastPathComponent().appendingPathComponent("history-\(UUID()).json")
            if corruptHistory { try Data("invalid fixture history".utf8).write(to: historyURL) }
            let menu = RecentMenuController(settings: AppSettings(defaults: defaults),
                history: RecentHistoryStore(fileURL: historyURL), textCopy: shared)
            session.bind(identity); XCTAssertTrue(session.start())
            await worker.waitForStart()
            let operation = shared.activeOperationID
            menu.panelVisible(false)
            await menu.reload()
            XCTAssertEqual(menu.historyUnavailable, corruptHistory)
            XCTAssertEqual(shared.activeOperationID, operation)
            XCTAssertEqual(session.state, .recognizing)
            XCTAssertTrue(shared.states.isEmpty, "Thumbnail feedback must not appear on a Recent row")
            await worker.finish("Thumbnail continues independently")
            await session.waitForIdle()
            XCTAssertEqual(writer.writes, 1)
            XCTAssertEqual(session.state, .copied)
            XCTAssertTrue(shared.states.isEmpty)
        }
    }

    func testRecentsStillCancelsItsOwnRequestOnCloseOrRevisionChange() async throws {
        for closeMenu in [false, true] {
            let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
            let identity = try identity(fixture)
            let worker = ThumbnailTextWorker(); let writer = ThumbnailTextWriter()
            let shared = ScreenshotTextCopyController(recognizer: worker, writer: writer)
            let suite = "ShotDrop-recents-ownership-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let history = RecentHistoryStore(fileURL: fixture.saved.deletingLastPathComponent().appendingPathComponent("history.json"))
            _ = try await history.admit(captureID: identity.captureID, pipelineSequence: 1, detectionDate: Date(), displayName: "fixture")
            let saved = try await history.update(captureID: identity.captureID, expectedRevision: 0,
                change: .init(saveOutcome: .success, savedReference: identity.reference))
            let menu = RecentMenuController(settings: AppSettings(defaults: defaults), history: history,
                rowValidator: { _, _ in .available(preview: nil, refreshedReference: nil) }, textCopy: shared)
            await menu.reload(); menu.rowVisible(identity.captureID, true)
            await menu.currentRowValidation(identity.captureID)?.value
            menu.perform(identity.captureID, .copyText)
            await worker.waitForStart()
            if closeMenu { menu.panelVisible(false) }
            else {
                _ = try await history.update(captureID: identity.captureID, expectedRevision: saved.revision,
                    change: .init(copyOutcome: .success))
                await menu.reload()
            }
            await worker.finish("Cancelled Recents text")
            await shared.waitForIdle()
            XCTAssertEqual(writer.writes, 0)
            XCTAssertNil(shared.activeID)
            XCTAssertNil(shared.states[identity.captureID], "Old revision feedback must not label the new row")
        }
    }

    func testAuthoritativeHistoryRevisionChangeWithoutRebindingPreventsPublication() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let identity = try identity(fixture)
        let history = try await history(fixture, identity: identity)
        let worker = ThumbnailTextWorker(); let writer = ThumbnailTextWriter()
        let shared = ScreenshotTextCopyController(recognizer: worker, writer: writer)
        let session = ThumbnailTextCopySession(controller: shared, history: history, manualCopyIntent: {})
        session.bind(identity); XCTAssertTrue(session.start())
        await worker.waitForStart()
        _ = try await history.update(captureID: identity.captureID, expectedRevision: identity.revision,
            change: .init(copyOutcome: .success))
        await worker.finish("Text from stale history revision")
        await session.waitForIdle()
        XCTAssertEqual(session.identity, identity, "No local rebinding occurred")
        XCTAssertEqual(writer.writes, 0)
        XCTAssertNotEqual(session.state, .copied)
        XCTAssertTrue(shared.states.isEmpty)
    }

    func testHistoryRemovalCaptureReferenceMismatchAndReadFailureFailClosed() async throws {
        for kind in ["removed", "capture", "reference", "failure", "unreadable"] {
            let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
            let identity = try identity(fixture)
            var authoritative = try await history(fixture, identity: identity)
            var bound = identity
            if kind == "capture" {
                bound = .init(captureID: UUID(), revision: identity.revision, reference: identity.reference)
            } else if kind == "reference" {
                let alternate = try RecentFileReference.capture(at: textFixtureURL(fixture.source), role: .savedCopy)
                bound = .init(captureID: identity.captureID, revision: identity.revision, reference: alternate)
            } else if kind == "unreadable" {
                let url = fixture.root.appendingPathComponent("unreadable-history.json")
                try Data("malformed history".utf8).write(to: url)
                authoritative = RecentHistoryStore(fileURL: url)
            }
            let worker = ThumbnailTextWorker(); let writer = ThumbnailTextWriter()
            let shared = ScreenshotTextCopyController(recognizer: worker, writer: writer)
            let session = ThumbnailTextCopySession(controller: shared, history: authoritative, manualCopyIntent: {})
            session.bind(bound); XCTAssertTrue(session.start())
            await worker.waitForStart()
            if kind == "removed" { try await authoritative.remove(captureID: identity.captureID) }
            if kind == "failure" {
                _ = try await authoritative.update(captureID: identity.captureID, expectedRevision: identity.revision,
                    change: .init(saveOutcome: .failure))
            }
            await worker.finish("Must not publish")
            await session.waitForIdle()
            XCTAssertEqual(writer.writes, 0, kind)
            XCTAssertNotEqual(session.state, .copied, kind)
            XCTAssertTrue(shared.states.isEmpty, kind)
        }
    }

    private func history(_ fixture: ClipboardTestFixture, identity: PinScreenshotIdentity) async throws -> RecentHistoryStore {
        let history = RecentHistoryStore(fileURL: fixture.root.appendingPathComponent("thumbnail-history-\(UUID().uuidString).json"))
        _ = try await history.admit(captureID: identity.captureID, pipelineSequence: 1, detectionDate: Date(), displayName: "Saved screenshot")
        _ = try await history.update(captureID: identity.captureID, expectedRevision: 0,
            change: .init(saveOutcome: .success, savedReference: identity.reference))
        _ = try await history.update(captureID: identity.captureID, expectedRevision: 1, change: .init(copyOutcome: .pending))
        return history
    }

    private func identity(_ fixture: ClipboardTestFixture) throws -> PinScreenshotIdentity {
        .init(captureID: UUID(), revision: 2,
            reference: try RecentFileReference.capture(at: textFixtureURL(fixture.saved), role: .savedCopy))
    }
    private func record(_ identity: PinScreenshotIdentity) -> RecentHistoryRecord {
        .init(captureID: identity.captureID, pipelineSequence: 1, detectionDate: Date(), displayName: "Saved screenshot",
              sourceReference: nil, savedReference: identity.reference, copyOutcome: .pending,
              saveOutcome: .success, revision: identity.revision)
    }
}

private actor ThumbnailTextWorker: ScreenshotTextRecognizing {
    private var continuation: CheckedContinuation<String, any Error>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var reference: RecentFileReference?
    func recognize(_ reference: RecentFileReference) async throws -> String {
        self.reference = reference
        return try await withCheckedThrowingContinuation {
            continuation = $0
            waiters.forEach { $0.resume() }; waiters.removeAll()
        }
    }
    func revalidate(_ reference: RecentFileReference) async throws {}
    func waitForStart() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func finish(_ text: String) { continuation?.resume(returning: text); continuation = nil }
}

@MainActor
private final class ThumbnailTextWriter: ScreenshotPasteboardWriting {
    var changeCount = 0
    var writes = 0
    var item: NSPasteboardItem?
    func makeItem() -> NSPasteboardItem { NSPasteboardItem() }
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType, on item: NSPasteboardItem) -> Bool { false }
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType, on item: NSPasteboardItem) -> Bool {
        type == .string && item.setString(string, forType: type)
    }
    func prepareForNewContents() { changeCount += 1 }
    func write(_ item: NSPasteboardItem) -> Bool { writes += 1; self.item = item; return true }
}
