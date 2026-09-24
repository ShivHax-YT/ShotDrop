import CryptoKit
import Darwin
import Foundation
import XCTest
import zlib
@testable import ShotDrop

/// Bounded compatibility checks for explicit validator paths and RGBA8 normalization.
/// These do not specify ImageIO encoder output or exhaustive malformed-PNG semantics.
final class AnnotationPNGVariantTests: XCTestCase, @unchecked Sendable {
    func testPackedIndexedTwoBitTransparencyNormalizesWithoutMutatingSource() async throws {
        // Five indices occupy two packed bytes; trailing six bits are padding.
        let rows = [[0, 1, 2, 3, 0], [3, 2, 1, 0, 3]]
        let filtered = Data([0, 0x1B, 0x00, 0, 0xE4, 0xC0])
        let png = try makePNG(width: 5, height: 2, depth: 2, color: 3, interlace: 0, filtered: filtered,
            ancillary: [chunk("PLTE", Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])),
                        chunk("tRNS", Data([255, 255, 0, 128]))])
        let palette: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 0, 0], [128, 128, 128, 128]]
        let expected = rows.flatMap { row in row.flatMap { palette[$0] } }
        try await assertNormalization(png, width: 5, height: 2, expected: expected)
    }

    func testRGBA16EndpointsAndHalfAlphaNormalizeWithoutMutatingSource() async throws {
        let samples: [UInt16] = [65535, 0, 0, 65535, 65535, 65535, 65535, 32768]
        var filtered = Data([0])
        for sample in samples { filtered.append(UInt8(sample >> 8)); filtered.append(UInt8(truncatingIfNeeded: sample)) }
        let png = try makePNG(width: 2, height: 1, depth: 16, color: 6, interlace: 0, filtered: filtered)
        try await assertNormalization(png, width: 2, height: 1,
            expected: [255, 0, 0, 255, 128, 128, 128, 128])
    }

    func testAdam7AllSevenPassesNormalizeExpectedPixelsWithoutMutation() async throws {
        let filtered = adam7Rows()
        let png = try makePNG(width: 9, height: 9, depth: 8, color: 2, interlace: 1, filtered: filtered)
        let expected = (0..<9).flatMap { y in
            (0..<9).flatMap { x in pixel(x, y) + [UInt8(255)] }
        }
        try await assertNormalization(png, width: 9, height: 9, expected: expected)
    }

    func testAdam7MissingAndExtraInflatedBytesWithValidChecksumsAreRejected() throws {
        let filtered = adam7Rows()
        for malformed in [Data(filtered.dropLast()), filtered + Data([0])] {
            let png = try makePNG(width: 9, height: 9, depth: 8, color: 2, interlace: 1, filtered: malformed)
            XCTAssertThrowsError(try AnnotationPNGContainer.validate(png)) {
                XCTAssertEqual($0 as? AnnotationFailure, .invalidImage)
            }
        }
        XCTAssertFalse(AnnotationExportAvailability.productionEnabled)
    }

    private func assertNormalization(_ png: Data, width: Int, height: Int, expected: [UInt8]) async throws {
        guard let temporary = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw POSIXError(.EIO) }
        defer { free(temporary) }
        let directory = URL(fileURLWithPath: String(cString: temporary), isDirectory: true)
            .appendingPathComponent("png-variants-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.png")
        try png.write(to: url)
        let attribute = Data("retained private fixture metadata".utf8)
        XCTAssertEqual(attribute.withUnsafeBytes {
            setxattr(url.path, "com.macfleet.fixture.png-variant", $0.baseAddress, $0.count, 0, 0)
        }, 0)
        let initialAttributes = try stagingTestAttributeHashes(at: url)
        let hash = Data(SHA256.hash(data: png))
        let reference = try RecentFileReference.capture(at: url, role: .savedCopy)
        XCTAssertNoThrow(try AnnotationPNGContainer.validate(png))
        let renderer = AnnotationRenderer()
        let source = try await renderer.load(reference: reference)
        XCTAssertEqual(source.width, width)
        XCTAssertEqual(source.height, height)
        assertPixels(source.rgba, expected)
        let state = try AnnotationDocument(width: width, height: height).state
        let preview = try await renderer.preview(source: source, state: state)
        XCTAssertEqual(preview.width, width)
        XCTAssertEqual(preview.height, height)
        assertPixels(preview.rgba, expected)
        let after = try Data(contentsOf: url)
        XCTAssertEqual(after, png)
        XCTAssertEqual(Data(SHA256.hash(data: after)), hash)
        XCTAssertEqual(try stagingTestAttributeHashes(at: url), initialAttributes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source.png"])
        XCTAssertFalse(AnnotationExportAvailability.productionEnabled)
    }

    private func assertPixels(_ actual: Data, _ expected: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (index, pair) in zip(actual, expected).enumerated() {
            XCTAssertLessThanOrEqual(abs(Int(pair.0) - Int(pair.1)), 2, "RGBA byte \(index)", file: file, line: line)
        }
    }

    private func pixel(_ x: Int, _ y: Int) -> [UInt8] {
        [x % 2 == 0 ? 255 : 0, y % 2 == 0 ? 255 : 0, (x + y) % 3 == 0 ? 255 : 0]
    }
    private func adam7Rows() -> Data {
        let passes = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
                      (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
        var result = Data()
        for (startX, startY, stepX, stepY) in passes {
            for y in stride(from: startY, to: 9, by: stepY) {
                result.append(0) // None filter, independently packed for each pass row.
                for x in stride(from: startX, to: 9, by: stepX) { result.append(contentsOf: pixel(x, y)) }
            }
        }
        return result
    }
    private func makePNG(width: UInt32, height: UInt32, depth: UInt8, color: UInt8,
                         interlace: UInt8, filtered: Data, ancillary: [Data] = []) throws -> Data {
        var header = bigEndian(width) + bigEndian(height)
        header.append(contentsOf: [depth, color, 0, 0, interlace])
        var result = Data([137, 80, 78, 71, 13, 10, 26, 10])
        result.append(chunk("IHDR", header))
        result.append(chunk("sRGB", Data([0])))
        ancillary.forEach { result.append($0) }
        var compressed = Data(count: Int(compressBound(uLong(filtered.count))))
        var count = uLongf(compressed.count)
        let status = compressed.withUnsafeMutableBytes { output in
            filtered.withUnsafeBytes { input in
                compress2(output.baseAddress!.assumingMemoryBound(to: Bytef.self), &count,
                          input.baseAddress!.assumingMemoryBound(to: Bytef.self), uLong(filtered.count), Z_BEST_COMPRESSION)
            }
        }
        guard status == Z_OK else { throw AnnotationFailure.encodingFailed }
        compressed.count = Int(count)
        result.append(chunk("IDAT", compressed))
        result.append(chunk("IEND", Data()))
        return result
    }
    private func chunk(_ name: String, _ payload: Data) -> Data {
        var body = Data(name.utf8); body.append(payload)
        let checksum = body.withUnsafeBytes { crc32(0, $0.baseAddress!.assumingMemoryBound(to: Bytef.self), uInt($0.count)) }
        return bigEndian(UInt32(payload.count)) + body + bigEndian(UInt32(checksum))
    }
    private func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
}
