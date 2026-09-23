import CoreText
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShotDrop

final class ScreenshotTextRecognitionTests: XCTestCase {
    func testLineAssemblyPreservesUnicodeNewlinesAndBoundsWithoutLayoutClaims() throws {
        var text = ""
        for line in ["Café", "日本語", "مرحبا", "left column", "right column", " \t"] {
            try ScreenshotTextLimits.append(line, to: &text)
        }
        XCTAssertEqual(text, "Café\n日本語\nمرحبا\nleft column\nright column")
        var full = String(repeating: "x", count: ScreenshotTextLimits.outputBytes)
        XCTAssertThrowsError(try ScreenshotTextLimits.append("a", to: &full)) {
            XCTAssertEqual($0 as? ScreenshotTextFailure, .outputTooLarge)
        }
        XCTAssertEqual(full.utf8.count, ScreenshotTextLimits.outputBytes)
    }

    func testCorruptEncodedOversizeAndOversizeDimensionsRejectBeforeDecode() throws {
        XCTAssertThrowsError(try ScreenshotTextImage(data: Data("not an image".utf8)))
        XCTAssertThrowsError(try ScreenshotTextImage(data: Data(count: ScreenshotTextLimits.encodedBytes + 1))) {
            XCTAssertEqual($0 as? ScreenshotTextFailure, .inputTooLarge)
        }
        var png = try ClipboardTestFixture.imageData(type: .png)
        // Change only PNG IHDR dimensions and its CRC; compressed pixels stay tiny.
        png.replaceSubrange(16..<24, with: [0, 0, 0x1F, 0x41, 0, 0, 0x0F, 0xA0]) // 8001 x 4000
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in png[12..<29] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        crc ^= 0xFFFF_FFFF
        png.replaceSubrange(29..<33, with: [UInt8(crc >> 24), UInt8((crc >> 16) & 255), UInt8((crc >> 8) & 255), UInt8(crc & 255)])
        XCTAssertThrowsError(try ScreenshotTextImage(data: png)) {
            XCTAssertEqual($0 as? ScreenshotTextFailure, .inputTooLarge)
        }
    }

    func testOneFrameAndOrientationAreValidatedBeforeVision() throws {
        let image = try ScreenshotTextImage(data: ClipboardTestFixture.imageData(type: .png)).image
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertThrowsError(try ScreenshotTextImage(data: data as Data)) {
            XCTAssertEqual($0 as? ScreenshotTextFailure, .multipleFrames)
        }
        for raw in UInt32(1)...8 {
            let rotated = try encoded(image, orientation: raw)
            let input = try ScreenshotTextImage(data: rotated)
            XCTAssertEqual(input.orientation.rawValue, raw)
            XCTAssertEqual(input.image.width, image.width)
            XCTAssertEqual(input.image.height, image.height)
        }
    }

    func testLocalRecognizerRejectsSourceCorruptMissingAndReplacedFiles() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let url = textFixtureURL(fixture.saved)
        let service = LocalScreenshotTextRecognizer()
        let source = try RecentFileReference.capture(at: url, role: .source)
        do { _ = try await service.recognize(source); XCTFail("Source reference admitted") }
        catch { XCTAssertEqual(error as? ScreenshotTextFailure, .fileUnavailable) }
        try Data("corrupt fixture".utf8).write(to: url)
        let corrupt = try RecentFileReference.capture(at: url, role: .savedCopy)
        do { _ = try await service.recognize(corrupt); XCTFail("Corrupt image admitted") }
        catch { XCTAssertEqual(error as? ScreenshotTextFailure, .invalidImage) }
        try fixture.png.write(to: url)
        do { try await service.revalidate(corrupt); XCTFail("Replacement admitted") }
        catch { XCTAssertEqual(error as? ScreenshotTextFailure, .fileUnavailable) }
        let current = try RecentFileReference.capture(at: url, role: .savedCopy)
        try FileManager.default.removeItem(at: url)
        do { _ = try await service.recognize(current); XCTFail("Missing file admitted") }
        catch { XCTAssertEqual(error as? ScreenshotTextFailure, .fileUnavailable) }
    }

    func testLocalVisionReadsSyntheticFullResolutionTextAndBlank() async throws {
        let fixture = try ClipboardTestFixture(); defer { fixture.cleanUp() }
        let url = textFixtureURL(fixture.saved)
        let context = try XCTUnwrap(CGContext(data: nil, width: 900, height: 240, bitsPerComponent: 8,
            bytesPerRow: 900 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 900, height: 240))
        let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]
        for (index, line) in ["SHOTDROP LOCAL TEST", "Second line 123"].enumerated() {
            context.textPosition = CGPoint(x: 25, y: 155 - index * 80)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes)), context)
        }
        let image = try XCTUnwrap(context.makeImage())
        try encoded(image).write(to: url)
        let reference = try RecentFileReference.capture(at: url, role: .savedCopy)
        let start = ContinuousClock.now
        let output = try await LocalScreenshotTextRecognizer().recognize(reference)
        print("OCR_SYNTHETIC cold=\(start.duration(to: .now)) pixels=216000")
        XCTAssertTrue(output.contains("SHOTDROP LOCAL TEST"))
        XCTAssertTrue(output.contains("Second line 123"))
        XCTAssertTrue(output.contains("\n"))
        // Pixel data is upside down; EXIF down must correct it exactly once.
        let rotatedContext = try XCTUnwrap(CGContext(data: nil, width: 900, height: 240, bitsPerComponent: 8,
            bytesPerRow: 900 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        rotatedContext.translateBy(x: 900, y: 240); rotatedContext.rotate(by: .pi)
        rotatedContext.draw(image, in: CGRect(x: 0, y: 0, width: 900, height: 240))
        try encoded(XCTUnwrap(rotatedContext.makeImage()), orientation: 3).write(to: url)
        let rotated = try RecentFileReference.capture(at: url, role: .savedCopy)
        let warmStart = ContinuousClock.now
        let rotatedOutput = try await LocalScreenshotTextRecognizer().recognize(rotated)
        print("OCR_SYNTHETIC warmRotated=\(warmStart.duration(to: .now)) pixels=216000")
        XCTAssertTrue(rotatedOutput.contains("SHOTDROP LOCAL TEST"))
        try fixture.png.write(to: url)
        let blank = try RecentFileReference.capture(at: url, role: .savedCopy)
        let blankOutput = try await LocalScreenshotTextRecognizer().recognize(blank)
        XCTAssertTrue(blankOutput.isEmpty)
    }

    private func encoded(_ image: CGImage, orientation: UInt32 = 1) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotTextFailure.invalidImage }
        return data as Data
    }
}

func textFixtureURL(_ url: URL) -> URL {
    guard let path = realpath(url.path, nil) else { return url }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path))
}
