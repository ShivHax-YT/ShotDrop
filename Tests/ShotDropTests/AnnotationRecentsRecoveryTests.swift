import Foundation
import XCTest
@testable import ShotDrop

@MainActor
final class AnnotationRecentsRecoveryTests: XCTestCase {
    func testCloseAndReopenHoldReservationUntilCancelledLoadDrains() async {
        let gate = RecoveryLoadGate()
        let model = AnnotationRecentsRecoveryModel(history: RecentHistoryStore(),
            loadRecords: { await gate.load() }, reveal: { _ in XCTFail("No reveal expected"); return false })
        model.open()
        await gate.waitForStart()
        model.close()
        model.open()
        model.open()
        let beforeDrain = await gate.calls
        XCTAssertEqual(beforeDrain, 1)
        XCTAssertTrue(model.busy)
        await gate.release()
        await model.finishPendingWork()
        await model.finishPendingWork()
        let afterDrain = await gate.calls
        XCTAssertEqual(afterDrain, 2)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.message, "No recent screenshots are recorded.")
        model.close()
    }

    func testFinderFailureIsReportedAndSourceRoleCannotBeRevealed() async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "bookmarkData": Data([1]).base64EncodedString(), "lastKnownPath": "/saved.png",
            "role": "savedCopy", "volumeUUID": UUID().uuidString,
            "persistentFileID": 1, "birthSeconds": 1, "birthNanoseconds": 0,
            "byteCount": 1, "sha256": String(repeating: "a", count: 64)
        ])
        let reference = try JSONDecoder().decode(RecentFileReference.self, from: data)
        let record = RecentHistoryRecord(captureID: UUID(), pipelineSequence: 1, detectionDate: Date(),
            displayName: "Capture", sourceReference: nil, savedReference: reference,
            copyOutcome: .pending, saveOutcome: .success, revision: 1)
        for role in [RecentFileRole.savedCopy, .source] {
            let file = RecentResolvedFile(url: URL(fileURLWithPath: "/saved.png"), role: role,
                validatedData: Data([1]), liveIdentity: ScreenshotFileIdentity(device: 1, inode: 1, birthNanoseconds: 1), refreshedReference: nil)
            var revealCalls = 0
            let model = AnnotationRecentsRecoveryModel(history: RecentHistoryStore(), loadRecords: { [record] },
                resolve: { _ in .available(file) }, reveal: { _ in revealCalls += 1; return false })
            model.open()
            await model.finishPendingWork()
            model.revealSavedCopy(record.id)
            await model.finishPendingWork()
            XCTAssertEqual(revealCalls, role == .savedCopy ? 1 : 0)
            XCTAssertTrue(model.message.hasPrefix(role == .savedCopy ? "Could not reveal" : "Saved copy unavailable."))
            model.close()
        }
    }

    func testLoadsOnlyTwentyMetadataRecordsWithoutRevealing() async {
        let records = (0..<25).map { index in
            RecentHistoryRecord(captureID: UUID(), pipelineSequence: UInt64(index), detectionDate: Date(),
                displayName: "Capture \(index)", sourceReference: nil, savedReference: nil,
                copyOutcome: .pending, saveOutcome: .pending, revision: 0)
        }
        var revealed = false
        let model = AnnotationRecentsRecoveryModel(history: RecentHistoryStore(),
            loadRecords: { records }, reveal: { _ in revealed = true; return true })
        model.open()
        await model.finishPendingWork()
        XCTAssertEqual(model.records.count, 20)
        XCTAssertFalse(model.busy)
        model.revealSavedCopy(records[0].id)
        XCTAssertFalse(revealed)
        model.close()
    }

    func testLoadFailureShowsHonestRecoveryMessage() async {
        let model = AnnotationRecentsRecoveryModel(history: RecentHistoryStore(),
            loadRecords: { throw RecentHistoryStoreError.unreadable }, reveal: { _ in XCTFail("No file should be revealed"); return false })
        model.open()
        await model.finishPendingWork()
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertEqual(model.message, "Recent screenshots could not be loaded.")
        XCTAssertFalse(model.busy)
        model.close()
    }

    func testUnavailableSavedCopyNeverFallsBackOrReveals() async throws {
        let reference = try JSONDecoder().decode(RecentFileReference.self, from: JSONSerialization.data(withJSONObject: [
            "bookmarkData": Data([1]).base64EncodedString(), "lastKnownPath": "/saved.png",
            "role": "savedCopy", "volumeUUID": UUID().uuidString,
            "persistentFileID": 1, "birthSeconds": 1, "birthNanoseconds": 0,
            "byteCount": 1, "sha256": String(repeating: "a", count: 64)
        ]))
        let record = RecentHistoryRecord(captureID: UUID(), pipelineSequence: 1, detectionDate: Date(),
            displayName: "Missing capture", sourceReference: nil, savedReference: reference,
            copyOutcome: .pending, saveOutcome: .success, revision: 1)
        let model = AnnotationRecentsRecoveryModel(history: RecentHistoryStore(),
            loadRecords: { [record] }, resolve: { received in
                XCTAssertEqual(received, reference)
                return .unavailable(.replaced)
            }, reveal: { _ in XCTFail("Replacement must not be revealed"); return false })
        model.open()
        await model.finishPendingWork()
        model.revealSavedCopy(record.id)
        await model.finishPendingWork()
        XCTAssertTrue(model.message.hasPrefix("Saved copy unavailable."))
        XCTAssertEqual(model.records.first?.savedReference, reference)
        model.close()
    }
}

private actor RecoveryLoadGate {
    private(set) var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func load() async -> [RecentHistoryRecord] {
        calls += 1
        guard calls == 1 else { return [] }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            startedWaiters.forEach { $0.resume() }
            startedWaiters.removeAll()
        }
        return []
    }

    func waitForStart() async {
        if continuation != nil { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() { continuation?.resume(); continuation = nil }
}
