import Darwin
import Foundation

enum ShotDropSetupSourceResolution: Equatable, Sendable {
    case known(URL)
    case unknown
}

/// This is a live setup-session identity, never a persisted volume identity or an enrollment attestation.
struct ShotDropSetupDirectoryIdentity: Equatable, Sendable {
    let path: String
    let device: UInt64
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
}

enum ShotDropSetupAccessIssue: Error, Equatable, Sendable {
    case missing, denied, changed, unsupported, unsafe, unavailable
}

enum ShotDropSetupSourceAccessResult: Equatable, Sendable {
    case accessible(ShotDropSetupDirectoryIdentity)
    case unavailable(ShotDropSetupAccessIssue)
}

enum ShotDropSetupDestinationAccessResult: Equatable, Sendable {
    /// Read-only checks are insufficient to issue the ordinary-local review required by staging.
    case needsReview(ShotDropSetupDirectoryIdentity)
    case unavailable(ShotDropSetupAccessIssue)
}

protocol ShotDropSetupAccessServing: Sendable {
    func discoverSource() async -> ShotDropSetupSourceResolution
    func checkSource(_ url: URL, expecting: ShotDropSetupDirectoryIdentity?) async -> ShotDropSetupSourceAccessResult
    func checkDestination(
        _ url: URL, source: URL?, sourceIdentity: ShotDropSetupDirectoryIdentity?
    ) async -> ShotDropSetupDestinationAccessResult
}

/// Narrow read-only operations allow permission/error fixtures without accessing protected user folders.
struct ShotDropSetupAccessOperations: Sendable {
    var openDirectory: @Sendable (URL) throws -> Int32 = { url in
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw setupAccessPOSIX(errno) }
        return descriptor
    }
    var enumerateDirectory: @Sendable (Int32) throws -> Void = { descriptor in
        let copied = dup(descriptor)
        guard copied >= 0 else { throw setupAccessPOSIX(errno) }
        guard let directory = fdopendir(copied) else {
            let code = errno
            close(copied)
            throw setupAccessPOSIX(code)
        }
        defer { closedir(directory) }
        // One real directory read exercises access, including on an empty directory.
        // Names are neither stored nor logged, and no child file is opened.
        errno = 0
        if readdir(directory) == nil && errno != 0 { throw setupAccessPOSIX(errno) }
    }
    var checkDestinationWritable: @Sendable (Int32) throws -> Void = { descriptor in
        guard faccessat(descriptor, ".", W_OK | X_OK, AT_EACCESS) == 0 else {
            throw setupAccessPOSIX(errno)
        }
    }
    var inspectDestination: @Sendable (Int32) throws -> Void = { descriptor in
        do {
            _ = try ScreenshotStagingLocalPathPolicy.checkedPath(descriptor)
            try DarwinScreenshotStagingVolumeInspector().inspect(descriptor).requireSupported()
        } catch {
            throw ShotDropSetupAccessIssue.unsupported
        }
    }
}

/// Discovery reads only an explicit screenshot preference. Filesystem checks run solely when
/// the setup model calls them after Continue; this service never creates folders, probes, or pools.
struct LocalShotDropSetupAccessService: ShotDropSetupAccessServing {
    private let readLocationPreference: @Sendable () -> String?
    private let homeDirectory: URL
    private let operations: ShotDropSetupAccessOperations

    init(
        readLocationPreference: @escaping @Sendable () -> String? = {
            CFPreferencesCopyValue(
                "location" as CFString, "com.apple.screencapture" as CFString,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost
            ) as? String
        },
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        operations: ShotDropSetupAccessOperations = ShotDropSetupAccessOperations()
    ) {
        self.readLocationPreference = readLocationPreference
        self.homeDirectory = homeDirectory
        self.operations = operations
    }

    func discoverSource() async -> ShotDropSetupSourceResolution {
        await setupAccessInBackground {
            guard !Task.isCancelled, let value = readLocationPreference(), !value.isEmpty else { return .unknown }
            let path: String
            if value.hasPrefix("~/") {
                path = homeDirectory.path + String(value.dropFirst())
            } else {
                path = value
            }
            guard Self.isValidPath(path) else { return .unknown }
            return .known(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    func checkSource(
        _ url: URL, expecting: ShotDropSetupDirectoryIdentity? = nil
    ) async -> ShotDropSetupSourceAccessResult {
        await setupAccessInBackground {
            do { return .accessible(try inspectSource(url, expecting: expecting)) }
            catch { return .unavailable(Self.issue(error)) }
        }
    }

    func checkDestination(
        _ url: URL, source: URL? = nil, sourceIdentity: ShotDropSetupDirectoryIdentity? = nil
    ) async -> ShotDropSetupDestinationAccessResult {
        await setupAccessInBackground {
            do {
                try Task.checkCancellation()
                try Self.validateURL(url)
                let descriptor = try operations.openDirectory(url)
                defer { close(descriptor) }
                let identity = try Self.identity(descriptor, url: url)
                try operations.checkDestinationWritable(descriptor)
                try operations.inspectDestination(descriptor)
                if let source {
                    guard let sourceIdentity else { throw ShotDropSetupAccessIssue.changed }
                    _ = try inspectSource(source, expecting: sourceIdentity)
                    do {
                        try LocalScreenshotDestinationValidator().validate(sourceDirectory: source, destinationDirectory: url)
                    } catch let error as ScreenshotDestinationValidationFailure {
                        if error.code == .overlap || error.code == .invalidPath { throw ShotDropSetupAccessIssue.unsafe }
                        throw ShotDropSetupAccessIssue.changed
                    }
                    _ = try inspectSource(source, expecting: sourceIdentity)
                } else if sourceIdentity != nil {
                    throw ShotDropSetupAccessIssue.unsafe
                }
                try confirm(url, identity: identity)
                try Task.checkCancellation()
                return .needsReview(identity)
            } catch { return .unavailable(Self.issue(error)) }
        }
    }

    private func inspectSource(
        _ url: URL, expecting: ShotDropSetupDirectoryIdentity?
    ) throws -> ShotDropSetupDirectoryIdentity {
        try Task.checkCancellation()
        try Self.validateURL(url)
        if let expecting, expecting.path != url.path { throw ShotDropSetupAccessIssue.changed }
        let descriptor: Int32
        do { descriptor = try operations.openDirectory(url) }
        catch ShotDropSetupAccessIssue.missing where expecting != nil { throw ShotDropSetupAccessIssue.changed }
        defer { close(descriptor) }
        let identity = try Self.identity(descriptor, url: url)
        if let expecting, expecting != identity { throw ShotDropSetupAccessIssue.changed }
        try operations.enumerateDirectory(descriptor)
        try confirm(url, identity: identity)
        try Task.checkCancellation()
        return identity
    }

    private func confirm(_ url: URL, identity: ShotDropSetupDirectoryIdentity) throws {
        let descriptor: Int32
        do { descriptor = try operations.openDirectory(url) }
        catch { throw ShotDropSetupAccessIssue.changed }
        defer { close(descriptor) }
        guard try Self.identity(descriptor, url: url) == identity else { throw ShotDropSetupAccessIssue.changed }
    }

    private static func identity(_ descriptor: Int32, url: URL) throws -> ShotDropSetupDirectoryIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw setupAccessPOSIX(errno) }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw ShotDropSetupAccessIssue.unsafe }
        return ShotDropSetupDirectoryIdentity(
            path: url.path, device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino),
            birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec)
        )
    }

    private static func isValidPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0")
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    private static func validateURL(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              isValidPath(url.path) else { throw ShotDropSetupAccessIssue.unsafe }
    }

    private static func issue(_ error: Error) -> ShotDropSetupAccessIssue {
        (error as? ShotDropSetupAccessIssue) ?? .unavailable
    }
}

private func setupAccessPOSIX(_ code: Int32) -> ShotDropSetupAccessIssue {
    switch code {
    case ENOENT, ENOTDIR: .missing
    case EACCES, EPERM: .denied
    case ELOOP: .unsafe
    default: .unavailable
    }
}

private func setupAccessInBackground<Value: Sendable>(
    _ operation: @escaping @Sendable () -> Value
) async -> Value {
    let worker = Task.detached(priority: .utility, operation: operation)
    return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
}
