import Foundation

protocol ScreenshotDetectionClock: Sendable {
    func now() async -> Duration
    func sleep(for delay: Duration) async throws
}

struct ContinuousScreenshotDetectionClock: ScreenshotDetectionClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    init() {
        origin = clock.now
    }

    func now() async -> Duration {
        origin.duration(to: clock.now)
    }

    func sleep(for delay: Duration) async throws {
        try await clock.sleep(for: delay)
    }
}

struct ScreenshotReadinessResult: Sendable {
    let snapshot: ScreenshotFileSnapshot
    let latency: Duration
    let attempts: Int
}

/// Samples a candidate without moving, removing, or modifying the source file.
/// The first sample is immediate; each remaining sample follows one bounded delay.
struct ScreenshotReadinessChecker: Sendable {
    static let defaultRetryDelays: [Duration] = [
        .milliseconds(50), .milliseconds(100), .milliseconds(200),
        .milliseconds(350), .milliseconds(500), .milliseconds(750),
        .seconds(1), .seconds(1), .seconds(1)
    ]
    private let fileSystem: any ScreenshotFileSystemReading
    private let clock: any ScreenshotDetectionClock
    private let retryDelays: [Duration]

    init(
        fileSystem: any ScreenshotFileSystemReading = LocalScreenshotFileSystem(),
        clock: any ScreenshotDetectionClock = ContinuousScreenshotDetectionClock(),
        retryDelays: [Duration] = Self.defaultRetryDelays
    ) {
        self.fileSystem = fileSystem
        self.clock = clock
        // Invalid injected delays cannot accidentally turn retries into a busy loop.
        self.retryDelays = retryDelays.map { max($0, .milliseconds(1)) }
    }

    func waitUntilReady(at url: URL) async throws -> ScreenshotReadinessResult? {
        try Task.checkCancellation()
        let start = await clock.now()
        var previous: ScreenshotFileSnapshot?

        for attempt in 0...retryDelays.count {
            try Task.checkCancellation()
            if attempt > 0 {
                try await clock.sleep(for: retryDelays[attempt - 1])
                try Task.checkCancellation()
            }

            let current: ScreenshotFileSnapshot?
            do {
                current = try fileSystem.snapshot(at: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // File creation, metadata writes, and image finalization can race.
                // A failure breaks the consecutive-observation requirement.
                previous = nil
                try Task.checkCancellation()
                continue
            }
            try Task.checkCancellation()

            guard let current, current.size > 0,
                  current.isScreenshot, current.isCompleteImage else {
                previous = nil
                continue
            }

            if let previous,
               previous.identity == current.identity,
               previous.size == current.size,
               previous.modifiedNanoseconds == current.modifiedNanoseconds {
                let end = await clock.now()
                try Task.checkCancellation()
                return ScreenshotReadinessResult(
                    snapshot: current,
                    latency: max(.zero, end - start),
                    attempts: attempt + 1
                )
            }
            previous = current
        }

        return nil
    }
}
