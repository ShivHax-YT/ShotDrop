import Foundation
import ImageIO
import zlib

/// This gate is intentionally not derived from setup preferences or a chosen folder.
/// Production integration remains closed until the reviewed save/issuer dependencies pass.
enum AnnotationExportAvailability {
    static let productionEnabled = false
    static let unavailableReason = "This build cannot save annotated copies while ShotDrop’s save path is under review."
    static let explanation = unavailableReason + " Your original is unchanged. Keep this editor open to retain edits."
    static let dirtyCloseExplanation = unavailableReason + " Unsaved edits will be lost if you discard them."
}

/// A rendered export uses the same fixed-stage transaction as screenshot organization.
/// The editor does not construct this adapter while the production gate is closed.
actor AnnotationExportService {
    private let fileSystem: LocalScreenshotOrganizationFileSystem

    init(fileSystem: LocalScreenshotOrganizationFileSystem) {
        self.fileSystem = fileSystem
    }

    func export(png: Data, source: RecentFileReference, destination: URL,
                proposedStem: String) throws -> VerifiedScreenshotCopy {
        try Task.checkCancellation()
        guard source.role == .savedCopy,
              case .available(let file) = RecentFileResolver().resolve(source) else {
            throw AnnotationFailure.unavailable
        }
        let plan = try ScreenshotNaming.plan(template: "{app}", sourceExtension: "png",
            context: ScreenshotNamingContext(appName: proposedStem, capturedAt: Date(), timeZone: .current),
            organizeByDate: false)
        let staged = try fileSystem.stageRenderedPNG(source: file.url, destinationRoot: destination,
            expectedIdentity: file.liveIdentity, expectedSourceDigest: source.sha256, png: png)
        defer { staged.discard() }
        for index in 0..<1_000 {
            try Task.checkCancellation()
            do { return try staged.publish(named: plan.filename(collisionIndex: index)) }
            catch let failure as ScreenshotCopyFailure where failure.code == .collision { continue }
        }
        throw ScreenshotCopyFailure(code: .collision, detail: "No unused annotation filename was available. Your original is unchanged.")
    }
}

/// Reject source-specific ancillary chunks, including EXIF, text, GPS and thumbnails.
/// Color profile chunks describe the freshly rendered pixels and are allowed.
enum AnnotationPNGContainer {
    private static let allowed: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "sRGB", "gAMA", "cHRM", "iCCP"]

    /// ImageIO may add an eXIf chunk even when no properties are supplied. Drop
    /// unapproved ancillary chunks from the fresh encoder result, never from a source.
    static func cleanEncoderOutput(_ data: Data) throws -> Data {
        guard data.count <= ScreenshotStagingLimits.maximumPayloadBytes, data.count >= 20,
              data.prefix(8).elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw AnnotationFailure.invalidImage
        }
        var clean = Data(data.prefix(8))
        var cursor = 8
        while cursor <= data.count - 12 {
            let count = data[cursor..<(cursor + 4)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard count <= UInt64(data.count - cursor - 12),
                  let name = String(data: data[(cursor + 4)..<(cursor + 8)], encoding: .ascii) else {
                throw AnnotationFailure.invalidImage
            }
            let end = cursor + Int(count) + 12
            if allowed.contains(name) { clean.append(data[cursor..<end]) }
            else if data[cursor + 4] & 0x20 == 0 { throw AnnotationFailure.invalidImage }
            cursor = end
            if name == "IEND" { break }
        }
        guard cursor == data.count else { throw AnnotationFailure.invalidImage }
        try validate(clean)
        return clean
    }

    static func validate(_ data: Data) throws {
        guard data.count <= ScreenshotStagingLimits.maximumPayloadBytes,
              data.count >= 45, data.prefix(8).elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw AnnotationFailure.invalidImage
        }
        var cursor = 8
        var ended = false
        var imageRanges: [Range<Int>] = []
        var dataEnded = false
        while cursor <= data.count - 12 {
            let count = data[cursor..<(cursor + 4)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard count <= UInt64(data.count - cursor - 12),
                  let name = String(data: data[(cursor + 4)..<(cursor + 8)], encoding: .ascii),
                  allowed.contains(name) else { throw AnnotationFailure.invalidImage }
            let payloadEnd = cursor + 8 + Int(count)
            let expectedCRC = data[payloadEnd..<(payloadEnd + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let actualCRC = data.withUnsafeBytes { buffer in
                crc32(0, buffer.baseAddress!.assumingMemoryBound(to: Bytef.self).advanced(by: cursor + 4), uInt(count + 4))
            }
            guard UInt32(actualCRC) == expectedCRC,
                  (cursor == 8 ? (name == "IHDR" && count == 13) : name != "IHDR") else {
                throw AnnotationFailure.invalidImage
            }
            if name == "IDAT" {
                guard !dataEnded, imageRanges.count < 65_536 else { throw AnnotationFailure.invalidImage }
                imageRanges.append((cursor + 8)..<payloadEnd)
            } else if !imageRanges.isEmpty { dataEnded = true }
            cursor = payloadEnd + 4
            if name == "IEND" {
                guard count == 0 else { throw AnnotationFailure.invalidImage }
                ended = true; break
            }
        }
        guard ended, cursor == data.count, !imageRanges.isEmpty else { throw AnnotationFailure.invalidImage }
        // Validate the complete zlib stream, including its checksum. ImageIO can
        // recover partial pixels from damaged IDAT, which is not export success.
        let expectedBytes = try inflatedSize(data)
        try validateDeflate(data, ranges: imageRanges, expectedBytes: expectedBytes)
        let input = try ScreenshotTextImage(data: data) // retains existing encoded/frame/pixel limits
        guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true,
                 kCGImageSourceShouldAllowFloat: false] as CFDictionary),
              image.width == input.image.width, image.height == input.image.height,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw AnnotationFailure.invalidImage
        }
    }

    /// Exact filtered scanline size, including Adam7 passes, checked before decode.
    private static func inflatedSize(_ data: Data) throws -> Int {
        let width = data[16..<20].reduce(0) { ($0 << 8) | Int($1) }
        let height = data[20..<24].reduce(0) { ($0 << 8) | Int($1) }
        guard width > 0, height > 0, width <= 32_000_000, height <= 32_000_000 / width,
              data[26] == 0, data[27] == 0, data[28] <= 1 else { throw AnnotationFailure.invalidImage }
        let depth = Int(data[24]), color = data[25]
        let channels: Int
        switch color {
        case 0: guard [1, 2, 4, 8, 16].contains(depth) else { throw AnnotationFailure.invalidImage }; channels = 1
        case 2: guard [8, 16].contains(depth) else { throw AnnotationFailure.invalidImage }; channels = 3
        case 3: guard [1, 2, 4, 8].contains(depth) else { throw AnnotationFailure.invalidImage }; channels = 1
        case 4: guard [8, 16].contains(depth) else { throw AnnotationFailure.invalidImage }; channels = 2
        case 6: guard [8, 16].contains(depth) else { throw AnnotationFailure.invalidImage }; channels = 4
        default: throw AnnotationFailure.invalidImage
        }
        let passes = data[28] == 0 ? [(0, 0, 1, 1)] :
            [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
             (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
        return passes.reduce(0) { total, pass in
            guard width > pass.0, height > pass.1 else { return total }
            let columns = (width - pass.0 + pass.2 - 1) / pass.2
            let rows = (height - pass.1 + pass.3 - 1) / pass.3
            return total + ((columns * channels * depth + 7) / 8 + 1) * rows
        }
    }

    private static func validateDeflate(_ data: Data, ranges: [Range<Int>], expectedBytes: Int) throws {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw AnnotationFailure.invalidImage
        }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: 64 * 1024)
        var complete = false
        try data.withUnsafeBytes { input in
            for range in ranges {
                try Task.checkCancellation()
                guard !complete || range.isEmpty else { throw AnnotationFailure.invalidImage }
                stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress!.assumingMemoryBound(to: Bytef.self).advanced(by: range.lowerBound))
                stream.avail_in = uInt(range.count)
                if range.isEmpty { continue }
                repeat {
                    try Task.checkCancellation()
                    let result = output.withUnsafeMutableBytes { buffer in
                        stream.next_out = buffer.baseAddress!.assumingMemoryBound(to: Bytef.self)
                        stream.avail_out = uInt(buffer.count)
                        return inflate(&stream, Z_NO_FLUSH)
                    }
                    guard stream.total_out <= uLong(expectedBytes) else { throw AnnotationFailure.invalidImage }
                    if result == Z_STREAM_END {
                        guard stream.avail_in == 0 else { throw AnnotationFailure.invalidImage }
                        complete = true; break
                    }
                    if result == Z_BUF_ERROR && stream.avail_in == 0 { break }
                    guard result == Z_OK else { throw AnnotationFailure.invalidImage }
                } while stream.avail_in > 0 || stream.avail_out == 0
            }
        }
        guard complete, stream.total_out == uLong(expectedBytes) else { throw AnnotationFailure.invalidImage }
    }
}
