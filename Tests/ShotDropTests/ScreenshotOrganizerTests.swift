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

    func testExhaustedCollisionBudgetPreservesSourceAndExistingFiles() async throws {
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
        XCTAssertEqual(Set(try visibleEntries(in: fixture.destination)),
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

    func testPublicationHookRegistersTokenBeforeVisibleOutputAndReturnsClonedIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let receipt = OSAllocatedUnfairLock<(token: UUID?, stageInode: UInt64?)>(initialState: (nil, nil))
        let destination = fixture.destination
        let result = try await ScreenshotOrganizer().organize(fixture.request()) { token in
            let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            XCTAssertEqual(names.count, 1)
            XCTAssertTrue(names.allSatisfy { $0.hasPrefix(".shotdrop-staging-") })
            let directory = destination.appendingPathComponent(try XCTUnwrap(names.first))
            let stages = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            XCTAssertEqual(stages.count, 1)
            let stage = try XCTUnwrap(stages.first)
            let attributes = try FileManager.default.attributesOfItem(atPath: stage.path)
            let inode = try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber).uint64Value
            receipt.withLock { $0 = (token, inode) }
        }
        XCTAssertEqual(receipt.withLock { $0.token }, result.outputToken)
        XCTAssertNotEqual(receipt.withLock { $0.stageInode }, result.destinationIdentity.inode)
        XCTAssertEqual(try LocalScreenshotFileSystem().identity(at: result.destinationURL), result.destinationIdentity)
        let snapshot = try XCTUnwrap(LocalScreenshotFileSystem().snapshot(at: result.destinationURL))
        XCTAssertEqual(snapshot.outputToken, result.outputToken)
    }

    func testCancelledPublicationHookLeavesOriginalAndNoVisibleOutput() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        do {
            _ = try await ScreenshotOrganizer().organize(fixture.request()) { _ in
                throw CancellationError()
            }
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.data)
        XCTAssertEqual(try visibleEntries(in: fixture.destination), [])
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
            let result = try await ScreenshotOrganizer().organize(request) { token in
                await detector.ignoreOutput(token: token)
            }
            let snapshot = try XCTUnwrap(LocalScreenshotFileSystem().snapshot(at: result.destinationURL))
            XCTAssertTrue(snapshot.isScreenshot)
            XCTAssertTrue(snapshot.isCompleteImage)
            XCTAssertEqual(snapshot.outputToken, result.outputToken)
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

    private func visibleEntries(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".shotdrop-staging-") }
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
