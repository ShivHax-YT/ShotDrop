import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShotDrop

@MainActor
final class PinScreenshotActionsTests: XCTestCase {
    func testMissingSourceBlocksFileActionsButSnapshotCopyRemainsAvailable() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.removeItem(at: fixture.url)
        let writer = PinActionWriter()
        var externalCalls = 0
        let actions = PinScreenshotActions(writer: writer, beginClipboardIntent: { {} },
            open: { _ in externalCalls += 1; return true }, reveal: { _ in externalCalls += 1; return true })
        let feedback = ThumbnailFeedback()
        for action in [PinScreenshotAction.open, .reveal, .copyFile] {
            let result = await actions.perform(fixture.snapshot, action: action)
            XCTAssertFalse(result.fileActionsAvailable)
            feedback.apply(result, action: action)
            XCTAssertFalse(feedback.fileActionsAvailable, "The thumbnail must offer recovery for unavailable files")
        }
        XCTAssertEqual(externalCalls, 0)
        XCTAssertEqual(writer.ownershipCount, 0)
        let copied = await actions.perform(fixture.snapshot, action: .copyImage)
        feedback.apply(copied, action: .copyImage)
        XCTAssertFalse(feedback.fileActionsAvailable, "Copying cached pixels must not restore broken file actions")
        XCTAssertTrue(copied.status.contains("Copied"))
        XCTAssertEqual(writer.ownershipCount, 1)
        try assertRedPNG(try XCTUnwrap(writer.png), width: fixture.snapshot.image.width, height: fixture.snapshot.image.height)
        XCTAssertNil(writer.fileURL)
        feedback.beginPresentation(isKeyWindow: false)
        XCTAssertTrue(feedback.fileActionsAvailable, "A newly verified capture starts with its own available file")
        XCTAssertNil(feedback.status, "Recovery feedback must not leak into the next capture")
    }

    func testReplacementDoesNotRetargetFileActionsOrPinnedPixels() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try png(width: 4, height: 4, red: false).write(to: fixture.url, options: .atomic)
        let writer = PinActionWriter()
        var targets: [URL] = []
        let actions = PinScreenshotActions(writer: writer, beginClipboardIntent: { {} },
            open: { targets.append($0); return true }, reveal: { targets.append($0); return true })
        for action in [PinScreenshotAction.open, .reveal, .copyFile] {
            let result = await actions.perform(fixture.snapshot, action: action)
            XCTAssertFalse(result.fileActionsAvailable)
        }
        XCTAssertTrue(targets.isEmpty)
        XCTAssertEqual(writer.ownershipCount, 0)
        _ = await actions.perform(fixture.snapshot, action: .copyImage)
        try assertRedPNG(try XCTUnwrap(writer.png), width: 4, height: 4)
    }

    func testReducedPreviewCopiesOnlyDisplayedResolutionPNG() async throws {
        let fixture = try await makeFixture(width: 2050, height: 4)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        XCTAssertTrue(fixture.snapshot.isReduced)
        let writer = PinActionWriter()
        let actions = PinScreenshotActions(writer: writer, beginClipboardIntent: { {} })
        let result = await actions.perform(fixture.snapshot, action: .copyImage)
        XCTAssertEqual(result.status, "Copied preview image at its displayed resolution.")
        XCTAssertEqual(writer.writes, 1)
        XCTAssertNil(writer.fileURL)
        try assertRedPNG(try XCTUnwrap(writer.png), width: fixture.snapshot.image.width, height: fixture.snapshot.image.height)
    }

    func testSupersededClipboardIntentNeverTakesOwnership() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let writer = PinActionWriter()
        var checked = 0
        let actions = PinScreenshotActions(writer: writer, beginClipboardIntent: {
            { checked += 1; throw CancellationError() }
        })
        for action in [PinScreenshotAction.copyImage, .copyFile] {
            let result = await actions.perform(fixture.snapshot, action: action)
            XCTAssertEqual(result.status, "Pin action cancelled.")
        }
        XCTAssertEqual(checked, 2)
        XCTAssertEqual(writer.ownershipCount, 0)
        XCTAssertEqual(writer.writes, 0)
        XCTAssertNil(writer.png)
        XCTAssertNil(writer.fileURL)
    }

    func testAlreadyCancelledActionsHaveNoClipboardOrFileEffects() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let writer = PinActionWriter()
        var effects = 0
        let actions = PinScreenshotActions(writer: writer, beginClipboardIntent: {
            effects += 1
            return {}
        }, open: { _ in effects += 1; return true }, reveal: { _ in effects += 1; return true })
        for action in [PinScreenshotAction.copyImage, .copyFile, .open, .reveal] {
            let task = Task { @MainActor in await actions.perform(fixture.snapshot, action: action) }
            // This synchronous MainActor section cancels before the child can start.
            task.cancel()
            let result = await task.value
            XCTAssertEqual(result.status, "Pin action cancelled.")
        }
        XCTAssertEqual(effects, 0)
        XCTAssertEqual(writer.ownershipCount, 0)
        XCTAssertEqual(writer.writes, 0)
    }

    func testMatchingSourceFileActionsUseVerifiedURLAndFileOnlyRepresentation() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let writer = PinActionWriter()
        var targets: [URL] = []
        let actions = PinScreenshotActions(writer: writer, beginClipboardIntent: { {} },
            open: { targets.append($0); return true }, reveal: { targets.append($0); return true })
        _ = await actions.perform(fixture.snapshot, action: .open)
        _ = await actions.perform(fixture.snapshot, action: .reveal)
        _ = await actions.perform(fixture.snapshot, action: .copyFile)
        XCTAssertEqual(targets, [fixture.url, fixture.url])
        XCTAssertEqual(writer.fileURL, fixture.url.absoluteString)
        XCTAssertNil(writer.png)
        XCTAssertEqual(writer.ownershipCount, 1)
        XCTAssertEqual(writer.writes, 1)
    }

    private func makeFixture(width: Int = 4, height: Int = 4) async throws -> (directory: URL, url: URL, snapshot: PinScreenshotSnapshot) {
        let directory = (try physicalTemporaryDirectory())
            .appendingPathComponent("pin-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let url = directory.appendingPathComponent("saved.png")
            try png(width: width, height: height, red: true).write(to: url)
            let reference = try RecentFileReference.capture(at: url, role: .savedCopy)
            let store = PinScreenshotStore()
            let identity = PinScreenshotIdentity(captureID: UUID(), revision: 1, reference: reference)
            guard case .opened(let token) = try await store.admit(identity) else {
                throw PinScreenshotFailure.unavailable
            }
            do {
                let snapshot = try await store.snapshot(for: token)
                await store.closeAll()
                return (directory, url, snapshot)
            } catch { await store.closeAll(); throw error }
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    private func png(width: Int, height: Int, red: Bool) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [red ? 1 : 0, 0, red ? 0 : 1, 1])))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func assertRedPNG(_ data: Data, width: Int, height: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil), file: file, line: line)
        XCTAssertEqual(CGImageSourceGetCount(source), 1, file: file, line: line)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), file: file, line: line)
        XCTAssertEqual(image.width, width, file: file, line: line)
        XCTAssertEqual(image.height, height, file: file, line: line)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), file: file, line: line)
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try XCTUnwrap(context.data, file: file, line: line).assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(bytes[0], 245, file: file, line: line)
        XCTAssertLessThan(bytes[1], 10, file: file, line: line)
        XCTAssertLessThan(bytes[2], 10, file: file, line: line)
        XCTAssertEqual(bytes[3], 255, file: file, line: line)
    }
    /// Foundation may re-abbreviate /private/var to /var; the resolver correctly
    /// rejects that symlink ancestor with O_NOFOLLOW_ANY. Use the physical path.
    private func physicalTemporaryDirectory() throws -> URL {
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

}

/// In-memory writer: no NSPasteboard instance, ownership, or user's clipboard access.
@MainActor
private final class PinActionWriter: ScreenshotPasteboardWriting {
    var changeCount: Int { ownershipCount }
    private(set) var ownershipCount = 0
    private(set) var writes = 0
    private(set) var png: Data?
    private(set) var fileURL: String?
    func makeItem() -> NSPasteboardItem { NSPasteboardItem() }
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType, on item: NSPasteboardItem) -> Bool {
        guard type == .png else { return false }
        png = data
        return true
    }
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType, on item: NSPasteboardItem) -> Bool {
        guard type == .fileURL else { return false }
        fileURL = string
        return true
    }
    func prepareForNewContents() { ownershipCount += 1 }
    func write(_ item: NSPasteboardItem) -> Bool { writes += 1; return true }


}
