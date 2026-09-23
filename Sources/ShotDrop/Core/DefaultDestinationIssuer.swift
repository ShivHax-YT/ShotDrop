import Darwin
import Foundation

enum DefaultDestinationIssuerIssue: Error, Equatable, Sendable {
    case needsReview
    case collision
    case changed
    case unsupported
    case enrollmentPaused
}

/// Durable part of the policy decision. It is an application invariant, not a credential
/// against another process running as the same user.
struct DefaultDestinationPolicyBinding: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let policyVersion: Int
    let path: String
    let volumeUUID: UUID
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let owner: UInt32
    let permissions: UInt16

    fileprivate static func capture(_ descriptor: Int32,
                                    inspection: DefaultDestinationPolicyPathInspection) throws -> Self {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o700,
              UInt64(UInt32(bitPattern: info.st_dev)) == inspection.volume.device,
              info.st_ino != 0 else { throw DefaultDestinationIssuerIssue.changed }
        return Self(policyVersion: currentVersion, path: inspection.childPath.path,
                    volumeUUID: inspection.volume.volumeUUID, inode: UInt64(info.st_ino),
                    birthSeconds: Int64(info.st_birthtimespec.tv_sec),
                    birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec),
                    owner: UInt32(info.st_uid), permissions: UInt16(info.st_mode & 0o777))
    }

    /// Core calls this independently at enrollment and admission. The inspector keeps the
    /// complete parent walk pinned while the destination descriptor is compared.
    func requireCurrent(descriptor: Int32, inspector: DefaultDestinationPolicyPathInspector) throws {
        guard policyVersion == Self.currentVersion else { throw DefaultDestinationIssuerIssue.needsReview }
        try inspector.withInspectedParent { parentFD, inspection in
            guard path == inspection.childPath.path, volumeUUID == inspection.volume.volumeUUID else {
                throw DefaultDestinationIssuerIssue.changed
            }
            try inspector.revalidate(inspection, parentDescriptor: parentFD)
            let childFD = openat(parentFD, "ShotDrop", O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
            guard childFD >= 0 else { throw DefaultDestinationIssuerIssue.changed }
            defer { close(childFD) }
            let actual = try Self.capture(childFD, inspection: inspection)
            guard actual == self else { throw DefaultDestinationIssuerIssue.changed }
            var held = stat()
            var current = stat()
            guard fstat(descriptor, &held) == 0, fstat(childFD, &current) == 0,
                  held.st_dev == current.st_dev, held.st_ino == current.st_ino,
                  held.st_birthtimespec.tv_sec == current.st_birthtimespec.tv_sec,
                  held.st_birthtimespec.tv_nsec == current.st_birthtimespec.tv_nsec else {
                throw DefaultDestinationIssuerIssue.changed
            }
            try Self.requireUnmanagedChild(inspection.childPath, descriptor: childFD,
                                           inspector: inspector)
            try inspector.revalidate(inspection, parentDescriptor: parentFD)
        }
    }

    fileprivate static func requireUnmanagedChild(_ url: URL, descriptor: Int32,
                                                   inspector: DefaultDestinationPolicyPathInspector) throws {
        do { try ScreenshotStagingLocalPathPolicy.rejectKnownManagedPath(url) }
        catch { throw DefaultDestinationIssuerIssue.unsupported }
        let before = try DefaultDestinationDirectoryIdentity(descriptor)
        let cloud: Bool?
        do { cloud = try inspector.operations.isUbiquitous(url) }
        catch { throw DefaultDestinationIssuerIssue.unsupported }
        guard cloud == false else { throw DefaultDestinationIssuerIssue.unsupported }
        let provider: Bool?
        do { provider = try inspector.operations.isProviderManaged(url, descriptor) }
        catch { throw DefaultDestinationIssuerIssue.unsupported }
        guard provider == false else { throw DefaultDestinationIssuerIssue.unsupported }
        guard try DefaultDestinationDirectoryIdentity(descriptor) == before else {
            throw DefaultDestinationIssuerIssue.changed
        }
    }
}

/// The live-device comparison is deliberately one-operation only. Restarts revalidate the
/// durable binding against the current opened volume rather than persisting st_dev.
struct DefaultDestinationAttestation: Sendable {
    let binding: DefaultDestinationPolicyBinding
    let liveDevice: UInt64

    fileprivate init(binding: DefaultDestinationPolicyBinding, liveDevice: UInt64) {
        self.binding = binding
        self.liveDevice = liveDevice
    }
}

/// May be called only after the user has entered the existing setup flow. It never deletes,
/// renames or silently adopts a pre-existing screenshot directory.
struct DefaultDestinationIssuer: Sendable {
    let inspector: DefaultDestinationPolicyPathInspector
    let journal: DefaultDestinationJournal
    let pool: ScreenshotStagingPool

    func createAndEnroll(sourceDirectory: URL, stagingRoot: URL) throws -> DefaultDestinationAttestation {
        try inspector.withInspectedParent { parentFD, inspection in
            guard try journal.load() == .empty else { throw DefaultDestinationIssuerIssue.needsReview }
            try LocalScreenshotDestinationValidator().validate(
                sourceDirectory: sourceDirectory, destinationDirectory: inspection.childPath)
            try inspector.revalidate(inspection, parentDescriptor: parentFD)
            var existing = stat()
            guard fstatat(parentFD, "ShotDrop", &existing, AT_SYMLINK_NOFOLLOW) != 0,
                  errno == ENOENT else { throw DefaultDestinationIssuerIssue.collision }
            let parentIdentity = ShotDropSetupDirectoryIdentity(path: inspection.path.path,
                device: inspection.identity.device, inode: inspection.identity.inode,
                birthSeconds: inspection.identity.birthSeconds,
                birthNanoseconds: inspection.identity.birthNanoseconds)
            let intent = try DefaultDestinationJournal.Intent(destination: inspection.childPath,
                volumeUUID: inspection.volume.volumeUUID, parent: parentIdentity)
            try journal.begin(intent)
            try inspector.revalidate(inspection, parentDescriptor: parentFD)
            guard mkdirat(parentFD, "ShotDrop", 0o700) == 0 else {
                throw DefaultDestinationIssuerIssue.collision
            }
            let childFD = openat(parentFD, "ShotDrop", O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
            guard childFD >= 0 else { throw DefaultDestinationIssuerIssue.changed }
            defer { close(childFD) }
            try inspector.revalidate(inspection, parentDescriptor: parentFD)
            try DefaultDestinationPolicyBinding.requireUnmanagedChild(inspection.childPath,
                descriptor: childFD, inspector: inspector)
            let binding = try DefaultDestinationPolicyBinding.capture(childFD, inspection: inspection)
            try binding.requireCurrent(descriptor: childFD, inspector: inspector)
            let created = ShotDropSetupDirectoryIdentity(path: binding.path,
                device: inspection.volume.device, inode: binding.inode,
                birthSeconds: binding.birthSeconds, birthNanoseconds: binding.birthNanoseconds)
            try journal.recordCreated(intent, created: created)
            let attestation = DefaultDestinationAttestation(binding: binding,
                                                             liveDevice: inspection.volume.device)
            do {
                try pool.registerPolicyRoot(at: stagingRoot, sourceDirectory: sourceDirectory,
                                            destinationDirectory: inspection.childPath,
                                            attestation: attestation)
            } catch { throw DefaultDestinationIssuerIssue.enrollmentPaused }
            try journal.recordEnrolled(intent, created: created)
            return attestation
        }
    }
}
