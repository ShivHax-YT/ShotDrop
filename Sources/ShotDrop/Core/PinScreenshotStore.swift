import CoreGraphics
import Foundation
import ImageIO

struct PinScreenshotIdentity: Equatable, Sendable {
    let captureID: UUID
    let revision: UInt64
    let reference: RecentFileReference
}

struct PinScreenshotSnapshot: Sendable {
    let identity: PinScreenshotIdentity
    let image: RecentPreviewImage
    let sourceWidth: Int
    let sourceHeight: Int
    var isReduced: Bool { image.width != sourceWidth || image.height != sourceHeight }
}

enum PinScreenshotFailure: Error, Equatable {
    case unavailable, invalidImage, budgetExceeded, closed
}

/// Session-only ownership. A canceled native decode retains its admission until it returns.
/// Limits cover retained RGBA data, not ImageIO internals or total process memory.
actor PinScreenshotStore {
    static let maximumSessions = 3
    static let maximumCacheBytes = 64 * 1_024 * 1_024
    static let maximumDimension = 2048
    typealias Decoder = @Sendable (PinScreenshotIdentity) throws -> PinScreenshotSnapshot
    enum Admission: Equatable, Sendable { case opened(UUID), existing(UUID), closing(UUID), full }
    struct Statistics: Sendable { let sessions: Int; let cachedBytes: Int; let runningJobs: Int }
    private struct Entry {
        let identity: PinScreenshotIdentity
        var closing = false
        var snapshot: PinScreenshotSnapshot?
        var waiters: [CheckedContinuation<PinScreenshotSnapshot, Error>] = []
        var failure: PinScreenshotFailure?
    }
    private var entries: [UUID: Entry] = [:]
    private var queue: [UUID] = []
    private var running: (UUID, Task<Void, Never>)?
    private let decode: Decoder
    private let budget: Int
    private var cachedBytes = 0

    init(cacheBudgetBytes: Int = maximumCacheBytes, decoder: @escaping Decoder = { try PinScreenshotStore.decode($0) }) {
        budget = min(Self.maximumCacheBytes, max(0, cacheBudgetBytes))
        decode = decoder
    }

    func admit(_ identity: PinScreenshotIdentity) throws -> Admission {
        guard identity.reference.role == .savedCopy else { throw PinScreenshotFailure.unavailable }
        if let existing = entries.first(where: { $0.value.identity == identity }) {
            return existing.value.closing ? .closing(existing.key) : .existing(existing.key)
        }
        guard entries.count < Self.maximumSessions else { return .full }
        let token = UUID()
        entries[token] = Entry(identity: identity)
        queue.append(token)
        startNext()
        return .opened(token)
    }

    func snapshot(for token: UUID) async throws -> PinScreenshotSnapshot {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard let entry = entries[token], !entry.closing else { throw PinScreenshotFailure.closed }
            if let snapshot = entry.snapshot { return snapshot }
            if let failure = entry.failure { throw failure }
            return try await withCheckedThrowingContinuation { entries[token]?.waiters.append($0) }
        } onCancel: {
            Task { await self.close(token) }
        }
    }

    func close(_ token: UUID) {
        guard var entry = entries[token] else { return }
        entry.closing = true
        entry.waiters.forEach { $0.resume(throwing: PinScreenshotFailure.closed) }
        entry.waiters.removeAll()
        if let snapshot = entry.snapshot { cachedBytes -= snapshot.image.rgba.count }
        entry.snapshot = nil
        entries[token] = entry
        queue.removeAll { $0 == token }
        if running?.0 == token { running?.1.cancel() }
        else { entries.removeValue(forKey: token) }
    }

    func closeAll() { for token in Array(entries.keys) { close(token) } }
    func statistics() -> Statistics {
        Statistics(sessions: entries.count, cachedBytes: cachedBytes, runningJobs: running == nil ? 0 : 1)
    }

    private func startNext() {
        guard running == nil, !queue.isEmpty else { return }
        let token = queue.removeFirst()
        guard let entry = entries[token] else { startNext(); return }
        let decoder = decode, identity = entry.identity
        let task = Task.detached(priority: .utility) { [weak self] in
            let result: Result<PinScreenshotSnapshot, Error>
            do {
                try Task.checkCancellation()
                let value = try autoreleasepool { try decoder(identity) }
                try Task.checkCancellation()
                result = .success(value)
            } catch { result = .failure(error) }
            await self?.finish(token, result: result)
        }
        running = (token, task)
    }

    private func finish(_ token: UUID, result: Result<PinScreenshotSnapshot, Error>) {
        running = nil
        defer { startNext() }
        guard var entry = entries[token] else { return }
        guard !entry.closing else { entries.removeValue(forKey: token); return }
        do {
            let snapshot = try result.get()
            guard snapshot.identity == entry.identity else { throw PinScreenshotFailure.unavailable }
            let size = try Self.byteCount(width: snapshot.image.width, height: snapshot.image.height)
            guard snapshot.image.bytesPerRow == snapshot.image.width * 4,
                  snapshot.image.rgba.count == size,
                  size <= budget - cachedBytes else { throw PinScreenshotFailure.budgetExceeded }
            entry.snapshot = snapshot
            cachedBytes += size
            entry.waiters.forEach { $0.resume(returning: snapshot) }
        } catch {
            entry.failure = (error as? PinScreenshotFailure) ?? .unavailable
            entry.waiters.forEach { $0.resume(throwing: entry.failure!) }
        }
        entry.waiters.removeAll()
        entries[token] = entry
    }

    nonisolated static func byteCount(width: Int, height: Int) throws -> Int {
        guard (1...maximumDimension).contains(width), (1...maximumDimension).contains(height) else {
            throw PinScreenshotFailure.invalidImage
        }
        let row = width.multipliedReportingOverflow(by: 4)
        let total = row.partialValue.multipliedReportingOverflow(by: height)
        guard !row.overflow, !total.overflow else { throw PinScreenshotFailure.budgetExceeded }
        return total.partialValue
    }

    private nonisolated static func decode(_ identity: PinScreenshotIdentity) throws -> PinScreenshotSnapshot {
        guard case .available(let file) = RecentFileResolver().resolve(identity.reference),
              file.role == .savedCopy,
              file.validatedData.count <= Int(RecentFileReference.maximumFileBytes) else {
            throw PinScreenshotFailure.unavailable
        }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(file.validatedData as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let h = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw PinScreenshotFailure.invalidImage }
        let width = w.doubleValue, height = h.doubleValue
        guard width.isFinite, height.isFinite, width.rounded() == width, height.rounded() == height,
              width >= 1, height >= 1, width <= 32_000_000, height <= 32_000_000 / width else {
            throw PinScreenshotFailure.invalidImage
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation) else { throw PinScreenshotFailure.invalidImage }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: false]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PinScreenshotFailure.invalidImage
        }
        let count = try byteCount(width: image.width, height: image.height)
        var pixels = Data(count: count)
        let success = pixels.withUnsafeMutableBytes { bytes in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard success else { throw PinScreenshotFailure.invalidImage }
        try Task.checkCancellation()
        let swaps = orientation >= 5
        return PinScreenshotSnapshot(identity: identity,
            image: RecentPreviewImage(width: image.width, height: image.height, bytesPerRow: image.width * 4, rgba: pixels),
            sourceWidth: Int(swaps ? height : width), sourceHeight: Int(swaps ? width : height))
    }
}
