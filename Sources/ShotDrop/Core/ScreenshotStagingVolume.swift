import Darwin
import DiskArbitration
import Foundation

protocol ScreenshotStagingVolumeInspecting: Sendable {
    func inspect(_ descriptor: Int32) throws -> ScreenshotStagingVolume
}

/// The UUID identifies the filesystem across mounts. Device numbers are only live
/// same-filesystem evidence and must never be persisted as a volume identity.
struct ScreenshotStagingVolume: Sendable, Equatable {
    let volumeUUID: UUID
    let device: UInt64
    let isLocal: Bool
    let isReadOnly: Bool
    let isInternal: Bool?
    let isRemovable: Bool?
    let isEjectable: Bool?
    let fileSystemType: String
    let supportsCloning: Bool?
    let supportsPersistentIDs: Bool?

    func requireSupported() throws {
        guard volumeUUID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
              isLocal, !isReadOnly, isInternal == true, isRemovable == false, isEjectable == false,
              fileSystemType == "apfs",
              supportsCloning == true, supportsPersistentIDs == true else {
            throw stagingVolumeFailure("Staging requires an identified writable internal APFS volume with known clone and persistent identity support.")
        }
    }
}

/// Read-only preflight, using the held descriptor rather than looking up its path.
/// A positive capability result does not promise the later clone will succeed.
struct DarwinScreenshotStagingVolumeInspector: ScreenshotStagingVolumeInspecting {
    func inspect(_ descriptor: Int32) throws -> ScreenshotStagingVolume {
        var file = stat()
        var filesystem = statfs()
        guard fstat(descriptor, &file) == 0, fstatfs(descriptor, &filesystem) == 0 else {
            throw stagingVolumePOSIX("Inspect staging volume")
        }
        let type = withUnsafeBytes(of: filesystem.f_fstypename) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let local = filesystem.f_flags & UInt32(MNT_LOCAL) != 0
        let readOnly = filesystem.f_flags & UInt32(MNT_RDONLY) != 0
        // Do not request further metadata on a known unsupported filesystem.
        guard local, !readOnly, type == "apfs" else {
            throw stagingVolumeFailure("This destination is not a writable local APFS volume.")
        }

        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_CAPABILITIES) | UInt32(ATTR_VOL_UUID)
        // Darwin packs attributes on four-byte boundaries: length (4), returned
        // attribute_set_t (20), vol_capabilities_attr_t (32), and uuid_t (16).
        var packed = [UInt32](repeating: 0, count: 18)
        let result = packed.withUnsafeMutableBytes {
            fgetattrlist(descriptor, &request, $0.baseAddress, $0.count, UInt32(FSOPT_PACK_INVAL_ATTRS))
        }
        guard result == 0 else { throw stagingVolumePOSIX("Read staging volume identity and capabilities") }
        let attributes = try Self.decodeAttributes(packed)
        let mountedDevice = withUnsafeBytes(of: filesystem.f_mntfromname) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        guard mountedDevice.hasPrefix("/dev/"),
              let session = DASessionCreate(kCFAllocatorDefault),
              let disk = mountedDevice.withCString({ DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) }),
              let description = DADiskCopyDescription(disk) else {
            throw stagingVolumeFailure("The staging volume's internal device status is unavailable.")
        }
        let deviceProperties = try Self.decodeDeviceProperties(description as NSDictionary, volumeUUID: attributes.volumeUUID)
        let volume = ScreenshotStagingVolume(
            volumeUUID: attributes.volumeUUID, device: UInt64(UInt32(bitPattern: file.st_dev)),
            isLocal: local, isReadOnly: readOnly,
            isInternal: deviceProperties.isInternal, isRemovable: deviceProperties.isRemovable,
            isEjectable: deviceProperties.isEjectable, fileSystemType: type,
            supportsCloning: attributes.supportsCloning, supportsPersistentIDs: attributes.supportsPersistentIDs
        )
        try volume.requireSupported()
        return volume
    }

    struct DeviceProperties: Sendable {
        let isInternal: Bool?
        let isRemovable: Bool?
        let isEjectable: Bool?
    }

    static func decodeDeviceProperties(_ description: NSDictionary, volumeUUID: UUID) throws -> DeviceProperties {
        guard let value = description[kDADiskDescriptionVolumeUUIDKey] as AnyObject?,
              CFGetTypeID(value) == CFUUIDGetTypeID() else {
            throw stagingVolumeFailure("Disk Arbitration did not identify the staging volume.")
        }
        // The type ID is checked before treating the Core Foundation value as a UUID.
        let identifier = unsafeDowncast(value, to: CFUUID.self)
        guard let identifierString = CFUUIDCreateString(kCFAllocatorDefault, identifier),
              UUID(uuidString: identifierString as String) == volumeUUID else {
            throw stagingVolumeFailure("The device description does not match the opened staging volume.")
        }
        func boolean(_ key: CFString) -> Bool? {
            guard let value = description[key] as AnyObject?, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
        }
        return DeviceProperties(isInternal: boolean(kDADiskDescriptionDeviceInternalKey),
                                isRemovable: boolean(kDADiskDescriptionMediaRemovableKey),
                                isEjectable: boolean(kDADiskDescriptionMediaEjectableKey))
    }

    struct Attributes: Sendable {
        let volumeUUID: UUID
        let supportsCloning: Bool?
        let supportsPersistentIDs: Bool?
    }

    /// The fixed buffer and returned mask must both be valid. Capability bits
    /// without their corresponding validity bits mean unknown, not supported.
    static func decodeAttributes(_ packed: [UInt32]) throws -> Attributes {
        let required = UInt32(ATTR_VOL_CAPABILITIES | ATTR_VOL_UUID)
        guard packed.count == 18, packed[0] == 72,
              packed[1] & UInt32(ATTR_CMN_RETURNED_ATTRS) != 0,
              packed[2] & required == required else {
            throw stagingVolumeFailure("The volume did not return its required identity and capability attributes.")
        }
        let bytes = packed.withUnsafeBytes { Array($0[56..<72]) }
        guard bytes.contains(where: { $0 != 0 }) else {
            throw stagingVolumeFailure("The volume has no persistent filesystem UUID.")
        }
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        func capability(_ index: Int, _ bit: UInt32) -> Bool? {
            guard packed[10 + index] & bit != 0 else { return nil }
            return packed[6 + index] & bit != 0
        }
        return Attributes(
            volumeUUID: uuid,
            supportsCloning: capability(Int(VOL_CAPABILITIES_INTERFACES), UInt32(VOL_CAP_INT_CLONE)),
            supportsPersistentIDs: capability(Int(VOL_CAPABILITIES_FORMAT), UInt32(VOL_CAP_FMT_PERSISTENTOBJECTIDS))
        )
    }
}

/// A conservative rejection filter, not proof that an arbitrary provider is absent.
/// Pool enrollment also requires a reviewed ordinary-local-path attestation.
enum ScreenshotStagingLocalPathPolicy {
    static func checkedPath(_ descriptor: Int32) throws -> URL {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathResult = bytes.withUnsafeMutableBufferPointer {
            fcntl(descriptor, F_GETPATH, $0.baseAddress!)
        }
        guard pathResult == 0 else {
            throw stagingVolumePOSIX("Read the opened staging directory path")
        }
        guard let terminator = bytes.firstIndex(of: 0), terminator > 0,
              let path = String(bytes: bytes[..<terminator].map { UInt8(bitPattern: $0) }, encoding: .utf8),
              path.hasPrefix("/") else { throw stagingVolumeFailure("The staging directory path is unavailable.") }
        let url = URL(fileURLWithPath: path)
        try rejectKnownManagedPath(url)
        // Resource values are path-based. Hold and validate that path's inode
        // before and after the query rather than trusting a stale F_GETPATH name.
        let pathFD = open(path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard pathFD >= 0 else { throw stagingVolumePOSIX("Bind the staging directory path") }
        defer { close(pathFD) }
        try verifySameObject(descriptor, pathFD)
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isUbiquitousItemKey]) }
        catch { throw stagingVolumeFailure("Cloud management status could not be inspected: \(error.localizedDescription)") }
        guard values.isUbiquitousItem != true else {
            throw stagingVolumeFailure("Cloud-managed paths cannot enroll a staging root.")
        }
        let confirmedFD = open(path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard confirmedFD >= 0 else { throw stagingVolumePOSIX("Recheck the staging directory path") }
        defer { close(confirmedFD) }
        try verifySameObject(descriptor, confirmedFD)
        return url
    }

    static func rejectKnownManagedPath(_ url: URL) throws {
        let components = url.standardizedFileURL.pathComponents.map { $0.lowercased() }
        guard !zip(components, components.dropFirst()).contains(where: { parent, child in
            parent == "library" && (child == "mobile documents" || child == "cloudstorage")
        }) else {
            throw stagingVolumeFailure("Known iCloud and File Provider storage paths cannot enroll a staging root.")
        }
    }

    private static func verifySameObject(_ descriptor: Int32, _ other: Int32) throws {
        var held = stat()
        var path = stat()
        guard fstat(descriptor, &held) == 0, fstat(other, &path) == 0 else {
            throw stagingVolumePOSIX("Verify the staging directory path")
        }
        guard held.st_dev == path.st_dev, held.st_ino == path.st_ino,
              held.st_birthtimespec.tv_sec == path.st_birthtimespec.tv_sec,
              held.st_birthtimespec.tv_nsec == path.st_birthtimespec.tv_nsec else {
            throw stagingVolumeFailure("The staging directory path changed while its cloud status was inspected.")
        }
    }
}

private func stagingVolumeFailure(_ detail: String) -> ScreenshotCopyFailure {
    ScreenshotCopyFailure(code: .stagingPaused, detail: detail)
}

private func stagingVolumePOSIX(_ operation: String) -> ScreenshotCopyFailure {
    let saved = errno
    return ScreenshotCopyFailure(code: .stagingPaused, detail: "\(operation): \(String(cString: strerror(saved))).", posixCode: saved)
}
