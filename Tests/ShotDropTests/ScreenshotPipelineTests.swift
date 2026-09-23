import AppKit
import Foundation
import XCTest
@testable import ShotDrop

@MainActor
final class ScreenshotPipelineTests: XCTestCase {
    func testExplanationAndDeniedAccessNeverStartDetector() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        let harness = try PipelineHarness(fixture)
        let denied = harness.make(authorize: { throw PipelineTestFailure.denied })
        do { try await denied.start(sourceAccessExplained: false); XCTFail("Explanation required") }
        catch ScreenshotPipelineFailure.accessExplanationRequired {}
        do { try await denied.start(sourceAccessExplained: true); XCTFail("Access denial must propagate") }
        catch PipelineTestFailure.denied {}
        let starts = await harness.detector.startCount
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(harness.writer.writes, 0)
    }

    func testSuccessfulSaveCopyAndDuplicateSuppression() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        let h = try PipelineHarness(fixture)
        let done = expectation(description: "One outcome")
        let pipeline = h.make(completion: { _ in done.fulfill() })
        try await pipeline.start(sourceAccessExplained: true)
        let event = h.event(sequence: 1)
        await h.detector.emit(event)
        await h.detector.emit(event)
        await fulfillment(of: [done], timeout: 3)
        await pipeline.finishPendingWork()
        XCTAssertEqual(h.outcomes.count, 1)
        guard case .saved = h.outcomes[0].save, case .copied = h.outcomes[0].copy else {
            return XCTFail("Both operations must succeed")
        }
        let saves = await h.saves.count
        let tokens = await h.detector.tokens.count
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(tokens, 1)
        XCTAssertEqual(h.writer.writes, 1)
        XCTAssertEqual(Set(h.writer.items[0].types), Set([.png, .fileURL]))
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.png)
        await pipeline.stop()
    }

    func testOlderReadinessAfterNewerPublicationStillSavesWithoutCopying() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        let h = try PipelineHarness(fixture)
        let newer = expectation(description: "Newer completed")
        let older = expectation(description: "Older completed")
        let pipeline = h.make(completion: { outcome in
            if outcome.observationSequence == 2 { newer.fulfill() } else { older.fulfill() }
        })
        try await pipeline.start(sourceAccessExplained: true)
        await h.detector.emit(h.event(sequence: 2, alternate: true))
        await fulfillment(of: [newer], timeout: 3)
        await h.detector.emit(h.event(sequence: 1))
        await fulfillment(of: [older], timeout: 3)
        XCTAssertEqual(h.writer.writes, 1)
        guard case .superseded = h.outcomes.last?.copy else { return XCTFail("Older result must be superseded") }
        let count = await h.saves.count
        XCTAssertEqual(count, 2)
        await pipeline.stop()
    }

    func testOlderPreparationCannotReplaceNewerPublication() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        let h = try PipelineHarness(fixture)
        let gate = PipelineTestGate()
        let newer = expectation(description: "Newer copied while older preparation held")
        let older = expectation(description: "Older finishes superseded")
        let prepareCount = PipelineTestCounter()
        let pipeline = h.make(prepare: { request in
            let index = await prepareCount.increment()
            if index == 1 { await gate.suspend() }
            return try await ScreenshotClipboardPreparer().prepare(request)
        }, completion: { outcome in
            if outcome.observationSequence == 2 { newer.fulfill() } else { older.fulfill() }
        })
        try await pipeline.start(sourceAccessExplained: true)
        await h.detector.emit(h.event(sequence: 1))
        await gate.waitUntilEntered()
        await h.detector.emit(h.event(sequence: 2, alternate: true))
        await fulfillment(of: [newer], timeout: 3)
        await gate.release()
        await fulfillment(of: [older], timeout: 3)
        XCTAssertEqual(h.writer.writes, 1)
        guard case .superseded = h.outcomes.last?.copy else { return XCTFail("Slow old preparation cannot publish") }
        let count = await h.saves.count
        XCTAssertEqual(count, 2)
        await pipeline.stop()
    }

    func testManualCopyAndExternalOwnershipEachSupersedeHeldPreparation() async throws {
        for manual in [true, false] {
            let fixture = try ClipboardTestFixture()
            defer { fixture.cleanUp() }
            let h = try PipelineHarness(fixture)
            let gate = PipelineTestGate()
            let done = expectation(description: "Held job ends")
            let pipeline = h.make(prepare: { request in
                await gate.suspend()
                return try await ScreenshotClipboardPreparer().prepare(request)
            }, completion: { _ in done.fulfill() })
            try await pipeline.start(sourceAccessExplained: true)
            await h.detector.emit(h.event(sequence: 1))
            await gate.waitUntilEntered()
            if manual {
                pipeline.manualCopyWillBegin()
                h.writer.changeCount += 1
                pipeline.manualCopyDidFinish()
            } else { h.writer.changeCount += 1 }
            await gate.release()
            await fulfillment(of: [done], timeout: 3)
            XCTAssertEqual(h.writer.writes, 0)
            XCTAssertEqual(h.writer.preparations, 0)
            guard case .saved = h.outcomes[0].save, case .superseded = h.outcomes[0].copy else {
                return XCTFail("Saving survives clipboard supersession")
            }
            await pipeline.stop()
        }
    }

    func testStopDrainsLatePreparationAndRestartRejectsOldDetectorCallback() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        let h = try PipelineHarness(fixture)
        let gate = PipelineTestGate()
        let calls = PipelineTestCounter()
        let done = expectation(description: "New generation reports separately")
        let pipeline = h.make(prepare: { request in
            if await calls.increment() == 1 { await gate.suspend() }
            return try await ScreenshotClipboardPreparer().prepare(request)
        }, completion: { outcome in
            if outcome.sourceURL == fixture.saved { done.fulfill() }
        })
        try await pipeline.start(sourceAccessExplained: true)
        await h.detector.emit(h.event(sequence: 1))
        await gate.waitUntilEntered()
        let stopping = Task { await pipeline.stop() }
        await h.detector.waitUntilStopped()
        XCTAssertEqual(pipeline.state, .stopping)
        await gate.release()
        await stopping.value
        XCTAssertEqual(h.outcomes.count, 1)
        guard case .saved = h.outcomes[0].save, case .cancelled = h.outcomes[0].copy else {
            return XCTFail("Stopping retains an already verified save receipt with cancelled copy")
        }
        let oldSession = h.outcomes[0].sessionID
        XCTAssertEqual(h.writer.writes, 0)
        try await pipeline.start(sourceAccessExplained: true)
        await h.detector.emit(h.event(sequence: 9), generation: 0)
        await h.detector.emit(h.event(sequence: 1, alternate: true))
        await fulfillment(of: [done], timeout: 3)
        await pipeline.finishPendingWork()
        XCTAssertEqual(h.outcomes.count, 2)
        XCTAssertEqual(h.outcomes[1].sourceURL, fixture.saved)
        XCTAssertNotEqual(h.outcomes[1].sessionID, oldSession)
        XCTAssertEqual(h.writer.writes, 1)
        await pipeline.stop()
    }

    func testStopDrainsSuspendedAuthorizationAndDetectorStartupBeforeRestart() async throws {
        for holdAuthorization in [true, false] {
            let fixture = try ClipboardTestFixture()
            defer { fixture.cleanUp() }
            let h = try PipelineHarness(fixture)
            let startupGate = PipelineTestGate()
            let pipeline = h.make(authorize: {
                if holdAuthorization { await startupGate.suspend() }
            }, beforeStart: {
                if !holdAuthorization { await startupGate.suspend() }
            })
            let starting = Task { try await pipeline.start(sourceAccessExplained: true) }
            await startupGate.waitUntilEntered()
            let stopEntered = expectation(description: "Stop begins while startup is held")
            var stopReturned = false
            let stopping = Task {
                stopEntered.fulfill()
                await pipeline.stop()
                stopReturned = true
            }
            await fulfillment(of: [stopEntered], timeout: 3)
            XCTAssertEqual(pipeline.state, .stopping)
            XCTAssertFalse(stopReturned)
            let stopsBeforeRelease = await h.detector.stopCount
            XCTAssertEqual(stopsBeforeRelease, 0, "Stop must follow actual startup completion")
            do {
                try await pipeline.start(sourceAccessExplained: true)
                XCTFail("Old startup must drain before restart")
            } catch ScreenshotPipelineFailure.busy {}
            await startupGate.release()
            do { try await starting.value; XCTFail("Stopped startup cannot report success") }
            catch is CancellationError {}
            await stopping.value
            XCTAssertTrue(stopReturned)
            XCTAssertEqual(pipeline.state, .stopped)
            let starts = await h.detector.startCount
            let stops = await h.detector.stopCount
            XCTAssertEqual(starts, holdAuthorization ? 0 : 1)
            XCTAssertEqual(stops, 1)
            try await pipeline.start(sourceAccessExplained: true)
            XCTAssertEqual(pipeline.state, .running)
            await pipeline.stop()
        }
    }

    func testOverlappingStopAndSourceFailureBlockRestartUntilDetectorDrainCompletes() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        let h = try PipelineHarness(fixture)
        let detectorDrain = PipelineTestGate()
        let pipeline = h.make(beforeStop: { await detectorDrain.suspend() })
        try await pipeline.start(sourceAccessExplained: true)
        var normalStopReturned = false
        var failureReturned = false
        let stopping = Task { await pipeline.stop(); normalStopReturned = true }
        await detectorDrain.waitUntilEntered()
        let failureEntered = expectation(description: "Overlapping source failure joins stop")
        let failure = Task {
            failureEntered.fulfill()
            await pipeline.sourceBecameUnavailable("Fixture source disappeared")
            failureReturned = true
        }
        await fulfillment(of: [failureEntered], timeout: 3)
        XCTAssertEqual(pipeline.state, .stopping)
        XCTAssertFalse(normalStopReturned)
        XCTAssertFalse(failureReturned)
        do {
            try await pipeline.start(sourceAccessExplained: true)
            XCTFail("Restart must not overlap the old detector drain")
        } catch ScreenshotPipelineFailure.busy {}
        let before = await h.detector.startCount
        XCTAssertEqual(before, 1)
        await detectorDrain.release()
        await stopping.value
        await failure.value
        XCTAssertTrue(normalStopReturned)
        XCTAssertTrue(failureReturned)
        XCTAssertEqual(pipeline.state, .failed("Fixture source disappeared"))
        let stops = await h.detector.stopCount
        XCTAssertEqual(stops, 1, "Concurrent stop callers share one drain")
        try await pipeline.start(sourceAccessExplained: true)
        XCTAssertEqual(pipeline.state, .running)
        let after = await h.detector.startCount
        XCTAssertEqual(after, 2)
        await pipeline.stop()
    }

    func testSaveFailureCopiesOnlyWithExplicitSurvivingOriginalFallback() async throws {
        for allowFallback in [false, true] {
            let fixture = try ClipboardTestFixture()
            defer { fixture.cleanUp() }
            let h = try PipelineHarness(fixture)
            let done = expectation(description: "Save failure reported")
            let pipeline = h.make(failSave: true, fallback: allowFallback, completion: { _ in done.fulfill() })
            try await pipeline.start(sourceAccessExplained: true)
            await h.detector.emit(h.event(sequence: 1))
            await fulfillment(of: [done], timeout: 3)
            guard case .failed = h.outcomes[0].save else { return XCTFail("Save must remain failed") }
            if allowFallback {
                guard case .copied = h.outcomes[0].copy else { return XCTFail("Explicit fallback should copy original") }
                XCTAssertEqual(h.writer.items[0].string(forType: .fileURL), fixture.source.absoluteString)
            } else {
                guard case .notAttempted = h.outcomes[0].copy else { return XCTFail("No implicit fallback") }
            }
            XCTAssertEqual(h.writer.writes, allowFallback ? 1 : 0)
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.png)
            await pipeline.stop()
        }
    }

    func testClipboardWriteFailureRetainsSuccessfulSaveReceipt() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        let h = try PipelineHarness(fixture)
        h.writer.failWrite = true
        let done = expectation(description: "Partial failure")
        let pipeline = h.make(completion: { _ in done.fulfill() })
        try await pipeline.start(sourceAccessExplained: true)
        await h.detector.emit(h.event(sequence: 1))
        await fulfillment(of: [done], timeout: 3)
        guard case .saved(let receipt) = h.outcomes[0].save,
              case .failed = h.outcomes[0].copy else { return XCTFail("Save and copy remain independent") }
        XCTAssertEqual(receipt.destinationURL, fixture.saved)
        XCTAssertEqual(try Data(contentsOf: fixture.saved), fixture.png)
        XCTAssertEqual(h.writer.preparations, 1)
        await pipeline.stop()
    }
}

private enum PipelineTestFailure: Error { case denied }

@MainActor
private final class PipelineHarness {
    let fixture: ClipboardTestFixture
    let writer = PipelineTestWriter()
    let detector = PipelineTestDetector()
    let saves = PipelineTestCounter()
    let sourceIdentity: ScreenshotFileIdentity
    let savedIdentity: ScreenshotFileIdentity
    var outcomes: [ScreenshotPipelineOutcome] = []

    init(_ fixture: ClipboardTestFixture) throws {
        self.fixture = fixture
        sourceIdentity = try XCTUnwrap(LocalScreenshotFileSystem().identity(at: fixture.source))
        savedIdentity = try XCTUnwrap(LocalScreenshotFileSystem().identity(at: fixture.saved))
    }
    func event(sequence: UInt64, alternate: Bool = false) -> DetectedScreenshot {
        .init(url: alternate ? fixture.saved : fixture.source,
              identity: alternate ? savedIdentity : sourceIdentity,
              readinessLatency: .zero, candidateToReadyLatency: .zero, readinessAttempts: 1,
              observationSequence: sequence, observedAt: Date(timeIntervalSince1970: 100))
    }
    func make(authorize: @escaping @Sendable () async throws -> Void = {},
              prepare: @escaping ScreenshotPipeline.Prepare = { try await ScreenshotClipboardPreparer().prepare($0) },
              failSave: Bool = false, fallback: Bool = false,
              beforeStart: @escaping @Sendable () async -> Void = {},
              beforeStop: @escaping @Sendable () async -> Void = {},
              completion: @escaping (ScreenshotPipelineOutcome) -> Void = { _ in }) -> ScreenshotPipeline {
        let detector = detector, fixture = fixture, saves = saves, savedIdentity = savedIdentity
        return ScreenshotPipeline(writer: writer, mode: .both, authorizeSource: authorize,
            startDetector: { await beforeStart(); await detector.start($0) }, stopDetector: { await beforeStop(); await detector.stop() },
            registerOutput: { await detector.register($0) }, request: { event in
                .init(organization: .init(sourceURL: event.url, destinationRoot: fixture.root,
                    template: "{app}", namingContext: .init(appName: "Fixture", capturedAt: event.observedAt,
                    timeZone: TimeZone(secondsFromGMT: 0)!), expectedIdentity: event.identity),
                    sourceDirectoryURL: fixture.root, destinationAccess: .userApproved)
            }, save: { request, beforePublishing in
                _ = await saves.increment()
                if failSave {
                    return .failed(.init(reason: .stagingPaused, detail: "Fixture refusal",
                        originalURL: request.organization.sourceURL, originalStatus: .available,
                        recoverableDestination: nil))
                }
                let token = UUID()
                do { try await beforePublishing(token) }
                catch { return .cancelled(originalURL: request.organization.sourceURL) }
                return .saved(.init(sourceURL: request.organization.sourceURL, destinationURL: fixture.saved,
                    destinationIdentity: savedIdentity, outputToken: token))
            }, prepare: prepare, allowSurvivingOriginalFallback: fallback,
            onOutcome: { [weak self] value in self?.outcomes.append(value); completion(value) })
    }
}

@MainActor
private final class PipelineTestWriter: ScreenshotPasteboardWriting {
    var changeCount = 0
    var failWrite = false
    var writes = 0
    var preparations = 0
    var items: [NSPasteboardItem] = []
    func makeItem() -> NSPasteboardItem { NSPasteboardItem() }
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType, on item: NSPasteboardItem) -> Bool {
        item.setData(data, forType: type)
    }
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType, on item: NSPasteboardItem) -> Bool {
        item.setString(string, forType: type)
    }
    func prepareForNewContents() { preparations += 1; changeCount += 1 }
    func write(_ item: NSPasteboardItem) -> Bool {
        writes += 1
        guard !failWrite else { return false }
        items.append(item)
        return true
    }
}

private actor PipelineTestCounter {
    private(set) var count = 0
    func increment() -> Int { count += 1; return count }
}

private actor PipelineTestGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var held: CheckedContinuation<Void, Never>?
    func suspend() async {
        entered = true
        entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        if !released { await withCheckedContinuation { held = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func release() { released = true; held?.resume(); held = nil }
}

private actor PipelineTestDetector {
    private var callbacks: [@Sendable (DetectedScreenshot) -> Void] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var tokens: [UUID] = []
    private var stopped = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    func start(_ callback: @escaping @Sendable (DetectedScreenshot) -> Void) {
        startCount += 1; callbacks.append(callback); stopped = false
    }
    func emit(_ event: DetectedScreenshot, generation: Int? = nil) {
        callbacks[generation ?? (callbacks.count - 1)](event)
    }
    func register(_ token: UUID) { tokens.append(token) }
    func stop() { stopCount += 1; stopped = true; stopWaiters.forEach { $0.resume() }; stopWaiters.removeAll() }
    func waitUntilStopped() async {
        if !stopped { await withCheckedContinuation { stopWaiters.append($0) } }
    }
}
