import Darwin
import Foundation
import XCTest
@testable import ShotDrop

final class RecentHistoryStoreTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        guard let physicalTemporary = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(physicalTemporary) }
        let directory = URL(fileURLWithPath: String(cString: physicalTemporary), isDirectory: true)
            .appendingPathComponent("ShotDrop-History-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("RecentHistory.json"))
    }

    func testStableSequenceOrderCapAndUUIDDeduplication() async throws {
        let (directory, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecentHistoryStore(fileURL: url)
        let IDs = (0..<23).map { _ in UUID() }
        for index in IDs.indices.reversed() {
            _ = try await store.admit(captureID: IDs[index], pipelineSequence: UInt64(index),
                                      detectionDate: Date(timeIntervalSince1970: Double(index)),
                                      displayName: "Shot \(index)")
        }
        let newest = try await store.admit(captureID: IDs[22], pipelineSequence: 0,
                                           detectionDate: .distantPast, displayName: "duplicate")
        XCTAssertEqual(newest.pipelineSequence, 22)
        let rows = try await store.snapshot().records
        XCTAssertEqual(rows.count, 20)
        XCTAssertEqual(rows.map(\.pipelineSequence), Array((3...22).reversed()).map(UInt64.init))
        XCTAssertEqual(Set(rows.map(\.captureID)).count, 20)
        let reopened = RecentHistoryStore(fileURL: url)
        let reopenedRows = try await reopened.snapshot().records
        XCTAssertEqual(reopenedRows, rows)
    }

    func testRevisionCASAndIndependentOutcomes() async throws {
        let (directory, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecentHistoryStore(fileURL: url)
        let id = UUID()
        let initial = try await store.admit(captureID: id, pipelineSequence: 8,
                                            detectionDate: Date(), displayName: "Shot.png")
        XCTAssertEqual(initial.revision, 0)
        let copied = try await store.update(captureID: id, expectedRevision: 0,
                                            change: RecentHistoryChange(copyOutcome: .success))
        XCTAssertEqual(copied.copyOutcome, .success)
        XCTAssertEqual(copied.saveOutcome, .pending)
        XCTAssertEqual(copied.revision, 1)
        do {
            _ = try await store.update(captureID: id, expectedRevision: 0,
                                       change: RecentHistoryChange(saveOutcome: .failure))
            XCTFail("stale pipeline result overwrote the current record")
        } catch RecentHistoryStoreError.staleRevision { }
        let failed = try await store.update(captureID: id, expectedRevision: 1,
                                            change: RecentHistoryChange(saveOutcome: .failure))
        XCTAssertEqual(failed.copyOutcome, .success)
        XCTAssertEqual(failed.saveOutcome, .failure)
        XCTAssertNil(failed.savedReference)
    }

    func testRemoveRejectsStaleRowRevisionAfterPipelineUpdate() async throws {
        let (directory, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecentHistoryStore(fileURL: url)
        let id = UUID()
        _ = try await store.admit(captureID: id, pipelineSequence: 1,
                                  detectionDate: Date(), displayName: "Shot.png")
        _ = try await store.update(captureID: id, expectedRevision: 0,
                                   change: RecentHistoryChange(copyOutcome: .success))
        do {
            try await store.remove(captureID: id, expectedRevision: 0)
            XCTFail("A stale missing-file action removed a newer capture revision")
        } catch RecentHistoryStoreError.staleRevision { }
        let remaining = try await store.snapshot().records
        XCTAssertEqual(remaining.first?.revision, 1)
    }

    func testSavedReferenceRequiresVerifiedSaveOutcome() async throws {
        let (directory, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecentHistoryStore(fileURL: url)
        let id = UUID()
        _ = try await store.admit(captureID: id, pipelineSequence: 1,
                                  detectionDate: Date(), displayName: "Shot.png")
        do {
            _ = try await store.update(captureID: id, expectedRevision: 0,
                                       change: RecentHistoryChange(saveOutcome: .success))
            XCTFail("success without verified saved copy reference")
        } catch RecentHistoryStoreError.invalidRecord { }
        let savedURL = directory.appendingPathComponent("saved.png")
        try Data("fixture".utf8).write(to: savedURL)
        let reference = try RecentFileReference.capture(at: savedURL, role: .savedCopy)
        let saved = try await store.update(captureID: id, expectedRevision: 0,
                                           change: RecentHistoryChange(saveOutcome: .success,
                                                                       savedReference: reference))
        XCTAssertEqual(saved.savedReference, reference)
        let failed = try await store.update(captureID: id, expectedRevision: 1,
                                            change: RecentHistoryChange(saveOutcome: .failure))
        XCTAssertNil(failed.savedReference)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
    }

    func testCorruptUnknownAndOversizedFilesArePreserved() async throws {
        let (directory, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (bytes, expected) in [
            (Data("{broken".utf8), RecentHistoryStoreError.unreadable),
            (Data("{\"schemaVersion\":99,\"records\":[]}".utf8), .unsupportedFormat),
            (Data(repeating: 65, count: RecentHistoryStore.maxFileBytes + 1), .tooLarge)
        ] {
            try bytes.write(to: url, options: .atomic)
            let store = RecentHistoryStore(fileURL: url)
            do {
                _ = try await store.admit(captureID: UUID(), pipelineSequence: 1,
                                          detectionDate: Date(), displayName: "Shot")
                XCTFail("invalid history was overwritten")
            } catch let error as RecentHistoryStoreError {
                XCTAssertEqual(error, expected)
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testInjectedWriteFailureKeepsFileAndRequiresFreshStore() async throws {
        let (directory, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecentHistoryStore(fileURL: url, writer: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        do {
            _ = try await store.admit(captureID: UUID(), pipelineSequence: 1,
                                      detectionDate: Date(), displayName: "Shot")
            XCTFail("writer failure must surface")
        } catch RecentHistoryStoreError.writeFailed { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        do {
            _ = try await store.snapshot()
            XCTFail("store must not continue from uncertain cached state")
        } catch RecentHistoryStoreError.writeFailed { }
    }

    func testSecondStoreCannotOverwriteNewerSnapshot() async throws {
        let (directory, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = RecentHistoryStore(fileURL: url)
        let second = RecentHistoryStore(fileURL: url)
        let initial = UUID()
        _ = try await first.admit(captureID: initial, pipelineSequence: 1,
                                  detectionDate: Date(), displayName: "one")
        _ = try await second.snapshot()
        let newer = UUID()
        _ = try await first.admit(captureID: newer, pipelineSequence: 2,
                                  detectionDate: Date(), displayName: "two")
        do {
            try await second.clear()
            XCTFail("stale actor erased another actor's write")
        } catch RecentHistoryStoreError.staleRevision { }
        let reopened = RecentHistoryStore(fileURL: url)
        let rows = try await reopened.snapshot().records
        XCTAssertEqual(Set(rows.map(\.captureID)), Set([initial, newer]))
    }

    func testClearAndRemoveAffectOnlyHistory() async throws {
        let (directory, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenshot = directory.appendingPathComponent("original.png")
        let bytes = Data("original".utf8)
        try bytes.write(to: screenshot)
        let store = RecentHistoryStore(fileURL: url)
        let first = UUID(), second = UUID()
        _ = try await store.admit(captureID: first, pipelineSequence: 1,
                                  detectionDate: Date(), displayName: "one")
        _ = try await store.admit(captureID: second, pipelineSequence: 2,
                                  detectionDate: Date(), displayName: "two")
        try await store.remove(captureID: first)
        let remaining = try await store.snapshot().records
        XCTAssertEqual(remaining.map(\.captureID), [second])
        try await store.clear()
        let cleared = try await store.snapshot().records
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertEqual(try Data(contentsOf: screenshot), bytes)
    }
}
