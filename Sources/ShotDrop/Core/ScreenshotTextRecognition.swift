import Foundation
import ImageIO
import Vision

enum ScreenshotTextFailure: Error, Equatable {
    case fileUnavailable, invalidImage, multipleFrames, inputTooLarge, outputTooLarge, recognitionFailed
    case clipboardChanged, representationFailed, writeFailed
}

enum ScreenshotTextLimits {
    static let encodedBytes = 64 * 1024 * 1024
    static let pixels = 32_000_000
    static let outputBytes = 1024 * 1024

    /// Preserve Unicode and Vision's line order. Columns and RTL layout are not reconstructed.
    static func append(_ line: String, to text: inout String) throws {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let separator = text.isEmpty ? 0 : 1
        guard line.utf8.count <= outputBytes - text.utf8.count - separator else {
            throw ScreenshotTextFailure.outputTooLarge
        }
        if separator != 0 { text.append("\n") }
        text.append(line)
    }

    static func validateOutput(_ text: String) throws {
        guard text.utf8.count <= outputBytes else { throw ScreenshotTextFailure.outputTooLarge }
    }
}

protocol ScreenshotTextRecognizing: Sendable {
    func recognize(_ reference: RecentFileReference) async throws -> String
    func revalidate(_ reference: RecentFileReference) async throws
}

/// All ImageIO/Vision state stays on this worker. The controller admits only one job
/// and does not release that slot until synchronous Vision work has actually returned.
struct LocalScreenshotTextRecognizer: ScreenshotTextRecognizing {
    @concurrent
    func recognize(_ reference: RecentFileReference) async throws -> String {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard reference.role == .savedCopy else { throw ScreenshotTextFailure.fileUnavailable }
            guard reference.byteCount <= ScreenshotTextLimits.encodedBytes else { throw ScreenshotTextFailure.inputTooLarge }
            guard case .available(let file) = RecentFileResolver().resolve(reference), file.role == .savedCopy else {
                throw ScreenshotTextFailure.fileUnavailable
            }
            let input = try ScreenshotTextImage(data: file.validatedData)
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.automaticallyDetectsLanguage = true
            request.usesLanguageCorrection = true
            // ImageIO returns untransformed pixels. Apply EXIF orientation once in Vision.
            let handler = VNImageRequestHandler(cgImage: input.image, orientation: input.orientation, options: [:])
            do { try handler.perform([request]) }
            catch { throw ScreenshotTextFailure.recognitionFailed }
            try Task.checkCancellation()
            var text = ""
            for observation in request.results ?? [] {
                try Task.checkCancellation()
                if let line = observation.topCandidates(1).first?.string {
                    try ScreenshotTextLimits.append(line, to: &text)
                }
            }
            return text
        }
    }

    @concurrent
    func revalidate(_ reference: RecentFileReference) async throws {
        try Task.checkCancellation()
        guard reference.role == .savedCopy,
              case .available = RecentFileResolver().resolve(reference) else {
            throw ScreenshotTextFailure.fileUnavailable
        }
    }
}

struct ScreenshotTextImage {
    let image: CGImage
    let orientation: CGImagePropertyOrientation

    init(data: Data) throws {
        guard data.count <= ScreenshotTextLimits.encodedBytes else { throw ScreenshotTextFailure.inputTooLarge }
        // PNG screenshot dimensions are available without asking a decoder to
        // initialize the image. Reject oversized headers before ImageIO work.
        if data.count >= 24, data.prefix(8).elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]),
           data[12..<16].elementsEqual([73, 72, 68, 82]) {
            let width = data[16..<20].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let height = data[20..<24].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard width > 0, height > 0, width <= ScreenshotTextLimits.pixels,
                  height <= UInt64(ScreenshotTextLimits.pixels) / width else { throw ScreenshotTextFailure.inputTooLarge }
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ScreenshotTextFailure.invalidImage
        }
        guard CGImageSourceGetCount(source) <= 1 else { throw ScreenshotTextFailure.multipleFrames }
        guard CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw ScreenshotTextFailure.invalidImage
        }
        let w = width.int64Value, h = height.int64Value
        guard w > 0, h > 0, w <= ScreenshotTextLimits.pixels,
              h <= Int64(ScreenshotTextLimits.pixels) / w else { throw ScreenshotTextFailure.inputTooLarge }
        let rawOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        guard let orientation = CGImagePropertyOrientation(rawValue: rawOrientation),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.width == w, image.height == h else { throw ScreenshotTextFailure.invalidImage }
        self.image = image
        self.orientation = orientation
    }
}
