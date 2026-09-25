import Foundation
import OSLog

struct DetectedScreenshot: Sendable {
    let url: URL
    let identity: ScreenshotFileIdentity
    let readinessLatency: Duration
    let candidateToReadyLatency: Duration
    let readinessAttempts: Int
    /// Order assigned when first observed, before concurrent readiness work; scoped to one start.
    let observationSequence: UInt64
    /// Observation time, not an assertion of the system screenshot's capture time.
    let observedAt: Date

    init(url: URL, identity: ScreenshotFileIdentity, readinessLatency: Duration,
         candidateToReadyLatency: Duration, readinessAttempts: Int,
         observationSequence: UInt64 = 0, observedAt: Date = Date(timeIntervalSince1970: 0)) {
        self.url = url
        self.identity = identity
        self.readinessLatency = readinessLatency
        self.candidateToReadyLatency = candidateToReadyLatency
        self.readinessAttempts = readinessAttempts
        self.observationSequence = observationSequence
        self.observedAt = observedAt
    }
}

/// Explicitly started by a future permission/pipeline coordinator, never by app initialization.
/// File work is actor-isolated away from MainActor; only Spotlight lives on MainActor.
actor ScreenshotDetector {
    enum Status: Equatable, Sendable {
        case idle
        case starting
        case watching(URL)
        case stopping
        case failed(String)
    }

    enum DetectionError: LocalizedError {
        case alreadyRunning
        var errorDescription: String? { "Screenshot detection is already running or changing state." }
    }

    private(set) var status: Status = .idle { didSet { onStatus?(status) } }
    private let onStatus: (@Sendable (Status) -> Void)?
    private let fileSystem: any ScreenshotFileSystemReading
    private let watcher: any ScreenshotWatching
    private let checker: ScreenshotReadinessChecker
    private let resolveDirectory: @Sendable () throws -> URL
    private let wallTimeNanoseconds: @Sendable () -> Int64
    private let useSpotlight: Bool
    private let onScreenshot: @Sendable (DetectedScreenshot) -> Void
    private let logger = Logger(subsystem: "com.macfleet.shotdrop", category: "Detection")
    private let maxConcurrentChecks = 4

    private var generation = UUID()
    private var directory: URL?
    private var metadata: ScreenshotMetadataReconciler?
    private var historical: Set<ScreenshotFileIdentity> = []
    private var emitted: Set<ScreenshotFileIdentity> = []
    private var outputTokens: Set<UUID> = []
    private var queued: [URL] = []
    private var queuedSet: Set<URL> = []
    private var pending: [URL: PendingCheck] = [:]
    private var changedWhilePending: Set<URL> = []
    private struct Observation {
        let instant: ContinuousClock.Instant
        let date: Date
        let sequence: UInt64
    }
    private var firstObserved: [URL: Observation] = [:]
    private var observationSequence: UInt64 = 0
    private var startupEvents: [ScreenshotWatchEvent] = []

    private struct PendingCheck {
        let token: UUID
        let task: Task<Void, Never>
    }

    init(
        fileSystem: any ScreenshotFileSystemReading = LocalScreenshotFileSystem(),
        watcher: any ScreenshotWatching = ScreenshotDirectoryWatcher(),
        clock: any ScreenshotDetectionClock = ContinuousScreenshotDetectionClock(),
        retryDelays: [Duration] = ScreenshotReadinessChecker.defaultRetryDelays,
        useSpotlight: Bool = true,
        resolveDirectory: @escaping @Sendable () throws -> URL = ScreenshotDirectoryResolver.systemLocation,
        wallTimeNanoseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        },
        onStatus: (@Sendable (Status) -> Void)? = nil,
        onScreenshot: @escaping @Sendable (DetectedScreenshot) -> Void
    ) {
        self.onStatus = onStatus
        self.fileSystem = fileSystem
        self.watcher = watcher
        checker = ScreenshotReadinessChecker(fileSystem: fileSystem, clock: clock, retryDelays: retryDelays)
        self.resolveDirectory = resolveDirectory
        self.wallTimeNanoseconds = wallTimeNanoseconds
        self.useSpotlight = useSpotlight
        self.onScreenshot = onScreenshot
    }

    deinit {
        for check in pending.values { check.task.cancel() }
        let watcher = watcher
        let metadata = metadata
        Task {
            await watcher.stop()
            await metadata?.stop()
        }
    }

    func start(in requestedDirectory: URL? = nil) async throws {
        switch status {
        case .idle, .failed: break
        default: throw DetectionError.alreadyRunning
        }
        let token = UUID()
        generation = token
        status = .starting
        observationSequence = 0
        let startedAt = wallTimeNanoseconds()

        do {
            try Task.checkCancellation()
            let requested = try requestedDirectory ?? resolveDirectory()
            guard requested.isFileURL else { throw ScreenshotDirectoryWatcher.WatchError.invalidDirectoryURL }
            let resolved = requested.standardizedFileURL.resolvingSymlinksInPath()
            let source = URL(fileURLWithPath: resolved.path, isDirectory: true)
            directory = source
            // Observe before scanning. Birth time separates creations during this scan from history.
            try await watcher.start(in: source) { [weak self] event in
                Task { await self?.receive(event, generation: token) }
            }
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            let initialURLs = try fileSystem.contents(of: source)
            var createdDuringStartup: [URL] = []
            for url in initialURLs where accepts(url) {
                guard let identity = try? fileSystem.identity(at: url) else { continue }
                if identity.birthNanoseconds < startedAt {
                    historical.insert(identity)
                } else {
                    createdDuringStartup.append(url)
                }
            }
            status = .watching(source)
            enqueue(createdDuringStartup)
            let events = startupEvents
            startupEvents.removeAll()
            for event in events {
                await receive(event, generation: token)
            }
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }

            if useSpotlight {
                let reconciler = await MainActor.run { ScreenshotMetadataReconciler() }
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                metadata = reconciler
                let started = await reconciler.start(in: source) { [weak self] urls in
                    Task { await self?.receive(.paths(urls), generation: token) }
                }
                try Task.checkCancellation()
                guard generation == token else {
                    await reconciler.stop()
                    throw CancellationError()
                }
                if !started {
                    logger.notice("Spotlight reconciliation unavailable; filesystem detection remains active.")
                }
            }
            try Task.checkCancellation()
            logger.info("Screenshot detector started; historical files excluded.")
        } catch {
            if generation == token {
                await stop()
                status = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    func stop() async {
        if status == .stopping { return }
        generation = UUID()
        status = .stopping
        for check in pending.values { check.task.cancel() }
        pending.removeAll()
        changedWhilePending.removeAll()
        firstObserved.removeAll()
        queued.removeAll()
        queuedSet.removeAll()
        startupEvents.removeAll()
        historical.removeAll()
        emitted.removeAll()
        outputTokens.removeAll()
        directory = nil
        let oldMetadata = metadata
        metadata = nil
        await watcher.stop()
        await oldMetadata?.stop()
        status = .idle
        logger.info("Screenshot detector stopped.")
    }

    /// Reserve a staged output before it receives a visible name in the source folder.
    /// The organizer exposes this identity before publication to prevent feedback loops.
    func ignoreOutput(_ identity: ScreenshotFileIdentity) {
        emitted.insert(identity)
    }

    /// Register provenance before publication; cloned outputs have a new file identity.
    func ignoreOutput(token: UUID) {
        outputTokens.insert(token)
    }

    private func accepts(_ url: URL) -> Bool {
        guard let directory, url.isFileURL else { return false }
        let canonical = url.standardizedFileURL
        return canonical.deletingLastPathComponent() == directory
            && ScreenshotFileFilter.accepts(canonical)
    }

    private func receive(_ event: ScreenshotWatchEvent, generation token: UUID) async {
        guard generation == token else { return }
        if status == .starting {
            startupEvents.append(event)
            return
        }
        guard case .watching = status else { return }
        switch event {
        case .paths(let urls):
            enqueue(urls)
        case .rescanRequired:
            guard let directory else { return }
            do {
                enqueue(try fileSystem.contents(of: directory))
            } catch {
                await stop()
                status = .failed("Cannot read the screenshot folder: \(error.localizedDescription)")
            }
        case .rootChanged:
            // Do not silently follow a moved folder or keep watching a stale inode.
            await stop()
            status = .failed("The screenshot folder changed or became unavailable. Start detection again to resolve its location.")
        }
    }

    private func enqueue(_ urls: [URL]) {
        // Watcher batches and directory enumerations do not promise order. Give ties a
        // stable path order before any readiness task can complete.
        for candidate in urls.sorted(by: { $0.standardizedFileURL.path < $1.standardizedFileURL.path }) {
            let url = candidate.standardizedFileURL
            guard accepts(url) else { continue }
            if pending[url] != nil {
                changedWhilePending.insert(url)
                continue
            }
            guard !queuedSet.contains(url) else { continue }
            if let identity = try? fileSystem.identity(at: url),
               historical.contains(identity) || emitted.contains(identity) { continue }
            if firstObserved[url] == nil {
                // Never wrap and make new work appear older than an earlier observation.
                guard observationSequence < UInt64.max else {
                    logger.error("Screenshot observation sequence exhausted; restart detection before admitting more candidates.")
                    continue
                }
                observationSequence += 1
                firstObserved[url] = Observation(instant: .now,
                    date: Date(timeIntervalSince1970: Double(wallTimeNanoseconds()) / 1_000_000_000),
                    sequence: observationSequence)
            }
            queued.append(url)
            queuedSet.insert(url)
        }
        scheduleChecks()
    }

    private func scheduleChecks() {
        while pending.count < maxConcurrentChecks, !queued.isEmpty {
            let url = queued.removeFirst()
            queuedSet.remove(url)
            let token = UUID()
            let session = generation
            let checker = checker
            let task = Task { [weak self] in
                do {
                    let result = try await checker.waitUntilReady(at: url)
                    try Task.checkCancellation()
                    await self?.finished(url, result: result, token: token, generation: session)
                } catch {
                    await self?.finished(url, result: nil, token: token, generation: session)
                }
            }
            pending[url] = PendingCheck(token: token, task: task)
        }
    }

    private func finished(
        _ url: URL, result: ScreenshotReadinessResult?, token: UUID, generation session: UUID
    ) {
        guard generation == session, pending[url]?.token == token else { return }
        pending.removeValue(forKey: url)
        let observed = firstObserved[url]
        let changed = changedWhilePending.remove(url) != nil
        defer {
            if changed { enqueue([url]) }
            // A hint received while checking may retry the same pending observation.
            // Preserve its sequence/time through that retry, but release completed state.
            if pending[url] == nil && !queuedSet.contains(url) { firstObserved.removeValue(forKey: url) }
            scheduleChecks()
        }
        guard let result, let observed else {
            logger.debug("Candidate did not become ready within the bounded retry window.")
            return
        }
        let identity = result.snapshot.identity
        if let token = result.snapshot.outputToken, outputTokens.contains(token) {
            emitted.insert(identity)
            return
        }
        guard !historical.contains(identity), !emitted.contains(identity),
              let current = try? fileSystem.identity(at: url), current == identity else { return }
        emitted.insert(identity)
        let candidateLatency = observed.instant.duration(to: .now)
        let parts = candidateLatency.components
        let milliseconds = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
        logger.info("Verified screenshot; candidate-to-ready ms=\(milliseconds), attempts=\(result.attempts)")
        onScreenshot(DetectedScreenshot(
            url: url, identity: identity, readinessLatency: result.latency,
            candidateToReadyLatency: candidateLatency,
            readinessAttempts: result.attempts, observationSequence: observed.sequence,
            observedAt: observed.date
        ))
    }
}
