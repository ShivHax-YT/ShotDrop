import CoreGraphics
import Darwin
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers
import XCTest
@testable import ShotDrop

final class ScreenshotOrganizerTests: XCTestCase {
    func testOrganizesWithDateFoldersAndPreservesOriginal() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var request = fixture.request(template: "{app}-{date}-{time}")
        request.organizeByDate = true
        request.expectedIdentity = try LocalScreenshotFileSystem().identity(at: fixture.source)
        let result = try await ScreenshotOrganizer().organize(request)
        XCTAssertEqual(result.destinationURL.path, fixture.destination.path + "/2026/09/Notes-2026-09-22-12-00-00.png")
        XCTAssertFalse(result.sourceWasRemoved)
        XCTAssertEqual(try Data(contentsOf: result.destinationURL), fixture.data)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.data)
        XCTAssertEqual(try LocalScreenshotFileSystem().identity(at: result.destinationURL), result.destinationIdentity)
    }

    func testCollisionSuffixesNeverOverwriteExistingFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        for name in ["capture.png", "capture (2).png", "capture (3).png"] {
            try Data(name.utf8).write(to: fixture.destination.appendingPathComponent(name))
        }
        let result = try await ScreenshotOrganizer().organize(fixture.request())
        XCTAssertEqual(result.destinationURL.lastPathComponent, "capture (4).png")
        for name in ["capture.png", "capture (2).png", "capture (3).png"] {
            XCTAssertEqual(try Data(contentsOf: fixture.destination.appendingPathComponent(name)), Data(name.utf8))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.data)
    }

    func testExhaustedCollisionBudgetPreservesSourceAndRemovesOnlyStage() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        for name in ["capture.png", "capture (2).png"] {
            try Data(name.utf8).write(to: fixture.destination.appendingPathComponent(name))
        }
        do {
            _ = try await ScreenshotOrganizer(collisionLimit: 2).organize(fixture.request())
            XCTFail("Expected collision exhaustion")
        } catch let failure as ScreenshotCopyFailure {
            XCTAssertEqual(failure.code, .collision)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.data)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path)),
                       ["capture.png", "capture (2).png"])
    }

    func testInvalidTemplateDoesNotStartFilesystemWork() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        do {
            _ = try await ScreenshotOrganizer().organize(fixture.request(template: "{unknown}"))
            XCTFail("Expected template failure")
        } catch is ScreenshotNamingError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.data)
    }

    func testPublicationHookRunsBeforeVisibleOutputAndGetsFinalIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let receipt = OSAllocatedUnfairLock<ScreenshotFileIdentity?>(initialState: nil)
        let destination = fixture.destination
        let result = try await ScreenshotOrganizer().organize(fixture.request()) { identity in
            receipt.withLock { $0 = identity }
            let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            XCTAssertTrue(names.allSatisfy { $0.hasPrefix(".") })
        }
        XCTAssertEqual(receipt.withLock { $0 }, result.destinationIdentity)
    }

    func testCancelledPublicationHookCleansStageAndLeavesOriginal() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        do {
            _ = try await ScreenshotOrganizer().organize(fixture.request()) { _ in
                throw CancellationError()
            }
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
    }

    func testAlreadyCancelledOperationDoesNotCreateDestination() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let request = fixture.request()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ScreenshotOrganizer().organize(request)
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.data)
    }

    func testSourceFolderDestinationDoesNotFeedOwnCopyBackIntoDetector() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try markScreenshot(fixture.source)
        let unexpected = expectation(description: "Own organized output is never recaptured")
        unexpected.isInverted = true
        let detector = ScreenshotDetector(useSpotlight: false) { _ in unexpected.fulfill() }
        try await detector.start(in: fixture.root)
        let base = fixture.request()
        let request = ScreenshotOrganizationRequest(
            sourceURL: base.sourceURL, destinationRoot: fixture.root, template: base.template,
            namingContext: base.namingContext
        )
        do {
            let result = try await ScreenshotOrganizer().organize(request) { identity in
                await detector.ignoreOutput(identity)
            }
            let snapshot = try XCTUnwrap(LocalScreenshotFileSystem().snapshot(at: result.destinationURL))
            XCTAssertTrue(snapshot.isScreenshot)
            XCTAssertTrue(snapshot.isCompleteImage)
            await fulfillment(of: [unexpected], timeout: 0.4)
            await detector.stop()
            XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.data)
        } catch {
            await detector.stop()
            throw error
        }
    }

    private func markScreenshot(_ url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        let result = data.withUnsafeBytes {
            setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, $0.count, 0, 0)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

private struct Fixture {
    let root: URL
    let source: URL
    let destination: URL
    let data: Data

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotDropOrganizer-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("source.png")
        destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let buffer = NSMutableData()
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw CocoaError(.fileWriteUnknown) }
        data = buffer as Data
        try data.write(to: source)
    }

    func request(template: String = "capture") -> ScreenshotOrganizationRequest {
        ScreenshotOrganizationRequest(
            sourceURL: source, destinationRoot: destination, template: template,
            namingContext: ScreenshotNamingContext(
                appName: "Notes", capturedAt: Date(timeIntervalSince1970: 1_790_078_400),
                timeZone: TimeZone(secondsFromGMT: 0)!
            )
        )
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
