import Darwin
import Foundation
import XCTest
@testable import ShotDrop

@MainActor
final class RecentRowValidationTests: XCTestCase {
    func testNearLimitFileHasOneReadAndHashPerValidationIncludingCacheHit() async throws {
        let fixture = try RowValidationFixture(byteCount: RecentPreviewCache.maximumEncodedBytes)
        defer { fixture.remove() }
        let counts = RowReadCounts()
        let cache = RecentPreviewCache()
        let id = UUID()
        for _ in 0..<2 {
            let result = try await cache.validateRow(captureID: id, reference: fixture.reference) { reference in
                counts.begin(); defer { counts.end() }
                return RecentFileResolver(onRead: counts.read, onHash: counts.hash).resolve(reference)
            }
            guard case .available(let image, _) = result else { return XCTFail("Verified row unavailable") }
            XCTAssertNotNil(image)
            XCTAssertLessThanOrEqual(try XCTUnwrap(image).width, 112)
        }
        XCTAssertEqual(counts.readBytes, 2 * RecentPreviewCache.maximumEncodedBytes)
        XCTAssertEqual(counts.hashBytes, counts.readBytes)
        XCTAssertEqual(counts.hashCalls, 2, "Thumbnail decode must reuse the verified snapshot")
        XCTAssertEqual(counts.calls, 2, "A cached thumbnail never skips fresh file validation")
        XCTAssertFalse(counts.usedMainThread)
        let stats = await cache.statistics()
        XCTAssertEqual(stats.cachedImages, 1)
        XCTAssertLessThanOrEqual(stats.cachedBytes, RecentPreviewCache.maximumCacheBytes)
    }

    func testTwentyVisibleRowsShareAtMostTwoValidationAndDecodeWorkers() async throws {
        let fixture = try RowValidationFixture(byteCount: 1024 * 1024)
        defer { fixture.remove() }
        let started = expectation(description: "Only two initial workers")
        started.expectedFulfillmentCount = 2
        let gate = RowValidationGate()
        defer { gate.release() }
        let counts = RowReadCounts()
        let cache = RecentPreviewCache(maxConcurrentDecodes: 99)
        let requests = (0..<20).map { _ in
            Task {
                try await cache.validateRow(captureID: UUID(), reference: fixture.reference) { reference in
                    let number = counts.begin(); defer { counts.end() }
                    if number <= 2 { started.fulfill() }
                    gate.wait()
                    return RecentFileResolver(onRead: counts.read, onHash: counts.hash).resolve(reference)
                }
            }
        }
        await fulfillment(of: [started], timeout: 5)
        let busy = await cache.statistics()
        XCTAssertEqual(busy.runningJobs, 2)
        XCTAssertEqual(counts.calls, 2, "Queued rows must not read a full encoded image")
        XCTAssertEqual(counts.readBytes, 0)
        gate.release()
        for request in requests { _ = try await request.value }
        XCTAssertEqual(counts.calls, 20)
        XCTAssertEqual(counts.hashCalls, 20)
        XCTAssertEqual(counts.readBytes, 20 * 1024 * 1024)
        XCTAssertLessThanOrEqual(counts.maximumActive, 2)
        let stats = await cache.statistics()
        XCTAssertEqual(stats.runningJobs, 0)
        XCTAssertEqual(stats.pendingJobs, 0)
        XCTAssertLessThanOrEqual(stats.cachedBytes, RecentPreviewCache.maximumCacheBytes)
    }

    func testCancelDuringNearLimitReadStopsBeforeHashAndRetainsSlotUntilReturn() async throws {
        let fixture = try RowValidationFixture(byteCount: RecentPreviewCache.maximumEncodedBytes)
        defer { fixture.remove() }
        let firstChunk = expectation(description: "First descriptor read completed")
        let gate = RowValidationGate(); defer { gate.release() }
        let counts = RowReadCounts()
        let cache = RecentPreviewCache()
        let request = Task {
            try await cache.validateRow(captureID: UUID(), reference: fixture.reference) { reference in
                RecentFileResolver(onRead: { bytes in
                    counts.read(bytes)
                    if counts.readBytes == 64 * 1024 { firstChunk.fulfill(); gate.wait() }
                }, onHash: counts.hash).resolve(reference)
            }
        }
        await fulfillment(of: [firstChunk], timeout: 5)
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled snapshot published") }
        catch { XCTAssertTrue(error is CancellationError) }
        let blocked = await cache.statistics()
        XCTAssertEqual(blocked.runningJobs, 1)
        XCTAssertEqual(blocked.cachedBytes, 0)
        gate.release()
        // A new admitted job is also a barrier for the previous worker's actual exit.
        _ = try await cache.validateRow(captureID: UUID(), reference: fixture.reference)
        XCTAssertEqual(counts.readBytes, 64 * 1024)
        XCTAssertEqual(counts.hashCalls, 0)
        let finished = await cache.statistics()
        XCTAssertEqual(finished.runningJobs, 0)
    }

    func testPanelCloseAndQueuedCancellationNeverPublishOldGeneration() async throws {
        let fixture = try RowValidationFixture()
        defer { fixture.remove() }
        let started = expectation(description: "Old row holds slot")
        let gate = RowValidationGate(); defer { gate.release() }
        let cache = RecentPreviewCache()
        let old = Task {
            try await cache.validateRow(captureID: UUID(), reference: fixture.reference) { reference in
                started.fulfill(); gate.wait()
                return RecentFileResolver().resolve(reference)
            }
        }
        await fulfillment(of: [started], timeout: 5)
        let queuedCounts = RowReadCounts()
        let queued = Task {
            try await cache.validateRow(captureID: UUID(), reference: fixture.reference) { reference in
                queuedCounts.begin(); defer { queuedCounts.end() }
                return RecentFileResolver().resolve(reference)
            }
        }
        queued.cancel()
        do { _ = try await queued.value; XCTFail("Cancelled queue entry ran") }
        catch { XCTAssertTrue(error is CancellationError) }
        await cache.panelDidClose()
        do { _ = try await old.value; XCTFail("Closed panel published old row") }
        catch { XCTAssertTrue(error is CancellationError) }
        let closed = await cache.statistics()
        XCTAssertEqual(closed.runningJobs, 1)
        XCTAssertEqual(closed.pendingJobs, 0)
        XCTAssertEqual(closed.cachedBytes, 0)
        XCTAssertEqual(queuedCounts.calls, 0)
        gate.release()
        _ = try await cache.validateRow(captureID: UUID(), reference: fixture.reference)
        let reopened = await cache.statistics()
        XCTAssertEqual(reopened.runningJobs, 0)
        XCTAssertEqual(reopened.cachedImages, 1, "Only the new generation may cache its result")
    }

    func testCachedPreviewCannotHideContentOrIdentityReplacement() async throws {
        for sameBytes in [false, true] {
            let fixture = try RowValidationFixture(); defer { fixture.remove() }
            let cache = RecentPreviewCache(); let id = UUID()
            _ = try await cache.validateRow(captureID: id, reference: fixture.reference)
            if sameBytes {
                try FileManager.default.moveItem(at: fixture.file, to: fixture.root.appendingPathComponent("old.png"))
                try fixture.png.write(to: fixture.file)
            } else {
                try Data(repeating: 42, count: fixture.png.count).write(to: fixture.file)
            }
            let result = try await cache.validateRow(captureID: id, reference: fixture.reference)
            guard case .unavailable(.replaced) = result else { return XCTFail("Cached row accepted a replacement") }
            let stats = await cache.statistics()
            XCTAssertEqual(stats.cachedImages, 0)
        }
    }

    func testDecodeFailureKeepsVerifiedRowAndMovedBookmarkRefreshIsReturned() async throws {
        let fixture = try RowValidationFixture(); defer { fixture.remove() }
        try Data("not an image".utf8).write(to: fixture.file)
        let reference = try RecentFileReference.capture(at: fixture.file, role: .savedCopy)
        let moved = fixture.root.appendingPathComponent("moved.png")
        try FileManager.default.moveItem(at: fixture.file, to: moved)
        let result = try await RecentPreviewCache().validateRow(captureID: UUID(), reference: reference) { reference in
            RecentFileResolver(resolveBookmark: { _ in (moved, true) }).resolve(reference)
        }
        guard case .available(let preview, let refreshed) = result else { return XCTFail("Verified row lost") }
        XCTAssertNil(preview)
        XCTAssertEqual(refreshed?.lastKnownPath, moved.path)
        XCTAssertEqual(refreshed?.sha256, reference.sha256)
    }
}

private struct RowValidationFixture: Sendable {
    let root: URL
    let file: URL
    let png: Data
    let reference: RecentFileReference

    init(byteCount: Int? = nil) throws {
        guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw POSIXError(.EIO) }
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("ShotDrop-RowValidation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        file = root.appendingPathComponent("saved.png")
        png = try ClipboardTestFixture.imageData(type: .png)
        try png.write(to: file)
        if let byteCount {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(byteCount))
        }
        reference = try RecentFileReference.capture(at: file, role: .savedCopy)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// Test-only counters: every mutation/read is protected by the lock.
private final class RowReadCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0, active = 0, maximum = 0, bytes = 0, hashed = 0, hashes = 0
    private var main = false
    @discardableResult func begin() -> Int {
        lock.withLock { count += 1; active += 1; maximum = max(maximum, active); main = main || Thread.isMainThread; return count }
    }
    func end() { lock.withLock { active -= 1 } }
    func read(_ count: Int) { lock.withLock { bytes += count } }
    func hash(_ count: Int) { lock.withLock { hashed += count; hashes += 1 } }
    var calls: Int { lock.withLock { count } }
    var readBytes: Int { lock.withLock { bytes } }
    var hashBytes: Int { lock.withLock { hashed } }
    var hashCalls: Int { lock.withLock { hashes } }
    var maximumActive: Int { lock.withLock { maximum } }
    var usedMainThread: Bool { lock.withLock { main } }
}

private final class RowValidationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var open = false
    func wait() {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while !open && condition.wait(until: deadline) {}
    }
    func release() {
        condition.lock(); open = true; condition.broadcast(); condition.unlock()
    }
}
