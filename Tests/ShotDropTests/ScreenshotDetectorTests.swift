import Foundation
import os
import XCTest
@testable import ShotDrop

final class ScreenshotDetectorTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/detector-fixture", isDirectory: true)

    func testBaselineRemainsSuppressedOnLaterEventsAndRescan() async throws {
        let oldURL = folder.appendingPathComponent("old.png")
        let freshURL = folder.appendingPathComponent("fresh.png")
        let fileSystem = DetectorFixtureFileSystem([oldURL: shot(inode: 1, birth: 1)])
        let watcher = DetectorFixtureWatcher()
        let fresh = expectation(description: "New screenshot emitted")
        let unexpected = expectation(description: "Baseline screenshot stays suppressed")
        unexpected.isInverted = true
        let detector = makeDetector(fileSystem: fileSystem, watcher: watcher) { screenshot in
            if screenshot.url == freshURL { fresh.fulfill() } else { unexpected.fulfill() }
        }
        try await detector.start(in: folder)
        fileSystem.set(shot(inode: 2), at: freshURL)
        await watcher.emit(.paths([oldURL, freshURL]))
        await watcher.emit(.rescanRequired)

        await fulfillment(of: [fresh], timeout: 2)
        await fulfillment(of: [unexpected], timeout: 0.1)
        await detector.stop()
    }

    func testSameIdentityEmitsOnceAcrossDuplicatePathsRescansAndRename() async throws {
        let original = folder.appendingPathComponent("original.png")
        let renamed = folder.appendingPathComponent("renamed.png")
        let fileSystem = DetectorFixtureFileSystem()
        let watcher = DetectorFixtureWatcher()
        let first = expectation(description: "First identity emitted")
        let duplicate = expectation(description: "No duplicate identity emission")
        duplicate.isInverted = true
        let count = OSAllocatedUnfairLock(initialState: 0)
        let detector = makeDetector(fileSystem: fileSystem, watcher: watcher) { _ in
            let value = count.withLock { $0 += 1; return $0 }
            if value == 1 { first.fulfill() } else { duplicate.fulfill() }
        }
        try await detector.start(in: folder)
        let image = shot(inode: 1)
        fileSystem.set(image, at: original)
        await watcher.emit(.paths([original, original]))
        await fulfillment(of: [first], timeout: 2)

        fileSystem.set(image, at: renamed)
        fileSystem.remove(original)
        await watcher.emit(.paths([original, renamed, renamed]))
        await watcher.emit(.rescanRequired)
        await fulfillment(of: [duplicate], timeout: 0.1)
        XCTAssertEqual(count.withLock { $0 }, 1)
        await detector.stop()
    }

    func testReplacementIdentityAtSamePathEmitsAgain() async throws {
        let url = folder.appendingPathComponent("reused.png")
        let fileSystem = DetectorFixtureFileSystem()
        let watcher = DetectorFixtureWatcher()
        let first = expectation(description: "Original inode emitted")
        let second = expectation(description: "Replacement inode emitted")
        let detector = makeDetector(fileSystem: fileSystem, watcher: watcher) { screenshot in
            switch screenshot.identity.inode {
            case 1: first.fulfill()
            case 2: second.fulfill()
            default: XCTFail("Unexpected identity")
            }
        }
        try await detector.start(in: folder)
        fileSystem.set(shot(inode: 1), at: url)
        await watcher.emit(.paths([url]))
        await fulfillment(of: [first], timeout: 2)

        fileSystem.set(shot(inode: 2), at: url)
        await watcher.emit(.paths([url]))
        await fulfillment(of: [second], timeout: 2)
        await detector.stop()
    }

    func testLateCallbackAfterStopIsSuppressed() async throws {
        let url = folder.appendingPathComponent("late.png")
        let fileSystem = DetectorFixtureFileSystem()
        let watcher = DetectorFixtureWatcher()
        let unexpected = expectation(description: "Stopped detector emits nothing")
        unexpected.isInverted = true
        let detector = makeDetector(fileSystem: fileSystem, watcher: watcher) { _ in
            unexpected.fulfill()
        }
        try await detector.start(in: folder)
        await detector.stop()
        fileSystem.set(shot(inode: 1), at: url)
        await watcher.emit(.paths([url]), generation: 0)
        await watcher.emit(.rescanRequired, generation: 0)

        await fulfillment(of: [unexpected], timeout: 0.1)
        let status = await detector.status
        XCTAssertEqual(status, .idle)
        XCTAssertEqual(fileSystem.snapshotReadCount, 0)
    }

    func testStaleGenerationCannotStopOrEmitIntoRestartedSession() async throws {
        let url = folder.appendingPathComponent("restart.png")
        let fileSystem = DetectorFixtureFileSystem()
        let watcher = DetectorFixtureWatcher()
        let emitted = expectation(description: "Current session emits screenshot")
        let detector = makeDetector(fileSystem: fileSystem, watcher: watcher) { screenshot in
            XCTAssertEqual(screenshot.url, url)
            emitted.fulfill()
        }
        try await detector.start(in: folder)
        await detector.stop()
        try await detector.start(in: folder)
        fileSystem.set(shot(inode: 1), at: url)
        await watcher.emit(.rootChanged, generation: 0)
        await watcher.emit(.paths([url]), generation: 0)
        await watcher.emit(.paths([url]), generation: 1)

        await fulfillment(of: [emitted], timeout: 2)
        let status = await detector.status
        XCTAssertEqual(status, .watching(folder))
        await detector.stop()
    }

    func testRootChangeStopsWatcherAndFailsDetector() async throws {
        let watcher = DetectorFixtureWatcher()
        let unexpected = expectation(description: "Root change emits no screenshot")
        unexpected.isInverted = true
        let detector = makeDetector(fileSystem: DetectorFixtureFileSystem(), watcher: watcher) { _ in
            unexpected.fulfill()
        }
        try await detector.start(in: folder)
        await watcher.emit(.rootChanged)

        let status = await waitForFailure(detector)
        guard case .failed(let message) = status else {
            XCTFail("Expected failed state, received \(status)")
            await detector.stop()
            return
        }
        XCTAssertTrue(message.contains("folder changed"))
        let stops = await watcher.stopCount
        XCTAssertEqual(stops, 1)
        await fulfillment(of: [unexpected], timeout: 0.05)
        await detector.stop()
    }

    func testWatcherStartFailureCleansUpAndReportsFailedStatus() async throws {
        let watcher = DetectorFixtureWatcher(failStart: true)
        let fileSystem = DetectorFixtureFileSystem()
        let detector = makeDetector(fileSystem: fileSystem, watcher: watcher) { _ in
            XCTFail("Failed start cannot emit screenshots")
        }
        do {
            try await detector.start(in: folder)
            XCTFail("Watcher start error must propagate")
        } catch DetectorFixtureError.start {}

        let status = await detector.status
        guard case .failed = status else { return XCTFail("Expected failed state") }
        let stops = await watcher.stopCount
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(fileSystem.contentsReadCount, 0)
        await detector.stop()
    }

    func testInitialDirectoryReadFailureStopsStartedWatcher() async throws {
        let fileSystem = DetectorFixtureFileSystem()
        fileSystem.setContentsFailure(true)
        let watcher = DetectorFixtureWatcher()
        let detector = makeDetector(fileSystem: fileSystem, watcher: watcher) { _ in
            XCTFail("Failed baseline cannot emit screenshots")
        }
        do {
            try await detector.start(in: folder)
            XCTFail("Directory read error must propagate")
        } catch DetectorFixtureError.read {}

        let status = await detector.status
        guard case .failed = status else { return XCTFail("Expected failed state") }
        let stops = await watcher.stopCount
        XCTAssertEqual(stops, 1)
        await detector.stop()
    }

    func testRescanReadFailureStopsWatcherAndFailsDetector() async throws {
        let fileSystem = DetectorFixtureFileSystem()
        let watcher = DetectorFixtureWatcher()
        let detector = makeDetector(fileSystem: fileSystem, watcher: watcher) { _ in
            XCTFail("Failed rescan cannot emit screenshots")
        }
        try await detector.start(in: folder)
        fileSystem.setContentsFailure(true)
        await watcher.emit(.rescanRequired)

        let status = await waitForFailure(detector)
        guard case .failed(let message) = status else {
            XCTFail("Expected failed state")
            await detector.stop()
            return
        }
        XCTAssertTrue(message.contains("Cannot read"))
        let stops = await watcher.stopCount
        XCTAssertEqual(stops, 1)
        await detector.stop()
    }

    func testAtMostFourReadinessChecksRunConcurrently() async throws {
        let fileSystem = DetectorFixtureFileSystem()
        let watcher = DetectorFixtureWatcher()
        let suspended = expectation(description: "First four checks reach delay")
        suspended.expectedFulfillmentCount = 4
        let emitted = expectation(description: "All eight screenshots emitted")
        emitted.expectedFulfillmentCount = 8
        let clock = DetectorGateClock { suspended.fulfill() }
        let detector = makeDetector(fileSystem: fileSystem, watcher: watcher, clock: clock) { _ in
            emitted.fulfill()
        }
        try await detector.start(in: folder)
        let urls = (1...8).map { folder.appendingPathComponent("\($0).png") }
        for (index, url) in urls.enumerated() {
            fileSystem.set(shot(inode: UInt64(index + 1)), at: url)
        }
        await watcher.emit(.paths(urls))
        await fulfillment(of: [suspended], timeout: 2)
        XCTAssertEqual(fileSystem.snapshotReadCount, 4)

        await clock.releaseAll()
        await fulfillment(of: [emitted], timeout: 2)
        await detector.stop()
    }

    func testReplacementEventWhileOldIdentityIsPendingIsRetried() async throws {
        let url = folder.appendingPathComponent("replaced-while-pending.png")
        let sentinel = folder.appendingPathComponent("historical-barrier.png")
        let original = shot(inode: 1)
        let replacement = shot(inode: 2)
        let fileSystem = DetectorFixtureFileSystem([sentinel: shot(inode: 99, birth: 1)])
        let watcher = DetectorFixtureWatcher()
        let suspended = expectation(description: "Old inode readiness check is pending")
        let eventProcessed = expectation(description: "Replacement event traversed detector queue")
        let emitted = expectation(description: "Replacement inode is eventually emitted")
        let clock = DetectorGateClock { suspended.fulfill() }
        let detector = makeDetector(fileSystem: fileSystem, watcher: watcher, clock: clock) { screenshot in
            XCTAssertEqual(screenshot.identity, replacement.identity)
            emitted.fulfill()
        }
        try await detector.start(in: folder)
        fileSystem.set(original, at: url)
        // Model an old open-file observation completing after its path was replaced.
        fileSystem.setSnapshotSequence([original, original], at: url)
        await watcher.emit(.paths([url]))
        await fulfillment(of: [suspended], timeout: 2)

        fileSystem.set(replacement, at: url)
        fileSystem.observeIdentity { candidate in
            if candidate == sentinel { eventProcessed.fulfill() }
        }
        // The second path is an in-actor barrier: it is visited after the pending path.
        await watcher.emit(.paths([url, sentinel]))
        await fulfillment(of: [eventProcessed], timeout: 2)
        fileSystem.observeIdentity(nil)
        await clock.releaseAll()

        await fulfillment(of: [emitted], timeout: 2)
        XCTAssertGreaterThanOrEqual(fileSystem.snapshotReadCount, 4)
        await detector.stop()
    }

    func testCancellationDuringWatcherStartCannotLeaveActiveDetector() async throws {
        let startSuspended = expectation(description: "Watcher start is suspended")
        let watcher = DetectorFixtureWatcher(onStartSuspended: { startSuspended.fulfill() })
        let fileSystem = DetectorFixtureFileSystem()
        let detector = makeDetector(fileSystem: fileSystem, watcher: watcher) { _ in
            XCTFail("Cancelled start cannot emit screenshots")
        }
        let source = folder
        let start = Task { try await detector.start(in: source) }
        await fulfillment(of: [startSuspended], timeout: 2)
        start.cancel()
        await watcher.releaseStart()

        do {
            try await start.value
            XCTFail("Cancellation after watcher start must propagate")
        } catch is CancellationError {}

        let status = await detector.status
        switch status {
        case .idle, .failed: break
        default: XCTFail("Cancelled start left detector active: \(status)")
        }
        let stops = await watcher.stopCount
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(fileSystem.contentsReadCount, 0)
        await detector.stop()
    }

    private func makeDetector(
        fileSystem: DetectorFixtureFileSystem,
        watcher: DetectorFixtureWatcher,
        clock: any ScreenshotDetectionClock = DetectorFixtureClock(),
        onScreenshot: @escaping @Sendable (DetectedScreenshot) -> Void
    ) -> ScreenshotDetector {
        ScreenshotDetector(
            fileSystem: fileSystem, watcher: watcher, clock: clock,
            retryDelays: [.milliseconds(10), .milliseconds(20)],
            useSpotlight: false, wallTimeNanoseconds: { 100 }, onScreenshot: onScreenshot
        )
    }

    private func shot(inode: UInt64, birth: Int64 = 200) -> ScreenshotFileSnapshot {
        ScreenshotFileSnapshot(
            identity: ScreenshotFileIdentity(device: 1, inode: inode, birthNanoseconds: birth),
            size: 100, modifiedNanoseconds: 1, isScreenshot: true, isCompleteImage: true
        )
    }

    // The production status has no observer. Bound this diagnostic wait to one second;
    // screenshot delivery itself is synchronized by XCTest expectations above.
    private func waitForFailure(_ detector: ScreenshotDetector) async -> ScreenshotDetector.Status {
        for _ in 0..<100 {
            let status = await detector.status
            if case .failed = status { return status }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await detector.status
    }
}

private enum DetectorFixtureError: Error { case start, read }

private actor DetectorFixtureWatcher: ScreenshotWatching {
    private let failStart: Bool
    private let onStartSuspended: (@Sendable () -> Void)?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var callbacks: [@Sendable (ScreenshotWatchEvent) -> Void] = []
    private(set) var stopCount = 0

    init(failStart: Bool = false, onStartSuspended: (@Sendable () -> Void)? = nil) {
        self.failStart = failStart
        self.onStartSuspended = onStartSuspended
    }

    func start(in directory: URL, onEvent: @escaping @Sendable (ScreenshotWatchEvent) -> Void) async throws {
        callbacks.append(onEvent)
        if failStart { throw DetectorFixtureError.start }
        if let onStartSuspended {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
                onStartSuspended()
            }
        }
    }

    func stop() async { stopCount += 1 }

    func releaseStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func emit(_ event: ScreenshotWatchEvent, generation: Int? = nil) {
        let index = generation ?? (callbacks.count - 1)
        guard callbacks.indices.contains(index) else { return }
        callbacks[index](event)
    }
}

private struct DetectorFixtureFileSystem: ScreenshotFileSystemReading {
    private struct State: Sendable {
        var files: [URL: ScreenshotFileSnapshot]
        var contentsFailure = false
        var contentsReads = 0
        var snapshotReads = 0
        var sequences: [URL: [ScreenshotFileSnapshot]] = [:]
        var identityObserver: (@Sendable (URL) -> Void)?
    }
    private let state: OSAllocatedUnfairLock<State>

    init(_ files: [URL: ScreenshotFileSnapshot] = [:]) {
        state = OSAllocatedUnfairLock(initialState: State(files: files))
    }

    var contentsReadCount: Int { state.withLock { $0.contentsReads } }
    var snapshotReadCount: Int { state.withLock { $0.snapshotReads } }

    func set(_ snapshot: ScreenshotFileSnapshot, at url: URL) {
        state.withLock { $0.files[url] = snapshot }
    }

    func remove(_ url: URL) { state.withLock { $0.files[url] = nil } }
    func setContentsFailure(_ fails: Bool) { state.withLock { $0.contentsFailure = fails } }
    func setSnapshotSequence(_ snapshots: [ScreenshotFileSnapshot], at url: URL) {
        state.withLock { $0.sequences[url] = snapshots }
    }
    func observeIdentity(_ observer: (@Sendable (URL) -> Void)?) {
        state.withLock { $0.identityObserver = observer }
    }

    func contents(of directory: URL) throws -> [URL] {
        try state.withLock { state in
            state.contentsReads += 1
            if state.contentsFailure { throw DetectorFixtureError.read }
            return state.files.keys.filter { $0.deletingLastPathComponent() == directory }
                .sorted { $0.path < $1.path }
        }
    }

    func identity(at url: URL) throws -> ScreenshotFileIdentity? {
        let (identity, observer) = state.withLock { ($0.files[url]?.identity, $0.identityObserver) }
        observer?(url)
        return identity
    }

    func snapshot(at url: URL) throws -> ScreenshotFileSnapshot? {
        state.withLock { state in
            state.snapshotReads += 1
            if var snapshots = state.sequences[url], !snapshots.isEmpty {
                let snapshot = snapshots.removeFirst()
                state.sequences[url] = snapshots
                return snapshot
            }
            return state.files[url]
        }
    }
}

private actor DetectorFixtureClock: ScreenshotDetectionClock {
    private var elapsed: Duration = .zero
    func now() async -> Duration { elapsed }
    func sleep(for delay: Duration) async throws {
        try Task.checkCancellation()
        elapsed += delay
    }
}

private actor DetectorGateClock: ScreenshotDetectionClock {
    private let onSuspend: @Sendable () -> Void
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var elapsed: Duration = .zero

    init(onSuspend: @escaping @Sendable () -> Void) { self.onSuspend = onSuspend }
    func now() async -> Duration { elapsed }
    func sleep(for delay: Duration) async throws {
        try Task.checkCancellation()
        if !released {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
                onSuspend()
            }
        }
        try Task.checkCancellation()
        elapsed += delay
    }
    func releaseAll() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
