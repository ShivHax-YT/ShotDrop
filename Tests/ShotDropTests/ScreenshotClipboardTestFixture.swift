import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShotDrop

struct ClipboardTestFixture: Sendable {
    let root: URL
    let source: URL
    let saved: URL
    let png: Data

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ShotDrop-Clipboard-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("original.png")
        saved = root.appendingPathComponent("saved screenshot.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        png = try Self.imageData(type: .png)
        try png.write(to: source)
        try png.write(to: saved)
    }

    func request(_ mode: CopyMode) -> ScreenshotClipboardRequest {
        ScreenshotClipboardRequest(sourceURL: source, mode: mode, survivingFileURL: saved)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    static func imageData(type: UTType) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                                             bytesPerRow: 16 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
