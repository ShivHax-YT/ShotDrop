import Darwin
import Foundation

/// A small record of pipeline results. `detectionDate` is when ShotDrop noticed the file;
/// it is not a claim about the screenshot's exact capture time.
struct RecentHistoryRecord: Codable, Equatable, Sendable, Identifiable {
    let captureID: UUID
    let pipelineSequence: UInt64
    let detectionDate: Date
    let displayName: String
    var sourceReference: RecentFileReference?
    var savedReference: RecentFileReference?
    var copyOutcome: RecentHistoryOutcome
    var saveOutcome: RecentHistoryOutcome
    var revision: UInt64

    var id: UUID { captureID }
}

enum RecentHistoryOutcome: String, Codable, Sendable {
    case pending
    case success
    case failure
}

struct RecentHistorySnapshot: Sendable {
    let records: [RecentHistoryRecord]
}

/// A nil field leaves that part of a record unchanged. A saved reference may be installed
/// only when the resulting save outcome is success. Save failure removes any old saved ref.
struct RecentHistoryChange: Sendable {
    var copyOutcome: RecentHistoryOutcome?
    var saveOutcome: RecentHistoryOutcome?
    var sourceReference: RecentFileReference?
    var savedReference: RecentFileReference?

    init(copyOutcome: RecentHistoryOutcome? = nil,
         saveOutcome: RecentHistoryOutcome? = nil,
         sourceReference: RecentFileReference? = nil,
         savedReference: RecentFileReference? = nil) {
        self.copyOutcome = copyOutcome
        self.saveOutcome = saveOutcome
        self.sourceReference = sourceReference
        self.savedReference = savedReference
    }
}

enum RecentHistoryStoreError: Error, Equatable {
    case unreadable
    case unsupportedFormat
    case invalidRecord
    case tooLarge
    case missingRecord
    case staleRevision
    case revisionExhausted
    case writeFailed
}

/// Actor ownership serializes admission, snapshot, revision updates and JSON replacement.
/// All writes are staged in memory and committed only after the atomic writer succeeds.
actor RecentHistoryStore {
    static let maxRecords = 20
    static let maxFileBytes = 1_048_576
    // A 64 KiB bookmark expands to about 86 KiB when JSON/base64 encoded.
    static let maxRecordBytes = 131_072
    static let maxDisplayNameBytes = 512

    typealias Writer = @Sendable (Data, URL) throws -> Void

    private struct Envelope: Codable {
        let schemaVersion: Int
        let records: [RecentHistoryRecord]
    }

    private let fileURL: URL
    private let writer: Writer
    private var records: [RecentHistoryRecord]?
    private var loadedBytes: Data?
    private var writePoisoned = false

    init(fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.macfleet.shotdrop/RecentHistory.json"),
         writer: @escaping Writer = RecentHistoryStore.atomicWrite) {
        self.fileURL = fileURL
        self.writer = writer
    }

    func snapshot() throws -> RecentHistorySnapshot {
        try loadIfNeeded()
        return RecentHistorySnapshot(records: records ?? [])
    }

    @discardableResult
    func admit(captureID: UUID, pipelineSequence: UInt64, detectionDate: Date,
               displayName: String, sourceReference: RecentFileReference? = nil) throws -> RecentHistoryRecord {
        try loadIfNeeded()
        if let existing = records?.first(where: { $0.captureID == captureID }) {
            return existing // Duplicate detector hints never make a second row or reset outcomes.
        }
        let record = RecentHistoryRecord(captureID: captureID, pipelineSequence: pipelineSequence,
                                         detectionDate: detectionDate, displayName: displayName,
                                         sourceReference: sourceReference, savedReference: nil,
                                         copyOutcome: .pending, saveOutcome: .pending, revision: 0)
        try validate(record)
        var next = records ?? []
        next.append(record)
        next.sort(by: Self.newerFirst)
        if next.count > Self.maxRecords { next.removeLast(next.count - Self.maxRecords) }
        try commit(next)
        return record
    }

    @discardableResult
    func update(captureID: UUID, expectedRevision: UInt64,
                change: RecentHistoryChange) throws -> RecentHistoryRecord {
        try loadIfNeeded()
        guard var next = records, let index = next.firstIndex(where: { $0.captureID == captureID }) else {
            throw RecentHistoryStoreError.missingRecord
        }
        guard next[index].revision == expectedRevision else { throw RecentHistoryStoreError.staleRevision }
        guard next[index].revision < UInt64.max else { throw RecentHistoryStoreError.revisionExhausted }
        var record = next[index]
        if let value = change.copyOutcome { record.copyOutcome = value }
        if let value = change.saveOutcome { record.saveOutcome = value }
        if let value = change.sourceReference { record.sourceReference = value }
        if let value = change.savedReference {
            guard record.saveOutcome == .success else { throw RecentHistoryStoreError.invalidRecord }
            record.savedReference = value
        }
        if record.saveOutcome != .success { record.savedReference = nil }
        guard record.saveOutcome != .success || record.savedReference != nil else {
            throw RecentHistoryStoreError.invalidRecord
        }
        record.revision += 1
        try validate(record)
        next[index] = record
        try commit(next)
        return record
    }

    func remove(captureID: UUID, expectedRevision: UInt64? = nil) throws {
        try loadIfNeeded()
        var next = records ?? []
        guard let index = next.firstIndex(where: { $0.captureID == captureID }) else { return }
        if let expectedRevision, next[index].revision != expectedRevision {
            throw RecentHistoryStoreError.staleRevision
        }
        next.remove(at: index)
        try commit(next)
    }

    func clear() throws {
        try loadIfNeeded()
        try commit([])
    }

    private static func newerFirst(_ lhs: RecentHistoryRecord, _ rhs: RecentHistoryRecord) -> Bool {
        if lhs.pipelineSequence != rhs.pipelineSequence { return lhs.pipelineSequence > rhs.pipelineSequence }
        return lhs.captureID.uuidString < rhs.captureID.uuidString
    }

    private func loadIfNeeded() throws {
        if writePoisoned { throw RecentHistoryStoreError.writeFailed }
        if records != nil { return }
        guard let bytes = try Self.readBounded(fileURL) else {
            records = []
            loadedBytes = nil
            return
        }
        let envelope: Envelope
        do {
            // Preflight the raw container and each row before Codable expands bookmarks.
            guard let raw = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let version = raw["schemaVersion"] as? Int,
                  version == 1,
                  let rows = raw["records"] as? [[String: Any]],
                  rows.count <= Self.maxRecords else { throw RecentHistoryStoreError.unsupportedFormat }
            for row in rows {
                let rowBytes = try JSONSerialization.data(withJSONObject: row)
                guard rowBytes.count <= Self.maxRecordBytes else { throw RecentHistoryStoreError.tooLarge }
            }
            envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        } catch let error as RecentHistoryStoreError {
            throw error
        } catch {
            throw RecentHistoryStoreError.unreadable
        }
        guard envelope.schemaVersion == 1, envelope.records.count <= Self.maxRecords else {
            throw RecentHistoryStoreError.unsupportedFormat
        }
        var seen = Set<UUID>()
        for record in envelope.records {
            try validate(record)
            guard seen.insert(record.captureID).inserted else { throw RecentHistoryStoreError.invalidRecord }
        }
        guard envelope.records.sorted(by: Self.newerFirst) == envelope.records else {
            throw RecentHistoryStoreError.invalidRecord
        }
        records = envelope.records
        loadedBytes = bytes
    }

    private func validate(_ record: RecentHistoryRecord) throws {
        guard !record.displayName.isEmpty,
              record.displayName.utf8.count <= Self.maxDisplayNameBytes,
              !record.displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              record.detectionDate.timeIntervalSinceReferenceDate.isFinite,
              record.sourceReference?.role != .savedCopy,
              record.savedReference?.role != .source,
              (record.saveOutcome == .success) == (record.savedReference != nil) else {
            throw RecentHistoryStoreError.invalidRecord
        }
        do {
            let encoded = try JSONEncoder().encode(record)
            guard encoded.count <= Self.maxRecordBytes else { throw RecentHistoryStoreError.tooLarge }
        } catch let error as RecentHistoryStoreError {
            throw error
        } catch {
            throw RecentHistoryStoreError.invalidRecord
        }
    }

    private func commit(_ next: [RecentHistoryRecord]) throws {
        guard next.count <= Self.maxRecords else { throw RecentHistoryStoreError.tooLarge }
        let bytes: Data
        do { bytes = try JSONEncoder().encode(Envelope(schemaVersion: 1, records: next)) }
        catch { throw RecentHistoryStoreError.invalidRecord }
        guard bytes.count <= Self.maxFileBytes else { throw RecentHistoryStoreError.tooLarge }
        do {
            try withFileLock {
                // A second process may have written after our actor loaded its snapshot.
                // Check under one lock before replacing the JSON file.
                guard try Self.readBounded(fileURL) == loadedBytes else {
                    throw RecentHistoryStoreError.staleRevision
                }
                do { try writer(bytes, fileURL) }
                catch {
                    writePoisoned = true
                    throw RecentHistoryStoreError.writeFailed
                }
            }
        } catch RecentHistoryStoreError.writeFailed {
            // The writer may have replaced the file before throwing. Require a new store
            // instance to reload it; never continue from an uncertain cached revision.
            writePoisoned = true
            throw RecentHistoryStoreError.writeFailed
        }
        records = next
        loadedBytes = bytes
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        let parent = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw RecentHistoryStoreError.writeFailed }
        let lockURL = parent.appendingPathComponent(".RecentHistory.lock")
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RecentHistoryStoreError.writeFailed }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == getuid() else { throw RecentHistoryStoreError.writeFailed }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw RecentHistoryStoreError.writeFailed }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func readBounded(_ url: URL) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw RecentHistoryStoreError.unreadable
        }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw RecentHistoryStoreError.unreadable
        }
        guard metadata.st_size >= 0, metadata.st_size <= Self.maxFileBytes else {
            throw RecentHistoryStoreError.tooLarge
        }
        var bytes = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw RecentHistoryStoreError.unreadable
            }
            if count == 0 { return bytes }
            guard bytes.count + count <= Self.maxFileBytes else { throw RecentHistoryStoreError.tooLarge }
            bytes.append(contentsOf: chunk.prefix(count))
        }
    }

    static func atomicWrite(_ bytes: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = parent.appendingPathComponent(".RecentHistory-\(UUID().uuidString).tmp")
        do {
            try bytes.write(to: temporary, options: [.withoutOverwriting])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            let descriptor = open(temporary.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw RecentHistoryStoreError.writeFailed }
            defer { _ = close(descriptor) }
            guard fsync(descriptor) == 0 else { throw RecentHistoryStoreError.writeFailed }
            guard rename(temporary.path, url.path) == 0 else { throw RecentHistoryStoreError.writeFailed }
            let parentDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if parentDescriptor >= 0 {
                defer { _ = close(parentDescriptor) }
                guard fsync(parentDescriptor) == 0 else { throw RecentHistoryStoreError.writeFailed }
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
