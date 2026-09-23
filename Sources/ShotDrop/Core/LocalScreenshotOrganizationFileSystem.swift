import CryptoKit
import Darwin
import Foundation

/// Descriptor-relative, source-preserving publication. The transaction is actor confined.
struct LocalScreenshotOrganizationFileSystem: ScreenshotOrganizationFileSystem {
    private let fault: @Sendable (ScreenshotCopyPhase) throws -> Void

    init(fault: @escaping @Sendable (ScreenshotCopyPhase) throws -> Void = { _ in }) {
        self.fault = fault
    }

    func stageCopy(
        source: URL,
        destinationRoot: URL,
        subdirectories: [String],
        expectedIdentity: ScreenshotFileIdentity?
    ) throws -> any ScreenshotStagedCopy {
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
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
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
        let stageName = ".shotdrop-\(UUID().uuidString).stage"
        let stageFD = openat(directoryFD, stageName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard stageFD >= 0 else { throw posixCopyFailure(.destinationUnavailable, "Create screenshot stage") }
        // Ownership transfers immediately, so every throwing path closes and discards our stage.
        let staged = LocalStagedScreenshotCopy(
            source: source, sourceFD: sourceFD, initial: initial,
            directory: directoryURL, directoryFD: directoryFD, directories: directories,
            stageName: stageName, stageFD: stageFD, fault: fault
        )
        ownsSource = false
        ownsDirectory = false
        try staged.prepare()
        return staged
    }
}

private final class LocalStagedScreenshotCopy: ScreenshotStagedCopy {
    private let source: URL
    private let sourceFD: Int32
    private let initial: CopyFileState
    private let directory: URL
    private let directoryFD: Int32
    private let directories: [(URL, ScreenshotFileIdentity)]
    private let stageName: String
    private let stageFD: Int32
    private let fault: @Sendable (ScreenshotCopyPhase) throws -> Void
    private var stageOwned = true
    private var publishedURL: URL?
    private var digest = Data()
    private var attributes: [String: Data] = [:]
    private(set) var identity: ScreenshotFileIdentity

    init(source: URL, sourceFD: Int32, initial: CopyFileState,
         directory: URL, directoryFD: Int32, directories: [(URL, ScreenshotFileIdentity)],
         stageName: String, stageFD: Int32,
         fault: @escaping @Sendable (ScreenshotCopyPhase) throws -> Void) {
        self.source = source
        self.sourceFD = sourceFD
        self.initial = initial
        self.directory = directory
        self.directoryFD = directoryFD
        self.directories = directories
        self.stageName = stageName
        self.stageFD = stageFD
        self.fault = fault
        // fstat on our newly opened descriptor cannot ordinarily fail; prepare verifies it.
        var info = stat()
        _ = fstat(stageFD, &info)
        identity = CopyFileState(info).identity
    }

    deinit {
        discard()
        close(stageFD)
        close(directoryFD)
        close(sourceFD)
    }

    func prepare() throws {
        try fault(.beforeCopy)
        try verifySource()
        try verifyDirectories()
        attributes = try copyAttributes(sourceFD)
        guard fcopyfile(sourceFD, stageFD, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
            throw posixCopyFailure(.ioFailure, "Copy screenshot data and metadata")
        }
        identity = try CopyFileState.read(stageFD).identity
        try fault(.afterCopy)
        try fault(.beforeVerification)
        try verifySource()
        digest = try copyDigest(sourceFD)
        try verifyStageContents()
        try verifySource()
        guard attributes == (try copyAttributes(sourceFD)) else {
            throw copyFailure(.sourceChanged, "Screenshot metadata changed while copying.")
        }
        try verifyStagePath(stageName)
        try verifyDirectories()
        guard fsync(stageFD) == 0 else { throw posixCopyFailure(.ioFailure, "Flush screenshot stage") }
    }

    func publish(named filename: String) throws -> VerifiedScreenshotCopy {
        try validateCopyComponent(filename)
        guard stageOwned, publishedURL == nil else {
            throw copyFailure(.ioFailure, "Screenshot stage is no longer available.")
        }
        do {
            try Task.checkCancellation()
            try fault(.beforePublish)
            // Skip known collisions cheaply. Exclusive rename below still arbitrates races.
            var existing = stat()
            if fstatat(directoryFD, filename, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                throw copyFailure(.collision, "Destination filename already exists.")
            }
            if errno != ENOENT { throw posixCopyFailure(.destinationUnavailable, "Inspect destination filename") }
            try verifySource()
            try verifyDirectories()
            try verifyStagePath(stageName)
            try verifyStageContents()
            guard renameatx_np(directoryFD, stageName, directoryFD, filename, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw copyFailure(.collision, "Destination filename already exists.") }
                throw posixCopyFailure(.destinationUnavailable, "Publish screenshot")
            }
            stageOwned = false
            let output = directory.appendingPathComponent(filename)
            publishedURL = output
            try fault(.afterPublish)
            try verifyStagePath(filename)
            try verifyDirectories()
            try verifyStageContents()
            try verifySource()
            guard fsync(directoryFD) == 0 else { throw posixCopyFailure(.ioFailure, "Flush destination directory") }
            return VerifiedScreenshotCopy(destinationURL: output, identity: identity)
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
        // Only unlink the hidden name if it still denotes the exact inode we created.
        var pathInfo = stat()
        var descriptorInfo = stat()
        if fstat(stageFD, &descriptorInfo) == 0,
           fstatat(directoryFD, stageName, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
           pathInfo.st_dev == descriptorInfo.st_dev, pathInfo.st_ino == descriptorInfo.st_ino,
           (pathInfo.st_mode & S_IFMT) == S_IFREG {
            _ = unlinkat(directoryFD, stageName, 0)
        }
        stageOwned = false
    }

    private func recoveryURL(preferred: URL) -> URL? {
        func stillIdentifiesOutput(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0 && CopyFileState(info).regular
                && CopyFileState(info).identity == identity
        }
        if stillIdentifiesOutput(preferred) { return preferred }
        // A caller may have moved the directory after publication. Do not return a stale
        // URL that now names nothing (or an unrelated replacement file).
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBytes { fcntl(stageFD, F_GETPATH, $0.baseAddress!) }
        guard result == 0 else { return nil }
        let current = URL(fileURLWithPath: String(cString: buffer))
        return stillIdentifiesOutput(current) ? current : nil
    }

    private func verifySource() throws {
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

    private func verifyStagePath(_ name: String) throws {
        var info = stat()
        guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              CopyFileState(info).regular, CopyFileState(info).identity == identity else {
            throw copyFailure(.verificationFailed, "Screenshot destination identity changed.")
        }
    }

    private func verifyStageContents() throws {
        guard try copyDigest(stageFD) == digest, try copyAttributes(stageFD) == attributes else {
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

/// Bound metadata allocation independently of image size. Oversized metadata fails safely.
private func copyAttributes(_ descriptor: Int32) throws -> [String: Data] {
    let listSize = flistxattr(descriptor, nil, 0, 0)
    guard listSize >= 0 else { throw posixCopyFailure(.verificationFailed, "Read screenshot metadata names") }
    guard listSize <= 1024 * 1024 else { throw copyFailure(.verificationFailed, "Screenshot metadata list is too large.") }
    if listSize == 0 { return [:] }
    var names = [CChar](repeating: 0, count: listSize)
    let readSize = flistxattr(descriptor, &names, names.count, 0)
    guard readSize == listSize else { throw copyFailure(.verificationFailed, "Screenshot metadata changed during verification.") }
    let decoded = names.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    var result: [String: Data] = [:]
    for name in decoded {
        try Task.checkCancellation()
        let size = fgetxattr(descriptor, name, nil, 0, 0, 0)
        guard size >= 0 else { throw posixCopyFailure(.verificationFailed, "Read screenshot metadata size") }
        guard size <= 16 * 1024 * 1024 else { throw copyFailure(.verificationFailed, "Screenshot metadata value is too large to verify safely.") }
        var value = Data(count: size)
        let actual = value.withUnsafeMutableBytes { fgetxattr(descriptor, name, $0.baseAddress, size, 0, 0) }
        guard actual == size else { throw copyFailure(.verificationFailed, "Screenshot metadata changed during verification.") }
        result[name] = Data(SHA256.hash(data: value))
    }
    return result
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
    return copyFailure(saved == EACCES || saved == EPERM ? .permissionDenied : code,
                       "\(operation): \(String(cString: strerror(saved))).")
}
