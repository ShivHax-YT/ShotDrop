import Foundation
import XCTest
@testable import ShotDrop

final class ThumbnailIdentityTests: XCTestCase, @unchecked Sendable {
    func testDragRevalidatesSavedIdentityAndRejectsReplacement() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("saved.png")
        try Data("original".utf8).write(to: url)
        let reference = try RecentFileReference.capture(at: url, role: .savedCopy)
        let verified = try await ShotDropThumbnailController.verifiedDragURL(reference)
        XCTAssertEqual(verified.path, url.path)
        try Data("replacement".utf8).write(to: url, options: .atomic)
        do {
            _ = try await ShotDropThumbnailController.verifiedDragURL(reference)
            XCTFail("A replacement must not become the dragged original")
        } catch { XCTAssertEqual(error as? PinScreenshotFailure, .unavailable) }
    }

    func testDragRejectsOriginalRoleAndMissingSavedFile() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.png")
        try Data("original".utf8).write(to: url)
        let source = try RecentFileReference.capture(at: url, role: .source)
        let saved = try RecentFileReference.capture(at: url, role: .savedCopy)
        do {
            _ = try await ShotDropThumbnailController.verifiedDragURL(source)
            XCTFail("Original source is not saved output")
        } catch { XCTAssertEqual(error as? PinScreenshotFailure, .unavailable) }
        try FileManager.default.removeItem(at: url)
        do {
            _ = try await ShotDropThumbnailController.verifiedDragURL(saved)
            XCTFail("Missing output cannot be dragged")
        } catch { XCTAssertEqual(error as? PinScreenshotFailure, .unavailable) }
    }

    private func directory() throws -> URL {
        let result = (try physicalTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
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
