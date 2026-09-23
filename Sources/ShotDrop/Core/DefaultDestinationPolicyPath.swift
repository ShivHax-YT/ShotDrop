import Darwin
import Foundation

enum DefaultDestinationPolicyIssue: Error, Equatable, Sendable {
    case redirectedHome, missingPictures, unsafePath, changed, unsupported, cloudStatusUnknown, providerStatusUnknown
}

struct DefaultDestinationDirectoryIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64

    init(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw DefaultDestinationPolicyIssue.unsafePath
        }
        device = UInt64(UInt32(bitPattern: info.st_dev))
        inode = UInt64(info.st_ino)
        birthSeconds = Int64(info.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
    }
}

/// Immutable policy result. The descriptor exists only inside `withInspectedParent`.
struct DefaultDestinationPolicyPathInspection: Sendable {
    let identity: DefaultDestinationDirectoryIdentity
    let homeIdentity: DefaultDestinationDirectoryIdentity
    let path: URL
    let childPath: URL
    let volume: ScreenshotStagingVolume
}

struct DefaultDestinationPolicyOperations: Sendable {
    var inspectVolume: @Sendable (Int32) throws -> ScreenshotStagingVolume = {
        try DarwinScreenshotStagingVolumeInspector().inspect($0)
    }
    /// `false` is an explicit negative result. Unknown and errors fail closed.
    var isUbiquitous: @Sendable (URL) throws -> Bool? = {
        try DefaultDestinationUbiquityEvidence.inspect($0)
    }
    /// Nil selects Main's approved ordinary-home support assumption, after the exact path,
    /// volume and iCloud gates. It is not a measured negative provider result. If a caller
    /// supplies additional evidence, a positive, unknown or failed query rejects the path.
    var isProviderManaged: (@Sendable (URL, Int32) throws -> Bool?)? = nil

    func checkProviderPolicy(_ url: URL, descriptor: Int32) throws {
        guard let isProviderManaged else { return }
        let evidence: Bool?
        do { evidence = try isProviderManaged(url, descriptor) }
        catch { throw DefaultDestinationPolicyIssue.providerStatusUnknown }
        guard evidence == false else {
            throw evidence == true ? DefaultDestinationPolicyIssue.unsupported : .providerStatusUnknown
        }
    }
}

/// FileManager supplies an explicit Boolean for iCloud targeting; the optional URL
/// resource value can be absent for an ordinary local directory. A false Boolean
/// also describes a missing item, so require the same existing no-follow directory
/// on both sides of that path-based query. This is not provider-management evidence.
enum DefaultDestinationUbiquityEvidence {
    static func inspect(_ url: URL,
                        query: (URL) throws -> Bool = { FileManager.default.isUbiquitousItem(at: $0) }) throws -> Bool {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              !url.path.contains("\0") else { throw DefaultDestinationPolicyIssue.unsafePath }
        let held = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard held >= 0 else { throw DefaultDestinationPolicyIssue.cloudStatusUnknown }
        defer { close(held) }
        let identity = try DefaultDestinationDirectoryIdentity(held)
        let result = try query(url)
        let current = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard current >= 0 else { throw DefaultDestinationPolicyIssue.changed }
        defer { close(current) }
        guard try DefaultDestinationDirectoryIdentity(current) == identity,
              try DefaultDestinationDirectoryIdentity(held) == identity else {
            throw DefaultDestinationPolicyIssue.changed
        }
        return result
    }
}

/// Inspects only the exact existing account-home/Pictures parent. No child lookup,
/// creation, staging registration, or final destination attestation occurs here.
struct DefaultDestinationPolicyPathInspector: Sendable {
    let accountsRoot: URL
    let accountName: String
    let accountRecordHome: URL
    let requestedHome: URL
    let standardPictures: URL?
    let operations: DefaultDestinationPolicyOperations

    init(accountsRoot: URL = URL(fileURLWithPath: "/Users", isDirectory: true),
         accountName: String = NSUserName(),
         accountRecordHome: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
         requestedHome: URL = FileManager.default.homeDirectoryForCurrentUser,
         standardPictures: URL? = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first,
         operations: DefaultDestinationPolicyOperations = .init()) {
        self.accountsRoot = accountsRoot
        self.accountName = accountName
        self.accountRecordHome = accountRecordHome
        self.requestedHome = requestedHome
        self.standardPictures = standardPictures
        self.operations = operations
    }

    func withInspectedParent<R>(
        _ body: (Int32, DefaultDestinationPolicyPathInspection) throws -> R
    ) throws -> R {
        guard isSingleComponent(accountName), isAbsoluteClean(accountsRoot),
              isAbsoluteClean(accountRecordHome), isAbsoluteClean(requestedHome) else {
            throw DefaultDestinationPolicyIssue.redirectedHome
        }
        let expectedHome = accountsRoot.appendingPathComponent(accountName, isDirectory: true)
        let expectedPictures = expectedHome.appendingPathComponent("Pictures", isDirectory: true)
        guard accountRecordHome.path == expectedHome.path,
              requestedHome.path == expectedHome.path,
              let standardPictures, isAbsoluteClean(standardPictures),
              standardPictures.path == expectedPictures.path else {
            throw DefaultDestinationPolicyIssue.redirectedHome
        }
        let homeFD = try openPathFromRoot(expectedHome.path)
        defer { close(homeFD) }
        let homeIdentity = try DefaultDestinationDirectoryIdentity(homeFD)
        try requireOwnedParent(homeFD)
        let picturesFD = openat(homeFD, "Pictures", O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard picturesFD >= 0 else {
            throw errno == ENOENT ? DefaultDestinationPolicyIssue.missingPictures : DefaultDestinationPolicyIssue.unsafePath
        }
        defer { close(picturesFD) }
        let picturesIdentity = try DefaultDestinationDirectoryIdentity(picturesFD)
        try requireOwnedParent(picturesFD)
        guard homeIdentity.device == picturesIdentity.device else {
            throw DefaultDestinationPolicyIssue.unsupported
        }
        let picturesPath = expectedPictures
        do { try ScreenshotStagingLocalPathPolicy.rejectKnownManagedPath(picturesPath) }
        catch { throw DefaultDestinationPolicyIssue.unsafePath }
        let volume: ScreenshotStagingVolume
        do {
            volume = try operations.inspectVolume(picturesFD)
            try volume.requireSupported()
        } catch { throw DefaultDestinationPolicyIssue.unsupported }
        guard volume.device == picturesIdentity.device else { throw DefaultDestinationPolicyIssue.changed }
        let cloud: Bool?
        do { cloud = try operations.isUbiquitous(picturesPath) }
        catch { throw DefaultDestinationPolicyIssue.cloudStatusUnknown }
        guard cloud == false else {
            throw cloud == true ? DefaultDestinationPolicyIssue.unsupported : DefaultDestinationPolicyIssue.cloudStatusUnknown
        }
        try operations.checkProviderPolicy(picturesPath, descriptor: picturesFD)
        let currentHome = try openPathFromRoot(expectedHome.path)
        defer { close(currentHome) }
        let currentPictures = openat(currentHome, "Pictures", O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard currentPictures >= 0 else { throw DefaultDestinationPolicyIssue.changed }
        defer { close(currentPictures) }
        guard try DefaultDestinationDirectoryIdentity(currentHome) == homeIdentity,
              try DefaultDestinationDirectoryIdentity(currentPictures) == picturesIdentity else {
            throw DefaultDestinationPolicyIssue.changed
        }
        let inspection = DefaultDestinationPolicyPathInspection(
            identity: picturesIdentity, homeIdentity: homeIdentity, path: picturesPath,
            childPath: picturesPath.appendingPathComponent("ShotDrop", isDirectory: true), volume: volume
        )
        return try body(picturesFD, inspection)
    }

    func revalidate(_ parent: DefaultDestinationPolicyPathInspection, parentDescriptor: Int32) throws {
        let expectedHome = accountsRoot.appendingPathComponent(accountName, isDirectory: true)
        let expectedPictures = expectedHome.appendingPathComponent("Pictures", isDirectory: true)
        guard accountRecordHome.path == expectedHome.path, requestedHome.path == expectedHome.path,
              standardPictures?.path == expectedPictures.path,
              parent.path.path == expectedPictures.path,
              try DefaultDestinationDirectoryIdentity(parentDescriptor) == parent.identity else {
            throw DefaultDestinationPolicyIssue.changed
        }
        let homeFD = try openPathFromRoot(expectedHome.path)
        defer { close(homeFD) }
        let picturesFD = openat(homeFD, "Pictures", O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard picturesFD >= 0 else { throw DefaultDestinationPolicyIssue.changed }
        defer { close(picturesFD) }
        guard try DefaultDestinationDirectoryIdentity(homeFD) == parent.homeIdentity,
              try DefaultDestinationDirectoryIdentity(picturesFD) == parent.identity else {
            throw DefaultDestinationPolicyIssue.changed
        }
        do { try ScreenshotStagingLocalPathPolicy.rejectKnownManagedPath(parent.path) }
        catch { throw DefaultDestinationPolicyIssue.unsafePath }
        let volume: ScreenshotStagingVolume
        do {
            volume = try operations.inspectVolume(parentDescriptor)
            try volume.requireSupported()
        } catch { throw DefaultDestinationPolicyIssue.unsupported }
        guard volume == parent.volume else { throw DefaultDestinationPolicyIssue.changed }
        let cloud: Bool?
        do { cloud = try operations.isUbiquitous(parent.path) }
        catch { throw DefaultDestinationPolicyIssue.cloudStatusUnknown }
        guard cloud == false else { throw cloud == true ? DefaultDestinationPolicyIssue.unsupported : DefaultDestinationPolicyIssue.cloudStatusUnknown }
        try operations.checkProviderPolicy(parent.path, descriptor: parentDescriptor)
        let confirmedHome = try openPathFromRoot(expectedHome.path)
        defer { close(confirmedHome) }
        let confirmedPictures = openat(confirmedHome, "Pictures", O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard confirmedPictures >= 0 else { throw DefaultDestinationPolicyIssue.changed }
        defer { close(confirmedPictures) }
        guard try DefaultDestinationDirectoryIdentity(confirmedHome) == parent.homeIdentity,
              try DefaultDestinationDirectoryIdentity(confirmedPictures) == parent.identity else {
            throw DefaultDestinationPolicyIssue.changed
        }
        try requireOwnedParent(confirmedHome)
        try requireOwnedParent(confirmedPictures)
    }

    private func requireOwnedParent(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & 0o022 == 0 else { throw DefaultDestinationPolicyIssue.unsafePath }
    }

    private func isSingleComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private func isAbsoluteClean(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
            && url.path.hasPrefix("/") && !url.path.contains("\0")
            && !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    private func openPathFromRoot(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/") else { throw DefaultDestinationPolicyIssue.unsafePath }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard current >= 0 else { throw DefaultDestinationPolicyIssue.unsafePath }
        for component in path.split(separator: "/") {
            let next = component.withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
            }
            close(current)
            guard next >= 0 else {
                throw errno == ENOENT ? DefaultDestinationPolicyIssue.missingPictures : DefaultDestinationPolicyIssue.unsafePath
            }
            current = next
        }
        return current
    }
}
