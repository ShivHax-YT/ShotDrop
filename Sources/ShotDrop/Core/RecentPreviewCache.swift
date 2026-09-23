import CoreGraphics
import Foundation
import ImageIO

struct RecentPreviewKey: Hashable, Sendable {
    let captureID: UUID
    let role: RecentFileRole
    let volumeUUID: UUID?
    let documentIdentifier: UInt64?
    let persistentFileID: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let byteCount: UInt64
    let sha256: String
    let maxPixel: Int

    init(captureID: UUID, reference: RecentFileReference, maxPixel: Int = 112) {
        self.captureID = captureID
        role = reference.role
        volumeUUID = reference.volumeUUID
        documentIdentifier = reference.documentIdentifier
        persistentFileID = reference.persistentFileID
        birthSeconds = reference.birthSeconds
        birthNanoseconds = reference.birthNanoseconds
        byteCount = reference.byteCount
        sha256 = reference.sha256
        self.maxPixel = min(512, max(1, maxPixel))
    }

    private func sameVersion(as other: Self) -> Bool {
        volumeUUID == other.volumeUUID && documentIdentifier == other.documentIdentifier
            && persistentFileID == other.persistentFileID
            && birthSeconds == other.birthSeconds && birthNanoseconds == other.birthNanoseconds
            && byteCount == other.byteCount && sha256 == other.sha256
    }

    fileprivate func replaces(_ other: Self) -> Bool {
        captureID == other.captureID && role == other.role && !sameVersion(as: other)
    }
}

/// Small, decoded, premultiplied RGBA pixels; no AppKit object crosses the actor boundary.
struct RecentPreviewImage: Sendable, Equatable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let rgba: Data
}

enum RecentPreviewError: Error, Equatable {
    case inputTooLarge
    case decodeFailed
    case queueFull
}

/// Call from a row task and cancel that task when the row disappears. Loading and decoding
/// share a bounded worker slot, so queued rows do not retain full encoded screenshot data.
actor RecentPreviewCache {
    typealias Loader = @Sendable () throws -> Data
    static let maximumCacheBytes = 8 * 1_024 * 1_024
    static let maximumEncodedBytes = 64 * 1_024 * 1_024

    struct Statistics: Sendable {
        let cachedBytes: Int
        let cachedImages: Int
        let runningJobs: Int
        let pendingJobs: Int
    }

    private struct Entry {
        let image: RecentPreviewImage
        var lastUse: UInt64
    }

    private struct Job {
        let key: RecentPreviewKey
        let generation: UInt64
        let load: Loader
        let continuation: CheckedContinuation<RecentPreviewImage, Error>
    }

    private let concurrencyLimit: Int
    private let cacheBudget: Int
    private var entries: [RecentPreviewKey: Entry] = [:]
    private var cachedBytes = 0
    private var clock: UInt64 = 0
    private var generation: UInt64 = 0
    private var jobs: [UUID: Job] = [:]
    private var queue: [UUID] = []
    // Cancelled ImageIO calls keep their slot until they actually return.
    private var running: [UUID: Task<Void, Never>] = [:]

    init(maxConcurrentDecodes: Int = 1, cacheBudgetBytes: Int = maximumCacheBytes) {
        concurrencyLimit = min(2, max(1, maxConcurrentDecodes))
        cacheBudget = min(Self.maximumCacheBytes, max(0, cacheBudgetBytes))
    }

    func thumbnail(for key: RecentPreviewKey, load: @escaping Loader) async throws -> RecentPreviewImage {
        try Task.checkCancellation()
        invalidateReplacedVersions(by: key)
        if var entry = entries[key] {
            clock &+= 1
            entry.lastUse = clock
            entries[key] = entry
            return entry.image
        }
        let identifier = UUID()
        let image: RecentPreviewImage = try await withTaskCancellationHandler(
            operation: {
                try await self.enqueue(identifier: identifier, key: key, load: load)
            },
            onCancel: {
                Task<Void, Never> { await self.cancel(identifier) }
            }
        )
        try Task.checkCancellation()
        return image
    }

    private func enqueue(identifier: UUID, key: RecentPreviewKey,
                         load: @escaping Loader) async throws -> RecentPreviewImage {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<RecentPreviewImage, Error>) in
            guard jobs.count < 64 else {
                continuation.resume(throwing: RecentPreviewError.queueFull)
                return
            }
            jobs[identifier] = Job(key: key, generation: generation, load: load,
                                   continuation: continuation)
            queue.append(identifier)
            startAvailableJobs()
        }
    }

    func invalidate(captureID: UUID) {
        let keys = entries.keys.filter { $0.captureID == captureID }
        for key in keys { removeEntry(key) }
        let identifiers = jobs.compactMap { $0.value.key.captureID == captureID ? $0.key : nil }
        for identifier in identifiers { cancel(identifier) }
    }

    func clear() {
        generation &+= 1
        entries.removeAll(keepingCapacity: false)
        cachedBytes = 0
        let identifiers = Array(jobs.keys)
        for identifier in identifiers { cancel(identifier) }
        queue.removeAll(keepingCapacity: false)
    }

    func panelDidClose() { clear() }
    func handleMemoryPressure() { clear() }

    func statistics() -> Statistics {
        Statistics(cachedBytes: cachedBytes, cachedImages: entries.count,
                   runningJobs: running.count, pendingJobs: queue.filter { jobs[$0] != nil }.count)
    }

    private func invalidateReplacedVersions(by key: RecentPreviewKey) {
        for old in entries.keys.filter({ key.replaces($0) }) { removeEntry(old) }
        let identifiers = jobs.compactMap { key.replaces($0.value.key) ? $0.key : nil }
        for identifier in identifiers { cancel(identifier) }
    }

    private func cancel(_ identifier: UUID) {
        guard let job = jobs.removeValue(forKey: identifier) else { return }
        running[identifier]?.cancel()
        queue.removeAll { $0 == identifier }
        job.continuation.resume(throwing: CancellationError())
    }

    private func startAvailableJobs() {
        while running.count < concurrencyLimit, !queue.isEmpty {
            let identifier = queue.removeFirst()
            guard let job = jobs[identifier] else { continue }
            let load = job.load
            let maximum = job.key.maxPixel
            running[identifier] = Task.detached(priority: .utility) { [weak self] in
                let result: Result<RecentPreviewImage, Error>
                do {
                    try Task.checkCancellation()
                    let image = try autoreleasepool {
                        let data = try load()
                        try Task.checkCancellation()
                        return try Self.decode(data, maximum: maximum)
                    }
                    try Task.checkCancellation()
                    result = .success(image)
                } catch { result = .failure(error) }
                await self?.finish(identifier, result: result)
            }
        }
    }

    private func finish(_ identifier: UUID, result: Result<RecentPreviewImage, Error>) {
        running.removeValue(forKey: identifier)
        if let job = jobs.removeValue(forKey: identifier) {
            if job.generation != generation {
                job.continuation.resume(throwing: CancellationError())
            } else {
                if case .success(let image) = result { store(image, for: job.key) }
                job.continuation.resume(with: result)
            }
        }
        startAvailableJobs()
    }

    private func store(_ image: RecentPreviewImage, for key: RecentPreviewKey) {
        let size = image.rgba.count
        guard size <= cacheBudget else { return }
        removeEntry(key)
        while cachedBytes + size > cacheBudget,
              let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            removeEntry(oldest)
        }
        clock &+= 1
        entries[key] = Entry(image: image, lastUse: clock)
        cachedBytes += size
    }

    private func removeEntry(_ key: RecentPreviewKey) {
        if let old = entries.removeValue(forKey: key) { cachedBytes -= old.image.rgba.count }
    }

    private nonisolated static func decode(_ data: Data, maximum: Int) throws -> RecentPreviewImage {
        guard data.count <= maximumEncodedBytes else { throw RecentPreviewError.inputTooLarge }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else { throw RecentPreviewError.decodeFailed }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              thumbnail.width > 0, thumbnail.height > 0,
              thumbnail.width <= maximum, thumbnail.height <= maximum else {
            throw RecentPreviewError.decodeFailed
        }
        let bytesPerRow = thumbnail.width * 4
        var pixels = Data(count: bytesPerRow * thumbnail.height)
        let rendered = pixels.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress,
                  let context = CGContext(data: base, width: thumbnail.width, height: thumbnail.height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
            return true
        }
        guard rendered else { throw RecentPreviewError.decodeFailed }
        return RecentPreviewImage(width: thumbnail.width, height: thumbnail.height,
                                  bytesPerRow: bytesPerRow, rgba: pixels)
    }
}
