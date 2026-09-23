import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShotDrop

@MainActor
final class RecentPreviewCacheTests: XCTestCase {
    func testTemporaryPNGDecodesOffMainAndNeverExceeds512Pixels() async throws {
        let png = try previewPNG(width: 1_200, height: 800)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("synthetic.png")
        try png.write(to: file)
        let key = try previewKey(pixel: 9_999)
        let cache = RecentPreviewCache()
        let thread = PreviewLoadProbe()

        let image = try await cache.thumbnail(for: key) {
            thread.record()
            return try Data(contentsOf: file)
        }

        XCTAssertEqual(key.maxPixel, 512)
        XCTAssertEqual(image.width, 512)
        XCTAssertLessThanOrEqual(image.height, 512)
        XCTAssertEqual(image.rgba.count, image.width * image.height * 4)
        XCTAssertEqual(image.bytesPerRow, image.width * 4)
        XCTAssertFalse(thread.wasMainThread)
        let stats = await cache.statistics()
        XCTAssertEqual(stats.cachedBytes, image.rgba.count)
    }

    func testMalformedAndOversizedInputFailDistinctlyWithoutCaching() async throws {
        let cache = RecentPreviewCache()
        let key = try previewKey()
        do {
            _ = try await cache.thumbnail(for: key) { Data("not an image".utf8) }
            XCTFail("Malformed bytes must not become a preview")
        } catch { XCTAssertEqual(error as? RecentPreviewError, .decodeFailed) }
        do {
            _ = try await cache.thumbnail(for: key) {
                Data(count: RecentPreviewCache.maximumEncodedBytes + 1)
            }
            XCTFail("Oversized encoded data must be rejected")
        } catch { XCTAssertEqual(error as? RecentPreviewError, .inputTooLarge) }
        let stats = await cache.statistics()
        XCTAssertEqual(stats.cachedImages, 0)
    }

    func testLoaderFailureDoesNotBecomeDecodeFailure() async throws {
        let cache = RecentPreviewCache()
        let key = try previewKey()
        do {
            _ = try await cache.thumbnail(for: key) { throw RecentFileReferenceError.unavailable(.replaced) }
            XCTFail("An invalidated source must remain unavailable")
        } catch {
            XCTAssertEqual(error as? RecentFileReferenceError, .unavailable(.replaced))
        }
    }

    func testTwoWorkerLimitIncludesLoaderAndCannotBeRaisedByCaller() async throws {
        let png = try previewPNG(width: 20, height: 12)
        let started = expectation(description: "Two worker slots started")
        started.expectedFulfillmentCount = 2
        let gate = PreviewWorkerGate(onStart: { count in if count <= 2 { started.fulfill() } })
        defer { gate.release() }
        let cache = RecentPreviewCache(maxConcurrentDecodes: 99)
        let keys = try (0..<5).map { _ in try previewKey() }
        let requests = keys.map { key in
            Task { try await cache.thumbnail(for: key) { gate.wait(); return png } }
        }
        await fulfillment(of: [started], timeout: 3)
        let busy = await cache.statistics()
        XCTAssertEqual(busy.runningJobs, 2)
        XCTAssertEqual(gate.maximumSimultaneous, 2)
        gate.release()
        for request in requests { _ = try await request.value }
        XCTAssertLessThanOrEqual(gate.maximumSimultaneous, 2)
    }

    func testCancelledQueuedRowNeverLoadsItsFile() async throws {
        let png = try previewPNG(width: 8, height: 8)
        let started = expectation(description: "First loader occupies the only slot")
        let gate = PreviewWorkerGate(onStart: { _ in started.fulfill() })
        defer { gate.release() }
        let cache = RecentPreviewCache()
        let firstKey = try previewKey()
        let nextKey = try previewKey()
        let first = Task { try await cache.thumbnail(for: firstKey) { gate.wait(); return png } }
        await fulfillment(of: [started], timeout: 3)
        let probe = PreviewLoadProbe()
        let next = Task { try await cache.thumbnail(for: nextKey) { probe.record(); return png } }
        next.cancel()
        do { _ = try await next.value; XCTFail("Cancelled rows must finish as cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(probe.count, 0)
        gate.release()
        _ = try await first.value
    }

    func testClearCancelsRunningGenerationWithoutReleasingItsSlotEarly() async throws {
        let png = try previewPNG(width: 8, height: 8)
        let started = expectation(description: "Old generation has entered its loader")
        let gate = PreviewWorkerGate(onStart: { _ in started.fulfill() })
        defer { gate.release() }
        let cache = RecentPreviewCache()
        let key = try previewKey()
        let old = Task { try await cache.thumbnail(for: key) { gate.wait(); return png } }
        await fulfillment(of: [started], timeout: 3)
        await cache.clear()
        do { _ = try await old.value; XCTFail("Clear must invalidate waiting callers") }
        catch { XCTAssertTrue(error is CancellationError) }
        let whileBlocked = await cache.statistics()
        XCTAssertEqual(whileBlocked.runningJobs, 1, "An uncancellable decoder must keep its worker slot")
        XCTAssertEqual(whileBlocked.cachedImages, 0)
        gate.release()
        _ = try await cache.thumbnail(for: key) { png }
        let finished = await cache.statistics()
        XCTAssertEqual(finished.cachedImages, 1)
        XCTAssertEqual(finished.runningJobs, 0)
    }

    func testLRUEvictsLeastRecentlyUsedImageWithinDecodedByteBudget() async throws {
        let png = try previewPNG(width: 8, height: 8)
        let cache = RecentPreviewCache(cacheBudgetBytes: 512)
        let a = try previewKey()
        let b = try previewKey()
        let c = try previewKey()
        let bLoads = PreviewLoadProbe()
        _ = try await cache.thumbnail(for: a) { png }
        _ = try await cache.thumbnail(for: b) { bLoads.record(); return png }
        _ = try await cache.thumbnail(for: a) { throw RecentPreviewError.decodeFailed }
        _ = try await cache.thumbnail(for: c) { png }
        var stats = await cache.statistics()
        XCTAssertEqual(stats.cachedImages, 2)
        XCTAssertEqual(stats.cachedBytes, 512)
        _ = try await cache.thumbnail(for: b) { bLoads.record(); return png }
        XCTAssertEqual(bLoads.count, 2, "B was older than A and must be reloaded")
        stats = await cache.statistics()
        XCTAssertLessThanOrEqual(stats.cachedBytes, 512)
    }

    func testCacheBudgetCannotExceedEightMiBEvenWithLargerRequestedBudget() async throws {
        let png = try previewPNG(width: 512, height: 512)
        let cache = RecentPreviewCache(cacheBudgetBytes: 99 * 1_024 * 1_024)
        for _ in 0..<9 {
            let key = try previewKey(pixel: 512)
            _ = try await cache.thumbnail(for: key) { png }
        }
        let stats = await cache.statistics()
        XCTAssertEqual(stats.cachedBytes, RecentPreviewCache.maximumCacheBytes)
        XCTAssertEqual(stats.cachedImages, 8)
    }

    func testSameBytesAtReplacedPersistentIdentityInvalidateOldCache() async throws {
        let png = try previewPNG(width: 8, height: 8)
        let id = UUID()
        let original = try previewKey(captureID: id, fileID: 20)
        let replaced = try previewKey(captureID: id, fileID: 21)
        let cache = RecentPreviewCache()
        _ = try await cache.thumbnail(for: original) { png }
        let replacementLoads = PreviewLoadProbe()
        _ = try await cache.thumbnail(for: replaced) { replacementLoads.record(); return png }
        XCTAssertEqual(replacementLoads.count, 1)
        let stats = await cache.statistics()
        XCTAssertEqual(stats.cachedImages, 1)
        XCTAssertEqual(stats.cachedBytes, 256)
    }

    func testSourceAndSavedCopyRolesDoNotShareCachedPixels() async throws {
        let png = try previewPNG(width: 8, height: 8)
        let id = UUID()
        let source = try previewKey(captureID: id, role: .source)
        let saved = try previewKey(captureID: id, role: .savedCopy)
        let cache = RecentPreviewCache()
        let probe = PreviewLoadProbe()
        _ = try await cache.thumbnail(for: source) { png }
        _ = try await cache.thumbnail(for: saved) { probe.record(); return png }
        XCTAssertEqual(probe.count, 1)
        let stats = await cache.statistics()
        XCTAssertEqual(stats.cachedImages, 2)
        await cache.invalidate(captureID: id)
        let removed = await cache.statistics()
        XCTAssertEqual(removed.cachedImages, 0)
    }

    func testPanelCloseAndMemoryPressureDiscardDecodedPixels() async throws {
        let png = try previewPNG(width: 8, height: 8)
        let key = try previewKey()
        let cache = RecentPreviewCache()
        _ = try await cache.thumbnail(for: key) { png }
        await cache.panelDidClose()
        let closed = await cache.statistics()
        XCTAssertEqual(closed.cachedBytes, 0)
        _ = try await cache.thumbnail(for: key) { png }
        await cache.handleMemoryPressure()
        let pressured = await cache.statistics()
        XCTAssertEqual(pressured.cachedBytes, 0)
    }
}

private func previewKey(captureID: UUID = UUID(), role: RecentFileRole = .savedCopy,
                        fileID: UInt64 = 1, pixel: Int = 112) throws -> RecentPreviewKey {
    let fields: [String: Any] = [
        "bookmarkData": Data([1]).base64EncodedString(), "lastKnownPath": "/fixture/preview.png",
        "role": role.rawValue, "volumeUUID": "00000000-0000-0000-0000-000000000001",
        "persistentFileID": fileID, "birthSeconds": 10, "birthNanoseconds": 20,
        "byteCount": 1, "sha256": String(repeating: "a", count: 64)
    ]
    let reference = try JSONDecoder().decode(RecentFileReference.self,
                                            from: JSONSerialization.data(withJSONObject: fields))
    return RecentPreviewKey(captureID: captureID, reference: reference, maxPixel: pixel)
}

private func previewPNG(width: Int, height: Int) throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}

/// Test-only synchronization: all mutable state is guarded by the condition or lock.
private final class PreviewWorkerGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var open = false
    private var active = 0
    private var started = 0
    private var maximum = 0
    private let onStart: @Sendable (Int) -> Void

    init(onStart: @escaping @Sendable (Int) -> Void) { self.onStart = onStart }

    func wait() {
        condition.lock()
        active += 1
        started += 1
        maximum = max(maximum, active)
        onStart(started)
        let deadline = Date().addingTimeInterval(5)
        while !open && condition.wait(until: deadline) {}
        active -= 1
        condition.unlock()
    }

    func release() {
        condition.lock()
        open = true
        condition.broadcast()
        condition.unlock()
    }

    var maximumSimultaneous: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximum
    }
}

private final class PreviewLoadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var main = false
    func record() { lock.withLock { calls += 1; main = main || Thread.isMainThread } }
    var count: Int { lock.withLock { calls } }
    var wasMainThread: Bool { lock.withLock { main } }
}
