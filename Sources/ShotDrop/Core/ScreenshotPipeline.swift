import Foundation

enum ScreenshotPipelineCopyOutcome: Sendable {
    case copied(ScreenshotClipboardReceipt)
    case superseded
    case failed(String)
    case cancelled
    case notAttempted(String)
}

struct ScreenshotPipelineOutcome: Sendable {
    let captureID: UUID
    let sessionID: UUID
    let observationSequence: UInt64
    let sourceURL: URL
    let save: ScreenshotSaveOutcome
    let copy: ScreenshotPipelineCopyOutcome
    var observedAt: Date = Date()
}

enum ScreenshotPipelineFailure: Error { case accessExplanationRequired, busy, superseded }

/// Dormant integration core. No production instance is created by app startup.
/// The caller must supply explained source access, lifecycle, save policy and writer.
@MainActor
final class ScreenshotPipeline {
    enum State: Equatable { case stopped, starting, running, stopping, failed(String) }
    typealias Save = @Sendable (ScreenshotSaveRequest, @escaping @Sendable (UUID) async throws -> Void) async -> ScreenshotSaveOutcome
    typealias Prepare = @Sendable (ScreenshotClipboardRequest) async throws -> PreparedScreenshotClipboard
    typealias Start = @Sendable (@escaping @Sendable (DetectedScreenshot) -> Void) async throws -> Void

    private struct Job {
        let id = UUID()
        let event: DetectedScreenshot
        let generation: UUID
        let manualEpoch: UUID
        let admittedDuringManualCopy: Bool
    }
    private struct Order: Comparable {
        let sequence: UInt64
        let birth: Int64
        let path: String
        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
            if lhs.birth != rhs.birth { return lhs.birth < rhs.birth }
            return lhs.path < rhs.path
        }
    }

    static let maximumPending = 64
    static let maximumAcceptedPerSession = 4_096
    private(set) var state: State = .stopped
    private(set) var rejectedSources: [URL] = []
    private let authorizeSource: @Sendable () async throws -> Void
    private let startDetector: Start
    private let stopDetector: @Sendable () async -> Void
    private let registerOutput: @Sendable (UUID) async -> Void
    private let request: (DetectedScreenshot) -> ScreenshotSaveRequest
    private let prepare: Prepare
    private let saveLane: ScreenshotPipelineSaveLane
    private let publisher: ScreenshotClipboardPublisher
    private let deduplicationLimit: Int
    private let mode: CopyMode
    private let modeProvider: (() -> CopyMode)?
    private let allowSurvivingOriginalFallback: Bool
    private let onOutcome: (ScreenshotPipelineOutcome) -> Void
    private var generation = UUID()
    private var manualEpoch = UUID()
    private var manualCopyPending = false
    private var expectedClipboardCount: Int
    private var latestPublished: Order?
    private var queue: [Job] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var accepted: Set<ScreenshotFileIdentity> = []
    private var acceptedOrder: [ScreenshotFileIdentity] = []
    private var stopTask: Task<Void, Never>?
    private var startupTask: Task<Void, Error>?
    private var ingressTask: Task<Void, Never>?
    private var ingress: AsyncStream<DetectedScreenshot>.Continuation?

    init(writer: any ScreenshotPasteboardWriting, mode: CopyMode, modeProvider: (() -> CopyMode)? = nil, deduplicationLimit: Int = ScreenshotPipeline.maximumAcceptedPerSession,
         authorizeSource: @escaping @Sendable () async throws -> Void,
         startDetector: @escaping Start, stopDetector: @escaping @Sendable () async -> Void,
         registerOutput: @escaping @Sendable (UUID) async -> Void,
         request: @escaping (DetectedScreenshot) -> ScreenshotSaveRequest,
         save: @escaping Save,
         prepare: @escaping Prepare = { try await ScreenshotClipboardPreparer().prepare($0) },
         allowSurvivingOriginalFallback: Bool = false,
         onOutcome: @escaping (ScreenshotPipelineOutcome) -> Void) {
        self.deduplicationLimit = max(1, deduplicationLimit)
        self.authorizeSource = authorizeSource; self.startDetector = startDetector
        self.stopDetector = stopDetector; self.registerOutput = registerOutput
        self.request = request; self.prepare = prepare
        self.saveLane = ScreenshotPipelineSaveLane(save: save)
        self.publisher = ScreenshotClipboardPublisher(writer: writer)
        self.mode = mode; self.modeProvider = modeProvider; self.allowSurvivingOriginalFallback = allowSurvivingOriginalFallback
        self.expectedClipboardCount = writer.changeCount; self.onOutcome = onOutcome
    }

    func start(sourceAccessExplained: Bool) async throws {
        guard sourceAccessExplained else { throw ScreenshotPipelineFailure.accessExplanationRequired }
        guard state == .stopped || { if case .failed = state { return true }; return false }(), tasks.isEmpty, stopTask == nil, startupTask == nil else {
            throw ScreenshotPipelineFailure.busy
        }
        generation = UUID(); let session = generation
        accepted.removeAll(); acceptedOrder.removeAll(); rejectedSources.removeAll(); latestPublished = nil
        let drops = ScreenshotPipelineIngressDrops() // Overflow recovery belongs to this session only.
        expectedClipboardCount = publisher.changeCount; state = .starting
        // The lifecycle owns authorization and detector startup through actual completion.
        // Cancellation alone cannot prove an injected/platform startup stopped its work.
        let startup = Task { [self] in
            try await authorizeSource()
            try Task.checkCancellation()
            guard generation == session, state == .starting else { throw CancellationError() }
            state = .running
            let (stream, continuation) = AsyncStream<DetectedScreenshot>.makeStream(bufferingPolicy: .bufferingOldest(Self.maximumPending))
            ingress = continuation
            ingressTask = Task { [weak self] in
                for await event in stream {
                    guard let self, !Task.isCancelled else { break }
                    self.rejectedSources.append(contentsOf: drops.take())
                    self.rejectedSources = Array(self.rejectedSources.suffix(Self.maximumPending))
                    self.admit(event, generation: session)
                }
            }
            try await startDetector { event in
                if case .dropped(let dropped) = continuation.yield(event) { drops.record(dropped.url) }
            }
            try Task.checkCancellation()
            guard generation == session, state == .running else { throw CancellationError() }
        }
        startupTask = startup
        do {
            try await withTaskCancellationHandler {
                try await startup.value
            } onCancel: {
                startup.cancel()
            }
            if generation == session { startupTask = nil }
        } catch {
            if generation == session {
                startupTask = nil // Completed startup cannot await its own stop drain.
                await stop()
                if state == .stopped { state = .failed(error.localizedDescription) }
            }
            throw error
        }
    }

    /// Stop, sleep and source-access/root failure use the same draining boundary.
    func stop() async {
        if let stopTask { await stopTask.value; return }
        state = .stopping; generation = UUID(); manualEpoch = UUID()
        ingress?.finish(); ingress = nil
        let incoming = ingressTask; ingressTask = nil; incoming?.cancel()
        let waiting = queue; queue.removeAll()
        for job in waiting {
            onOutcome(.init(captureID: job.id, sessionID: job.generation, observationSequence: job.event.observationSequence,
                sourceURL: job.event.url, save: .cancelled(originalURL: job.event.url), copy: .cancelled, observedAt: job.event.observedAt))
        }
        let active = Array(tasks.values)
        for task in active { task.cancel() }
        let starting = startupTask
        starting?.cancel()
        let drain = Task { [self] in
            // A suspended start may still finish installing resources after cancellation.
            // Stop the detector only after that installation has actually returned.
            _ = await starting?.result
            startupTask = nil
            await stopDetector()
            await incoming?.value
            for task in active { await task.value }
            state = .stopped
            stopTask = nil
        }
        stopTask = drain
        await drain.value
    }

    func sourceBecameUnavailable(_ reason: String) async {
        await stop()
        if state == .stopped { state = .failed(reason) }
    }
    func willSleep() async { await stop() }
    // Wake never silently reauthorizes/restarts observation; caller explicitly starts again.
    func manualCopyWillBegin() { manualEpoch = UUID(); manualCopyPending = true }
    func manualCopyDidFinish() {
        manualEpoch = UUID(); manualCopyPending = false; expectedClipboardCount = publisher.changeCount
    }

    private func admit(_ event: DetectedScreenshot, generation session: UUID) {
        guard state == .running, generation == session, !accepted.contains(event.identity) else { return }
        guard queue.count < Self.maximumPending else {
            // Admission pressure remains visible and recoverable; never call it saved.
            rejectedSources.append(event.url)
            if rejectedSources.count > Self.maximumPending { rejectedSources.removeFirst() }
            return
        }
        if publisher.changeCount != expectedClipboardCount {
            manualEpoch = UUID(); expectedClipboardCount = publisher.changeCount
        }
        if acceptedOrder.count == deduplicationLimit { accepted.remove(acceptedOrder.removeFirst()) }
        acceptedOrder.append(event.identity)
        accepted.insert(event.identity)
        queue.append(Job(event: event, generation: session, manualEpoch: manualEpoch,
                         admittedDuringManualCopy: manualCopyPending))
        schedule()
    }

    private func schedule() {
        while state == .running, tasks.count < 2, !queue.isEmpty {
            let job = queue.removeFirst()
            tasks[job.id] = Task { [self] in
                await process(job)
                tasks.removeValue(forKey: job.id)
                schedule()
            }
        }
    }

    private func process(_ job: Job) async {
        let saved = await saveLane.perform(request(job.event)) { [weak self] token in
            guard let self else { throw CancellationError() }
            try await self.beforeSavePublication(job, outputToken: token)
        }
        var copy: ScreenshotPipelineCopyOutcome
        do {
            try Task.checkCancellation()
            try validateClipboardIntent(job)
            let clipboardRequest: ScreenshotClipboardRequest
            switch saved {
            case .saved(let result):
                clipboardRequest = .init(sourceURL: result.destinationURL, mode: modeProvider?() ?? mode,
                    expectedIdentity: result.destinationIdentity, survivingFileURL: result.destinationURL,
                    survivingFileIdentity: result.destinationIdentity)
            case .failed where allowSurvivingOriginalFallback:
                clipboardRequest = .init(sourceURL: job.event.url, mode: modeProvider?() ?? mode,
                    expectedIdentity: job.event.identity, survivingFileURL: job.event.url,
                    survivingFileIdentity: job.event.identity)
            default:
                onOutcome(.init(captureID: job.id, sessionID: job.generation, observationSequence: job.event.observationSequence,
                    sourceURL: job.event.url, save: saved, copy: .notAttempted("No verified saved file; original fallback was not selected."), observedAt: job.event.observedAt))
                return
            }
            let prepared = try await prepare(clipboardRequest)
            let receipt = try await publisher.publish(prepared) { try self.validateClipboardIntent(job) }
            expectedClipboardCount = receipt.changeCount
            latestPublished = order(job)
            copy = .copied(receipt)
        } catch is CancellationError { copy = .cancelled }
        catch ScreenshotPipelineFailure.superseded { copy = .superseded }
        catch { copy = .failed(error.localizedDescription) }
        // Preserve a real save receipt even when a stopped session cannot copy.
        // Consumers use sessionID/captureID to avoid retargeting current UI/history.
        onOutcome(.init(captureID: job.id, sessionID: job.generation, observationSequence: job.event.observationSequence,
                        sourceURL: job.event.url, save: saved, copy: copy, observedAt: job.event.observedAt))
    }

    private func beforeSavePublication(_ job: Job, outputToken: UUID) async throws {
        try Task.checkCancellation()
        guard generation == job.generation, state == .running else { throw CancellationError() }
        await registerOutput(outputToken)
        try Task.checkCancellation()
        guard generation == job.generation, state == .running else { throw CancellationError() }
    }

    private func order(_ job: Job) -> Order {
        Order(sequence: job.event.observationSequence, birth: job.event.identity.birthNanoseconds,
              path: job.event.url.path)
    }

    private func validateClipboardIntent(_ job: Job) throws {
        guard state == .running, generation == job.generation else { throw CancellationError() }
        if publisher.changeCount != expectedClipboardCount {
            manualEpoch = UUID(); expectedClipboardCount = publisher.changeCount
        }
        guard job.manualEpoch == manualEpoch, !job.admittedDuringManualCopy, !manualCopyPending,
              latestPublished.map({ order(job) > $0 }) ?? true else { throw ScreenshotPipelineFailure.superseded }
    }

    func finishPendingWork() async {
        while let task = tasks.values.first { await task.value }
    }
}

/// Serialization covers the entire save including callback awaits. Waiting work keeps
/// its caller slot until cancellation actually returns, rather than opening another lane.
private actor ScreenshotPipelineSaveLane {
    private let save: ScreenshotPipeline.Save
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(save: @escaping ScreenshotPipeline.Save) { self.save = save }
    func perform(_ request: ScreenshotSaveRequest,
                 beforePublishing: @escaping @Sendable (UUID) async throws -> Void) async -> ScreenshotSaveOutcome {
        if occupied { await withCheckedContinuation { waiters.append($0) } } else { occupied = true }
        defer {
            if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume() }
        }
        guard !Task.isCancelled else { return .cancelled(originalURL: request.organization.sourceURL) }
        return await save(request, beforePublishing)
    }
}

/// No task allocation per detector callback; retain only bounded overflow recovery paths.
private final class ScreenshotPipelineIngressDrops: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func record(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        if urls.count == 64 { urls.removeFirst() }
        urls.append(url)
    }
    func take() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        let result = urls; urls.removeAll(); return result
    }
}
