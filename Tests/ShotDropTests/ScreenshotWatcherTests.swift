import CoreServices
import Foundation
import XCTest
@testable import ShotDrop

final class ScreenshotWatcherTests: XCTestCase {
    func testLossFlagsRequireRescanInsteadOfTreatingPathAsFileHint() {
        let url = URL(fileURLWithPath: "/fixture/shot.png")
        for flag in [
            kFSEventStreamEventFlagMustScanSubDirs,
            kFSEventStreamEventFlagUserDropped,
            kFSEventStreamEventFlagKernelDropped,
            kFSEventStreamEventFlagEventIdsWrapped
        ] {
            XCTAssertEqual(
                ScreenshotDirectoryWatcher.events(paths: [url], flags: [FSEventStreamEventFlags(flag)]),
                [.rescanRequired]
            )
        }
    }

    func testRootChangeIsDistinctAndOrdinaryHintsArePreserved() {
        let root = URL(fileURLWithPath: "/fixture")
        let shot = root.appendingPathComponent("shot.png")
        XCTAssertEqual(
            ScreenshotDirectoryWatcher.events(
                paths: [root, shot],
                flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged),
                        FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)]
            ),
            [.rootChanged, .paths([shot])]
        )
    }

    func testRootAndDroppedFlagsAreBothReportedAndHistorySentinelIsIgnored() {
        let root = URL(fileURLWithPath: "/fixture")
        XCTAssertEqual(
            ScreenshotDirectoryWatcher.events(
                paths: [root, root],
                flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagKernelDropped),
                        FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)]
            ),
            [.rootChanged, .rescanRequired]
        )
    }

    func testWatcherReceivesCreatedFileAndRestartsAfterRepeatedStop() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotDropWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let watcher = ScreenshotDirectoryWatcher()

        for index in 0..<2 {
            let file = directory.appendingPathComponent("new-\(index).png")
            let received = expectation(description: "Event for new file \(index)")
            // FSEvents can deliver multiple modification events for a single write.
            received.assertForOverFulfill = false
            try await watcher.start(in: directory) { event in
                if case .paths(let paths) = event,
                   paths.contains(where: { $0.lastPathComponent == file.lastPathComponent }) {
                    received.fulfill()
                }
            }
            try Data([0x01]).write(to: file)
            await fulfillment(of: [received], timeout: 5)
            await watcher.stop()
            await watcher.stop()
        }
    }

    func testWatcherReleasesCallbackContextOnStop() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotDropWatcherLifetime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let released = expectation(description: "Stream releases retained callback context")
        var probe: WatcherLifetimeProbe? = WatcherLifetimeProbe { released.fulfill() }
        let watcher = ScreenshotDirectoryWatcher()
        try await watcher.start(in: directory, onEvent: retainProbe(try XCTUnwrap(probe)))
        probe = nil
        await watcher.stop()
        await fulfillment(of: [released], timeout: 2)
    }

    func testNonFileURLIsRejectedAndStopRemainsSafe() async {
        let watcher = ScreenshotDirectoryWatcher()
        do {
            try await watcher.start(in: URL(string: "https://example.invalid/screenshots")!) { _ in }
            XCTFail("Expected invalid-directory error")
        } catch {
            XCTAssertTrue(error is ScreenshotDirectoryWatcher.WatchError)
        }
        await watcher.stop()
    }
}

private final class WatcherLifetimeProbe: Sendable {
    let onDeinit: @Sendable () -> Void
    init(onDeinit: @escaping @Sendable () -> Void) { self.onDeinit = onDeinit }
    deinit { onDeinit() }
}

private func retainProbe(_ probe: WatcherLifetimeProbe) -> @Sendable (ScreenshotWatchEvent) -> Void {
    { _ in withExtendedLifetime(probe) {} }
}
