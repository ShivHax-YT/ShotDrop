import Darwin
import Foundation
import os
import XCTest
@testable import ShotDrop

final class BoundedAnnotationWriteTests: XCTestCase {
    func testPartialAndInterruptedWritesPreserveEntireRenderedPayload() throws {
        let fixture = try AnnotationWriteFixture()
        defer { fixture.cleanUp() }
        let payload = Data((0..<3001).map { UInt8(truncatingIfNeeded: $0 &* 17) })
        let writes = OSAllocatedUnfairLock(initialState: 0)
        let writer = BoundedScreenshotCopy(write: { descriptor, bytes, count, offset in
            if writes.withLock({ $0 += 1; return $0 }) == 1 { errno = EINTR; return -1 }
            return pwrite(descriptor, bytes, min(count, 7), offset)
        })
        let token = UUID()
        try writer.writeRendered(payload, stageFD: fixture.descriptor, outputToken: token, baseline: fixture.baseline)
        XCTAssertEqual(try Data(contentsOf: fixture.stage), payload)
        XCTAssertGreaterThan(writes.withLock { $0 }, 400)
        XCTAssertEqual(try BoundedScreenshotCopy.attributes(fixture.descriptor),
                       fixture.baseline.expectedStageAttributes(sourceAttributes: [:], outputToken: token))
    }

    func testZeroProgressAndDiskFullStopWithoutMarkerOrRetryLoop() throws {
        for diskFull in [false, true] {
            let fixture = try AnnotationWriteFixture()
            defer { fixture.cleanUp() }
            let writes = OSAllocatedUnfairLock(initialState: 0)
            let writer = BoundedScreenshotCopy(write: { _, _, _, _ in
                writes.withLock { $0 += 1 }
                if diskFull { errno = ENOSPC; return -1 }
                return 0
            })
            XCTAssertThrowsError(try writer.writeRendered(Data(repeating: 1, count: 16),
                stageFD: fixture.descriptor, outputToken: UUID(), baseline: fixture.baseline)) {
                XCTAssertEqual(($0 as? ScreenshotCopyFailure)?.code, .ioFailure)
            }
            XCTAssertEqual(writes.withLock { $0 }, 1)
            XCTAssertEqual(try Data(contentsOf: fixture.stage), Data())
            XCTAssertEqual(try BoundedScreenshotCopy.attributes(fixture.descriptor), fixture.baseline.attributeHashes)
        }
    }

    func testCancellationAfterFirstPartialWriteStopsBeforeNextWriteAndMarker() async throws {
        let fixture = try AnnotationWriteFixture()
        defer { fixture.cleanUp() }
        let writes = OSAllocatedUnfairLock(initialState: 0)
        let payload = Data(repeating: 0x42, count: 512)
        let task = Task.detached {
            let writer = BoundedScreenshotCopy(write: { descriptor, bytes, count, offset in
                writes.withLock { $0 += 1 }
                let result = pwrite(descriptor, bytes, min(count, 7), offset)
                // The first completed write is the deterministic cancellation boundary.
                withUnsafeCurrentTask { $0?.cancel() }
                return result
            })
            try writer.writeRendered(payload, stageFD: fixture.descriptor, outputToken: UUID(), baseline: fixture.baseline)
        }
        do { try await task.value; XCTFail("Expected cancellation after partial write") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(writes.withLock { $0 }, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.stage), Data(payload.prefix(7)))
        XCTAssertEqual(try BoundedScreenshotCopy.attributes(fixture.descriptor), fixture.baseline.attributeHashes)
    }

    func testPayloadAndMarkerMetadataLimitsRejectBeforeAnyWrite() throws {
        let fixture = try AnnotationWriteFixture()
        defer { fixture.cleanUp() }
        let writes = OSAllocatedUnfairLock(initialState: 0)
        let payload = Data(repeating: 1, count: 8)
        let markerBytes = ScreenshotOutputMarker.attributeName.utf8.count + 1 + 36
        for configuration in [(7, Int.max), (8, fixture.baseline.chargedBytes + markerBytes - 1)] {
            let writer = BoundedScreenshotCopy(payloadLimit: configuration.0, metadataLimit: configuration.1,
                write: { descriptor, bytes, count, offset in
                    writes.withLock { $0 += 1 }
                    return pwrite(descriptor, bytes, count, offset)
                })
            XCTAssertThrowsError(try writer.writeRendered(payload, stageFD: fixture.descriptor,
                outputToken: UUID(), baseline: fixture.baseline)) {
                XCTAssertEqual(($0 as? ScreenshotCopyFailure)?.code, .stagingPaused)
            }
        }
        XCTAssertEqual(writes.withLock { $0 }, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.stage), Data())
        XCTAssertEqual(try BoundedScreenshotCopy.attributes(fixture.descriptor), fixture.baseline.attributeHashes)
        try BoundedScreenshotCopy(payloadLimit: 8, metadataLimit: fixture.baseline.chargedBytes + markerBytes)
            .writeRendered(payload, stageFD: fixture.descriptor, outputToken: UUID(), baseline: fixture.baseline)
        XCTAssertEqual(try Data(contentsOf: fixture.stage), payload)
    }
}

private struct AnnotationWriteFixture: Sendable {
    let root: URL
    let stage: URL
    let descriptor: Int32
    let baseline: ScreenshotStagingBaseline

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ShotDropAnnotationWrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        stage = root.appendingPathComponent("stage")
        descriptor = open(stage.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        baseline = try ScreenshotStagingBaseline.capture(descriptor)
    }
    func cleanUp() {
        close(descriptor)
        try? FileManager.default.removeItem(at: root)
    }
}
