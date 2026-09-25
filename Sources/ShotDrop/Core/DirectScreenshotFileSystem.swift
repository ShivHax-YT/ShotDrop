import CryptoKit
import Darwin
import Foundation

/// One exclusive temporary file beside the destination, atomically published without
/// replacing an existing file. Legacy private pools are neither read nor modified.
struct DirectScreenshotFileSystem: ScreenshotOrganizationFileSystem {
    func stageCopy(source: URL, destinationRoot: URL, subdirectories: [String],
                   expectedIdentity: ScreenshotFileIdentity?) throws -> any ScreenshotStagedCopy {
        try DirectScreenshotTransaction(source: source, destination: destinationRoot,
            components: subdirectories, expectedIdentity: expectedIdentity, rendered: nil, sourceDigest: nil)
    }

    func stageRenderedPNG(source: URL, destinationRoot: URL, expectedIdentity: ScreenshotFileIdentity,
                          expectedSourceDigest: String, png: Data) throws -> any ScreenshotStagedCopy {
        try AnnotationPNGContainer.validate(png)
        return try DirectScreenshotTransaction(source: source, destination: destinationRoot,
            components: [], expectedIdentity: expectedIdentity, rendered: png, sourceDigest: expectedSourceDigest)
    }
}

private struct DirectFileState: Equatable {
    let identity: ScreenshotFileIdentity
    let size: Int64
    let modified: timespec
    let changed: timespec
    static func == (a: Self, b: Self) -> Bool {
        a.identity == b.identity && a.size == b.size && a.modified.tv_sec == b.modified.tv_sec
        && a.modified.tv_nsec == b.modified.tv_nsec && a.changed.tv_sec == b.changed.tv_sec
        && a.changed.tv_nsec == b.changed.tv_nsec
    }
    static func read(_ fd: Int32) throws -> Self {
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG else { throw directError("Read screenshot identity") }
        return Self(identity: .init(device: UInt64(UInt32(bitPattern: s.st_dev)), inode: s.st_ino,
            birthNanoseconds: Int64(s.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(s.st_birthtimespec.tv_nsec)),
            size: s.st_size, modified: s.st_mtimespec, changed: s.st_ctimespec)
    }
}

private final class DirectScreenshotTransaction: ScreenshotStagedCopy {
    let outputToken = UUID()
    private let source: URL
    private var directory: URL
    private var sourceFD: Int32 = -1
    private var directoryFD: Int32 = -1
    private var stageFD: Int32 = -1
    private var temporaryName: String?
    private var initial: DirectFileState!
    private var digest = Data()
    private var attributes: [String: Data] = [:]
    private var published = false
    private(set) var identity = ScreenshotFileIdentity(device: 0, inode: 0, birthNanoseconds: 0)

    init(source: URL, destination: URL, components: [String], expectedIdentity: ScreenshotFileIdentity?,
         rendered: Data?, sourceDigest: String?) throws {
        self.source = source; directory = destination
        do {
            guard source.isFileURL, destination.isFileURL else { throw directError("Use local folders") }
            try Task.checkCancellation()
            sourceFD = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard sourceFD >= 0 else { throw directError("Open original") }
            initial = try DirectFileState.read(sourceFD)
            guard expectedIdentity == nil || expectedIdentity == initial.identity else {
                throw ScreenshotCopyFailure(code: .sourceChanged, detail: "The original changed before saving.")
            }
            directoryFD = open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard directoryFD >= 0 else { throw directError("Open save folder") }
            for component in components {
                try Self.validate(component)
                guard mkdirat(directoryFD, component, 0o700) == 0 || errno == EEXIST else { throw directError("Create date folder") }
                let child = openat(directoryFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw directError("Open date folder") }
                close(directoryFD); directoryFD = child; directory.appendPathComponent(component)
            }
            let name = ".shotdrop-\(outputToken.uuidString).tmp"
            stageFD = openat(directoryFD, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard stageFD >= 0 else { throw directError("Create temporary copy") }
            temporaryName = name
            identity = try DirectFileState.read(stageFD).identity
            let baseline = try ScreenshotStagingBaseline.capture(stageFD)
            if let rendered {
                if let sourceDigest, try Self.hash(sourceFD).map({ String(format: "%02x", $0) }).joined() != sourceDigest {
                    throw ScreenshotCopyFailure(code: .sourceChanged, detail: "The saved image changed before export.")
                }
                try BoundedScreenshotCopy().writeRendered(rendered, stageFD: stageFD, outputToken: outputToken, baseline: baseline)
                digest = Data(SHA256.hash(data: rendered))
            } else {
                try BoundedScreenshotCopy().copy(sourceFD: sourceFD, stageFD: stageFD, outputToken: outputToken, baseline: baseline)
                digest = try Self.hash(sourceFD)
            }
            attributes = try BoundedScreenshotCopy.attributes(stageFD)
            guard try DirectFileState.read(sourceFD) == initial, Self.samePath(source.path, fd: sourceFD),
                  try Self.hash(stageFD) == digest, fsync(stageFD) == 0 else {
                throw ScreenshotCopyFailure(code: .verificationFailed, detail: "The copy could not be verified. Original retained.")
            }
        } catch { discard(); throw error }
    }

    func publish(named filename: String) throws -> VerifiedScreenshotCopy {
        try Self.validate(filename)
        try Task.checkCancellation()
        guard !published, let temporaryName,
              Self.samePath(source.path, fd: sourceFD), try DirectFileState.read(sourceFD) == initial,
              Self.samePath(directory.path, fd: directoryFD),
              Self.samePath(directory.appendingPathComponent(temporaryName).path, fd: stageFD),
              try Self.hash(stageFD) == digest,
              try BoundedScreenshotCopy.attributes(stageFD) == attributes else {
            throw ScreenshotCopyFailure(code: .sourceChanged, detail: "A file or folder changed during saving. Original retained.")
        }
        guard renameatx_np(directoryFD, temporaryName, directoryFD, filename, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw ScreenshotCopyFailure(code: .collision, detail: "Filename already exists.") }
            throw directError("Publish screenshot")
        }
        published = true; self.temporaryName = nil
        let output = directory.appendingPathComponent(filename)
        guard Self.samePath(output.path, fd: stageFD), try Self.hash(stageFD) == digest,
              try BoundedScreenshotCopy.attributes(stageFD) == attributes, fsync(directoryFD) == 0 else {
            throw ScreenshotCopyFailure(code: .verificationFailed, detail: "A copy was written, but final verification failed.", recoverableDestination: output)
        }
        return VerifiedScreenshotCopy(destinationURL: output, identity: identity, outputToken: outputToken)
    }

    func discard() {
        if let temporaryName, directoryFD >= 0, stageFD >= 0 {
            var held = stat(); var path = stat()
            if fstat(stageFD, &held) == 0, fstatat(directoryFD, temporaryName, &path, AT_SYMLINK_NOFOLLOW) == 0,
               held.st_dev == path.st_dev, held.st_ino == path.st_ino { _ = unlinkat(directoryFD, temporaryName, 0) }
        }
        temporaryName = nil
        if stageFD >= 0 { close(stageFD); stageFD = -1 }
        if directoryFD >= 0 { close(directoryFD); directoryFD = -1 }
        if sourceFD >= 0 { close(sourceFD); sourceFD = -1 }
    }
    deinit { discard() }
    private static func validate(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw ScreenshotCopyFailure(code: .invalidName, detail: "Invalid filename component.")
        }
    }
    private static func samePath(_ path: String, fd: Int32) -> Bool {
        var a = stat(); var b = stat()
        return fstat(fd, &a) == 0 && lstat(path, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino
            && a.st_birthtimespec.tv_sec == b.st_birthtimespec.tv_sec && a.st_birthtimespec.tv_nsec == b.st_birthtimespec.tv_nsec
    }
    private static func hash(_ fd: Int32) throws -> Data {
        let state = try DirectFileState.read(fd)
        guard state.size >= 0, state.size <= ScreenshotStagingLimits.maximumPayloadBytes else {
            throw ScreenshotCopyFailure(code: .verificationFailed, detail: "Screenshot exceeds the 64 MB limit.")
        }
        var hasher = SHA256(); var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while offset < state.size {
            try Task.checkCancellation()
            let count = pread(fd, &buffer, min(buffer.count, Int(state.size - offset)), off_t(offset))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw directError("Verify screenshot bytes") }
            hasher.update(data: Data(buffer.prefix(count))); offset += Int64(count)
        }
        guard try DirectFileState.read(fd) == state else { throw ScreenshotCopyFailure(code: .sourceChanged, detail: "File changed while verifying.") }
        return Data(hasher.finalize())
    }
}

private func directError(_ operation: String) -> ScreenshotCopyFailure {
    let code = errno
    return ScreenshotCopyFailure(code: code == EACCES || code == EPERM ? .permissionDenied : .ioFailure,
        detail: "\(operation): \(String(cString: strerror(code)))", posixCode: code)
}
