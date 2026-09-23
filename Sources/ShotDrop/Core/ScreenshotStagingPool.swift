import Darwin
import Foundation

/// These names are persisted; a non-clean slot is never automatically reclaimed after a crash.
enum ScreenshotStagingSlotState: String, Codable, Sendable {
    case clean, reserved, writing, prepared, publishing, reclaiming, retired
}

enum ScreenshotStagingPoolFault: Sendable {
    case beforeRegistryWrite, beforeRegistrySync, afterRegistrySync
    case beforeRootCreation, beforeSlotCreation
    case beforeRemoveAttributes, beforeTruncate, beforeSlotSync, afterSlotSync
}

/// A fixed pool assumes its private namespace is not modified by hostile same-UID processes.
/// Advisory locking coordinates ShotDrop instances; it does not establish a security boundary.
struct ScreenshotStagingPool: Sendable {
    let registryDirectory: URL
    private let fault: @Sendable (ScreenshotStagingPoolFault) throws -> Void
    private let volumeInspector: any ScreenshotStagingVolumeInspecting
    private let liveDeviceReader: @Sendable (Int32) throws -> UInt64
    private let defaultPolicyInspector: DefaultDestinationPolicyPathInspector

    static var applicationDefault: Self {
        Self(registryDirectory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.macfleet.shotdrop/StagingRegistry", isDirectory: true))
    }

    init(
        registryDirectory: URL,
        volumeInspector: any ScreenshotStagingVolumeInspecting = DarwinScreenshotStagingVolumeInspector(),
        liveDeviceReader: @escaping @Sendable (Int32) throws -> UInt64 = poolDevice,
        defaultPolicyInspector: DefaultDestinationPolicyPathInspector = .init(),
        fault: @escaping @Sendable (ScreenshotStagingPoolFault) throws -> Void = { _ in }
    ) {
        self.registryDirectory = registryDirectory
        self.volumeInspector = volumeInspector
        self.liveDeviceReader = liveDeviceReader
        self.defaultPolicyInspector = defaultPolicyInspector
        self.fault = fault
    }

    /// Explicit enrollment only. Existing, incomplete, or corrupt registries are never reset.
    func initialize(legacyArtifactsAccountedFor: Bool = false) throws {
        try poolValidateURL(registryDirectory)
        var info = stat()
        guard lstat(registryDirectory.path, &info) != 0, errno == ENOENT else {
            throw poolFailure("A staging registry already exists or cannot be inspected. It must not be reset.")
        }
        let parent = registryDirectory.deletingLastPathComponent()
        try poolCreateRegistryParents(parent)
        let parentFD = try poolOpenDirectory(parent)
        defer { close(parentFD) }
        let registryVolume = try volumeInspector.inspect(parentFD)
        try registryVolume.requireSupported()
        _ = try ScreenshotStagingLocalPathPolicy.checkedPath(parentFD)
        guard mkdirat(parentFD, registryDirectory.lastPathComponent, 0o700) == 0 else {
            throw poolPOSIX("Create staging registry")
        }
        let directoryFD = try poolOpenDirectory(registryDirectory)
        defer { close(directoryFD) }
        let directoryIdentity = try PoolIdentity.read(directoryFD, volume: registryVolume, liveDeviceReader: liveDeviceReader, directory: true)
        let lockFD = openat(directoryFD, "lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw poolPOSIX("Create staging lock") }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw poolPOSIX("Lock new staging registry") }
        let lockIdentity = try PoolIdentity.read(lockFD, volume: registryVolume, liveDeviceReader: liveDeviceReader)
        let registryFD = openat(directoryFD, "registry.json", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard registryFD >= 0 else { throw poolPOSIX("Create staging journal") }
        defer { close(registryFD) }
        let registryIdentity = try PoolIdentity.read(registryFD, volume: registryVolume, liveDeviceReader: liveDeviceReader)
        let registry = PoolRegistry(version: 2, legacyArtifactsAccountedFor: legacyArtifactsAccountedFor,
                                    directory: directoryIdentity, lock: lockIdentity, journal: registryIdentity, roots: [])
        try poolWriteRegistry(registry, descriptor: registryFD, fault: fault)
        guard fsync(lockFD) == 0, fsync(directoryFD) == 0, fsync(parentFD) == 0 else {
            poolPoisonRegistry(registryFD)
            throw poolPOSIX("Flush staging registry initialization")
        }
    }

    /// Register a new, previously absent private root on an explicitly selected volume.
    /// The durable root intent consumes capacity even if mkdir or slot creation fails.
    func registerRoot(
        at root: URL, sourceDirectory: URL, destinationDirectory: URL,
        ordinaryLocalDestinationReviewed: Bool = false
    ) throws {
        guard ordinaryLocalDestinationReviewed else {
            throw poolFailure("Staging enrollment requires an explicit review of this ordinary local destination.")
        }
        do { try registerNewRoot(at: root, sourceDirectory: sourceDirectory,
                                 destinationDirectory: destinationDirectory, policyBinding: nil) }
        catch let error as ScreenshotCopyFailure where error.code == .stagingPaused { throw error }
        catch { throw poolFailure("Staging registration is paused: \(error.localizedDescription)") }
    }

    /// Policy-bound default enrollment has no Boolean review escape hatch. Core independently
    /// validates the issuer's object binding before its durable root reservation.
    func registerPolicyRoot(at root: URL, sourceDirectory: URL, destinationDirectory: URL,
                            attestation: DefaultDestinationAttestation) throws {
        do {
            try registerNewRoot(at: root, sourceDirectory: sourceDirectory,
                destinationDirectory: destinationDirectory, policyBinding: attestation.binding,
                liveDevice: attestation.liveDevice)
        } catch let error as ScreenshotCopyFailure where error.code == .stagingPaused { throw error }
        catch { throw poolFailure("Default destination enrollment is paused: \(error.localizedDescription)") }
    }

    private func registerNewRoot(at root: URL, sourceDirectory: URL, destinationDirectory: URL,
                                 policyBinding: DefaultDestinationPolicyBinding?,
                                 liveDevice: UInt64? = nil) throws {
        try poolValidateURL(root)
        let session = try PoolSession.open(at: registryDirectory, volumeInspector: volumeInspector, liveDeviceReader: liveDeviceReader, fault: fault)
        defer { session.close() }
        try LocalScreenshotDestinationValidator().validate(sourceDirectory: registryDirectory, destinationDirectory: sourceDirectory)
        try LocalScreenshotDestinationValidator().validate(sourceDirectory: registryDirectory, destinationDirectory: destinationDirectory)
        guard session.registry.roots.count < ScreenshotStagingLimits.maximumRoots else { throw poolFailure("All four staging root reservations are charged.") }
        try LocalScreenshotDestinationValidator().validate(sourceDirectory: sourceDirectory, destinationDirectory: root)
        try LocalScreenshotDestinationValidator().validate(sourceDirectory: destinationDirectory, destinationDirectory: root)
        try LocalScreenshotDestinationValidator().validate(sourceDirectory: registryDirectory, destinationDirectory: root)
        let destinationFD = try poolOpenExistingDirectory(destinationDirectory)
        defer { close(destinationFD) }
        let rootVolume = try volumeInspector.inspect(destinationFD)
        try rootVolume.requireSupported()
        if let policyBinding {
            guard liveDevice == rootVolume.device,
                  try liveDeviceReader(destinationFD) == rootVolume.device,
                  destinationDirectory.path == policyBinding.path else {
                throw poolFailure("The default destination's live identity changed before enrollment.")
            }
            try policyBinding.requireCurrent(descriptor: destinationFD,
                                             inspector: defaultPolicyInspector)
        }
        let destinationReview = try PoolDestinationReview.capture(destinationFD, volume: rootVolume, liveDeviceReader: liveDeviceReader)
        guard !session.registry.roots.contains(where: { $0.volumeUUID == rootVolume.volumeUUID }) else {
            throw poolFailure("This volume already has a charged staging root; another cannot be registered.")
        }
        var info = stat()
        guard lstat(root.path, &info) != 0, errno == ENOENT else {
            throw poolFailure("Staging registration requires a new absent directory; existing directories cannot be adopted.")
        }
        let parentFD = try poolOpenDirectory(root.deletingLastPathComponent())
        defer { close(parentFD) }
        let parentVolume = try volumeInspector.inspect(parentFD)
        try parentVolume.requireSupported()
        _ = try ScreenshotStagingLocalPathPolicy.checkedPath(parentFD)
        guard parentVolume.volumeUUID == rootVolume.volumeUUID,
              parentVolume.device == rootVolume.device,
              try liveDeviceReader(parentFD) == rootVolume.device,
              try liveDeviceReader(destinationFD) == rootVolume.device else {
            throw poolFailure("The staging root must be on the same supported destination volume.")
        }
        let index = session.registry.roots.count
        session.registry.roots.append(PoolRoot(path: root.path, volumeUUID: rootVolume.volumeUUID, identity: nil, ready: false,
            destinationReview: destinationReview,
            policyBinding: policyBinding,
            slots: (0..<ScreenshotStagingLimits.slotsPerRoot).map { PoolSlot(name: "slot-\($0).stage", identity: nil, baseline: nil, state: .retired) }))
        try session.persist()
        do {
            try fault(.beforeRootCreation)
            guard mkdirat(parentFD, root.lastPathComponent, 0o700) == 0 else { throw poolPOSIX("Create staging pool root") }
            let rootFD = try poolOpenDirectory(root)
            defer { close(rootFD) }
            session.registry.roots[index].identity = try PoolIdentity.read(rootFD, volume: rootVolume, liveDeviceReader: liveDeviceReader, directory: true)
            guard try liveDeviceReader(rootFD) == rootVolume.device else { throw poolFailure("The new staging root changed volumes.") }
            for slotIndex in 0..<ScreenshotStagingLimits.slotsPerRoot {
                try fault(.beforeSlotCreation)
                let name = session.registry.roots[index].slots[slotIndex].name
                let descriptor = openat(rootFD, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw poolPOSIX("Create fixed staging slot") }
                defer { close(descriptor) }
                session.registry.roots[index].slots[slotIndex].identity = try PoolIdentity.read(descriptor, volume: rootVolume, liveDeviceReader: liveDeviceReader)
                // Record the one bounded OS-owned creation baseline only on this O_EXCL inode.
                let baseline = try ScreenshotStagingBaseline.capture(descriptor)
                session.registry.roots[index].slots[slotIndex].baseline = baseline
                for name in try poolAttributeNames(descriptor) {
                    if name == ScreenshotStagingBaseline.attributeName, baseline.provenance != nil { continue }
                    guard fremovexattr(descriptor, name, 0) == 0 else { throw poolPOSIX("Initialize empty staging metadata") }
                }
                try poolVerifyEmpty(descriptor, baseline: baseline)
                guard fsync(descriptor) == 0 else { throw poolPOSIX("Flush new staging slot") }
                session.registry.roots[index].slots[slotIndex].state = .clean
            }
            guard fsync(rootFD) == 0, fsync(parentFD) == 0 else { throw poolPOSIX("Flush staging root") }
            session.registry.roots[index].ready = true
            try session.persist()
        } catch {
            session.registry.roots[index].ready = false
            for slotIndex in 0..<ScreenshotStagingLimits.slotsPerRoot { session.registry.roots[index].slots[slotIndex].state = .retired }
            try? session.persist()
            throw error
        }
    }

    /// Replace the one reviewed destination for an existing root; never allocate another root.
    func updateDestinationReview(
        at destinationDirectory: URL, forRoot rootURL: URL, sourceDirectory: URL,
        ordinaryLocalDestinationReviewed: Bool = false
    ) throws {
        guard ordinaryLocalDestinationReviewed else {
            throw poolFailure("A changed destination requires an explicit ordinary-local-path review.")
        }
        do {
            let session = try PoolSession.open(at: registryDirectory, volumeInspector: volumeInspector,
                                               liveDeviceReader: liveDeviceReader, fault: fault)
            defer { session.close() }
            try LocalScreenshotDestinationValidator().validate(sourceDirectory: registryDirectory, destinationDirectory: sourceDirectory)
            try LocalScreenshotDestinationValidator().validate(sourceDirectory: registryDirectory, destinationDirectory: destinationDirectory)
            try LocalScreenshotDestinationValidator().validate(sourceDirectory: sourceDirectory, destinationDirectory: rootURL)
            try LocalScreenshotDestinationValidator().validate(sourceDirectory: destinationDirectory, destinationDirectory: rootURL)
            let destinationFD = try poolOpenExistingDirectory(destinationDirectory)
            defer { close(destinationFD) }
            let volume = try volumeInspector.inspect(destinationFD)
            try volume.requireSupported()
            let review = try PoolDestinationReview.capture(destinationFD, volume: volume, liveDeviceReader: liveDeviceReader)
            guard let index = session.registry.roots.firstIndex(where: { $0.volumeUUID == volume.volumeUUID }),
                  session.registry.roots[index].ready, session.registry.roots[index].path == rootURL.path else {
                throw poolFailure("Only an existing registered root can receive a replacement destination review.")
            }
            let root = session.registry.roots[index]
            guard root.policyBinding == nil else {
                throw poolFailure("A policy-bound default destination cannot be replaced through manual review.")
            }
            let descriptor = try poolOpenDirectory(rootURL)
            defer { close(descriptor) }
            guard try PoolIdentity.read(descriptor, volume: volume, liveDeviceReader: liveDeviceReader, directory: true) == root.identity else {
                throw poolFailure("The staging root changed before destination review.")
            }
            _ = try ScreenshotStagingLocalPathPolicy.checkedPath(descriptor)
            try poolCheckChildren(descriptor, expected: Set(root.slots.map(\.name)))
            for slot in root.slots {
                let slotFD = openat(descriptor, slot.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard slotFD >= 0 else { throw poolPOSIX("Inspect staging slot before destination review") }
                defer { close(slotFD) }
                guard let expected = slot.identity,
                      try PoolIdentity.read(slotFD, volume: volume, liveDeviceReader: liveDeviceReader) == expected,
                      let baseline = slot.baseline else { throw poolFailure("A staging slot changed before destination review.") }
                try baseline.verify(slotFD)
                if slot.state == .clean { try poolVerifyEmpty(slotFD, baseline: baseline) }
            }
            session.registry.roots[index].destinationReview = review
            try session.persist()
        } catch let error as ScreenshotCopyFailure where error.code == .stagingPaused { throw error }
        catch { throw poolFailure("Destination review is paused: \(error.localizedDescription)") }
    }

    /// The returned lease holds the global nonblocking flock until reset, retirement, or deinit.
    func lease(sourceDirectory: URL, destinationDirectory: URL) throws -> ScreenshotStagingLease {
        do { return try acquireLease(sourceDirectory: sourceDirectory, destinationDirectory: destinationDirectory) }
        catch let error as ScreenshotCopyFailure where error.code == .stagingPaused { throw error }
        catch { throw poolFailure("Staging admission is paused: \(error.localizedDescription)") }
    }

    private func acquireLease(sourceDirectory: URL, destinationDirectory: URL) throws -> ScreenshotStagingLease {
        let session = try PoolSession.open(at: registryDirectory, volumeInspector: volumeInspector, liveDeviceReader: liveDeviceReader, fault: fault)
        var transfersSession = false
        defer { if !transfersSession { session.close() } }
        guard session.registry.legacyArtifactsAccountedFor else {
            throw poolFailure("Saving is paused until known legacy staging artifacts are explicitly accounted for.")
        }
        try LocalScreenshotDestinationValidator().validate(sourceDirectory: registryDirectory, destinationDirectory: sourceDirectory)
        try LocalScreenshotDestinationValidator().validate(sourceDirectory: registryDirectory, destinationDirectory: destinationDirectory)
        // An explicit destination review binds an existing selected root. Missing or replaced
        // selected folders pause admission; generated date subdirectories are separate.
        let destinationAnchorFD = try poolOpenExistingDirectory(destinationDirectory)
        defer { close(destinationAnchorFD) }
        let rootVolume = try volumeInspector.inspect(destinationAnchorFD)
        try rootVolume.requireSupported()
        guard try liveDeviceReader(destinationAnchorFD) == rootVolume.device else {
            throw poolFailure("The destination volume changed during admission.")
        }
        guard let rootIndex = session.registry.roots.firstIndex(where: { $0.volumeUUID == rootVolume.volumeUUID }),
              session.registry.roots[rootIndex].ready else {
            throw poolFailure("No usable staging root is registered on this destination volume.")
        }
        if let policyBinding = session.registry.roots[rootIndex].policyBinding {
            try policyBinding.requireCurrent(descriptor: destinationAnchorFD,
                                             inspector: defaultPolicyInspector)
        }
        let destinationReview = try PoolDestinationReview.capture(destinationAnchorFD, volume: rootVolume, liveDeviceReader: liveDeviceReader)
        guard destinationReview == session.registry.roots[rootIndex].destinationReview else {
            throw poolFailure("The selected destination changed and requires a new explicit local-path review.")
        }
        // A valid registry retains all volume reservations. Recover and inspect only the
        // selected volume; an offline unrelated volume does not disable a healthy pool.
        var changed = false
        for slotIndex in session.registry.roots[rootIndex].slots.indices {
            let state = session.registry.roots[rootIndex].slots[slotIndex].state
            if state != .clean && state != .retired {
                session.registry.roots[rootIndex].slots[slotIndex].state = .retired
                changed = true
            }
        }
        if changed { try session.persist() }
        let root = session.registry.roots[rootIndex]
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
        try LocalScreenshotDestinationValidator().validate(sourceDirectory: sourceDirectory, destinationDirectory: rootURL)
        try LocalScreenshotDestinationValidator().validate(sourceDirectory: rootURL, destinationDirectory: destinationDirectory)
        let rootFD = try poolOpenDirectory(rootURL)
        var transfersRoot = false
        defer { if !transfersRoot { close(rootFD) } }
        guard let expectedRoot = root.identity,
              try PoolIdentity.read(rootFD, volume: rootVolume, liveDeviceReader: liveDeviceReader, directory: true) == expectedRoot,
              try liveDeviceReader(rootFD) == rootVolume.device else { throw poolFailure("The registered staging root identity changed.") }
        try poolCheckChildren(rootFD, expected: Set(root.slots.map(\.name)))
        // Validate both fixed slots before admission; unknown aliases or substitutions pause the root.
        for slot in root.slots {
            let descriptor = openat(rootFD, slot.name, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw poolPOSIX("Open registered staging slot") }
            defer { close(descriptor) }
            guard let expected = slot.identity, try PoolIdentity.read(descriptor, volume: rootVolume, liveDeviceReader: liveDeviceReader) == expected else {
                throw poolFailure("A registered staging slot changed identity or ownership.")
            }
            guard let baseline = slot.baseline else { throw poolFailure("The staging slot creation baseline is missing.") }
            try baseline.verify(descriptor)
            if slot.state == .clean { try poolVerifyEmpty(descriptor, baseline: baseline) }
        }
        guard let slotIndex = root.slots.firstIndex(where: { $0.state == .clean }) else {
            throw poolFailure("Both staging slots are retired; their reservations remain charged.")
        }
        let slot = root.slots[slotIndex]
        let descriptor = openat(rootFD, slot.name, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw poolPOSIX("Open staging lease") }
        var transfersSlot = false
        defer { if !transfersSlot { close(descriptor) } }
        guard let expected = slot.identity, try PoolIdentity.read(descriptor, volume: rootVolume, liveDeviceReader: liveDeviceReader) == expected else {
            throw poolFailure("The staging slot changed before reservation.")
        }
        guard let baseline = slot.baseline else { throw poolFailure("The staging slot creation baseline is missing.") }
        try poolVerifyEmpty(descriptor, baseline: baseline)
        session.registry.roots[rootIndex].slots[slotIndex].state = .reserved
        try session.persist()
        let lease = ScreenshotStagingLease(session: session, rootIndex: rootIndex, slotIndex: slotIndex,
                                          rootDescriptor: rootFD, descriptor: descriptor,
                                          url: rootURL.appendingPathComponent(slot.name), baseline: baseline, rootVolume: rootVolume, fault: fault)
        transfersSession = true
        transfersRoot = true
        transfersSlot = true
        return lease
    }
}

/// Actor-confined and intentionally not Sendable. Never removes a pathname or the source/output.
final class ScreenshotStagingLease {
    private(set) var descriptor: Int32
    let url: URL
    let baseline: ScreenshotStagingBaseline
    private let session: PoolSession
    private let rootIndex: Int
    private let slotIndex: Int
    private var rootDescriptor: Int32
    private let rootVolume: ScreenshotStagingVolume
    private let fault: @Sendable (ScreenshotStagingPoolFault) throws -> Void
    private var active = true

    fileprivate init(session: PoolSession, rootIndex: Int, slotIndex: Int, rootDescriptor: Int32,
                     descriptor: Int32, url: URL, baseline: ScreenshotStagingBaseline, rootVolume: ScreenshotStagingVolume,
                     fault: @escaping @Sendable (ScreenshotStagingPoolFault) throws -> Void) {
        self.session = session
        self.rootIndex = rootIndex
        self.slotIndex = slotIndex
        self.rootDescriptor = rootDescriptor
        self.descriptor = descriptor
        self.url = url
        self.baseline = baseline
        self.rootVolume = rootVolume
        self.fault = fault
    }

    deinit { if active { retire("The staging transaction ended without verified reset.") }; release() }

    func transition(_ state: ScreenshotStagingSlotState) throws {
        guard active else { throw poolFailure("The staging lease has ended.") }
        let current = session.registry.roots[rootIndex].slots[slotIndex].state
        let valid = (current == .reserved && state == .writing)
            || (current == .writing && state == .prepared)
            || (current == .prepared && state == .publishing)
            || (current == .publishing && state == .publishing)
        guard valid else { throw poolFailure("Invalid staging state transition from \(current.rawValue) to \(state.rawValue).") }
        do {
            try validate()
            session.registry.roots[rootIndex].slots[slotIndex].state = state
            try session.persist()
        } catch { retire("Staging state could not be persisted."); throw error }
    }

    func retire(_ reason: String) {
        guard active else { return }
        session.registry.roots[rootIndex].slots[slotIndex].state = .retired
        try? session.persist()
        active = false
        release()
    }

    func reset(knownOutputFD: Int32? = nil) -> ScreenshotStageHousekeeping {
        guard active else { return .retired("The staging lease has already ended.") }
        do {
            guard session.registry.roots[rootIndex].slots[slotIndex].state == .publishing else {
                throw poolFailure("Only a transaction that reached verified publication may reclaim its staging slot.")
            }
            try validate()
            if let knownOutputFD {
                var output = stat()
                guard fstat(knownOutputFD, &output) == 0 else { throw poolPOSIX("Inspect known saved output before reset") }
                let stage = try PoolIdentity.read(descriptor, volume: rootVolume, liveDeviceReader: session.liveDeviceReader)
                guard try session.liveDeviceReader(descriptor) != session.liveDeviceReader(knownOutputFD)
                    || stage.inode != UInt64(output.st_ino) else {
                    throw poolFailure("The saved output aliases the staging slot; reset was refused.")
                }
            }
            session.registry.roots[rootIndex].slots[slotIndex].state = .reclaiming
            try session.persist()
            try fault(.beforeRemoveAttributes)
            try validate()
            for name in try poolAttributeNames(descriptor) {
                if name == ScreenshotStagingBaseline.attributeName, baseline.provenance != nil { continue }
                guard fremovexattr(descriptor, name, 0) == 0 else { throw poolPOSIX("Clear staging metadata") }
            }
            try fault(.beforeTruncate)
            try validate()
            guard ftruncate(descriptor, 0) == 0 else { throw poolPOSIX("Clear staging payload") }
            try fault(.beforeSlotSync)
            guard fsync(descriptor) == 0 else { throw poolPOSIX("Flush staging reset") }
            try fault(.afterSlotSync)
            try validate()
            try poolVerifyEmpty(descriptor, baseline: baseline)
            session.registry.roots[rootIndex].slots[slotIndex].state = .clean
            try session.persist()
            active = false
            release()
            return .clean
        } catch {
            let detail = "Staging slot retained and retired: \(error.localizedDescription)"
            retire(detail)
            return .retired(detail)
        }
    }

    private func validate() throws {
        try session.validateHandles()
        let root = session.registry.roots[rootIndex]
        guard let rootIdentity = root.identity, try PoolIdentity.read(rootDescriptor, volume: rootVolume, liveDeviceReader: session.liveDeviceReader, directory: true) == rootIdentity else {
            throw poolFailure("Staging root identity changed while leased.")
        }
        try poolConfirmPath(URL(fileURLWithPath: root.path), expected: rootIdentity, volume: rootVolume, liveDeviceReader: session.liveDeviceReader, directory: true)
        try poolCheckChildren(rootDescriptor, expected: Set(root.slots.map(\.name)))
        guard let expected = root.slots[slotIndex].identity, try PoolIdentity.read(descriptor, volume: rootVolume, liveDeviceReader: session.liveDeviceReader) == expected else {
            throw poolFailure("Staging slot identity, mode, ownership, or link count changed.")
        }
        try poolConfirmPath(url, expected: expected, volume: rootVolume, liveDeviceReader: session.liveDeviceReader)
        try baseline.verify(descriptor)
    }

    private func release() {
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
        if rootDescriptor >= 0 { close(rootDescriptor); rootDescriptor = -1 }
        session.close()
    }
}

private struct PoolIdentity: Codable, Equatable {
    let volumeUUID: UUID
    let inode: UInt64
    let birth: Int64
    let mode: UInt32
    let owner: UInt32

    static func read(
        _ descriptor: Int32, volume: ScreenshotStagingVolume,
        liveDeviceReader: @Sendable (Int32) throws -> UInt64, directory: Bool = false
    ) throws -> Self {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw poolPOSIX("Inspect staging descriptor") }
        guard try liveDeviceReader(descriptor) == volume.device else {
            throw poolFailure("A staging descriptor moved to a different live filesystem.")
        }
        let kind = directory ? S_IFDIR : S_IFREG
        let permissions: mode_t = directory ? 0o700 : 0o600
        guard (info.st_mode & S_IFMT) == kind, (info.st_mode & 0o7777) == permissions,
              info.st_uid == geteuid(), directory || info.st_nlink == 1 else {
            throw poolFailure("Staging entry has unexpected type, mode, owner, or links.")
        }
        try poolRequireEmptyACL(descriptor)
        return Self(volumeUUID: volume.volumeUUID, inode: UInt64(info.st_ino),
                    birth: Int64(info.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_birthtimespec.tv_nsec),
                    mode: UInt32(info.st_mode), owner: info.st_uid)
    }
}

private struct PoolSlot: Codable {
    let name: String
    var identity: PoolIdentity?
    var baseline: ScreenshotStagingBaseline?
    var state: ScreenshotStagingSlotState
}

private struct PoolRoot: Codable {
    let path: String
    let volumeUUID: UUID
    var identity: PoolIdentity?
    var ready: Bool
    var destinationReview: PoolDestinationReview
    var policyBinding: DefaultDestinationPolicyBinding?
    var slots: [PoolSlot]
}

private struct PoolDestinationReview: Codable, Equatable {
    let path: String
    let volumeUUID: UUID
    let inode: UInt64
    let birth: Int64

    static func capture(
        _ descriptor: Int32, volume: ScreenshotStagingVolume,
        liveDeviceReader: @Sendable (Int32) throws -> UInt64
    ) throws -> Self {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              try liveDeviceReader(descriptor) == volume.device else {
            throw poolFailure("The selected local destination could not be bound to its directory identity.")
        }
        let path = try ScreenshotStagingLocalPathPolicy.checkedPath(descriptor)
        return Self(path: path.path, volumeUUID: volume.volumeUUID, inode: UInt64(info.st_ino),
                    birth: Int64(info.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_birthtimespec.tv_nsec))
    }
}

private struct PoolRegistry: Codable {
    let version: Int
    let legacyArtifactsAccountedFor: Bool
    let directory: PoolIdentity
    let lock: PoolIdentity
    let journal: PoolIdentity
    var roots: [PoolRoot]
}

private final class PoolSession {
    let url: URL
    private var directoryFD: Int32
    private var lockFD: Int32
    private var registryFD: Int32
    var registry: PoolRegistry
    let registryVolume: ScreenshotStagingVolume
    let liveDeviceReader: @Sendable (Int32) throws -> UInt64
    private let fault: @Sendable (ScreenshotStagingPoolFault) throws -> Void
    private var poisoned = false

    private init(url: URL, directoryFD: Int32, lockFD: Int32, registryFD: Int32, registry: PoolRegistry,
                 registryVolume: ScreenshotStagingVolume, liveDeviceReader: @escaping @Sendable (Int32) throws -> UInt64,
                 fault: @escaping @Sendable (ScreenshotStagingPoolFault) throws -> Void) {
        self.url = url
        self.directoryFD = directoryFD
        self.lockFD = lockFD
        self.registryFD = registryFD
        self.registry = registry
        self.registryVolume = registryVolume
        self.liveDeviceReader = liveDeviceReader
        self.fault = fault
    }

    deinit { close() }

    static func open(at url: URL, volumeInspector: any ScreenshotStagingVolumeInspecting,
                     liveDeviceReader: @escaping @Sendable (Int32) throws -> UInt64, fault: @escaping @Sendable (ScreenshotStagingPoolFault) throws -> Void) throws -> PoolSession {
        try poolValidateURL(url)
        let directoryFD = try poolOpenDirectory(url)
        var adopted = false
        defer { if !adopted { Darwin.close(directoryFD) } }
        let registryVolume = try volumeInspector.inspect(directoryFD)
        try registryVolume.requireSupported()
        _ = try ScreenshotStagingLocalPathPolicy.checkedPath(directoryFD)
        let lockFD = openat(directoryFD, "lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard lockFD >= 0 else { throw poolPOSIX("Open staging registry lock") }
        defer { if !adopted { Darwin.close(lockFD) } }
        _ = try PoolIdentity.read(lockFD, volume: registryVolume, liveDeviceReader: liveDeviceReader)
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw poolPOSIX("Another staging transaction owns the pool lock") }
        try poolCheckChildren(directoryFD, expected: ["lock", "registry.json"])
        let registryFD = openat(directoryFD, "registry.json", O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard registryFD >= 0 else { throw poolPOSIX("Open staging registry journal") }
        defer { if !adopted { Darwin.close(registryFD) } }
        _ = try PoolIdentity.read(registryFD, volume: registryVolume, liveDeviceReader: liveDeviceReader)
        let data = try poolReadRegistry(registryFD)
        let registry: PoolRegistry
        do { registry = try JSONDecoder().decode(PoolRegistry.self, from: data) }
        catch { throw poolFailure("The staging registry is corrupt or incompatible. Saving remains paused.") }
        guard registry.version == 2, registry.roots.count <= ScreenshotStagingLimits.maximumRoots,
              Set(registry.roots.map(\.path)).count == registry.roots.count,
              Set(registry.roots.map(\.volumeUUID)).count == registry.roots.count else {
            throw poolFailure("The staging registry violates its fixed root bounds.")
        }
        for root in registry.roots {
            try poolValidateURL(URL(fileURLWithPath: root.path))
            guard root.path.hasPrefix("/"), root.destinationReview.path.hasPrefix("/"),
                  !root.destinationReview.path.contains("\0"), !root.destinationReview.path.contains("//"),
                  !root.destinationReview.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                  root.volumeUUID.uuidString != "00000000-0000-0000-0000-000000000000",
                  root.destinationReview.volumeUUID == root.volumeUUID,
                  root.slots.count == ScreenshotStagingLimits.slotsPerRoot,
                  root.slots.enumerated().allSatisfy({ $0.element.name == "slot-\($0.offset).stage" }),
                  root.ready || root.slots.allSatisfy({ $0.state == .retired }),
                  root.identity == nil || root.identity?.volumeUUID == root.volumeUUID,
                  root.slots.allSatisfy({ $0.identity == nil || $0.identity?.volumeUUID == root.volumeUUID }),
                  !root.ready || (root.identity != nil && root.slots.allSatisfy({ $0.identity != nil && $0.baseline != nil })) else {
                throw poolFailure("The staging registry has invalid fixed slot records.")
            }
        }
        let session = PoolSession(url: url, directoryFD: directoryFD, lockFD: lockFD, registryFD: registryFD,
                                  registry: registry, registryVolume: registryVolume, liveDeviceReader: liveDeviceReader, fault: fault)
        // Session now owns handles even if subsequent validation throws.
        adopted = true
        try session.validateHandles()
        return session
    }

    func validateHandles() throws {
        guard !poisoned, directoryFD >= 0, lockFD >= 0, registryFD >= 0,
              try PoolIdentity.read(directoryFD, volume: registryVolume, liveDeviceReader: liveDeviceReader, directory: true) == registry.directory,
              try PoolIdentity.read(lockFD, volume: registryVolume, liveDeviceReader: liveDeviceReader) == registry.lock,
              try PoolIdentity.read(registryFD, volume: registryVolume, liveDeviceReader: liveDeviceReader) == registry.journal else {
            throw poolFailure("The staging registry identity or durable state is uncertain.")
        }
        try poolConfirmPath(url, expected: registry.directory, volume: registryVolume, liveDeviceReader: liveDeviceReader, directory: true)
        try poolConfirmPath(url.appendingPathComponent("lock"), expected: registry.lock, volume: registryVolume, liveDeviceReader: liveDeviceReader)
        try poolConfirmPath(url.appendingPathComponent("registry.json"), expected: registry.journal, volume: registryVolume, liveDeviceReader: liveDeviceReader)
        try poolCheckChildren(directoryFD, expected: ["lock", "registry.json"])
    }

    func persist() throws {
        try validateHandles()
        do { try poolWriteRegistry(registry, descriptor: registryFD, fault: fault) }
        catch { poisoned = true; throw error }
    }

    func close() {
        if registryFD >= 0 { Darwin.close(registryFD); registryFD = -1 }
        if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 }
        if directoryFD >= 0 { Darwin.close(directoryFD); directoryFD = -1 }
    }
}

private func poolValidateURL(_ url: URL) throws {
    guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
          url.path.hasPrefix("/"), !url.path.contains("\0"),
          !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
        throw poolFailure("Staging paths must be absolute local paths without dot components.")
    }
}

private func poolOpenDirectory(_ url: URL) throws -> Int32 {
    try poolValidateURL(url)
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
    guard descriptor >= 0 else { throw poolPOSIX("Open private staging directory without aliases") }
    return descriptor
}

private func poolOpenExistingDirectory(_ url: URL) throws -> Int32 {
    try poolValidateURL(url)
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else { throw poolPOSIX("Open screenshot directory") }
    return descriptor
}

private func poolDevice(_ descriptor: Int32) throws -> UInt64 {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw poolPOSIX("Inspect destination volume") }
    return UInt64(UInt32(bitPattern: info.st_dev))
}

private func poolConfirmPath(
    _ url: URL, expected: PoolIdentity, volume: ScreenshotStagingVolume,
    liveDeviceReader: @Sendable (Int32) throws -> UInt64, directory: Bool = false
) throws {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK
                          | (directory ? O_DIRECTORY : 0))
    guard descriptor >= 0 else { throw poolPOSIX("Reopen registered staging path") }
    defer { close(descriptor) }
    guard try PoolIdentity.read(descriptor, volume: volume, liveDeviceReader: liveDeviceReader, directory: directory) == expected else {
        throw poolFailure("A registered staging pathname no longer names its original entry.")
    }
}

private func poolCheckChildren(_ descriptor: Int32, expected: Set<String>) throws {
    let independent = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard independent >= 0 else { throw poolPOSIX("Read staging directory") }
    guard let stream = fdopendir(independent) else { close(independent); throw poolPOSIX("Enumerate staging directory") }
    defer { closedir(stream) }
    var found = Set<String>()
    while true {
        errno = 0
        guard let entry = readdir(stream) else {
            guard errno == 0 else { throw poolPOSIX("Read staging directory entry") }
            break
        }
        let name = withUnsafePointer(to: entry.pointee.d_name) {
            String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
        if name == "." || name == ".." { continue }
        guard expected.contains(name), found.insert(name).inserted, found.count <= expected.count else {
            throw poolFailure("An unknown child exists in a registered staging directory.")
        }
    }
    guard found == expected else { throw poolFailure("A fixed staging entry is missing.") }
}

private func poolReadRegistry(_ descriptor: Int32) throws -> Data {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw poolPOSIX("Read staging journal size") }
    guard info.st_size > 0, info.st_size <= Int64(ScreenshotStagingLimits.maximumRegistryBytes) else { throw poolFailure("Staging journal size is invalid.") }
    var data = Data(count: Int(info.st_size))
    let count = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
    guard count == data.count else { throw poolFailure("The staging journal could not be read completely.") }
    return data
}

private func poolWriteRegistry(_ registry: PoolRegistry, descriptor: Int32,
                               fault: @Sendable (ScreenshotStagingPoolFault) throws -> Void) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(registry)
    guard data.count <= ScreenshotStagingLimits.maximumRegistryBytes else { throw poolFailure("The fixed staging journal capacity was exceeded.") }
    do {
        try fault(.beforeRegistryWrite)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = pwrite(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw poolPOSIX("Write staging journal") }
                offset += count
            }
        }
        guard ftruncate(descriptor, off_t(data.count)) == 0 else { throw poolPOSIX("Bound staging journal") }
        try fault(.beforeRegistrySync)
        guard fsync(descriptor) == 0 else { throw poolPOSIX("Flush staging journal") }
        try fault(.afterRegistrySync)
    } catch {
        // No replacement files: partial/unsynced journals become unreadable, never a clean reset.
        poolPoisonRegistry(descriptor)
        throw error
    }
}

private func poolPoisonRegistry(_ descriptor: Int32) {
    var invalid: UInt8 = 0
    _ = pwrite(descriptor, &invalid, 1, 0)
    _ = fsync(descriptor)
}

private func poolAttributeNames(_ descriptor: Int32) throws -> [String] {
    let count = flistxattr(descriptor, nil, 0, 0)
    guard count >= 0, count <= ScreenshotStagingLimits.maximumMetadataBytes else { throw poolFailure("Staging metadata cannot be safely enumerated.") }
    if count == 0 { return [] }
    var bytes = [UInt8](repeating: 0, count: count)
    let actual = bytes.withUnsafeMutableBytes { flistxattr(descriptor, $0.baseAddress?.assumingMemoryBound(to: CChar.self), count, 0) }
    guard actual == count, bytes.last == 0 else { throw poolFailure("Staging metadata changed during reset.") }
    let components = bytes.split(separator: 0)
    var names: [String] = []
    for component in components {
        guard let name = String(bytes: component, encoding: .utf8), !name.isEmpty else {
            throw poolFailure("Staging metadata has an invalid attribute name.")
        }
        names.append(name)
    }
    return names
}

private func poolVerifyEmpty(_ descriptor: Int32, baseline: ScreenshotStagingBaseline) throws {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw poolPOSIX("Inspect clean staging slot") }
    try baseline.verify(descriptor)
    let permitted: Set<String> = baseline.provenance == nil ? [] : [ScreenshotStagingBaseline.attributeName]
    guard info.st_size == 0, Set(try poolAttributeNames(descriptor)) == permitted else {
        throw poolFailure("A clean staging slot still contains payload or metadata.")
    }
}

private func poolFailure(_ detail: String) -> ScreenshotCopyFailure {
    ScreenshotCopyFailure(code: .stagingPaused, detail: detail)
}

private func poolPOSIX(_ operation: String) -> ScreenshotCopyFailure {
    let code = errno
    return ScreenshotCopyFailure(code: .stagingPaused,
                                 detail: "\(operation): \(String(cString: strerror(code))).", posixCode: code)
}

private func poolCreateRegistryParents(_ parent: URL) throws {
    try poolValidateURL(parent)
    var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard current >= 0 else { throw poolPOSIX("Open registry filesystem root") }
    defer { close(current) }
    for component in parent.path.split(separator: "/").map(String.init) {
        var child = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if child < 0 {
            guard errno == ENOENT else { throw poolPOSIX("Open registry parent without aliases") }
            guard mkdirat(current, component, 0o700) == 0 else { throw poolPOSIX("Create registry parent") }
            guard fsync(current) == 0 else { throw poolPOSIX("Flush registry parent creation") }
            child = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw poolPOSIX("Open new registry parent") }
        }
        close(current)
        current = child
    }
}

private func poolRequireEmptyACL(_ descriptor: Int32) throws {
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
        // Darwin returns ENOENT for absent ACLs, including after explicitly setting an
        // empty ACL. The caller has already fstat-validated this held descriptor.
        if errno == ENOENT { return }
        throw poolPOSIX("Read private staging ACL")
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    errno = 0
    let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
    // Darwin returns -1/EINVAL when an otherwise valid ACL has no first entry.
    guard result == -1, errno == EINVAL else {
        throw poolFailure("Private staging entries must not contain extended ACL entries.")
    }
}
