import CryptoKit
import Darwin
import Foundation

enum RecentFileRole: String, Codable, Sendable {
    case source
    case savedCopy
}

enum RecentFileIssue: String, Codable, Sendable, Equatable {
    case missing
    case offline
    case denied
    case replaced
    case needsLocation
}

/// A bookmark is a locator, not authority to trust the bytes found at its URL.
/// File resource identifiers and device numbers are deliberately not persisted.
struct RecentFileReference: Codable, Sendable, Equatable {
    static let maximumFileBytes: UInt64 = 64 * 1024 * 1024
    static let maximumBookmarkBytes = 64 * 1024
    static let maximumPathBytes = 4_096

    let bookmarkData: Data
    let lastKnownPath: String
    let role: RecentFileRole
    let volumeUUID: UUID?
    let documentIdentifier: UInt64?
    let persistentFileID: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let byteCount: UInt64
    let sha256: String

    private enum CodingKeys: String, CodingKey {
        case bookmarkData, lastKnownPath, role, volumeUUID, documentIdentifier
        case persistentFileID, birthSeconds, birthNanoseconds, byteCount, sha256
    }

    private init(bookmarkData: Data, lastKnownPath: String, role: RecentFileRole,
                 volumeUUID: UUID?, documentIdentifier: UInt64?, persistentFileID: UInt64,
                 birthSeconds: Int64, birthNanoseconds: Int64, byteCount: UInt64, sha256: String) throws {
        guard !bookmarkData.isEmpty, bookmarkData.count <= Self.maximumBookmarkBytes,
              lastKnownPath.hasPrefix("/"), lastKnownPath.utf8.count <= Self.maximumPathBytes,
              !lastKnownPath.contains("\0"),
              !lastKnownPath.contains("//"),
              !lastKnownPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              volumeUUID != nil, persistentFileID != 0,
              birthSeconds >= 0, birthNanoseconds >= 0, birthNanoseconds < 1_000_000_000,
              byteCount <= Self.maximumFileBytes,
              sha256.utf8.count == 64, sha256.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 || $0 >= 97 && $0 <= 102 }) else {
            throw RecentFileReferenceError.invalidReference
        }
        self.bookmarkData = bookmarkData
        self.lastKnownPath = lastKnownPath
        self.role = role
        self.volumeUUID = volumeUUID
        self.documentIdentifier = documentIdentifier
        self.persistentFileID = persistentFileID
        self.birthSeconds = birthSeconds
        self.birthNanoseconds = birthNanoseconds
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(bookmarkData: value.decode(Data.self, forKey: .bookmarkData),
                      lastKnownPath: value.decode(String.self, forKey: .lastKnownPath),
                      role: value.decode(RecentFileRole.self, forKey: .role),
                      volumeUUID: value.decodeIfPresent(UUID.self, forKey: .volumeUUID),
                      documentIdentifier: value.decodeIfPresent(UInt64.self, forKey: .documentIdentifier),
                      persistentFileID: value.decode(UInt64.self, forKey: .persistentFileID),
                      birthSeconds: value.decode(Int64.self, forKey: .birthSeconds),
                      birthNanoseconds: value.decode(Int64.self, forKey: .birthNanoseconds),
                      byteCount: value.decode(UInt64.self, forKey: .byteCount),
                      sha256: value.decode(String.self, forKey: .sha256))
    }

    static func capture(at url: URL, role: RecentFileRole) throws -> Self {
        let path = url.path
        let opened = try RecentFileDescriptor.open(path)
        defer { close(opened) }
        let snapshot = try RecentFileDescriptor.snapshot(opened)
        // Bookmark creation is path based. Confirm that it still names the held file.
        let bookmark = try URL(fileURLWithPath: path).bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try RecentFileDescriptor.verifyPath(path, matches: opened)
        return try Self(bookmarkData: bookmark, lastKnownPath: path, role: role,
                        volumeUUID: snapshot.volumeUUID, documentIdentifier: snapshot.documentIdentifier,
                        persistentFileID: snapshot.persistentFileID, birthSeconds: snapshot.birthSeconds,
                        birthNanoseconds: snapshot.birthNanoseconds,
                        byteCount: snapshot.byteCount, sha256: snapshot.sha256)
    }

    fileprivate func refreshing(bookmarkData: Data, path: String) throws -> Self {
        try Self(bookmarkData: bookmarkData, lastKnownPath: path, role: role,
                      volumeUUID: volumeUUID, documentIdentifier: documentIdentifier,
                      persistentFileID: persistentFileID, birthSeconds: birthSeconds,
                      birthNanoseconds: birthNanoseconds,
                      byteCount: byteCount, sha256: sha256)
    }
}

enum RecentFileReferenceError: Error, Equatable {
    case invalidReference
    case unavailable(RecentFileIssue)
}

struct RecentResolvedFile: Sendable {
    let url: URL
    let role: RecentFileRole
    /// These bytes came from the verified, held, no-follow descriptor. A later
    /// Finder URL handoff is necessarily a separate path lookup and can race.
    let validatedData: Data
    let liveIdentity: ScreenshotFileIdentity
    let refreshedReference: RecentFileReference?
}

enum RecentFileResolution: Sendable {
    case available(RecentResolvedFile)
    case unavailable(RecentFileIssue)
}

struct RecentFileResolver {
    typealias BookmarkResolution = (Data) throws -> (url: URL, stale: Bool)
    typealias BookmarkCreation = (URL) throws -> Data

    private let resolveBookmark: BookmarkResolution
    private let createBookmark: BookmarkCreation
    private let onRead: (@Sendable (Int) -> Void)?
    private let onHash: (@Sendable (Int) -> Void)?

    init(resolveBookmark: @escaping BookmarkResolution = { data in
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }, createBookmark: @escaping BookmarkCreation = { url in
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }, onRead: (@Sendable (Int) -> Void)? = nil, onHash: (@Sendable (Int) -> Void)? = nil) {
        self.resolveBookmark = resolveBookmark
        self.createBookmark = createBookmark
        self.onRead = onRead
        self.onHash = onHash
    }

    func resolve(_ reference: RecentFileReference) -> RecentFileResolution {
        let resolved: (url: URL, stale: Bool)
        do { resolved = try resolveBookmark(reference.bookmarkData) }
        catch { return .unavailable(Self.unresolvedIssue(for: reference)) }
        guard resolved.url.isFileURL else { return .unavailable(.needsLocation) }
        let path = resolved.url.path
        guard path.hasPrefix("/"), path.utf8.count <= RecentFileReference.maximumPathBytes else {
            return .unavailable(.needsLocation)
        }
        let descriptor: Int32
        do { descriptor = try RecentFileDescriptor.open(path) }
        catch let error as RecentFileReferenceError {
            if case let .unavailable(issue) = error { return .unavailable(issue) }
            return .unavailable(.needsLocation)
        } catch { return .unavailable(.needsLocation) }
        defer { close(descriptor) }
        do {
            let snapshot = try RecentFileDescriptor.snapshot(descriptor, onRead: onRead, onHash: onHash)
            guard snapshot.byteCount == reference.byteCount, snapshot.sha256 == reference.sha256,
                  reference.volumeUUID == nil || snapshot.volumeUUID == reference.volumeUUID,
                  reference.documentIdentifier == nil || snapshot.documentIdentifier == reference.documentIdentifier,
                  snapshot.persistentFileID == reference.persistentFileID,
                  snapshot.birthSeconds == reference.birthSeconds,
                  snapshot.birthNanoseconds == reference.birthNanoseconds else {
                return .unavailable(.replaced)
            }
            try RecentFileDescriptor.verifyPath(path, matches: descriptor)
            var refreshed: RecentFileReference?
            if resolved.stale || path != reference.lastKnownPath {
                let bookmark = try createBookmark(URL(fileURLWithPath: path))
                try RecentFileDescriptor.verifyPath(path, matches: descriptor)
                refreshed = try reference.refreshing(bookmarkData: bookmark, path: path)
            }
            return .available(RecentResolvedFile(url: URL(fileURLWithPath: path), role: reference.role,
                                                 validatedData: snapshot.data, liveIdentity: snapshot.liveIdentity,
                                                 refreshedReference: refreshed))
        } catch let error as RecentFileReferenceError {
            if case let .unavailable(issue) = error { return .unavailable(issue) }
            return .unavailable(.needsLocation)
        } catch { return .unavailable(.needsLocation) }
    }

    private static func unresolvedIssue(for reference: RecentFileReference) -> RecentFileIssue {
        // Bookmark failures do not prove deletion. An absent external mount is
        // distinctly offline; other failures ask the user to locate the file.
        let components = URL(fileURLWithPath: reference.lastKnownPath).pathComponents
        if components.count >= 3, components[1] == "Volumes",
           !FileManager.default.fileExists(atPath: "/Volumes/\(components[2])") { return .offline }
        return .needsLocation
    }
}

private enum RecentFileDescriptor {
    struct Snapshot {
        let data: Data
        let byteCount: UInt64
        let sha256: String
        let volumeUUID: UUID?
        let documentIdentifier: UInt64?
        let persistentFileID: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64
        let liveIdentity: ScreenshotFileIdentity
    }

    static func open(_ path: String) throws -> Int32 {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            let issue: RecentFileIssue
            switch errno {
            case ENOENT, ENOTDIR: issue = .missing
            case EACCES, EPERM: issue = .denied
            case ELOOP: issue = .replaced
            default: issue = .needsLocation
            }
            throw RecentFileReferenceError.unavailable(issue)
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw RecentFileReferenceError.unavailable(.replaced)
        }
        return fd
    }

    static func snapshot(_ fd: Int32, onRead: (@Sendable (Int) -> Void)? = nil,
                         onHash: (@Sendable (Int) -> Void)? = nil) throws -> Snapshot {
        try Task.checkCancellation()
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_size >= 0,
              UInt64(before.st_size) <= RecentFileReference.maximumFileBytes else {
            throw RecentFileReferenceError.unavailable(.replaced)
        }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var block = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = block.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw RecentFileReferenceError.unavailable(errno == EACCES ? .denied : .needsLocation)
            }
            if count == 0 { break }
            guard data.count <= Int(RecentFileReference.maximumFileBytes) - count else {
                throw RecentFileReferenceError.unavailable(.replaced)
            }
            data.append(contentsOf: block[..<count])
            onRead?(count)
        }
        var after = stat()
        guard fstat(fd, &after) == 0, sameFile(before, after),
              UInt64(data.count) == UInt64(after.st_size),
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw RecentFileReferenceError.unavailable(.replaced)
        }
        try Task.checkCancellation()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        onHash?(data.count)
        try Task.checkCancellation()
        guard let volumeUUID = volumeUUID(fd), let persistentFileID = persistentFileID(fd),
              persistentFileID != 0 else {
            throw RecentFileReferenceError.unavailable(.needsLocation)
        }
        let documentIdentifier = documentIdentifier(fd)
        var confirmed = stat()
        guard fstat(fd, &confirmed) == 0, sameFile(after, confirmed),
              after.st_size == confirmed.st_size,
              after.st_mtimespec.tv_sec == confirmed.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == confirmed.st_mtimespec.tv_nsec else {
            throw RecentFileReferenceError.unavailable(.replaced)
        }
        return Snapshot(data: data, byteCount: UInt64(data.count), sha256: digest,
                        volumeUUID: volumeUUID, documentIdentifier: documentIdentifier,
                        persistentFileID: persistentFileID,
                        birthSeconds: Int64(after.st_birthtimespec.tv_sec),
                        birthNanoseconds: Int64(after.st_birthtimespec.tv_nsec),
                        liveIdentity: ScreenshotFileIdentity(
                            device: UInt64(UInt32(bitPattern: after.st_dev)), inode: UInt64(after.st_ino),
                            birthNanoseconds: Int64(after.st_birthtimespec.tv_sec) * 1_000_000_000
                                + Int64(after.st_birthtimespec.tv_nsec)))
    }

    static func verifyPath(_ path: String, matches fd: Int32) throws {
        let pathFD = try open(path)
        defer { close(pathFD) }
        var held = stat()
        var current = stat()
        guard fstat(fd, &held) == 0, fstat(pathFD, &current) == 0, sameFile(held, current) else {
            throw RecentFileReferenceError.unavailable(.replaced)
        }
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino &&
        lhs.st_birthtimespec.tv_sec == rhs.st_birthtimespec.tv_sec &&
        lhs.st_birthtimespec.tv_nsec == rhs.st_birthtimespec.tv_nsec &&
        lhs.st_mode & S_IFMT == S_IFREG && rhs.st_mode & S_IFMT == S_IFREG
    }

    private static func volumeUUID(_ fd: Int32) -> UUID? {
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        request.volattr = UInt32(ATTR_VOL_UUID | ATTR_VOL_CAPABILITIES)
        var bytes = [UInt8](repeating: 0, count: 72)
        let result = bytes.withUnsafeMutableBytes {
            fgetattrlist(fd, &request, $0.baseAddress!, $0.count, UInt32(FSOPT_PACK_INVAL_ATTRS))
        }
        guard result == 0, bytes.withUnsafeBytes({ $0.load(as: UInt32.self) }) == 72,
              bytes.withUnsafeBytes({ $0.load(fromByteOffset: 8, as: UInt32.self) })
                & UInt32(ATTR_VOL_UUID | ATTR_VOL_CAPABILITIES) == UInt32(ATTR_VOL_UUID | ATTR_VOL_CAPABILITIES),
              bytes.withUnsafeBytes({ $0.load(fromByteOffset: 24, as: UInt32.self) })
                & UInt32(VOL_CAP_FMT_PERSISTENTOBJECTIDS) != 0,
              bytes.withUnsafeBytes({ $0.load(fromByteOffset: 40, as: UInt32.self) })
                & UInt32(VOL_CAP_FMT_PERSISTENTOBJECTIDS) != 0 else {
            return nil
        }
        let id = Array(bytes[56..<72])
        guard id.contains(where: { $0 != 0 }) else { return nil }
        return UUID(uuid: (id[0], id[1], id[2], id[3], id[4], id[5], id[6], id[7],
                           id[8], id[9], id[10], id[11], id[12], id[13], id[14], id[15]))
    }

    private static func documentIdentifier(_ fd: Int32) -> UInt64? {
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_DOCUMENT_ID)
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = bytes.withUnsafeMutableBytes {
            fgetattrlist(fd, &request, $0.baseAddress!, $0.count, UInt32(FSOPT_PACK_INVAL_ATTRS))
        }
        guard result == 0, bytes.withUnsafeBytes({ $0.load(as: UInt32.self) }) == 32,
              bytes.withUnsafeBytes({ $0.load(fromByteOffset: 4, as: UInt32.self) }) & UInt32(ATTR_CMN_DOCUMENT_ID) != 0 else {
            return nil
        }
        return bytes.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt64.self) }
    }

    private static func persistentFileID(_ fd: Int32) -> UInt64? {
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_FILEID)
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = bytes.withUnsafeMutableBytes {
            fgetattrlist(fd, &request, $0.baseAddress!, $0.count, UInt32(FSOPT_PACK_INVAL_ATTRS))
        }
        guard result == 0, bytes.withUnsafeBytes({ $0.load(as: UInt32.self) }) == 32,
              bytes.withUnsafeBytes({ $0.load(fromByteOffset: 4, as: UInt32.self) }) & UInt32(ATTR_CMN_FILEID) != 0 else {
            return nil
        }
        return bytes.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt64.self) }
    }
}
