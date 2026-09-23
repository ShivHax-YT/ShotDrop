import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShotDrop

final class AnnotationExportTests: XCTestCase {
    func testRenderedStageTamperingRejectsBytesAndUnexpectedMetadata() throws {
        for changeMetadata in [false, true] {
            let fixture = try AnnotationExportFixture()
            defer { fixture.cleanUp() }
            let staged = try fixture.stage(using: LocalScreenshotOrganizationFileSystem(pool: fixture.pool))
            defer { staged.discard() }
            let slot = try XCTUnwrap(fixture.slots.first { (try? Data(contentsOf: $0)) == fixture.rendered })
            let descriptor = open(slot.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(descriptor) }
            if changeMetadata {
                let value = Data("unapproved stage metadata".utf8)
                XCTAssertEqual(value.withUnsafeBytes {
                    fsetxattr(descriptor, "com.macfleet.fixture.tampered", $0.baseAddress, $0.count, 0, 0)
                }, 0)
            } else {
                var byte: UInt8 = 0
                XCTAssertEqual(pwrite(descriptor, &byte, 1, 0), 1)
            }
            XCTAssertThrowsError(try staged.publish(named: "must-not-exist.png")) {
                XCTAssertEqual(($0 as? ScreenshotCopyFailure)?.code, .verificationFailed)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
        }
    }

    func testSourceBytesOrMetadataChangedAfterRenderAreRetainedAndRejectExport() throws {
        for changeMetadata in [false, true] {
            let fixture = try AnnotationExportFixture()
            defer { fixture.cleanUp() }
            let sourceURL = fixture.source
            var expectedAttributes = try stagingTestAttributeHashes(at: fixture.source)
            let replacement = Data("intentional external fixture edit".utf8)
            let fileSystem = LocalScreenshotOrganizationFileSystem(pool: fixture.pool, fault: { phase in
                guard phase == .afterCopy else { return }
                if changeMetadata {
                    let result = replacement.withUnsafeBytes {
                        setxattr(sourceURL.path, "com.macfleet.fixture.external-edit", $0.baseAddress, $0.count, 0, 0)
                    }
                    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                } else {
                    let descriptor = open(sourceURL.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    defer { close(descriptor) }
                    guard ftruncate(descriptor, 0) == 0,
                          replacement.withUnsafeBytes({ pwrite(descriptor, $0.baseAddress, $0.count, 0) }) == replacement.count else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
            })
            XCTAssertThrowsError(try fixture.stage(using: fileSystem)) {
                XCTAssertEqual(($0 as? ScreenshotCopyFailure)?.code, .sourceChanged)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
            XCTAssertEqual(try Data(contentsOf: fixture.source), changeMetadata ? fixture.original : replacement)
            if changeMetadata {
                expectedAttributes["com.macfleet.fixture.external-edit"] = Data(SHA256.hash(data: replacement))
            }
            XCTAssertEqual(try stagingTestAttributeHashes(at: fixture.source), expectedAttributes)
        }
    }

    func testPostPublicationFailureRetainsRecoverableRenderedOutput() throws {
        let fixture = try AnnotationExportFixture()
        defer { fixture.cleanUp() }
        let fileSystem = LocalScreenshotOrganizationFileSystem(pool: fixture.pool, fault: { phase in
            if phase == .afterPublish { throw CocoaError(.fileWriteUnknown) }
        })
        let staged = try fixture.stage(using: fileSystem)
        defer { staged.discard() }
        let expected = fixture.destination.appendingPathComponent("recoverable.png")
        XCTAssertThrowsError(try staged.publish(named: "recoverable.png")) {
            XCTAssertEqual(($0 as? ScreenshotCopyFailure)?.recoverableDestination, expected)
        }
        XCTAssertEqual(try Data(contentsOf: expected), fixture.rendered)
        XCTAssertNotEqual(try Data(contentsOf: expected), fixture.original)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), ["recoverable.png"])
    }

    func testProductionExportRemainsClosed() {
        XCTAssertFalse(AnnotationExportAvailability.productionEnabled)
        XCTAssertFalse(AnnotationExportAvailability.explanation.isEmpty)
    }

    func testPNGContainerAcceptsFreshImageAndRejectsPrivateAncillaryChunks() throws {
        let fixture = try AnnotationExportFixture()
        defer { fixture.cleanUp() }
        XCTAssertNoThrow(try AnnotationPNGContainer.validate(fixture.rendered))
        for name in ["tEXt", "eXIf"] {
            var altered = fixture.rendered
            // Insert a correctly framed chunk immediately after the mandatory IHDR.
            altered.insert(contentsOf: Self.chunk(name, payload: Data("private metadata".utf8)), at: 33)
            XCTAssertThrowsError(try AnnotationPNGContainer.validate(altered)) {
                XCTAssertEqual($0 as? AnnotationFailure, .invalidImage)
            }
        }
    }

    func testPNGContainerRejectsTrailingBytesAndMalformedLength() throws {
        let fixture = try AnnotationExportFixture()
        defer { fixture.cleanUp() }
        var trailing = fixture.rendered
        trailing.append(Data("hidden trailing source information".utf8))
        XCTAssertThrowsError(try AnnotationPNGContainer.validate(trailing))
        var hugeLength = fixture.rendered
        hugeLength.replaceSubrange(8..<12, with: [255, 255, 255, 255])
        XCTAssertThrowsError(try AnnotationPNGContainer.validate(hugeLength))
        var truncated = fixture.rendered
        truncated.removeLast(1)
        XCTAssertThrowsError(try AnnotationPNGContainer.validate(truncated))
    }

    func testExportServiceCollisionInSourceDirectoryNeverOverwritesOriginal() async throws {
        let fixture = try AnnotationExportFixture(destinationIsSource: true)
        defer { fixture.cleanUp() }
        let source = try RecentFileReference.capture(at: fixture.source, role: .savedCopy)
        let originalAttributes = try stagingTestAttributeHashes(at: fixture.source)
        let service = AnnotationExportService(fileSystem: LocalScreenshotOrganizationFileSystem(pool: fixture.pool))
        let first = try await service.export(png: fixture.rendered, source: source,
                                             destination: fixture.destination, proposedStem: "original")
        XCTAssertEqual(first.destinationURL.lastPathComponent, "original (2).png")
        let second = try await service.export(png: fixture.rendered, source: source,
                                              destination: fixture.destination, proposedStem: "original")
        XCTAssertEqual(second.destinationURL.lastPathComponent, "original (3).png")
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
        XCTAssertEqual(try stagingTestAttributeHashes(at: fixture.source), originalAttributes)
        XCTAssertEqual(try Data(contentsOf: first.destinationURL), fixture.rendered)
        XCTAssertEqual(try Data(contentsOf: second.destinationURL), fixture.rendered)
        XCTAssertNotEqual(first.identity, fixture.identity)
        XCTAssertNotEqual(second.identity, first.identity)
    }

    func testExportServiceRejectsSourceRoleBeforeWriting() async throws {
        let fixture = try AnnotationExportFixture()
        defer { fixture.cleanUp() }
        let source = try RecentFileReference.capture(at: fixture.source, role: .source)
        let service = AnnotationExportService(fileSystem: LocalScreenshotOrganizationFileSystem(pool: fixture.pool))
        do {
            _ = try await service.export(png: fixture.rendered, source: source,
                                         destination: fixture.destination, proposedStem: "annotation")
            XCTFail("An original-only Recent entry must not enter the annotation export adapter")
        } catch {
            XCTAssertEqual(error as? AnnotationFailure, .unavailable)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
    }

    private static func chunk(_ name: String, payload: Data) -> Data {
        let length = UInt32(payload.count)
        var result = Data([UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
                           UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)])
        var body = Data(name.utf8)
        body.append(payload)
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in body {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB8_8320 : 0) }
        }
        crc ^= 0xFFFF_FFFF
        result.append(body)
        result.append(contentsOf: [UInt8(truncatingIfNeeded: crc >> 24), UInt8(truncatingIfNeeded: crc >> 16),
                                   UInt8(truncatingIfNeeded: crc >> 8), UInt8(truncatingIfNeeded: crc)])
        return result
    }

    func testRenderedPNGPreservesSourceAndPublishesOnlyEnrolledMetadata() throws {
        let fixture = try AnnotationExportFixture()
        defer { fixture.cleanUp() }
        try fixture.setSourceAttribute("com.macfleet.fixture.private-note", value: Data("private source metadata".utf8))
        let beforeAttributes = try stagingTestAttributeHashes(at: fixture.source)
        let slotAttributes = try fixture.slots.map { try stagingTestAttributeHashes(at: $0) }
        let fileSystem = LocalScreenshotOrganizationFileSystem(pool: fixture.pool)
        let staged = try fixture.stage(using: fileSystem)
        defer { staged.discard() }
        let result = try staged.publish(named: "annotated.png")
        XCTAssertEqual(result.housekeeping, .clean)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
        XCTAssertEqual(try stagingTestAttributeHashes(at: fixture.source), beforeAttributes)
        let published = try Data(contentsOf: result.destinationURL)
        XCTAssertEqual(published, fixture.rendered)
        XCTAssertNotEqual(published, fixture.original)
        let attributes = try stagingTestAttributeHashes(at: result.destinationURL)
        let markerHash = Data(SHA256.hash(data: Data(result.outputToken.uuidString.utf8)))
        XCTAssertEqual(attributes[ScreenshotOutputMarker.attributeName], markerHash)
        var withoutMarker = attributes
        withoutMarker.removeValue(forKey: ScreenshotOutputMarker.attributeName)
        XCTAssertTrue(slotAttributes.contains(withoutMarker), "Only the enrolled slot baseline may accompany the output marker")
        XCTAssertNil(attributes["com.macfleet.fixture.private-note"])
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(published as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(imageSource), 1)
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil(properties[kCGImagePropertyExifDictionary as String])
        for (index, slot) in fixture.slots.enumerated() {
            XCTAssertEqual(try Data(contentsOf: slot), Data())
            XCTAssertEqual(try stagingTestAttributeHashes(at: slot), slotAttributes[index])
        }
    }

    func testCollisionKeepsExistingBytesAndAllowsSameStageRetry() throws {
        let fixture = try AnnotationExportFixture()
        defer { fixture.cleanUp() }
        let existing = fixture.destination.appendingPathComponent("annotated.png")
        let existingBytes = Data("existing user file".utf8)
        try existingBytes.write(to: existing)
        let staged = try fixture.stage(using: LocalScreenshotOrganizationFileSystem(pool: fixture.pool))
        defer { staged.discard() }
        XCTAssertThrowsError(try staged.publish(named: "annotated.png")) {
            XCTAssertEqual(($0 as? ScreenshotCopyFailure)?.code, .collision)
        }
        XCTAssertEqual(try Data(contentsOf: existing), existingBytes)
        let result = try staged.publish(named: "annotated (2).png")
        XCTAssertEqual(try Data(contentsOf: result.destinationURL), fixture.rendered)
        XCTAssertEqual(try Data(contentsOf: existing), existingBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
    }

    func testSourceReplacementAfterStagingCannotRetargetExport() throws {
        let fixture = try AnnotationExportFixture()
        defer { fixture.cleanUp() }
        let staged = try fixture.stage(using: LocalScreenshotOrganizationFileSystem(pool: fixture.pool))
        defer { staged.discard() }
        let preserved = fixture.root.appendingPathComponent("preserved-original.png")
        try FileManager.default.moveItem(at: fixture.source, to: preserved)
        try fixture.original.write(to: fixture.source)
        XCTAssertThrowsError(try staged.publish(named: "must-not-exist.png")) {
            XCTAssertEqual(($0 as? ScreenshotCopyFailure)?.code, .sourceChanged)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
        XCTAssertEqual(try Data(contentsOf: preserved), fixture.original)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
    }

    func testWrongSourceDigestRejectsBeforePublication() throws {
        let fixture = try AnnotationExportFixture()
        defer { fixture.cleanUp() }
        let fileSystem = LocalScreenshotOrganizationFileSystem(pool: fixture.pool)
        XCTAssertThrowsError(try fileSystem.stageRenderedPNG(
            source: fixture.source, destinationRoot: fixture.destination,
            expectedIdentity: fixture.identity, expectedSourceDigest: String(repeating: "0", count: 64),
            png: fixture.rendered
        ))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
    }

    func testFailedPublicationRetainsSourceAndCanRetryWithRemainingCleanSlot() throws {
        let fixture = try AnnotationExportFixture()
        defer { fixture.cleanUp() }
        let failing = LocalScreenshotOrganizationFileSystem(pool: fixture.pool, clone: { _, _, _ in
            errno = ENOSPC
            return -1
        })
        let staged = try fixture.stage(using: failing)
        XCTAssertThrowsError(try staged.publish(named: "annotated.png"))
        staged.discard()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
        let retry = try fixture.stage(using: LocalScreenshotOrganizationFileSystem(pool: fixture.pool))
        defer { retry.discard() }
        let result = try retry.publish(named: "annotated.png")
        XCTAssertEqual(try Data(contentsOf: result.destinationURL), fixture.rendered)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
    }

    func testUnresolvedLegacyGatePreventsSlotAndDestinationWrites() throws {
        let fixture = try AnnotationExportFixture(legacyAccountedFor: false)
        defer { fixture.cleanUp() }
        let attributes = try fixture.slots.map { try stagingTestAttributeHashes(at: $0) }
        let identities = try fixture.slots.map { try fixture.inode(at: $0) }
        XCTAssertThrowsError(try fixture.stage(using: LocalScreenshotOrganizationFileSystem(pool: fixture.pool))) {
            XCTAssertEqual(($0 as? ScreenshotCopyFailure)?.code, .stagingPaused)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
        for (index, slot) in fixture.slots.enumerated() {
            XCTAssertEqual(try Data(contentsOf: slot), Data())
            XCTAssertEqual(try stagingTestAttributeHashes(at: slot), attributes[index])
            XCTAssertEqual(try fixture.inode(at: slot), identities[index])
        }
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
    }
}

private struct AnnotationExportFixture {
    let root: URL
    let source: URL
    let destination: URL
    let poolRoot: URL
    let pool: ScreenshotStagingPool
    let identity: ScreenshotFileIdentity
    let original: Data
    let rendered: Data
    var slots: [URL] { ["slot-0.stage", "slot-1.stage"].map { poolRoot.appendingPathComponent($0) } }

    init(legacyAccountedFor: Bool = true, destinationIsSource: Bool = false) throws {
        root = try resolvedStagingTemporaryDirectory().appendingPathComponent("ShotDropAnnotationExport-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        source = sourceDirectory.appendingPathComponent("original.png")
        destination = destinationIsSource ? sourceDirectory : root.appendingPathComponent("destination", isDirectory: true)
        poolRoot = root.appendingPathComponent("pool", isDirectory: true)
        original = try Self.png(red: 1, includeMetadata: true)
        rendered = try Self.png(red: 0, includeMetadata: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        if !destinationIsSource {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        }
        try original.write(to: source)
        identity = try XCTUnwrap(LocalScreenshotFileSystem().identity(at: source))
        pool = ScreenshotStagingPool(registryDirectory: root.appendingPathComponent("registry", isDirectory: true))
        try pool.initialize(legacyArtifactsAccountedFor: legacyAccountedFor)
        try pool.registerRoot(at: poolRoot, sourceDirectory: sourceDirectory, destinationDirectory: destination,
                              ordinaryLocalDestinationReviewed: true)
    }

    func stage(using fileSystem: LocalScreenshotOrganizationFileSystem) throws -> any ScreenshotStagedCopy {
        try fileSystem.stageRenderedPNG(source: source, destinationRoot: destination,
            expectedIdentity: identity, expectedSourceDigest: SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined(),
            png: rendered)
    }

    func setSourceAttribute(_ name: String, value: Data) throws {
        let result = value.withUnsafeBytes { bytes in
            setxattr(source.path, name, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func inode(at url: URL) throws -> UInt64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return UInt64(info.st_ino)
    }

    private static func png(red: CGFloat, includeMetadata: Bool) throws -> Data {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8,
            bytesPerRow: 16, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.5, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        let metadata: [CFString: Any] = includeMetadata ? [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private source comment"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.0, kCGImagePropertyGPSLatitudeRef: "N"]
        ] : [:]
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        let encoded = data as Data
        if includeMetadata { return encoded }
        // ImageIO synthesizes eXIf even for an empty property dictionary. This
        // fixture represents an already-sanitized renderer result, not raw ImageIO output.
        var sanitized = Data(encoded.prefix(8))
        var cursor = 8
        while cursor + 12 <= encoded.count {
            let count = encoded[cursor..<(cursor + 4)].reduce(0) { ($0 << 8) | Int($1) }
            let end = cursor + count + 12
            guard end <= encoded.count else { throw AnnotationFailure.invalidImage }
            let name = String(data: encoded[(cursor + 4)..<(cursor + 8)], encoding: .ascii)
            if name != "eXIf" { sanitized.append(encoded[cursor..<end]) }
            cursor = end
        }
        return sanitized
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
