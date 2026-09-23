import Foundation

/// This gate is intentionally not derived from setup preferences or a chosen folder.
/// Production integration remains closed until the reviewed save/issuer dependencies pass.
enum AnnotationExportAvailability {
    static let productionEnabled = false
    static let explanation = "Saving annotations is not available yet. Your original is unchanged. Keep this window open to retain edits."
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
              data.count >= 20, data.prefix(8).elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw AnnotationFailure.invalidImage
        }
        var cursor = 8
        var ended = false
        while cursor <= data.count - 12 {
            let count = data[cursor..<(cursor + 4)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard count <= UInt64(data.count - cursor - 12),
                  let name = String(data: data[(cursor + 4)..<(cursor + 8)], encoding: .ascii),
                  allowed.contains(name) else { throw AnnotationFailure.invalidImage }
            cursor += Int(count) + 12
            if name == "IEND" { ended = true; break }
        }
        guard ended, cursor == data.count else { throw AnnotationFailure.invalidImage }
        _ = try ScreenshotTextImage(data: data)
    }
}
