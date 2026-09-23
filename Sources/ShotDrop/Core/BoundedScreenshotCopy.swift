import CryptoKit
import Darwin
import Foundation

enum ScreenshotStagingLimits {
    static let maximumPayloadBytes = 64 * 1024 * 1024
    static let maximumMetadataBytes = 1024 * 1024
    static let maximumRoots = 4
    static let slotsPerRoot = 2
    static let maximumRegistryBytes = 64 * 1024
}

/// A slot may carry only this observed system attribute before use. Presence and raw
/// bytes are recorded at enrollment, then checked without trying to remove or change it.
struct ScreenshotStagingBaseline: Codable, Sendable, Equatable {
    static let attributeName = "com.apple.provenance"
    let provenance: Data?

    init(provenance: Data?) throws {
        guard provenance == nil || provenance?.count == 11 else {
            throw ScreenshotCopyFailure(code: .stagingPaused, detail: "Staging provenance has an unsupported size.")
        }
        self.provenance = provenance
    }

    private enum CodingKeys: String, CodingKey { case provenance }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(provenance: container.decodeIfPresent(Data.self, forKey: .provenance))
    }

    var chargedBytes: Int {
        provenance.map { Self.attributeName.utf8.count + 1 + $0.count } ?? 0
    }

    var attributeHashes: [String: Data] {
        provenance.map { [Self.attributeName: Data(SHA256.hash(data: $0))] } ?? [:]
    }

    static func capture(_ descriptor: Int32) throws -> Self {
        let count = fgetxattr(descriptor, attributeName, nil, 0, 0, 0)
        if count < 0, errno == ENOATTR { return try Self(provenance: nil) }
        guard count == 11 else {
            throw ScreenshotCopyFailure(code: .stagingPaused, detail: "Staging provenance is unavailable or has an unsupported size.")
        }
        var value = Data(count: count)
        let actual = value.withUnsafeMutableBytes {
            fgetxattr(descriptor, attributeName, $0.baseAddress, $0.count, 0, 0)
        }
        guard actual == count, fgetxattr(descriptor, attributeName, nil, 0, 0, 0) == count else {
            throw ScreenshotCopyFailure(code: .stagingPaused, detail: "Staging provenance changed during enrollment.")
        }
        return try Self(provenance: value)
    }

    func verify(_ descriptor: Int32) throws {
        guard try Self.capture(descriptor) == self else {
            throw ScreenshotCopyFailure(code: .stagingPaused, detail: "Staging provenance no longer matches its enrolled baseline.")
        }
    }

    func expectedStageAttributes(sourceAttributes: [String: Data], outputToken: UUID) -> [String: Data] {
        var result = sourceAttributes
        result.removeValue(forKey: Self.attributeName)
        result.merge(attributeHashes) { _, enrolled in enrolled }
        result[ScreenshotOutputMarker.attributeName] = Data(SHA256.hash(data: Data(outputToken.uuidString.utf8)))
        return result
    }
}

/// Copies data and bounded extended attributes, replacing the output marker and
/// retaining enrolled stage provenance instead of copying source provenance. Stage
/// permissions, ACLs, and flags are never inherited from an input screenshot.
struct BoundedScreenshotCopy: Sendable {
    typealias Reader = @Sendable (Int32, UnsafeMutableRawPointer, Int, off_t) -> Int
    typealias Writer = @Sendable (Int32, UnsafeRawPointer, Int, off_t) -> Int

    private let read: Reader
    private let write: Writer
    private let payloadLimit: Int
    private let metadataLimit: Int

    /// Test limits can only reduce the fixed storage caps.
    init(
        payloadLimit: Int = ScreenshotStagingLimits.maximumPayloadBytes,
        metadataLimit: Int = ScreenshotStagingLimits.maximumMetadataBytes,
        read: @escaping Reader = { pread($0, $1, $2, $3) },
        write: @escaping Writer = { pwrite($0, $1, $2, $3) }
    ) {
        self.payloadLimit = min(max(0, payloadLimit), ScreenshotStagingLimits.maximumPayloadBytes)
        self.metadataLimit = min(max(0, metadataLimit), ScreenshotStagingLimits.maximumMetadataBytes)
        self.read = read
        self.write = write
    }

    func copy(sourceFD: Int32, stageFD: Int32, outputToken: UUID, baseline: ScreenshotStagingBaseline) throws {
        try Task.checkCancellation()
        var source = stat()
        var stage = stat()
        guard fstat(sourceFD, &source) == 0, fstat(stageFD, &stage) == 0 else {
            throw Self.posixFailure("Inspect bounded screenshot copy")
        }
        guard source.st_mode & S_IFMT == S_IFREG, stage.st_mode & S_IFMT == S_IFREG,
              source.st_dev != stage.st_dev || source.st_ino != stage.st_ino else {
            throw Self.failure(.verificationFailed, "Screenshot and stage must be distinct regular files.")
        }
        guard source.st_size >= 0, source.st_size <= off_t(payloadLimit) else {
            throw Self.failure(.stagingPaused, "The screenshot exceeds the staging payload limit.")
        }
        guard stage.st_size == 0, stage.st_nlink == 1, stage.st_mode & 0o7777 == 0o600 else {
            throw Self.failure(.stagingPaused, "The screenshot staging slot is not empty and private.")
        }
        try baseline.verify(stageFD)
        guard try Self.attributes(stageFD) == baseline.attributeHashes else {
            throw Self.failure(.stagingPaused, "The screenshot staging slot contains metadata outside its enrolled baseline.")
        }

        let marker = Data(outputToken.uuidString.utf8)
        let markerBytes = ScreenshotOutputMarker.attributeName.utf8.count + 1 + marker.count
        var attributes = try Self.readAttributes(
            sourceFD, limit: metadataLimit,
            excluding: [ScreenshotOutputMarker.attributeName, ScreenshotStagingBaseline.attributeName],
            reservedBytes: markerBytes + baseline.chargedBytes
        )
        attributes[ScreenshotOutputMarker.attributeName] = marker
        var buffer = [UInt8](repeating: 0, count: min(256 * 1024, max(1, payloadLimit + 1)))
        var offset: off_t = 0
        while true {
            try Task.checkCancellation()
            // Read one byte beyond the remaining allowance, including at the exact cap,
            // so growth cannot be mistaken for EOF or silently truncated to stat.st_size.
            let requested = min(buffer.count, payloadLimit - Int(offset) + 1)
            let count = buffer.withUnsafeMutableBytes { read(sourceFD, $0.baseAddress!, requested, offset) }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.posixFailure("Read bounded screenshot payload")
            }
            guard count <= requested else {
                throw Self.failure(.verificationFailed, "Screenshot read exceeded its requested size.")
            }
            if count == 0 { break }
            guard count <= payloadLimit - Int(offset) else {
                throw Self.failure(.stagingPaused, "The screenshot grew beyond the staging payload limit.")
            }
            var written = 0
            while written < count {
                try Task.checkCancellation()
                let remaining = count - written
                let result = buffer.withUnsafeBytes {
                    write(stageFD, $0.baseAddress!.advanced(by: written), remaining, offset + off_t(written))
                }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw Self.posixFailure("Write bounded screenshot payload")
                }
                guard result > 0, result <= remaining else {
                    throw Self.failure(.ioFailure, "The screenshot payload write did not make valid progress.")
                }
                written += result
            }
            offset += off_t(count)
        }
        guard offset == source.st_size else {
            throw Self.failure(.verificationFailed, "The screenshot size changed while copying.")
        }
        for (name, value) in attributes {
            try Task.checkCancellation()
            let result = value.withUnsafeBytes {
                fsetxattr(stageFD, name, $0.baseAddress, $0.count, 0, 0)
            }
            guard result == 0 else { throw Self.posixFailure("Copy bounded screenshot metadata") }
        }
    }

    /// Writes a newly rendered payload without inheriting source metadata.
    func writeRendered(_ data: Data, stageFD: Int32, outputToken: UUID,
                       baseline: ScreenshotStagingBaseline) throws {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= payloadLimit else {
            throw Self.failure(.stagingPaused, "Rendered screenshot exceeds the payload limit.")
        }
        var stage = stat()
        guard fstat(stageFD, &stage) == 0, stage.st_mode & S_IFMT == S_IFREG,
              stage.st_size == 0, stage.st_nlink == 1, stage.st_mode & 0o7777 == 0o600 else {
            throw Self.failure(.stagingPaused, "Rendered screenshot requires an empty private slot.")
        }
        try baseline.verify(stageFD)
        guard try Self.attributes(stageFD) == baseline.attributeHashes else {
            throw Self.failure(.stagingPaused, "Staging metadata differs from its enrolled baseline.")
        }
        let marker = Data(outputToken.uuidString.utf8)
        guard baseline.chargedBytes + ScreenshotOutputMarker.attributeName.utf8.count + 1 + marker.count <= metadataLimit else {
            throw Self.failure(.stagingPaused, "Rendered screenshot metadata exceeds its limit.")
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let requested = min(256 * 1024, bytes.count - offset)
                let count = write(stageFD, bytes.baseAddress!.advanced(by: offset), requested, off_t(offset))
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Self.posixFailure("Write rendered screenshot")
                }
                guard count > 0, count <= requested else {
                    throw Self.failure(.ioFailure, "Rendered screenshot write made invalid progress.")
                }
                offset += count
            }
        }
        let result = marker.withUnsafeBytes {
            fsetxattr(stageFD, ScreenshotOutputMarker.attributeName, $0.baseAddress, $0.count, 0, 0)
        }
        guard result == 0 else { throw Self.posixFailure("Write rendered screenshot marker") }
    }

    /// Hashes actual metadata within the aggregate cap. Copying separately reserves
    /// capacity for its fresh output marker before it writes any stage bytes.
    static func attributes(_ descriptor: Int32) throws -> [String: Data] {
        try readAttributes(descriptor, limit: ScreenshotStagingLimits.maximumMetadataBytes)
            .mapValues { Data(SHA256.hash(data: $0)) }
    }

    private static func readAttributes(
        _ descriptor: Int32, limit: Int, excluding: Set<String> = [], reservedBytes: Int = 0
    ) throws -> [String: Data] {
        try Task.checkCancellation()
        let listSize = flistxattr(descriptor, nil, 0, 0)
        guard listSize >= 0 else { throw posixFailure("Read screenshot metadata names") }
        guard listSize <= limit else {
            throw failure(.stagingPaused, "Screenshot metadata names exceed the staging metadata limit.")
        }
        var names = [UInt8](repeating: 0, count: listSize)
        if listSize > 0 {
            let actual = names.withUnsafeMutableBytes {
                flistxattr(descriptor, $0.baseAddress?.assumingMemoryBound(to: CChar.self), $0.count, 0)
            }
            guard actual == listSize, names.last == 0 else {
                throw failure(.verificationFailed, "Screenshot metadata names changed while reading.")
            }
        }
        var decoded = [String]()
        var seen = Set<String>()
        for bytes in names.split(separator: 0) {
            guard let name = String(bytes: bytes, encoding: .utf8), seen.insert(name).inserted else {
                throw failure(.verificationFailed, "Screenshot metadata names could not be preserved.")
            }
            decoded.append(name)
        }
        let omittedNameBytes = decoded.filter { excluding.contains($0) }.reduce(0) { $0 + $1.utf8.count + 1 }
        var used = listSize - omittedNameBytes + reservedBytes
        guard used <= limit else {
            throw failure(.stagingPaused, "Screenshot metadata leaves no room for the output marker.")
        }
        var result: [String: Data] = [:]
        for name in decoded {
            try Task.checkCancellation()
            if excluding.contains(name) { continue }
            let size = fgetxattr(descriptor, name, nil, 0, 0, 0)
            guard size >= 0 else { throw posixFailure("Read screenshot metadata size", code: .verificationFailed) }
            guard size <= limit - used else {
                throw failure(.stagingPaused, "Screenshot metadata exceeds the aggregate staging limit.")
            }
            var value = Data(count: size)
            let actual = value.withUnsafeMutableBytes { fgetxattr(descriptor, name, $0.baseAddress, size, 0, 0) }
            guard actual == size else {
                throw failure(.verificationFailed, "Screenshot metadata changed while reading.")
            }
            guard fgetxattr(descriptor, name, nil, 0, 0, 0) == size else {
                throw failure(.verificationFailed, "Screenshot metadata size changed while reading.")
            }
            used += size
            result[name] = value
        }
        return result
    }

    private static func failure(_ code: ScreenshotCopyFailure.Code, _ detail: String) -> ScreenshotCopyFailure {
        ScreenshotCopyFailure(code: code, detail: detail)
    }

    private static func posixFailure(
        _ operation: String, code: ScreenshotCopyFailure.Code = .ioFailure
    ) -> ScreenshotCopyFailure {
        let saved = errno
        return ScreenshotCopyFailure(
            code: saved == EACCES || saved == EPERM ? .permissionDenied : code,
            detail: "\(operation): \(String(cString: strerror(saved))).", posixCode: saved
        )
    }
}
