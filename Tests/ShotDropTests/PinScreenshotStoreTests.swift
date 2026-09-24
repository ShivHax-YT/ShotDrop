import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShotDrop

final class PinScreenshotStoreTests: XCTestCase, @unchecked Sendable {
    func testDuplicateCapacityAndDistinctRevisions() async throws {
        let identity = try identity()
        let store = PinScreenshotStore(decoder: Self.snapshot)
        let token = try opened(try await store.admit(identity))
        _ = try await store.snapshot(for: token)
        let second = PinScreenshotIdentity(captureID: identity.captureID, revision: 2, reference: identity.reference)
        _ = try opened(try await store.admit(second))
        _ = try opened(try await store.admit(try self.identity()))
        let duplicate = try await store.admit(identity)
        let fourth = try await store.admit(try self.identity())
        XCTAssertEqual(duplicate, .existing(token))
        XCTAssertEqual(fourth, .full)
        await store.closeAll()
    }

    func testClosingBlockedDecoderRetainsCapacityAndCannotResurrect() async throws {
        let started = expectation(description: "Native worker entered")
        let gate = DispatchSemaphore(value: 0)
        let firstInvocation = PinDecoderFirstInvocation()
        defer { gate.signal() }
        let first = try identity()
        let store = PinScreenshotStore { identity in
            if identity == first, firstInvocation.take() {
                started.fulfill()
                guard gate.wait(timeout: .now() + 10) == .success else {
                    throw PinScreenshotFailure.closed
                }
            }
            return Self.snapshot(identity)
        }
        let firstToken = try opened(try await store.admit(first))
        await fulfillment(of: [started], timeout: 3)
        let secondToken = try opened(try await store.admit(try identity()))
        _ = try opened(try await store.admit(try identity()))
        await store.close(firstToken)
        let closing = try await store.admit(first)
        let full = try await store.admit(try identity())
        let stats = await store.statistics()
        XCTAssertEqual(closing, .closing(firstToken))
        XCTAssertEqual(full, .full)
        XCTAssertEqual(stats.runningJobs, 1)
        XCTAssertEqual(stats.sessions, 3)
        gate.signal()
        _ = try await store.snapshot(for: secondToken) // proves the old worker actually drained
        do { _ = try await store.snapshot(for: firstToken); XCTFail("Closed pin resurrected") }
        catch { XCTAssertEqual(error as? PinScreenshotFailure, .closed) }
        let after = await store.statistics()
        XCTAssertEqual(after.sessions, 2)
        let retry = try opened(try await store.admit(first))
        _ = try await store.snapshot(for: retry)
        await store.closeAll()
    }

    func testBudgetFailureNeverEvictsExistingSnapshotAndCloseReleasesBytes() async throws {
        let store = PinScreenshotStore(cacheBudgetBytes: 4, decoder: Self.snapshot)
        let first = try opened(try await store.admit(try identity()))
        let saved = try await store.snapshot(for: first)
        let second = try opened(try await store.admit(try identity()))
        do { _ = try await store.snapshot(for: second); XCTFail("Exceeded budget") }
        catch { XCTAssertEqual(error as? PinScreenshotFailure, .budgetExceeded) }
        let retained = try await store.snapshot(for: first)
        XCTAssertEqual(retained.identity, saved.identity)
        XCTAssertEqual(retained.image.rgba, saved.image.rgba)
        await store.close(first)
        let stats = await store.statistics()
        XCTAssertEqual(stats.cachedBytes, 0)
        await store.closeAll()
    }

    func testMismatchedDecoderIdentityDoesNotRetarget() async throws {
        let wrong = try identity()
        let store = PinScreenshotStore { _ in Self.snapshot(wrong) }
        let token = try opened(try await store.admit(try identity()))
        do { _ = try await store.snapshot(for: token); XCTFail("Retargeted") }
        catch { XCTAssertEqual(error as? PinScreenshotFailure, .unavailable) }
        let stats = await store.statistics()
        XCTAssertEqual(stats.cachedBytes, 0)
        await store.closeAll()
    }

    func testPixelBudgetRejectsInvalidOrOverflowingDimensions() throws {
        XCTAssertEqual(try PinScreenshotStore.byteCount(width: 2048, height: 2048), 16 * 1024 * 1024)
        for dimensions in [(0, 1), (1, -1), (Int.max, Int.max), (2049, 1)] {
            XCTAssertThrowsError(try PinScreenshotStore.byteCount(width: dimensions.0, height: dimensions.1))
        }
    }

    func testVerifiedDecodeIsReducedAndRemainsImmutableAfterReplacement() async throws {
        let directory = (try physicalTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pin.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 2050, height: 2,
            bitsPerComponent: 8, bytesPerRow: 2050 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2050, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (bytes as Data).write(to: url)
        let reference = try RecentFileReference.capture(at: url, role: .savedCopy)
        let identity = PinScreenshotIdentity(captureID: UUID(), revision: 1, reference: reference)
        let store = PinScreenshotStore()
        let token = try opened(try await store.admit(identity))
        let snapshot = try await store.snapshot(for: token)
        XCTAssertEqual(snapshot.sourceWidth, 2050)
        XCTAssertEqual(snapshot.sourceHeight, 2)
        XCTAssertEqual(snapshot.image.width, 2048)
        XCTAssertTrue(snapshot.isReduced)
        XCTAssertEqual(snapshot.image.rgba.count, snapshot.image.bytesPerRow * snapshot.image.height)
        try Data("replacement".utf8).write(to: url, options: .atomic)
        let retained = try await store.snapshot(for: token)
        XCTAssertEqual(retained.image.rgba, snapshot.image.rgba)
        let changed = PinScreenshotIdentity(captureID: UUID(), revision: 1, reference: reference)
        let changedToken = try opened(try await store.admit(changed))
        do { _ = try await store.snapshot(for: changedToken); XCTFail("Accepted replaced source") }
        catch { XCTAssertEqual(error as? PinScreenshotFailure, .unavailable) }
        await store.closeAll()
    }

    func testRepeatedRealDecodeAndCloseCyclesReleaseCacheWithoutChangingSavedFile() async throws {
        let directory = try physicalTemporaryDirectory().appendingPathComponent("pin-cycles-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("saved.png")
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1024, height: 512,
            bitsPerComponent: 8, bytesPerRow: 4096, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 0.5, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 1024, height: 512))
        let encoded = NSMutableData()
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, try XCTUnwrap(bitmap.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
        try (encoded as Data).write(to: url)
        let reference = try RecentFileReference.capture(at: url, role: .savedCopy)
        let identities = (0..<3).map { _ in PinScreenshotIdentity(captureID: UUID(), revision: 1, reference: reference) }
        let store = PinScreenshotStore()
        let start = ContinuousClock.now
        for _ in 0..<20 {
            for identity in identities {
                let token = try opened(try await store.admit(identity))
                let snapshot = try await store.snapshot(for: token)
                XCTAssertEqual(snapshot.image.rgba.count, 1024 * 512 * 4)
                let duplicate = try await store.admit(identity)
                XCTAssertEqual(duplicate, .existing(token))
            }
            let full = await store.statistics()
            XCTAssertEqual(full.sessions, 3)
            XCTAssertEqual(full.cachedBytes, 3 * 1024 * 512 * 4)
            XCTAssertEqual(full.runningJobs, 0)
            await store.closeAll()
            let empty = await store.statistics()
            XCTAssertEqual(empty.sessions, 0)
            XCTAssertEqual(empty.cachedBytes, 0)
            XCTAssertEqual(empty.runningJobs, 0)
        }
        XCTAssertEqual(try Data(contentsOf: url), encoded as Data)
        XCTAssertEqual(try RecentFileReference.capture(at: url, role: .savedCopy).sha256, reference.sha256)
        print("PIN_STORE_CYCLES cycles=20 native_decodes=60 retained_peak_bytes=6291456 retained_after_close=0 elapsed=\(start.duration(to: .now))")
    }

    private static func snapshot(_ identity: PinScreenshotIdentity) -> PinScreenshotSnapshot {
        PinScreenshotSnapshot(identity: identity,
            image: RecentPreviewImage(width: 1, height: 1, bytesPerRow: 4, rgba: Data([0, 0, 0, 255])),
            sourceWidth: 1, sourceHeight: 1)
    }

    private func opened(_ admission: PinScreenshotStore.Admission) throws -> UUID {
        guard case .opened(let token) = admission else {
            XCTFail("Expected opened: \(admission)")
            throw PinScreenshotFailure.unavailable
        }
        return token
    }

    private func identity() throws -> PinScreenshotIdentity {
        let data = try JSONSerialization.data(withJSONObject: [
            "bookmarkData": Data([1]).base64EncodedString(), "lastKnownPath": "/source.png",
            "role": "savedCopy", "volumeUUID": UUID().uuidString,
            "persistentFileID": 1, "birthSeconds": 1, "birthNanoseconds": 0,
            "byteCount": 1, "sha256": String(repeating: "a", count: 64)
        ])
        return PinScreenshotIdentity(captureID: UUID(), revision: 1,
            reference: try JSONDecoder().decode(RecentFileReference.self, from: data))
    }
    /// Foundation may re-abbreviate /private/var to /var; the resolver correctly
    /// rejects that symlink ancestor with O_NOFOLLOW_ANY. Use the physical path.
    private func physicalTemporaryDirectory() throws -> URL {
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

}

private final class PinDecoderFirstInvocation: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard available else { return false }
        available = false
        return true
    }
}
