import CryptoKit
import Darwin
import Foundation
import os
import XCTest
@testable import ShotDrop

final class BoundedScreenshotCopyTests: XCTestCase {
    func testCopiesPayloadAndAttributesWithFreshMarkerAndPrivateMode() throws {
        let fixture = try Fixture(payload: Data((0..<8_193).map { UInt8(truncatingIfNeeded: $0) }))
        defer { fixture.cleanUp() }
        let name = "com.macfleet.shotdrop.copy-test"
        let value = Data("preserved metadata".utf8)
        try setAttribute(name, value, descriptor: fixture.sourceFD)
        XCTAssertEqual(fchmod(fixture.sourceFD, 0o444), 0)
        let token = UUID()
        let sourceAttributes = try BoundedScreenshotCopy.attributes(fixture.sourceFD)
        try BoundedScreenshotCopy().copy(sourceFD: fixture.sourceFD, stageFD: fixture.stageFD, outputToken: token, baseline: fixture.baseline)
        XCTAssertEqual(try Data(contentsOf: fixture.stage), fixture.payload)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.payload)
        var info = stat()
        XCTAssertEqual(fstat(fixture.stageFD, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o600)
        let attributes = try BoundedScreenshotCopy.attributes(fixture.stageFD)
        XCTAssertEqual(attributes, fixture.baseline.expectedStageAttributes(sourceAttributes: sourceAttributes, outputToken: token))
        XCTAssertEqual(attributes[name], Data(SHA256.hash(data: value)))
        XCTAssertEqual(try BoundedScreenshotCopy.attributes(fixture.sourceFD), sourceAttributes)
        try fixture.baseline.verify(fixture.stageFD)
    }

    func testPartialWritesAndInterruptedReadsAndWritesStillCopyAllBytes() throws {
        let fixture = try Fixture(payload: Data((0..<3_001).map { UInt8(truncatingIfNeeded: $0 &* 17) }))
        defer { fixture.cleanUp() }
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let writes = OSAllocatedUnfairLock(initialState: 0)
        let copier = BoundedScreenshotCopy(read: { descriptor, buffer, count, offset in
            if reads.withLock({ $0 += 1; return $0 }) == 1 { errno = EINTR; return -1 }
            return pread(descriptor, buffer, min(count, 127), offset)
        }, write: { descriptor, buffer, count, offset in
            if writes.withLock({ $0 += 1; return $0 }) == 1 { errno = EINTR; return -1 }
            return pwrite(descriptor, buffer, min(count, 7), offset)
        })
        try copier.copy(sourceFD: fixture.sourceFD, stageFD: fixture.stageFD, outputToken: UUID(), baseline: fixture.baseline)
        XCTAssertEqual(try Data(contentsOf: fixture.stage), fixture.payload)
        XCTAssertGreaterThan(writes.withLock { $0 }, 400)
        XCTAssertGreaterThan(reads.withLock { $0 }, 20)
    }

    func testPayloadAtLowerLimitReadsThroughEOFAndSucceeds() throws {
        let fixture = try Fixture(payload: Data(repeating: 0xA4, count: 128))
        defer { fixture.cleanUp() }
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let copier = BoundedScreenshotCopy(payloadLimit: 128, read: { descriptor, buffer, count, offset in
            reads.withLock { $0 += 1 }
            return pread(descriptor, buffer, count, offset)
        })
        try copier.copy(sourceFD: fixture.sourceFD, stageFD: fixture.stageFD, outputToken: UUID(), baseline: fixture.baseline)
        XCTAssertEqual(try Data(contentsOf: fixture.stage), fixture.payload)
        XCTAssertEqual(reads.withLock { $0 }, 2, "Exactly capped data still needs a separate EOF read")
    }

    func testFixedPayloadCapCannotBeRaisedAndRejectsSparseOversizeBeforeReading() throws {
        let fixture = try Fixture(payload: Data())
        defer { fixture.cleanUp() }
        XCTAssertEqual(ftruncate(fixture.sourceFD, off_t(ScreenshotStagingLimits.maximumPayloadBytes + 1)), 0)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let copier = BoundedScreenshotCopy(payloadLimit: Int.max, read: { descriptor, buffer, count, offset in
            reads.withLock { $0 += 1 }
            return pread(descriptor, buffer, count, offset)
        })
        assertFailure(.stagingPaused) {
            try copier.copy(sourceFD: fixture.sourceFD, stageFD: fixture.stageFD, outputToken: UUID(), baseline: fixture.baseline)
        }
        XCTAssertEqual(reads.withLock { $0 }, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.stage), Data())
    }

    func testSourceGrowthPastLimitCannotWriteBeyondLimit() throws {
        let fixture = try Fixture(payload: Data(repeating: 1, count: 8))
        defer { fixture.cleanUp() }
        let didGrow = OSAllocatedUnfairLock(initialState: false)
        let growth = Data(repeating: 2, count: 200)
        let copier = BoundedScreenshotCopy(payloadLimit: 128, read: { descriptor, buffer, count, offset in
            if didGrow.withLock({ value in let old = value; value = true; return !old }) {
                let result = growth.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 8) }
                XCTAssertEqual(result, growth.count)
            }
            return pread(descriptor, buffer, count, offset)
        })
        assertFailure(.stagingPaused) {
            try copier.copy(sourceFD: fixture.sourceFD, stageFD: fixture.stageFD, outputToken: UUID(), baseline: fixture.baseline)
        }
        var stage = stat()
        XCTAssertEqual(fstat(fixture.stageFD, &stage), 0)
        XCTAssertLessThanOrEqual(stage.st_size, 128)
        XCTAssertEqual(stage.st_size, 0, "The read that crosses the cap must not be written")
    }

    func testSourceGrowthWithinLimitIsNotSilentlyTruncatedToInitialStatSize() throws {
        let fixture = try Fixture(payload: Data(repeating: 1, count: 8))
        defer { fixture.cleanUp() }
        let didGrow = OSAllocatedUnfairLock(initialState: false)
        let growth = Data(repeating: 2, count: 8)
        let copier = BoundedScreenshotCopy(payloadLimit: 128, read: { descriptor, buffer, count, offset in
            if didGrow.withLock({ value in let old = value; value = true; return !old }) {
                let result = growth.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 8) }
                XCTAssertEqual(result, growth.count)
            }
            return pread(descriptor, buffer, count, offset)
        })
        assertFailure(.verificationFailed) {
            try copier.copy(sourceFD: fixture.sourceFD, stageFD: fixture.stageFD, outputToken: UUID(), baseline: fixture.baseline)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.stage).count, 16)
    }

    func testZeroProgressWriteFailsWithoutLooping() throws {
        let fixture = try Fixture(payload: Data(repeating: 1, count: 8))
        defer { fixture.cleanUp() }
        let copier = BoundedScreenshotCopy(write: { _, _, _, _ in 0 })
        assertFailure(.ioFailure) {
            try copier.copy(sourceFD: fixture.sourceFD, stageFD: fixture.stageFD, outputToken: UUID(), baseline: fixture.baseline)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.stage), Data())
    }

    func testMetadataBudgetIncludesAllNamesValuesAndFreshMarkerBeforePayloadWrites() throws {
        let fixture = try Fixture(payload: Data(repeating: 1, count: 8))
        defer { fixture.cleanUp() }
        let names = ["com.macfleet.shotdrop.first", "com.macfleet.shotdrop.second"]
        let value = Data(repeating: 4, count: 100)
        for name in names { try setAttribute(name, value, descriptor: fixture.sourceFD) }
        let exactSize = fixture.baseline.chargedBytes + markerSize + names.reduce(0) { $0 + $1.utf8.count + 1 + value.count }
        let copier = BoundedScreenshotCopy(metadataLimit: exactSize - 1)
        assertFailure(.stagingPaused) {
            try copier.copy(sourceFD: fixture.sourceFD, stageFD: fixture.stageFD, outputToken: UUID(), baseline: fixture.baseline)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.stage), Data())
        try BoundedScreenshotCopy(metadataLimit: exactSize)
            .copy(sourceFD: fixture.sourceFD, stageFD: fixture.stageFD, outputToken: UUID(), baseline: fixture.baseline)
        XCTAssertEqual(try Data(contentsOf: fixture.stage), fixture.payload)
    }

    func testOldOutputMarkerIsReplacedWithoutCopyingItsValue() throws {
        let fixture = try Fixture(payload: Data(repeating: 1, count: 8))
        defer { fixture.cleanUp() }
        try setAttribute(ScreenshotOutputMarker.attributeName, Data(repeating: 0x7F, count: 512),
                         descriptor: fixture.sourceFD)
        let token = UUID()
        try BoundedScreenshotCopy(metadataLimit: fixture.baseline.chargedBytes + markerSize)
            .copy(sourceFD: fixture.sourceFD, stageFD: fixture.stageFD, outputToken: token, baseline: fixture.baseline)
        XCTAssertEqual(try BoundedScreenshotCopy.attributes(fixture.stageFD),
                       fixture.baseline.expectedStageAttributes(sourceAttributes: [:], outputToken: token))
    }

    func testResourceForkCountsTowardAggregateMetadataLimit() throws {
        let fixture = try Fixture(payload: Data(repeating: 1, count: 8))
        defer { fixture.cleanUp() }
        let resourceFork = Data(repeating: 0x4A, count: 4_096)
        let name = "com.apple.ResourceFork"
        try setAttribute(name, resourceFork, descriptor: fixture.sourceFD)
        let exactSize = fixture.baseline.chargedBytes + markerSize + name.utf8.count + 1 + resourceFork.count
        assertFailure(.stagingPaused) {
            try BoundedScreenshotCopy(metadataLimit: exactSize - 1)
                .copy(sourceFD: fixture.sourceFD, stageFD: fixture.stageFD, outputToken: UUID(), baseline: fixture.baseline)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.stage), Data())
        try BoundedScreenshotCopy(metadataLimit: exactSize)
            .copy(sourceFD: fixture.sourceFD, stageFD: fixture.stageFD, outputToken: UUID(), baseline: fixture.baseline)
        XCTAssertEqual(try BoundedScreenshotCopy.attributes(fixture.stageFD)[name], Data(SHA256.hash(data: resourceFork)))
    }

    func testStaticAttributeReaderRejectsAggregateAboveFixedCap() throws {
        let fixture = try Fixture(payload: Data())
        defer { fixture.cleanUp() }
        for index in 0..<17 {
            try setAttribute("com.macfleet.shotdrop.aggregate-\(index)", Data(repeating: UInt8(index), count: 64 * 1024),
                             descriptor: fixture.sourceFD)
        }
        assertFailure(.stagingPaused) { _ = try BoundedScreenshotCopy.attributes(fixture.sourceFD) }
        assertFailure(.stagingPaused) {
            try BoundedScreenshotCopy(metadataLimit: Int.max)
                .copy(sourceFD: fixture.sourceFD, stageFD: fixture.stageFD, outputToken: UUID(), baseline: fixture.baseline)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.stage), Data())
    }

    func testNonemptyOrLinkedStageIsRejectedWithoutResettingItsContents() throws {
        let fixture = try Fixture(payload: Data(repeating: 1, count: 8))
        defer { fixture.cleanUp() }
        let retained = Data("retained stage contents".utf8)
        XCTAssertEqual(retained.withUnsafeBytes { pwrite(fixture.stageFD, $0.baseAddress, $0.count, 0) }, retained.count)
        assertFailure(.stagingPaused) {
            try BoundedScreenshotCopy().copy(sourceFD: fixture.sourceFD, stageFD: fixture.stageFD, outputToken: UUID(), baseline: fixture.baseline)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.stage), retained)
        XCTAssertEqual(ftruncate(fixture.stageFD, 0), 0)
        try FileManager.default.linkItem(at: fixture.stage, to: fixture.root.appendingPathComponent("stage-link"))
        assertFailure(.stagingPaused) {
            try BoundedScreenshotCopy().copy(sourceFD: fixture.sourceFD, stageFD: fixture.stageFD, outputToken: UUID(), baseline: fixture.baseline)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.stage), Data())
    }

    func testProvenanceBaselineEncodingPreservesPresenceAbsenceAndExactBytes() throws {
        for value: Data? in [nil, Data(repeating: 0xA1, count: 11)] {
            let baseline = try ScreenshotStagingBaseline(provenance: value)
            let encoded = try JSONEncoder().encode(baseline)
            XCTAssertEqual(try JSONDecoder().decode(ScreenshotStagingBaseline.self, from: encoded), baseline)
            XCTAssertEqual(baseline.chargedBytes, value == nil ? 0 : ScreenshotStagingBaseline.attributeName.utf8.count + 1 + 11)
        }
        for count in [0, 10, 12, 1_024] {
            XCTAssertThrowsError(try ScreenshotStagingBaseline(provenance: Data(repeating: 0, count: count)))
        }
        let invalid = try JSONSerialization.data(withJSONObject: ["provenance": Data(repeating: 0, count: 12).base64EncodedString()])
        XCTAssertThrowsError(try JSONDecoder().decode(ScreenshotStagingBaseline.self, from: invalid))
    }

    func testSourceProvenanceConflictIsReplacedByEnrolledBaselineOrOmittedIfAbsent() throws {
        let sourceProvenance = Data(SHA256.hash(data: Data(repeating: 0x11, count: 11)))
        let retainedName = "com.macfleet.shotdrop.user-metadata"
        let retainedHash = Data(SHA256.hash(data: Data("keep this attribute".utf8)))
        let source = [ScreenshotStagingBaseline.attributeName: sourceProvenance, retainedName: retainedHash]
        let token = UUID()
        let present = try ScreenshotStagingBaseline(provenance: Data(repeating: 0x22, count: 11))
        let presentAttributes = present.expectedStageAttributes(sourceAttributes: source, outputToken: token)
        XCTAssertNotEqual(presentAttributes[ScreenshotStagingBaseline.attributeName], sourceProvenance)
        XCTAssertEqual(presentAttributes[ScreenshotStagingBaseline.attributeName], present.attributeHashes[ScreenshotStagingBaseline.attributeName])
        XCTAssertEqual(presentAttributes[retainedName], retainedHash)
        let absent = try ScreenshotStagingBaseline(provenance: nil)
        let absentAttributes = absent.expectedStageAttributes(sourceAttributes: source, outputToken: token)
        XCTAssertNil(absentAttributes[ScreenshotStagingBaseline.attributeName])
        XCTAssertEqual(absentAttributes[retainedName], retainedHash)
    }

    func testUnexpectedStageAttributeIsRejectedWithoutClearingIt() throws {
        let fixture = try Fixture(payload: Data(repeating: 1, count: 8))
        defer { fixture.cleanUp() }
        let name = "com.macfleet.shotdrop.unexpected-stage-metadata"
        let value = Data("not the enrolled baseline".utf8)
        try setAttribute(name, value, descriptor: fixture.stageFD)
        assertFailure(.stagingPaused) {
            try BoundedScreenshotCopy().copy(sourceFD: fixture.sourceFD, stageFD: fixture.stageFD,
                                             outputToken: UUID(), baseline: fixture.baseline)
        }
        XCTAssertEqual(try BoundedScreenshotCopy.attributes(fixture.stageFD)[name], Data(SHA256.hash(data: value)))
        XCTAssertEqual(try Data(contentsOf: fixture.stage), Data())
    }

    func testMismatchedEnrolledBaselineIsRejectedBeforePayloadWrites() throws {
        let fixture = try Fixture(payload: Data(repeating: 1, count: 8))
        defer { fixture.cleanUp() }
        let mismatch = try ScreenshotStagingBaseline(provenance: fixture.baseline.provenance == nil
                                                     ? Data(repeating: 0xA1, count: 11) : nil)
        assertFailure(.stagingPaused) {
            try BoundedScreenshotCopy().copy(sourceFD: fixture.sourceFD, stageFD: fixture.stageFD,
                                             outputToken: UUID(), baseline: mismatch)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.stage), Data())
    }

    private var markerSize: Int { ScreenshotOutputMarker.attributeName.utf8.count + 1 + 36 }

    private func assertFailure(_ expected: ScreenshotCopyFailure.Code, file: StaticString = #filePath,
                               line: UInt = #line, _ action: () throws -> Void) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            XCTAssertEqual((error as? ScreenshotCopyFailure)?.code, expected, file: file, line: line)
        }
    }

    private func setAttribute(_ name: String, _ data: Data, descriptor: Int32) throws {
        let result = data.withUnsafeBytes { fsetxattr(descriptor, name, $0.baseAddress, $0.count, 0, 0) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let stage: URL
        let payload: Data
        let sourceFD: Int32
        let stageFD: Int32
        let baseline: ScreenshotStagingBaseline

        init(payload: Data) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ShotDropBoundedCopy-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            source = root.appendingPathComponent("source.png")
            stage = root.appendingPathComponent("stage")
            self.payload = payload
            try payload.write(to: source)
            sourceFD = open(source.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            guard sourceFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            stageFD = open(stage.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard stageFD >= 0 else {
                close(sourceFD)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            baseline = try ScreenshotStagingBaseline.capture(stageFD)
        }

        func cleanUp() {
            close(stageFD)
            close(sourceFD)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
