import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShotDrop

/// Synthetic local fixtures only. Timing is diagnostic, not a latency/RSS guarantee.
final class ScreenshotTextCorpusTests: XCTestCase {
    func testLargeLightDarkAndRotatedSavedImagesWithTimingSamples() async throws {
        let directory = try resolvedStagingTemporaryDirectory().appendingPathComponent("ocr-corpus-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LocalScreenshotTextRecognizer()
        var warmed: [Double] = []
        for (name, dark, rotated) in [("light", false, false), ("dark", true, false), ("rotated", false, true)] {
            let url = directory.appendingPathComponent(name + ".tiff")
            try fixture(dark: dark, rotated: rotated).write(to: url)
            let reference = try RecentFileReference.capture(at: url, role: .savedCopy)
            let before = try Data(contentsOf: url)
            for sample in 0..<4 {
                let start = ContinuousClock.now
                let result = try await service.recognize(reference)
                let elapsed = start.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                XCTAssertTrue(result.contains("SHOTDROP LOCAL CORPUS"), name)
                XCTAssertTrue(result.contains("Second line 123"), name)
                XCTAssertTrue(result.contains("\n"), name)
                if sample == 0 { print("OCR_CORPUS first_\(name)_seconds=\(seconds) source_pixels=6000000") }
                else { warmed.append(seconds) }
            }
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
        let sorted = warmed.sorted()
        print("OCR_CORPUS warm_samples=\(sorted.count) p50_seconds=\(sorted[sorted.count / 2]) p95_nearest_rank_seconds=\(sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1])")
    }

    private func fixture(dark: Bool, rotated: Bool) throws -> Data {
        let width = 3000, height = 2000
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.setFillColor(CGColor(gray: dark ? 0 : 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if rotated { bitmap.translateBy(x: CGFloat(width), y: CGFloat(height)); bitmap.rotate(by: .pi) }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 36, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: dark ? 1 : 0, alpha: 1)
        ]
        for (index, line) in ["SHOTDROP LOCAL CORPUS", "Second line 123"].enumerated() {
            bitmap.textPosition = CGPoint(x: 180, y: 1600 - index * 80)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes)), bitmap)
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.makeImage()),
            [kCGImagePropertyOrientation: rotated ? 3 : 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
