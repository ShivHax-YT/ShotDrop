import CryptoKit
import Darwin
import Foundation

/// Descriptor-bound, source-preserving publication. Transactions are actor confined.
struct LocalScreenshotOrganizationFileSystem: ScreenshotOrganizationFileSystem {
    private let pool: ScreenshotStagingPool
    private let fault: @Sendable (ScreenshotCopyPhase) throws -> Void
    private let race: @Sendable (ScreenshotCopyRacePoint, URL) throws -> Void
    private let clone: @Sendable (Int32, Int32, String) -> Int32

    init(
        pool: ScreenshotStagingPool = .applicationDefault,
        fault: @escaping @Sendable (ScreenshotCopyPhase) throws -> Void = { _ in },
        race: @escaping @Sendable (ScreenshotCopyRacePoint, URL) throws -> Void = { _, _ in },
        clone: @escaping @Sendable (Int32, Int32, String) -> Int32 = { sourceFD, directoryFD, name in
            fclonefileat(sourceFD, directoryFD, name, UInt32(CLONE_ACL))
        }
    ) {
        self.pool = pool
        self.fault = fault
        self.race = race
        self.clone = clone
    }

    func stageCopy(
        source: URL,
        destinationRoot: URL,
        subdirectories: [String],
        expectedIdentity: ScreenshotFileIdentity?
    ) throws -> any ScreenshotStagedCopy {
        try stage(source: source, destinationRoot: destinationRoot, subdirectories: subdirectories,
                  expectedIdentity: expectedIdentity, renderedPNG: nil, expectedSourceDigest: nil)
    }

    /// Only the reviewed annotation adapter may call this after rendering and PNG validation.
    /// It uses the same fixed lease, exclusive clone, verification and reset as capture saves.
    func stageRenderedPNG(source: URL, destinationRoot: URL, expectedIdentity: ScreenshotFileIdentity,
                          expectedSourceDigest: String, png: Data) throws -> any ScreenshotStagedCopy {
        guard png.count <= ScreenshotStagingLimits.maximumPayloadBytes,
              png.prefix(8).elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw copyFailure(.verificationFailed, "Annotation output is not a bounded PNG.")
        }
        try AnnotationPNGContainer.validate(png)
        return try stage(source: source, destinationRoot: destinationRoot, subdirectories: [],
                         expectedIdentity: expectedIdentity, renderedPNG: png,
                         expectedSourceDigest: expectedSourceDigest)
    }

    private func stage(source: URL, destinationRoot: URL, subdirectories: [String],
                       expectedIdentity: ScreenshotFileIdentity?, renderedPNG: Data?,
                       expectedSourceDigest: String?) throws -> any ScreenshotStagedCopy {
        guard source.isFileURL, destinationRoot.isFileURL else {
            throw copyFailure(.invalidName, "Screenshot paths must be local file URLs.")
        }
        for component in subdirectories { try validateCopyComponent(component) }
        try Task.checkCancellation()
        let sourceFD = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard sourceFD >= 0 else { throw posixCopyFailure(.sourceUnavailable, "Open screenshot") }
        var ownsSource = true
        defer { if ownsSource { close(sourceFD) } }
        let initial = try CopyFileState.read(sourceFD)
        guard initial.regular else { throw copyFailure(.sourceUnavailable, "Screenshot is not a regular file.") }
        if let expectedIdentity, expectedIdentity != initial.identity {
            throw copyFailure(.sourceChanged, "Screenshot identity changed before copying.")
        }
        // Admission precedes any destination mutation. The cooperative global lock
        // remains owned by this lease through publication, actor awaits and reset.
        let lease = try pool.lease(sourceDirectory: source.deletingLastPathComponent(), destinationDirectory: destinationRoot)
        var transferredLease = false
        defer { if !transferredLease { lease.retire("Staging construction did not complete.") } }
        do {
            try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        } catch {
            throw Self.directoryCreationFailure(error)
        }
        var directoryFD = open(destinationRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw posixCopyFailure(.destinationUnavailable, "Open destination") }
        var ownsDirectory = true
        defer { if ownsDirectory { close(directoryFD) } }
        var directoryURL = destinationRoot
        var directories = [(URL, ScreenshotFileIdentity)]()
        directories.append((directoryURL, try CopyFileState.read(directoryFD).identity))
        for component in subdirectories {
            if mkdirat(directoryFD, component, 0o700) != 0 && errno != EEXIST {
                throw posixCopyFailure(.destinationUnavailable, "Create destination directory")
            }
            let child = openat(directoryFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw posixCopyFailure(.destinationUnavailable, "Open destination subdirectory") }
            close(directoryFD)
            directoryFD = child
            directoryURL.appendPathComponent(component, isDirectory: true)
            directories.append((directoryURL, try CopyFileState.read(directoryFD).identity))
        }
        let staged = LocalStagedScreenshotCopy(
            source: source, sourceFD: sourceFD, initial: initial,
            directory: directoryURL, directoryFD: directoryFD, directories: directories,
            lease: lease, fault: fault, race: race, clone: clone,
            renderedPNG: renderedPNG, expectedSourceDigest: expectedSourceDigest
        )
        transferredLease = true
        ownsSource = false
        ownsDirectory = false
        try staged.prepare()
        return staged
    }

    /// Prefer an underlying POSIX error over a Foundation category; never parse display text.
    static func directoryCreationFailure(_ error: Error) -> ScreenshotCopyFailure {
        var current: NSError? = error as NSError
        var visited = Set<ObjectIdentifier>()
        var cocoaFallback: Int32?
        var posixCode: Int32?
        while let candidate = current, visited.count < 32,
              visited.insert(ObjectIdentifier(candidate)).inserted {
            if candidate.domain == NSPOSIXErrorDomain,
               let code = Int32(exactly: candidate.code), code > 0 {
                posixCode = code
                break
            }
            if candidate.domain == NSCocoaErrorDomain, cocoaFallback == nil {
                switch candidate.code {
                case NSFileWriteOutOfSpaceError: cocoaFallback = ENOSPC
                case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: cocoaFallback = EACCES
                case NSFileWriteVolumeReadOnlyError: cocoaFallback = EROFS
                case NSFileWriteFileExistsError: cocoaFallback = EEXIST
                case NSFileNoSuchFileError, NSFileReadNoSuchFileError: cocoaFallback = ENOENT
                case NSFileWriteInvalidFileNameError: cocoaFallback = EINVAL
                default: break
                }
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let code = posixCode ?? cocoaFallback
        return ScreenshotCopyFailure(
            code: code == EACCES || code == EPERM ? .permissionDenied : .destinationUnavailable,
            detail: "Create destination directory: \(error.localizedDescription)",
            posixCode: code
        )
    }
}

private final class LocalStagedScreenshotCopy: ScreenshotStagedCopy {
    private let source: URL
    private let sourceFD: Int32
    private let initial: CopyFileState
    private let directory: URL
    private let directoryFD: Int32
    private let directories: [(URL, ScreenshotFileIdentity)]
    private let lease: ScreenshotStagingLease
    private let stageURL: URL
    private let stageFD: Int32
    private let fault: @Sendable (ScreenshotCopyPhase) throws -> Void
    private let race: @Sendable (ScreenshotCopyRacePoint, URL) throws -> Void
    private let clone: @Sendable (Int32, Int32, String) -> Int32
    private let renderedPNG: Data?
    private let expectedSourceDigest: String?
    private var sourceAttributes: [String: Data]?
    private var stageOwned = true
    private var publishedURL: URL?
    private var outputFD: Int32 = -1
    private var outputIdentity: ScreenshotFileIdentity?
    private var digest = Data()
    private var attributes: [String: Data] = [:]
    private(set) var identity: ScreenshotFileIdentity
    let outputToken = UUID()

    init(source: URL, sourceFD: Int32, initial: CopyFileState,
         directory: URL, directoryFD: Int32, directories: [(URL, ScreenshotFileIdentity)],
         lease: ScreenshotStagingLease,
         fault: @escaping @Sendable (ScreenshotCopyPhase) throws -> Void,
         race: @escaping @Sendable (ScreenshotCopyRacePoint, URL) throws -> Void,
         clone: @escaping @Sendable (Int32, Int32, String) -> Int32,
         renderedPNG: Data?, expectedSourceDigest: String?) {
        self.renderedPNG = renderedPNG
        self.expectedSourceDigest = expectedSourceDigest
        self.source = source
        self.sourceFD = sourceFD
        self.initial = initial
        self.directory = directory
        self.directoryFD = directoryFD
        self.directories = directories
        self.lease = lease
        self.stageURL = lease.url
        self.stageFD = lease.descriptor
        self.fault = fault
        self.race = race
        self.clone = clone
        var info = stat()
        _ = fstat(lease.descriptor, &info)
        identity = CopyFileState(info).identity
    }

    deinit {
        discard()
        if outputFD >= 0 { close(outputFD) }
        close(directoryFD)
        close(sourceFD)
    }

    func prepare() throws {
        try fault(.beforeCopy)
        try verifySource()
        try verifyDirectories()
        let sourceAttributes = try BoundedScreenshotCopy.attributes(sourceFD)
        try lease.transition(.writing)
        self.sourceAttributes = sourceAttributes
        if let renderedPNG {
            try BoundedScreenshotCopy().writeRendered(renderedPNG, stageFD: stageFD,
                                                       outputToken: outputToken, baseline: lease.baseline)
        } else {
            try BoundedScreenshotCopy().copy(sourceFD: sourceFD, stageFD: stageFD, outputToken: outputToken,
                                             baseline: lease.baseline)
        }
        attributes = lease.baseline.expectedStageAttributes(
            sourceAttributes: renderedPNG == nil ? sourceAttributes : [:], outputToken: outputToken)
        identity = try CopyFileState.read(stageFD).identity
        try fault(.afterCopy)
        try fault(.beforeVerification)
        try verifySource()
        digest = try renderedPNG.map { Data(SHA256.hash(data: $0)) } ?? copyDigest(sourceFD)
        try verifyContents(stageFD)
        try verifySource()
        guard sourceAttributes == (try BoundedScreenshotCopy.attributes(sourceFD)) else {
            throw copyFailure(.sourceChanged, "Screenshot metadata changed while copying.")
        }
        try verifyStagePath()
        try verifyDirectories()
        guard fsync(stageFD) == 0 else { throw posixCopyFailure(.ioFailure, "Flush screenshot stage") }
        try lease.transition(.prepared)
    }

    func publish(named filename: String) throws -> VerifiedScreenshotCopy {
        try validateCopyComponent(filename)
        guard stageOwned, publishedURL == nil else {
            throw copyFailure(.ioFailure, "Screenshot stage is no longer available.")
        }
        do {
            try Task.checkCancellation()
            try fault(.beforePublish)
            var existing = stat()
            if fstatat(directoryFD, filename, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                throw copyFailure(.collision, "Destination filename already exists.")
            }
            if errno != ENOENT { throw posixCopyFailure(.destinationUnavailable, "Inspect destination filename") }
            try verifySource()
            try verifyDirectories()
            try verifyStagePath()
            try verifyContents(stageFD)
            try lease.transition(.publishing)
            try race(.afterStageVerificationBeforePublish, stageURL)
            // Reads the pinned stage inode, never its mutable pathname. Atomic and exclusive.
            // Unsupported filesystems fail safely; a pathname-rename fallback is not safe.
            guard clone(stageFD, directoryFD, filename) == 0 else {
                if errno == EEXIST { throw copyFailure(.collision, "Destination filename already exists.") }
                throw posixCopyFailure(.destinationUnavailable, "Clone screenshot into destination (clone support required)")
            }
            let output = directory.appendingPathComponent(filename)
            publishedURL = output
            try race(.afterCloneBeforeOutputOpen, stageURL)
            outputFD = openat(directoryFD, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard outputFD >= 0 else { throw posixCopyFailure(.verificationFailed, "Open published screenshot") }
            let outputState = try CopyFileState.read(outputFD)
            guard outputState.regular else { throw copyFailure(.verificationFailed, "Published screenshot is not a regular file.") }
            guard outputState.identity.device != identity.device || outputState.identity.inode != identity.inode else {
                throw copyFailure(.verificationFailed, "Published screenshot was replaced with a link to its stage.")
            }
            try verifyContents(outputFD)
            outputIdentity = outputState.identity
            try fault(.afterPublish)
            try verifyDirectories()
            try verifyContents(outputFD)
            try verifySource()
            guard recoveryURL(preferred: output) == output else {
                throw copyFailure(.verificationFailed, "Published screenshot path changed during verification.")
            }
            guard fsync(directoryFD) == 0 else { throw posixCopyFailure(.ioFailure, "Flush destination directory") }
            // Output verification is complete. Housekeeping cannot revoke this receipt.
            let housekeeping: ScreenshotStageHousekeeping
            do {
                try race(.afterStageIdentityCheckBeforeCleanup, stageURL)
                housekeeping = lease.reset(knownOutputFD: outputFD)
            } catch {
                let reason = "Private staging cleanup was interrupted: \(error.localizedDescription)"
                lease.retire(reason)
                housekeeping = .retired(reason)
            }
            stageOwned = false
            return VerifiedScreenshotCopy(destinationURL: output, identity: outputState.identity,
                                          outputToken: outputToken, housekeeping: housekeeping)
        } catch {
            if let publishedURL {
                var failure = (error as? ScreenshotCopyFailure)
                    ?? copyFailure(.verificationFailed, "Published screenshot requires verification: \(error.localizedDescription)")
                failure.recoverableDestination = recoveryURL(preferred: publishedURL)
                throw failure
            }
            throw error
        }
    }

    func discard() {
        guard stageOwned else { return }
        stageOwned = false
        // Uncertain or unpublished transactions are never reset. Their fixed slot
        // remains charged at its full allowance until a reviewed recovery action.
        lease.retire("Screenshot transaction ended without verified publication.")
    }

    private func recoveryURL(preferred: URL) -> URL? {
        guard let outputIdentity, outputFD >= 0 else { return nil }
        func stillIdentifiesOutput(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0 && CopyFileState(info).regular
                && CopyFileState(info).identity == outputIdentity
        }
        if stillIdentifiesOutput(preferred) { return preferred }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBytes { fcntl(outputFD, F_GETPATH, $0.baseAddress!) }
        guard result == 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let current = URL(fileURLWithPath: path)
        return stillIdentifiesOutput(current) ? current : nil
    }

    private func verifySource() throws {
        if let expectedSourceDigest {
            let actual = try copyDigest(sourceFD).map { String(format: "%02x", $0) }.joined()
            let currentAttributes = try BoundedScreenshotCopy.attributes(sourceFD)
            guard actual == expectedSourceDigest,
                  sourceAttributes == nil || sourceAttributes == currentAttributes else {
                throw copyFailure(.sourceChanged, "Annotation source bytes or metadata changed; the original was retained.")
            }
        }
        let current = try CopyFileState.read(sourceFD)
        var pathInfo = stat()
        guard current == initial, lstat(source.path, &pathInfo) == 0,
              CopyFileState(pathInfo) == initial else {
            throw copyFailure(.sourceChanged, "Screenshot changed during copying; the source was retained.")
        }
    }

    private func verifyDirectories() throws {
        for (url, expected) in directories {
            let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw posixCopyFailure(.destinationUnavailable, "Reopen destination directory") }
            defer { close(descriptor) }
            guard try CopyFileState.read(descriptor).identity == expected else {
                throw copyFailure(.destinationUnavailable, "Destination directory changed during copying.")
            }
        }
    }

    private func verifyStagePath() throws {
        var info = stat()
        guard lstat(stageURL.path, &info) == 0,
              CopyFileState(info).regular, CopyFileState(info).identity == identity else {
            throw copyFailure(.verificationFailed, "Screenshot stage identity changed.")
        }
    }

    private func verifyContents(_ descriptor: Int32) throws {
        guard try copyDigest(descriptor) == digest, try BoundedScreenshotCopy.attributes(descriptor) == attributes else {
            throw copyFailure(.verificationFailed, "Screenshot bytes or metadata did not match the source.")
        }
    }
}

private struct CopyFileState: Equatable {
    let identity: ScreenshotFileIdentity
    let size: Int64
    let modified: Int64
    let changed: Int64
    let mode: mode_t
    var regular: Bool { (mode & S_IFMT) == S_IFREG }

    init(_ info: stat) {
        identity = ScreenshotFileIdentity(
            device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino),
            birthNanoseconds: Self.nanoseconds(info.st_birthtimespec)
        )
        size = info.st_size
        modified = Self.nanoseconds(info.st_mtimespec)
        changed = Self.nanoseconds(info.st_ctimespec)
        mode = info.st_mode
    }

    static func read(_ descriptor: Int32) throws -> Self {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixCopyFailure(.ioFailure, "Inspect screenshot descriptor") }
        return Self(info)
    }

    private static func nanoseconds(_ time: timespec) -> Int64 {
        Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
    }
}

private func copyDigest(_ descriptor: Int32) throws -> Data {
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 256 * 1024)
    var offset: off_t = 0
    let expectedSize = try CopyFileState.read(descriptor).size
    guard expectedSize >= 0, expectedSize <= Int64(ScreenshotStagingLimits.maximumPayloadBytes) else {
        throw copyFailure(.verificationFailed, "Screenshot exceeds the bounded verification size.")
    }
    while offset < expectedSize {
        try Task.checkCancellation()
        let requested = Int(min(Int64(buffer.count), expectedSize - offset))
        let count = pread(descriptor, &buffer, requested, offset)
        if count < 0 {
            if errno == EINTR { continue }
            throw posixCopyFailure(.ioFailure, "Read screenshot for verification")
        }
        if count == 0 { throw copyFailure(.verificationFailed, "Screenshot size changed during verification.") }
        buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
        offset += off_t(count)
    }
    guard try CopyFileState.read(descriptor).size == expectedSize else {
        throw copyFailure(.verificationFailed, "Screenshot size changed during verification.")
    }
    return Data(hasher.finalize())
}

private func validateCopyComponent(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
          name.utf8.count <= Int(NAME_MAX) else {
        throw copyFailure(.invalidName, "Destination name must be a single valid filename component.")
    }
}

private func copyFailure(_ code: ScreenshotCopyFailure.Code, _ detail: String) -> ScreenshotCopyFailure {
    ScreenshotCopyFailure(code: code, detail: detail)
}

private func posixCopyFailure(_ code: ScreenshotCopyFailure.Code, _ operation: String) -> ScreenshotCopyFailure {
    let saved = errno
    return ScreenshotCopyFailure(
        code: saved == EACCES || saved == EPERM ? .permissionDenied : code,
        detail: "\(operation): \(String(cString: strerror(saved))).",
        posixCode: saved
    )
}
