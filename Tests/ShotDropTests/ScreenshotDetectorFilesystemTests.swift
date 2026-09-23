import CoreGraphics
import Darwin
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers
import XCTest
@testable import ShotDrop

final class ScreenshotDetectorFilesystemTests: XCTestCase {
    func testRealWatcherDetectsLateMetadataOnceWithoutReplayingHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotDropPipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try makePNG()
        let historical = root.appendingPathComponent("historical.png")
        try png.write(to: historical)
        try markScreenshot(historical)
        let ordinary = root.appendingPathComponent("ordinary.png")
        let fresh = root.appendingPathComponent("fresh.png")
        let detected = expectation(description: "Late screenshot becomes ready")
        let events = OSAllocatedUnfairLock(initialState: [DetectedScreenshot]())
        let detector = ScreenshotDetector(useSpotlight: false) { event in
            events.withLock { $0.append(event) }
            detected.fulfill()
        }
        try await detector.start(in: root)
        do {
            try png.write(to: ordinary)
            try Data().write(to: fresh)
            // Reproduce a file visible before contents and xattr finish arriving.
            try await Task.sleep(for: .milliseconds(120))
            try png.write(to: fresh)
            try markScreenshot(fresh)
            await fulfillment(of: [detected], timeout: 5)
            // Extra xattr/file events must not emit the same file identity twice.
            try markScreenshot(fresh)
            try await Task.sleep(for: .milliseconds(150))
            await detector.stop()
        } catch {
            await detector.stop()
            throw error
        }
        let results = events.withLock { $0 }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.url.lastPathComponent, "fresh.png")
        XCTAssertGreaterThanOrEqual(results.first?.readinessAttempts ?? 0, 2)
        XCTAssertEqual(try Data(contentsOf: historical), png)
        XCTAssertEqual(try Data(contentsOf: ordinary), png)
        XCTAssertEqual(try Data(contentsOf: fresh), png)
        let status = await detector.status
        XCTAssertEqual(status, .idle)
    }

    private func makePNG() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func markScreenshot(_ url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        let result = data.withUnsafeBytes { buffer in
            setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", buffer.baseAddress, buffer.count, 0, 0)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
