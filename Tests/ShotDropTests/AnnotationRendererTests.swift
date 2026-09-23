import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShotDrop

final class AnnotationRendererTests: XCTestCase, @unchecked Sendable {
    func testFreshImageIOPNGContainerUsesOnlyApprovedChunks() throws {
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let data = bytes as Data
        var cursor = 8
        var chunks: [String] = []
        while cursor <= data.count - 12 {
            let length = data[cursor..<(cursor + 4)].reduce(0) { ($0 << 8) | Int($1) }
            chunks.append(String(decoding: data[(cursor + 4)..<(cursor + 8)], as: UTF8.self))
            cursor += length + 12
        }
        if chunks.contains("eXIf") { XCTAssertThrowsError(try AnnotationPNGContainer.validate(data)) }
        let clean = try AnnotationPNGContainer.cleanEncoderOutput(data)
        XCTAssertNoThrow(try AnnotationPNGContainer.validate(clean))
        let decoded = try ScreenshotTextImage(data: clean)
        XCTAssertEqual(decoded.image.width, 2)
        XCTAssertEqual(decoded.image.height, 2)
    }

    func testSourceLoadDoesNotModifyBytesAndNormalizesOrientation() async throws {
        let fixture = try fixture(orientation: 6)
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let original = try Data(contentsOf: fixture.url)
        let source = try await AnnotationRenderer().load(reference: fixture.reference)
        XCTAssertEqual(source.width, 48)
        XCTAssertEqual(source.height, 64)
        XCTAssertEqual(source.rgba.count, 48 * 64 * 4)
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        XCTAssertEqual(try RecentFileReference.capture(at: fixture.url, role: .savedCopy), fixture.reference)
    }

    func testAllEightEXIFOrientationsMatchIndependentImageIOPixelTransform() async throws {
        let renderer = AnnotationRenderer()
        for orientation in 1...8 {
            let fixture = try fixture(orientation: orientation)
            defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
            let source = try await renderer.load(reference: fixture.reference)
            let encoded = try Data(contentsOf: fixture.url)
            let container = try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData, nil))
            let referenceImage = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(container, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 64
            ] as CFDictionary))
            XCTAssertEqual(source.width, referenceImage.width, "EXIF \(orientation)")
            XCTAssertEqual(source.height, referenceImage.height, "EXIF \(orientation)")
            let expected = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: source.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            expected.draw(referenceImage, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            let expectedBytes = Data(bytes: try XCTUnwrap(expected.data), count: source.width * source.height * 4)
            let state = try AnnotationDocument(width: source.width, height: source.height).state
            let rendered = try await renderer.preview(source: source, state: state)
            XCTAssertEqual(rendered.rgba, expectedBytes, "Upright pixels must match independent ImageIO EXIF \(orientation)")
        }
    }

    func testCropPreviewAndCleanPNGHaveMatchingPixelsAndDimensions() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let renderer = AnnotationRenderer()
        let source = try await renderer.load(reference: fixture.reference)
        var state = try AnnotationDocument(width: source.width, height: source.height).state
        state.crop = CGRect(x: 8, y: 4, width: 32, height: 24)
        let preview = try await renderer.preview(source: source, state: state)
        XCTAssertEqual(preview.width, 32); XCTAssertEqual(preview.height, 24)
        let png = try await renderer.png(source: source, state: state)
        try AnnotationPNGContainer.validate(png)
        let decoded = try ScreenshotTextImage(data: png)
        XCTAssertEqual(decoded.image.width, preview.width); XCTAssertEqual(decoded.image.height, preview.height)
        let metadata = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(metadata, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(properties[kCGImagePropertyExifDictionary])
        XCTAssertNil(properties[kCGImagePropertyTIFFDictionary])
        XCTAssertEqual(CGImageSourceGetCount(metadata), 1)
        // Fresh PNG is lossless and uses the same canonical RGBA render.
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 128,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(decoded.image, in: CGRect(x: 0, y: 0, width: 32, height: 24))
        XCTAssertEqual(Data(bytes: try XCTUnwrap(bitmap.data), count: 32 * 24 * 4), preview.rgba)
    }

    func testArrowRectangleTextAndVisualBlurChangePixelsWithBoundedPreview() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let renderer = AnnotationRenderer()
        let source = try await renderer.load(reference: fixture.reference)
        let base = try AnnotationDocument(width: source.width, height: source.height).state
        let baseline = try await renderer.preview(source: source, state: base)
        for tool in [AnnotationTool.arrow, .rectangle, .text, .blur] {
            var state = base
            var mark = AnnotationMark(tool: tool, start: CGPoint(x: 5, y: 5), end: CGPoint(x: 60, y: 43))
            mark.fontSize = 18; mark.text = "Hi"
            state.marks = [mark]
            let rendered = try await renderer.preview(source: source, state: state)
            XCTAssertNotEqual(rendered.rgba, baseline.rgba, "\(tool) must affect pixels")
        }
        let small = try await renderer.preview(source: source, state: base, maximumDimension: 16)
        XCTAssertEqual(small.width, 16); XCTAssertEqual(small.height, 12)
    }

    func testSourceRoleCannotOpenAnnotationSession() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let sourceOnly = try RecentFileReference.capture(at: fixture.url, role: .source)
        do { _ = try await AnnotationRenderer().load(reference: sourceOnly); XCTFail("Source-only capture accepted") }
        catch { XCTAssertEqual(error as? AnnotationFailure, .unavailable) }
    }

    func testMissingSourceAndInvalidGeometryFailWithoutBlankCanvas() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let renderer = AnnotationRenderer()
        let source = try await renderer.load(reference: fixture.reference)
        try FileManager.default.removeItem(at: fixture.url)
        do { _ = try await renderer.load(reference: fixture.reference); XCTFail("Missing source accepted") }
        catch { XCTAssertEqual(error as? AnnotationFailure, .unavailable) }
        let invalid = AnnotationState(crop: CGRect(x: 0, y: 0, width: 1_000, height: 1))
        do { _ = try await renderer.preview(source: source, state: invalid); XCTFail("Invalid crop accepted") }
        catch { XCTAssertEqual(error as? AnnotationFailure, .invalidGeometry) }
        let state = try AnnotationDocument(width: source.width, height: source.height).state
        let preserved = try await renderer.preview(source: source, state: state)
        XCTAssertEqual(preserved.width, 64, "Decoded session survives source disappearance")
    }

    private func fixture(orientation: Int = 1) throws -> (url: URL, reference: RecentFileReference) {
        let directory = try resolvedStagingTemporaryDirectory().appendingPathComponent("annotation-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("source.tiff")
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 256,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        bitmap.setFillColor(CGColor(gray: 0, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.makeImage()), [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.0, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "private source author"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (output as Data).write(to: url)
        return (url, try RecentFileReference.capture(at: url, role: .savedCopy))
    }
}
