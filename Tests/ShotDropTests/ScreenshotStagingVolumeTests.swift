import Darwin
import DiskArbitration
import Foundation
import XCTest
@testable import ShotDrop

final class ScreenshotStagingVolumeTests: XCTestCase {
    func testKnownWritableInternalAPFSIsSupported() throws {
        try volume().requireSupported()
    }

    func testUnsupportedOrUnknownVolumePropertiesAreRejected() {
        let candidates = [
            volume(isLocal: false), volume(isReadOnly: true), volume(fileSystemType: "hfs"),
            volume(fileSystemType: "smbfs"), volume(fileSystemType: ""),
            volume(supportsCloning: false), volume(supportsCloning: nil),
            volume(supportsPersistentIDs: false), volume(supportsPersistentIDs: nil),
            volume(isInternal: false), volume(isInternal: nil),
            volume(isRemovable: true), volume(isRemovable: nil),
            volume(isEjectable: true), volume(isEjectable: nil),
            volume(uuid: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        ]
        for candidate in candidates { assertPaused { try candidate.requireSupported() } }
    }

    func testDeviceNumberMayChangeWithoutChangingPersistentVolumeIdentity() throws {
        let identifier = UUID()
        let before = volume(uuid: identifier, device: 1)
        let after = volume(uuid: identifier, device: 2)
        try before.requireSupported()
        try after.requireSupported()
        XCTAssertEqual(before.volumeUUID, after.volumeUUID)
        XCTAssertNotEqual(before.device, after.device)
    }

    func testPackedAttributesPreserveUUIDByteOrderAndCapabilityValidity() throws {
        let attributes = try DarwinScreenshotStagingVolumeInspector.decodeAttributes(packedAttributes())
        XCTAssertEqual(attributes.volumeUUID.uuidString, "00010203-0405-0607-0809-0A0B0C0D0E0F")
        XCTAssertEqual(attributes.supportsCloning, true)
        XCTAssertEqual(attributes.supportsPersistentIDs, true)

        var unknown = packedAttributes()
        unknown[10] = 0
        unknown[11] = 0
        let unknownAttributes = try DarwinScreenshotStagingVolumeInspector.decodeAttributes(unknown)
        XCTAssertNil(unknownAttributes.supportsCloning, "A capability bit without a validity bit is unknown")
        XCTAssertNil(unknownAttributes.supportsPersistentIDs)

        var unsupported = packedAttributes()
        unsupported[6] = 0
        unsupported[7] = 0
        let unsupportedAttributes = try DarwinScreenshotStagingVolumeInspector.decodeAttributes(unsupported)
        XCTAssertEqual(unsupportedAttributes.supportsCloning, false)
        XCTAssertEqual(unsupportedAttributes.supportsPersistentIDs, false)
    }

    func testPackedAttributesRejectMissingMaskZeroUUIDAndMalformedLength() {
        var missingUUID = packedAttributes()
        missingUUID[2] &= ~UInt32(ATTR_VOL_UUID)
        var missingCapabilities = packedAttributes()
        missingCapabilities[2] &= ~UInt32(ATTR_VOL_CAPABILITIES)
        var missingReturnedMask = packedAttributes()
        missingReturnedMask[1] = 0
        var shortLength = packedAttributes()
        shortLength[0] = 71
        var zeroUUID = packedAttributes()
        for index in 14..<18 { zeroUUID[index] = 0 }
        for packed in [[], Array(packedAttributes().dropLast()), missingUUID, missingCapabilities,
                       missingReturnedMask, shortLength, zeroUUID] {
            assertPaused { _ = try DarwinScreenshotStagingVolumeInspector.decodeAttributes(packed) }
        }
    }

    func testDeviceDescriptionMustBindToDescriptorVolumeUUID() throws {
        let identifier = UUID()
        let description = deviceDescription(uuid: identifier)
        let properties = try DarwinScreenshotStagingVolumeInspector.decodeDeviceProperties(description, volumeUUID: identifier)
        XCTAssertEqual(properties.isInternal, true)
        XCTAssertEqual(properties.isRemovable, false)
        XCTAssertEqual(properties.isEjectable, false)
        assertPaused { _ = try DarwinScreenshotStagingVolumeInspector.decodeDeviceProperties(description, volumeUUID: UUID()) }
        assertPaused { _ = try DarwinScreenshotStagingVolumeInspector.decodeDeviceProperties([:], volumeUUID: identifier) }
        assertPaused {
            _ = try DarwinScreenshotStagingVolumeInspector.decodeDeviceProperties(
                [kDADiskDescriptionVolumeUUIDKey: identifier.uuidString], volumeUUID: identifier)
        }
    }

    func testMissingOrWronglyTypedDeviceFlagsRemainUnknown() throws {
        let identifier = UUID()
        let description = deviceDescription(uuid: identifier).mutableCopy() as! NSMutableDictionary
        description.removeObject(forKey: kDADiskDescriptionDeviceInternalKey)
        description[kDADiskDescriptionMediaRemovableKey] = "false"
        description[kDADiskDescriptionMediaEjectableKey] = NSNumber(value: 7)
        let properties = try DarwinScreenshotStagingVolumeInspector.decodeDeviceProperties(description, volumeUUID: identifier)
        XCTAssertNil(properties.isInternal)
        XCTAssertNil(properties.isRemovable)
        XCTAssertNil(properties.isEjectable)
    }

    func testRealInspectorUsesOpenDirectoryAndFileWithoutCreatingProbeArtifacts() throws {
        let root = try resolvedStagingTemporaryDirectory()
            .appendingPathComponent("ShotDropVolume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        let renamed = root.appendingPathComponent("renamed")
        let payload = Data("descriptor-bound volume inspection".utf8)
        try payload.write(to: original)
        let directoryFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        let fileFD = open(original.path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(directoryFD, 0)
        XCTAssertGreaterThanOrEqual(fileFD, 0)
        defer { close(directoryFD); close(fileFD) }
        let inspector = DarwinScreenshotStagingVolumeInspector()
        let directoryVolume = try inspector.inspect(directoryFD)
        let originalVolume = try inspector.inspect(fileFD)
        try FileManager.default.moveItem(at: original, to: renamed)
        let renamedVolume = try inspector.inspect(fileFD)
        XCTAssertEqual(directoryVolume.volumeUUID, originalVolume.volumeUUID)
        XCTAssertEqual(directoryVolume.device, originalVolume.device)
        XCTAssertEqual(originalVolume, renamedVolume)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["renamed"])
        XCTAssertEqual(try Data(contentsOf: renamed), payload)
    }

    func testInvalidDescriptorPreservesPOSIXFailure() {
        XCTAssertThrowsError(try DarwinScreenshotStagingVolumeInspector().inspect(-1)) { error in
            XCTAssertEqual((error as? ScreenshotCopyFailure)?.code, .stagingPaused)
            XCTAssertEqual((error as? ScreenshotCopyFailure)?.posixCode, EBADF)
        }
    }

    func testKnownCloudStorageRootsRejectEvenWhenVolumeWouldBeSupported() {
        for path in ["/Users/example/Library/Mobile Documents/com~apple~CloudDocs/Screenshots",
                     "/Users/another/Library/CloudStorage/ExampleProvider/Screenshots",
                     "/Users/example/library/cloudstorage/provider",
                     "/Users/example/Library/CloudStorage"] {
            assertPaused { try ScreenshotStagingLocalPathPolicy.rejectKnownManagedPath(URL(fileURLWithPath: path)) }
        }
    }

    func testOrdinaryLocalPathFilterStillRequiresSeparateAttestation() throws {
        // Passing this rejection-only filter does not establish provider absence.
        try ScreenshotStagingLocalPathPolicy.rejectKnownManagedPath(URL(fileURLWithPath: "/Users/example/Pictures/Screenshots"))
        let root = try resolvedStagingTemporaryDirectory()
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(try ScreenshotStagingLocalPathPolicy.checkedPath(descriptor).path, root.path)
    }

    private func packedAttributes() -> [UInt32] {
        var words = [UInt32](repeating: 0, count: 18)
        words[0] = 72
        words[1] = UInt32(ATTR_CMN_RETURNED_ATTRS)
        words[2] = UInt32(ATTR_VOL_CAPABILITIES | ATTR_VOL_UUID)
        words[6] = UInt32(VOL_CAP_FMT_PERSISTENTOBJECTIDS)
        words[7] = UInt32(VOL_CAP_INT_CLONE)
        words[10] = words[6]
        words[11] = words[7]
        words.withUnsafeMutableBytes { bytes in
            for index in 0..<16 { bytes[56 + index] = UInt8(index) }
        }
        return words
    }

    private func deviceDescription(uuid: UUID) -> NSDictionary {
        let identifier = CFUUIDCreateFromString(kCFAllocatorDefault, uuid.uuidString as CFString)!
        return [kDADiskDescriptionVolumeUUIDKey: identifier,
                kDADiskDescriptionDeviceInternalKey: kCFBooleanTrue!,
                kDADiskDescriptionMediaRemovableKey: kCFBooleanFalse!,
                kDADiskDescriptionMediaEjectableKey: kCFBooleanFalse!]
    }

    private func volume(uuid: UUID = UUID(), device: UInt64 = 1, isLocal: Bool = true,
                        isReadOnly: Bool = false, fileSystemType: String = "apfs",
                        supportsCloning: Bool? = true, supportsPersistentIDs: Bool? = true,
                        isInternal: Bool? = true, isRemovable: Bool? = false,
                        isEjectable: Bool? = false) -> ScreenshotStagingVolume {
        ScreenshotStagingVolume(volumeUUID: uuid, device: device, isLocal: isLocal, isReadOnly: isReadOnly,
                                isInternal: isInternal, isRemovable: isRemovable, isEjectable: isEjectable,
                                fileSystemType: fileSystemType, supportsCloning: supportsCloning,
                                supportsPersistentIDs: supportsPersistentIDs)
    }

    private func assertPaused(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? ScreenshotCopyFailure)?.code, .stagingPaused, file: file, line: line)
        }
    }
}
