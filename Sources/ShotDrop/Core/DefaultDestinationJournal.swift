import Darwin
import Foundation

/// Records the one default-destination creation attempt. An intent discovered on a later launch
/// is uncertain: callers must pause for review rather than retry mkdir or adopt a directory.
struct DefaultDestinationJournal: Sendable {
    static let policyVersion = 1
    static let maximumBytes = 16 * 1024
    static let maximumPathBytes = 4 * 1024

    let directory: URL

    init(directory: URL) { self.directory = directory }

    struct ObjectBinding: Codable, Equatable, Sendable {
        let path: String
        let device: UInt64
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64

        init(_ identity: ShotDropSetupDirectoryIdentity) {
            path = identity.path
            device = identity.device
            inode = identity.inode
            birthSeconds = identity.birthSeconds
            birthNanoseconds = identity.birthNanoseconds
        }
    }

    struct Intent: Codable, Equatable, Sendable {
        let operationID: UUID
        let destinationPath: String
        let policyVersion: Int
        let volumeUUID: UUID
        let parent: ObjectBinding

        init(destination: URL, volumeUUID: UUID, parent: ShotDropSetupDirectoryIdentity) throws {
            let localHost = destination.host == nil || destination.host == "" || destination.host == "localhost"
            guard destination.isFileURL && localHost,
                  destination.path.utf8.count <= DefaultDestinationJournal.maximumPathBytes,
                  DefaultDestinationJournal.isAbsoluteClean(destination.path),
                  !destination.lastPathComponent.isEmpty,
                  destination.lastPathComponent != ".", destination.lastPathComponent != "..",
                  destination.deletingLastPathComponent().path == parent.path,
                  DefaultDestinationJournal.isAbsoluteClean(parent.path),
                  parent.inode != 0, parent.birthNanoseconds >= 0, parent.birthNanoseconds < 1_000_000_000
            else { throw Fault.invalidBinding }
            self.operationID = UUID()
            self.destinationPath = destination.path
            self.policyVersion = DefaultDestinationJournal.policyVersion
            self.volumeUUID = volumeUUID
            self.parent = ObjectBinding(parent)
        }
    }

    struct Receipt: Codable, Equatable, Sendable {
        let intent: Intent
        let created: ObjectBinding
    }

    enum State: Equatable, Sendable {
        case empty
        case intent(Intent)
        case created(Receipt)
        /// Registration was verified before this marker was flushed. Reuse still requires
        /// fresh issuer-side validation of the folder, volume, policy, and pool binding.
        case enrolled(Receipt)
    }

    enum Fault: Error, Equatable, Sendable {
        case invalidBinding
        case corruptOrUnsupported
        case uncertainWrite
        case priorOperationNeedsReview
        case mismatchedOperation
        case unavailable
    }

    private struct Document: Codable {
        let version: Int
        let intent: Intent
        let created: ObjectBinding?
        let enrolled: Bool
    }

    /// Read-only. A stale temporary file is itself evidence of an interrupted write.
    func load() throws -> State {
        try withLock { fd in try read(fd) }
    }

    /// Must complete (including fsync) before the caller attempts mkdir. Only an empty journal
    /// accepts an intent. A previous intent or receipt is never reset automatically.
    func begin(_ intent: Intent) throws {
        try withLock { fd in
            guard try read(fd) == .empty else { throw Fault.priorOperationNeedsReview }
            try write(Document(version: 1, intent: intent, created: nil, enrolled: false), in: fd)
        }
    }

    /// Call only after exclusive mkdir, descriptor identity validation, and parent revalidation.
    /// A receipt-write error leaves creation uncertain; the caller must pause for review.
    func recordCreated(_ intent: Intent, created: ShotDropSetupDirectoryIdentity) throws {
        let binding = ObjectBinding(created)
        guard binding.path == intent.destinationPath, binding.device == intent.parent.device,
              binding.inode != 0, binding.inode != intent.parent.inode,
              binding.birthNanoseconds >= 0, binding.birthNanoseconds < 1_000_000_000 else {
            throw Fault.invalidBinding
        }
        try withLock { fd in
            guard case .intent(let stored) = try read(fd), stored == intent else {
                throw Fault.mismatchedOperation
            }
            try write(Document(version: 1, intent: intent, created: binding, enrolled: false), in: fd)
        }
    }

    /// Call only after independently verifying the exact pool registration for this created
    /// object. A created-but-unenrolled record survives restart and cannot become enrolled
    /// without the original in-memory intent and binding supplied by the issuer.
    func recordEnrolled(_ intent: Intent, created: ShotDropSetupDirectoryIdentity) throws {
        let binding = ObjectBinding(created)
        try withLock { fd in
            guard case .created(let receipt) = try read(fd),
                  receipt.intent == intent, receipt.created == binding else {
                throw Fault.mismatchedOperation
            }
            try write(Document(version: 1, intent: intent, created: binding, enrolled: true), in: fd)
        }
    }

    private func withLock<T>(_ body: (Int32) throws -> T) throws -> T {
        guard directory.isFileURL, DefaultDestinationJournal.isAbsoluteClean(directory.path) else {
            throw Fault.invalidBinding
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw Fault.unavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw Fault.unavailable }
        let lockFD = openat(fd, "default-destination.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw Fault.unavailable }
        defer { close(lockFD) }
        guard fstat(lockFD, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw Fault.unavailable }
        defer { flock(lockFD, LOCK_UN) }
        return try body(fd)
    }

    private static func isAbsoluteClean(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0")
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    private func read(_ fd: Int32) throws -> State {
        var pending = stat()
        if fstatat(fd, "default-destination.pending", &pending, AT_SYMLINK_NOFOLLOW) == 0 {
            throw Fault.corruptOrUnsupported
        }
        guard errno == ENOENT else { throw Fault.unavailable }
        let journalFD = openat(fd, "default-destination.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard journalFD >= 0 else {
            if errno == ENOENT { return .empty }
            throw Fault.unavailable
        }
        defer { close(journalFD) }
        var info = stat()
        guard fstat(journalFD, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= Self.maximumBytes else { throw Fault.corruptOrUnsupported }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { buffer in
            Darwin.read(journalFD, buffer.baseAddress, buffer.count)
        }
        guard count == bytes.count else { throw Fault.corruptOrUnsupported }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: Data(bytes)) }
        catch { throw Fault.corruptOrUnsupported }
        let intent = document.intent
        guard document.version == 1, intent.policyVersion == Self.policyVersion,
              intent.destinationPath.utf8.count <= Self.maximumPathBytes,
              intent.destinationPath.hasPrefix("/"),
              Self.isAbsoluteClean(intent.destinationPath),
              URL(fileURLWithPath: intent.destinationPath).deletingLastPathComponent().path == intent.parent.path,
              intent.parent.inode != 0,
              intent.parent.birthNanoseconds >= 0, intent.parent.birthNanoseconds < 1_000_000_000
        else { throw Fault.corruptOrUnsupported }
        if let created = document.created {
            guard created.path == intent.destinationPath, created.device == intent.parent.device,
                  created.inode != 0, created.inode != intent.parent.inode,
                  created.birthNanoseconds >= 0, created.birthNanoseconds < 1_000_000_000
            else { throw Fault.corruptOrUnsupported }
            let receipt = Receipt(intent: intent, created: created)
            return document.enrolled ? .enrolled(receipt) : .created(receipt)
        }
        guard !document.enrolled else { throw Fault.corruptOrUnsupported }
        return .intent(intent)
    }

    private func write(_ document: Document, in fd: Int32) throws {
        let data = try JSONEncoder().encode(document)
        guard data.count <= Self.maximumBytes else { throw Fault.invalidBinding }
        let pendingFD = openat(fd, "default-destination.pending", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard pendingFD >= 0 else { throw Fault.uncertainWrite }
        defer { close(pendingFD) }
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(pendingFD, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    guard written > 0 else { throw Fault.uncertainWrite }
                    offset += written
                }
            }
            guard fsync(pendingFD) == 0,
                  renameat(fd, "default-destination.pending", fd, "default-destination.json") == 0,
                  fsync(fd) == 0 else { throw Fault.uncertainWrite }
        } catch {
            // Deliberately retain an incomplete pending file. No automatic cleanup or retry.
            throw Fault.uncertainWrite
        }
    }
}
