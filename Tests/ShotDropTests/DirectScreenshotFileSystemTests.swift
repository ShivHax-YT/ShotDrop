import Darwin
import Foundation
import XCTest
@testable import ShotDrop

final class DirectScreenshotFileSystemTests: XCTestCase {
    func testSavePreservesOriginalMetadataAndNeverOverwrites() async throws {
        try await fixture { root, source, destination in
            let bytes = Data("verified screenshot bytes".utf8)
            try bytes.write(to: source)
            let marker = Data([1, 2, 3])
            XCTAssertEqual(marker.withUnsafeBytes { setxattr(source.path, "com.macfleet.test", $0.baseAddress, $0.count, 0, 0) }, 0)
            let organizer = ScreenshotOrganizer(fileSystem: DirectScreenshotFileSystem())
            let request = ScreenshotOrganizationRequest(sourceURL: source, destinationRoot: destination,
                template: "shot", namingContext: .init(appName: "Test", capturedAt: Date(), timeZone: .current))
            let first = try await organizer.organize(request)
            let second = try await organizer.organize(request)
            XCTAssertNotEqual(first.destinationURL, second.destinationURL)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertEqual(try Data(contentsOf: first.destinationURL), bytes)
            XCTAssertEqual(try Data(contentsOf: second.destinationURL), bytes)
            XCTAssertEqual(getxattr(first.destinationURL.path, "com.macfleet.test", nil, 0, 0, 0), 3)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 2)
        }
    }
    func testChangedOriginalRejectsPublicationAndRemovesOnlyTemporaryCopy() async throws {
        try await fixture { _, source, destination in
            try Data("before".utf8).write(to: source)
            let staged = try DirectScreenshotFileSystem().stageCopy(source: source, destinationRoot: destination,
                subdirectories: [], expectedIdentity: nil)
            try Data("after".utf8).write(to: source)
            XCTAssertThrowsError(try staged.publish(named: "copy.png"))
            staged.discard()
            XCTAssertEqual(try Data(contentsOf: source), Data("after".utf8))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        }
    }
    func testSymlinkDestinationAndTraversalAreRejected() async throws {
        try await fixture { root, source, destination in
            try Data("source".utf8).write(to: source)
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
            XCTAssertThrowsError(try DirectScreenshotFileSystem().stageCopy(source: source, destinationRoot: link,
                subdirectories: [], expectedIdentity: nil))
            XCTAssertThrowsError(try DirectScreenshotFileSystem().stageCopy(source: source, destinationRoot: destination,
                subdirectories: [".."], expectedIdentity: nil))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        }
    }
    func testDateFoldersAndCancelledSaveLeaveOriginal() async throws {
        try await fixture { _, source, destination in
            try Data("source".utf8).write(to: source)
            let staged = try DirectScreenshotFileSystem().stageCopy(source: source, destinationRoot: destination,
                subdirectories: ["2026", "09"], expectedIdentity: nil)
            let saved = try staged.publish(named: "shot.png")
            XCTAssertTrue(saved.destinationURL.path.hasSuffix("2026/09/shot.png"))
            staged.discard()
            XCTAssertEqual(try Data(contentsOf: source), Data("source".utf8))
        }
    }
    private func fixture(_ action: (URL, URL, URL) async throws -> Void) async throws {
        let raw = FileManager.default.temporaryDirectory.path
        let canonical = try XCTUnwrap(realpath(raw, nil))
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent("ShotDropDirect-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try await action(root, root.appendingPathComponent("source.png"), destination)
    }
}
