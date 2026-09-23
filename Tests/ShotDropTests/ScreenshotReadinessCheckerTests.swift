import Foundation
import os
import XCTest
@testable import ShotDrop

final class ScreenshotReadinessCheckerTests: XCTestCase {
    private let candidate = URL(fileURLWithPath: "/test/screenshot.png")

    func testRequiresTwoStableObservationsAndReportsElapsedTime() async throws {
        let ready = snapshot()
        let fileSystem = ScriptedReadinessFileSystem([.value(ready), .value(ready)])
        let clock = ReadinessTestClock()
        let checker = ScreenshotReadinessChecker(fileSystem: fileSystem, clock: clock)

        let result = try await checker.waitUntilReady(at: candidate)

        XCTAssertEqual(result?.snapshot, ready)
        XCTAssertEqual(result?.attempts, 2)
        XCTAssertEqual(result?.latency, .milliseconds(50))
        XCTAssertEqual(fileSystem.readCount, 2)
        let sleeps = await clock.sleeps
        XCTAssertEqual(sleeps, [.milliseconds(50)])
    }

    func testWaitsForLateScreenshotMetadata() async throws {
        let ready = snapshot()
        let result = try await check([
            .value(snapshot(isScreenshot: false)), .value(ready), .value(ready)
        ])

        XCTAssertEqual(result?.attempts, 3)
        XCTAssertEqual(result?.snapshot, ready)
    }

    func testWaitsForCompleteImageAndNonzeroSize() async throws {
        let ready = snapshot()
        let result = try await check([
            .value(snapshot(size: 0)), .value(snapshot(isCompleteImage: false)),
            .value(ready), .value(ready)
        ])

        XCTAssertEqual(result?.attempts, 4)
    }

    func testChangingSizeRestartsStability() async throws {
        let larger = snapshot(size: 200)
        let result = try await check([.value(snapshot()), .value(larger), .value(larger)])

        XCTAssertEqual(result?.attempts, 3)
        XCTAssertEqual(result?.snapshot.size, 200)
    }

    func testChangingModificationTimeRestartsStability() async throws {
        let changed = snapshot(modified: 2)
        let result = try await check([.value(snapshot()), .value(changed), .value(changed)])

        XCTAssertEqual(result?.attempts, 3)
    }

    func testIdentityReplacementIsNotMistakenForStability() async throws {
        let replacement = snapshot(inode: 2)
        let result = try await check([
            .value(snapshot()), .value(replacement), .value(replacement)
        ])

        XCTAssertEqual(result?.attempts, 3)
        XCTAssertEqual(result?.snapshot.identity, replacement.identity)
    }

    func testMissingFileBreaksConsecutiveObservations() async throws {
        let ready = snapshot()
        let result = try await check([
            .value(ready), .value(nil), .value(ready), .value(ready)
        ])

        XCTAssertEqual(result?.attempts, 4)
    }

    func testTransientReadErrorBreaksConsecutiveObservations() async throws {
        let ready = snapshot()
        let result = try await check([
            .value(ready), .failure, .value(ready), .value(ready)
        ])

        XCTAssertEqual(result?.attempts, 4)
    }

    func testIncompleteImageBreaksConsecutiveObservations() async throws {
        let ready = snapshot()
        let result = try await check([
            .value(ready), .value(snapshot(isCompleteImage: false)),
            .value(ready), .value(ready)
        ])

        XCTAssertEqual(result?.attempts, 4)
    }

    func testExhaustionHasExactlyOneReadPerAttemptAndNoExtraSleep() async throws {
        let fileSystem = ScriptedReadinessFileSystem([.value(nil)])
        let clock = ReadinessTestClock()
        let delays: [Duration] = [.milliseconds(10), .milliseconds(20)]
        let checker = ScreenshotReadinessChecker(
            fileSystem: fileSystem, clock: clock, retryDelays: delays
        )

        let result = try await checker.waitUntilReady(at: candidate)

        XCTAssertNil(result)
        XCTAssertEqual(fileSystem.readCount, 3)
        let sleeps = await clock.sleeps
        XCTAssertEqual(sleeps, delays)
    }

    func testNoRetriesCannotAcceptSingleReadyObservation() async throws {
        let fileSystem = ScriptedReadinessFileSystem([.value(snapshot())])
        let clock = ReadinessTestClock()
        let checker = ScreenshotReadinessChecker(
            fileSystem: fileSystem, clock: clock, retryDelays: []
        )

        let result = try await checker.waitUntilReady(at: candidate)

        XCTAssertNil(result)
        XCTAssertEqual(fileSystem.readCount, 1)
        let sleeps = await clock.sleeps
        XCTAssertTrue(sleeps.isEmpty)
    }

    func testSleepCancellationPropagatesBeforeAnotherRead() async throws {
        let fileSystem = ScriptedReadinessFileSystem([.value(snapshot())])
        let clock = ReadinessTestClock(cancelOnSleep: true)
        let checker = ScreenshotReadinessChecker(fileSystem: fileSystem, clock: clock)

        do {
            _ = try await checker.waitUntilReady(at: candidate)
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {
            XCTAssertEqual(fileSystem.readCount, 1)
        }
    }

    func testFileSystemCancellationDoesNotBecomeRetry() async throws {
        let fileSystem = ScriptedReadinessFileSystem([.cancellation])
        let clock = ReadinessTestClock()
        let checker = ScreenshotReadinessChecker(fileSystem: fileSystem, clock: clock)

        do {
            _ = try await checker.waitUntilReady(at: candidate)
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {
            XCTAssertEqual(fileSystem.readCount, 1)
            let sleeps = await clock.sleeps
            XCTAssertTrue(sleeps.isEmpty)
        }
    }

    func testAlreadyCancelledTaskDoesNotReadFile() async throws {
        let fileSystem = ScriptedReadinessFileSystem([.value(snapshot())])
        let checker = ScreenshotReadinessChecker(
            fileSystem: fileSystem, clock: ReadinessTestClock()
        )
        let url = candidate
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await checker.waitUntilReady(at: url)
        }

        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {
            XCTAssertEqual(fileSystem.readCount, 0)
        }
    }

    private func check(
        _ steps: [ScriptedReadinessFileSystem.Step]
    ) async throws -> ScreenshotReadinessResult? {
        let checker = ScreenshotReadinessChecker(
            fileSystem: ScriptedReadinessFileSystem(steps), clock: ReadinessTestClock()
        )
        return try await checker.waitUntilReady(at: candidate)
    }

    private func snapshot(
        inode: UInt64 = 1,
        size: Int64 = 100,
        modified: Int64 = 1,
        isScreenshot: Bool = true,
        isCompleteImage: Bool = true
    ) -> ScreenshotFileSnapshot {
        ScreenshotFileSnapshot(
            identity: ScreenshotFileIdentity(device: 1, inode: inode, birthNanoseconds: 1),
            size: size,
            modifiedNanoseconds: modified,
            isScreenshot: isScreenshot,
            isCompleteImage: isCompleteImage
        )
    }
}

private struct ScriptedReadinessFileSystem: ScreenshotFileSystemReading {
    enum Step: Sendable {
        case value(ScreenshotFileSnapshot?)
        case failure
        case cancellation
    }

    private struct State: Sendable {
        let steps: [Step]
        var readCount = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ steps: [Step]) {
        precondition(!steps.isEmpty)
        state = OSAllocatedUnfairLock(initialState: State(steps: steps))
    }

    var readCount: Int { state.withLock { $0.readCount } }

    func contents(of url: URL) throws -> [URL] { [] }

    func snapshot(at url: URL) throws -> ScreenshotFileSnapshot? {
        let step = state.withLock { state in
            let step = state.steps[min(state.readCount, state.steps.count - 1)]
            state.readCount += 1
            return step
        }
        switch step {
        case .value(let snapshot): return snapshot
        case .failure: throw CocoaError(.fileReadUnknown)
        case .cancellation: throw CancellationError()
        }
    }
}

private actor ReadinessTestClock: ScreenshotDetectionClock {
    private var elapsed: Duration = .zero
    private let cancelOnSleep: Bool
    private(set) var sleeps: [Duration] = []

    init(cancelOnSleep: Bool = false) {
        self.cancelOnSleep = cancelOnSleep
    }

    func now() async -> Duration { elapsed }

    func sleep(for delay: Duration) async throws {
        sleeps.append(delay)
        if cancelOnSleep { throw CancellationError() }
        elapsed += delay
    }
}
