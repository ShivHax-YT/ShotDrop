import Darwin
import Foundation
import XCTest
@testable import ShotDrop

@MainActor
final class RecentMenuValidationStateTests: XCTestCase {
    private let fileActions: [RecentMenuAction] = [.open, .copyPreferred, .copyImage, .copyFile, .copyText, .annotate, .revealSaved, .revealOriginal]

    func testStoredReferenceStartsCheckingAndSuccessEnablesOnlySavedActions() async throws {
        let fixture = try MenuStateFixture(); defer { fixture.remove() }
        let id = try await fixture.addSaved()
        let worker = MenuValidationWorker()
        let controller = fixture.controller(worker)
        await controller.reload()
        let initial = try XCTUnwrap(controller.rows.first)
        XCTAssertEqual(initial.availability, .checking)
        XCTAssertEqual(initial.detail, "Checking saved copy…")
        for action in fileActions { XCTAssertFalse(initial.allows(action)) }
        controller.rowVisible(id, true)
        await worker.waitForStart(1)
        XCTAssertEqual(controller.rows.first?.availability, .checking)
        controller.perform(id, .retryFileCheck) // A queued check cannot admit duplicate work.
        let count = await worker.count
        XCTAssertEqual(count, 1)
        let completion = controller.currentRowValidation(id)
        await worker.complete(0, .success(.available(preview: nil, refreshedReference: nil)))
        await completion?.value
        let verified = try XCTUnwrap(controller.rows.first)
        XCTAssertEqual(verified.availability, .saved)
        XCTAssertEqual(verified.detail, "Saved copy")
        for action in fileActions where action != .revealOriginal { XCTAssertTrue(verified.allows(action)) }
        XCTAssertFalse(verified.allows(.revealOriginal))
        XCTAssertNil(verified.previewImage, "Thumbnail decode is not the availability gate")
    }

    func testVisibleQueuePressureCancellationAndFailureOfferRetryThenCheckAgain() async throws {
        for (failure, detail) in [(MenuValidationFailure.queueFull, "File check busy · Retry File Check"),
                                  (.cancelled, "File check cancelled · Retry File Check"),
                                  (.other, "File check unavailable · Retry File Check")] {
            let fixture = try MenuStateFixture(); defer { fixture.remove() }
            let id = try await fixture.addSaved()
            let worker = MenuValidationWorker(); let controller = fixture.controller(worker)
            await controller.reload(); controller.rowVisible(id, true); await worker.waitForStart(1)
            let first = controller.currentRowValidation(id)
            await worker.complete(0, .failure(failure)); await first?.value
            let row = try XCTUnwrap(controller.rows.first)
            XCTAssertEqual(row.availability, .unavailable)
            XCTAssertEqual(row.detail, detail)
            XCTAssertTrue(row.allows(.retryFileCheck))
            for action in fileActions { XCTAssertFalse(row.allows(action)) }
            controller.perform(id, .retryFileCheck)
            XCTAssertEqual(controller.rows.first?.availability, .checking)
            await worker.waitForStart(2)
            let second = controller.currentRowValidation(id)
            await worker.complete(1, .success(.available(preview: nil, refreshedReference: nil)))
            await second?.value
            XCTAssertEqual(controller.rows.first?.availability, .saved)
        }
    }

    func testOffscreenCancellationIsSilentAndReappearanceRevalidates() async throws {
        let fixture = try MenuStateFixture(); defer { fixture.remove() }
        let id = try await fixture.addSaved()
        let worker = MenuValidationWorker(); let controller = fixture.controller(worker)
        await controller.reload(); controller.rowVisible(id, true); await worker.waitForStart(1)
        let old = controller.currentRowValidation(id)
        controller.rowVisible(id, false)
        await worker.complete(0, .failure(.cancelled)); await old?.value
        XCTAssertEqual(controller.rows.first?.detail, "Checking saved copy…")
        XCTAssertEqual(controller.rows.first?.availability, .checking)
        controller.rowVisible(id, true); await worker.waitForStart(2)
        let fresh = controller.currentRowValidation(id)
        await worker.complete(1, .success(.available(preview: nil, refreshedReference: nil)))
        await fresh?.value
        XCTAssertEqual(controller.rows.first?.availability, .saved)
        controller.rowVisible(id, false)
        XCTAssertEqual(controller.rows.first?.availability, .checking, "Old verified availability cannot survive reappearance")
    }

    func testPanelCloseAndSameRevisionRecheckFenceOldSuccessAndFailure() async throws {
        for oldSuccess in [false, true] {
            let fixture = try MenuStateFixture(); defer { fixture.remove() }
            let id = try await fixture.addSaved()
            let worker = MenuValidationWorker(); let controller = fixture.controller(worker)
            await controller.reload(); controller.rowVisible(id, true); await worker.waitForStart(1)
            let old = controller.currentRowValidation(id)
            if oldSuccess { controller.panelVisible(false); await controller.reload() }
            else { controller.rowVisible(id, false) }
            controller.rowVisible(id, true); await worker.waitForStart(2)
            let fresh = controller.currentRowValidation(id)
            await worker.complete(1, .success(.unavailable(.replaced))); await fresh?.value
            XCTAssertEqual(controller.rows.first?.detail, "File changed")
            await worker.complete(0, oldSuccess ? .success(.available(preview: nil, refreshedReference: nil)) : .failure(.queueFull))
            await old?.value
            XCTAssertEqual(controller.rows.first?.availability, .unavailable)
            XCTAssertEqual(controller.rows.first?.detail, "File changed", "Old generation/token must not overwrite newer result")
        }
    }

    func testRevisionChangeRejectsOldResultAndMissingSavedCopyNeverFallsBackToSource() async throws {
        let fixture = try MenuStateFixture(); defer { fixture.remove() }
        let id = try await fixture.addSaved()
        let worker = MenuValidationWorker(); let controller = fixture.controller(worker)
        await controller.reload(); controller.rowVisible(id, true); await worker.waitForStart(1)
        let old = controller.currentRowValidation(id)
        _ = try await fixture.history.update(captureID: id, expectedRevision: 1, change: .init(copyOutcome: .success))
        await controller.reload(); await worker.waitForStart(2)
        let fresh = controller.currentRowValidation(id)
        await worker.complete(0, .success(.available(preview: nil, refreshedReference: nil))); await old?.value
        XCTAssertEqual(controller.rows.first?.availability, .checking)
        await worker.complete(1, .success(.unavailable(.missing))); await fresh?.value
        let row = try XCTUnwrap(controller.rows.first)
        XCTAssertEqual(row.availability, .missing)
        XCTAssertEqual(row.detail, "Saved file missing")
        XCTAssertTrue(row.allows(.removeFromRecents))
        for action in fileActions { XCTAssertFalse(row.allows(action)) }
        let roles = await worker.roles
        XCTAssertEqual(roles, [.savedCopy, .savedCopy], "Never fall back to the stored original")
    }

    func testSourceOnlyRowRequiresValidationAndEnablesOnlyRevealOriginal() async throws {
        let fixture = try MenuStateFixture(); defer { fixture.remove() }
        let record = try await fixture.history.admit(captureID: UUID(), pipelineSequence: 1,
            detectionDate: Date(), displayName: "source.png", sourceReference: fixture.source)
        let worker = MenuValidationWorker(); let controller = fixture.controller(worker)
        await controller.reload()
        XCTAssertEqual(controller.rows.first?.detail, "Checking original…")
        XCTAssertFalse(try XCTUnwrap(controller.rows.first).allows(.revealOriginal))
        controller.rowVisible(record.id, true); await worker.waitForStart(1)
        let completion = controller.currentRowValidation(record.id)
        await worker.complete(0, .success(.available(preview: nil, refreshedReference: nil))); await completion?.value
        let row = try XCTUnwrap(controller.rows.first)
        XCTAssertEqual(row.availability, .sourceOnly)
        XCTAssertTrue(row.allows(.revealOriginal))
        for action in fileActions where action != .revealOriginal { XCTAssertFalse(row.allows(action)) }
    }
}

@MainActor
private struct MenuStateFixture {
    let root: URL
    let history: RecentHistoryStore
    let source: RecentFileReference
    let saved: RecentFileReference
    let defaults: UserDefaults
    let suite: String

    init() throws {
        guard let temporary = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw POSIXError(.EIO) }
        defer { free(temporary) }
        root = URL(fileURLWithPath: String(cString: temporary), isDirectory: true)
            .appendingPathComponent("ShotDrop-RowStates-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("fixture.png")
        try ClipboardTestFixture.imageData(type: .png).write(to: file)
        source = try RecentFileReference.capture(at: file, role: .source)
        saved = try RecentFileReference.capture(at: file, role: .savedCopy)
        history = RecentHistoryStore(fileURL: root.appendingPathComponent("history.json"))
        suite = "ShotDrop-RowState-\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    func addSaved() async throws -> UUID {
        let id = UUID()
        _ = try await history.admit(captureID: id, pipelineSequence: 1, detectionDate: Date(),
                                   displayName: "fixture.png", sourceReference: source)
        _ = try await history.update(captureID: id, expectedRevision: 0,
                                     change: .init(saveOutcome: .success, savedReference: saved))
        return id
    }

    func controller(_ worker: MenuValidationWorker) -> RecentMenuController {
        RecentMenuController(settings: AppSettings(defaults: defaults), history: history,
                             rowValidator: { id, reference in try await worker.validate(id, reference) })
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private enum MenuValidationFailure: Error { case queueFull, cancelled, other }

private actor MenuValidationWorker {
    private var continuations: [Int: CheckedContinuation<RecentRowValidation, any Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var roles: [RecentFileRole] = []
    var count: Int { roles.count }

    func validate(_ id: UUID, _ reference: RecentFileReference) async throws -> RecentRowValidation {
        let index = roles.count
        roles.append(reference.role)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[index] = continuation
            for (target, waiter) in waiters where target <= roles.count { waiter.resume() }
            waiters.removeAll { $0.0 <= roles.count }
        }
    }

    func waitForStart(_ target: Int) async {
        if roles.count >= target { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }

    func complete(_ index: Int, _ result: Result<RecentRowValidation, MenuValidationFailure>) {
        guard let continuation = continuations.removeValue(forKey: index) else { return }
        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(.queueFull): continuation.resume(throwing: RecentPreviewError.queueFull)
        case .failure(.cancelled): continuation.resume(throwing: CancellationError())
        case .failure(.other): continuation.resume(throwing: RecentPreviewError.decodeFailed)
        }
    }
}
