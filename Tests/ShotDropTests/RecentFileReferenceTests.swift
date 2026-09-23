import Darwin
import Foundation
import XCTest
@testable import ShotDrop

@MainActor
final class RecentFileReferenceTests: XCTestCase {
    func testCaptureRoundTripAndResolveVerifiedBytes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reference = try RecentFileReference.capture(at: fixture.saved, role: .savedCopy)
        let decoded = try JSONDecoder().decode(RecentFileReference.self, from: JSONEncoder().encode(reference))
        XCTAssertEqual(decoded, reference)
        XCTAssertEqual(reference.byteCount, UInt64(fixture.bytes.count))
        XCTAssertEqual(reference.sha256.count, 64)
        guard case let .available(file) = RecentFileResolver().resolve(decoded) else {
            return XCTFail("The unchanged file should resolve")
        }
        XCTAssertEqual(file.role, .savedCopy)
        XCTAssertEqual(file.validatedData, fixture.bytes)
        XCTAssertNil(file.refreshedReference)
    }

    func testContentChangeAtSamePathIsReplaced() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reference = try RecentFileReference.capture(at: fixture.saved, role: .savedCopy)
        try Data("different image".utf8).write(to: fixture.saved)
        assertIssue(.replaced, from: RecentFileResolver().resolve(reference))
    }

    func testMovedOriginalResolvesOnlyWhenBookmarkTracksIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reference = try RecentFileReference.capture(at: fixture.saved, role: .savedCopy)
        let moved = fixture.root.appendingPathComponent("moved.png")
        try FileManager.default.moveItem(at: fixture.saved, to: moved)
        let resolver = RecentFileResolver(resolveBookmark: { _ in (moved, true) },
                                          createBookmark: { _ in reference.bookmarkData })
        guard case let .available(file) = resolver.resolve(reference) else {
            return XCTFail("A bookmark tracking the same bytes and identity should resolve")
        }
        XCTAssertEqual(file.url, moved)
        XCTAssertEqual(file.refreshedReference?.lastKnownPath, moved.path)
        XCTAssertEqual(file.validatedData, fixture.bytes)
    }

    func testBookmarkToReplacementIsRejectedEvenWhenOldFileMoved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reference = try RecentFileReference.capture(at: fixture.saved, role: .savedCopy)
        let moved = fixture.root.appendingPathComponent("old.png")
        try FileManager.default.moveItem(at: fixture.saved, to: moved)
        try Data("replacement".utf8).write(to: fixture.saved)
        let resolver = RecentFileResolver(resolveBookmark: { _ in (fixture.saved, false) })
        assertIssue(.replaced, from: resolver.resolve(reference))
        XCTAssertEqual(try Data(contentsOf: moved), fixture.bytes)
    }

    func testIdenticalBytesAtSamePathStillHaveDifferentDocumentIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reference = try RecentFileReference.capture(at: fixture.saved, role: .savedCopy)
        let moved = fixture.root.appendingPathComponent("original.png")
        try FileManager.default.moveItem(at: fixture.saved, to: moved)
        try fixture.bytes.write(to: fixture.saved)
        let resolver = RecentFileResolver(resolveBookmark: { _ in (fixture.saved, false) })
        assertIssue(.replaced, from: resolver.resolve(reference))
    }

    func testMissingFileAndSymlinkAreNotOpened() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reference = try RecentFileReference.capture(at: fixture.saved, role: .savedCopy)
        try FileManager.default.removeItem(at: fixture.saved)
        let resolver = RecentFileResolver(resolveBookmark: { _ in (fixture.saved, false) })
        assertIssue(.missing, from: resolver.resolve(reference))
        try FileManager.default.createSymbolicLink(at: fixture.saved, withDestinationURL: fixture.source)
        assertIssue(.replaced, from: resolver.resolve(reference))
    }

    func testBookmarkFailureNeverFallsBackToSamePath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reference = try RecentFileReference.capture(at: fixture.saved, role: .savedCopy)
        let resolver = RecentFileResolver(resolveBookmark: { _ in throw CocoaError(.fileReadUnknown) })
        assertIssue(.needsLocation, from: resolver.resolve(reference))
        XCTAssertEqual(try Data(contentsOf: fixture.saved), fixture.bytes)
    }

    func testUnresolvableUnmountedVolumeIsOffline() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reference = try RecentFileReference.capture(at: fixture.saved, role: .savedCopy)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as? [String: Any])
        object["lastKnownPath"] = "/Volumes/ShotDrop-Missing-\(UUID().uuidString)/saved.png"
        let offline = try JSONDecoder().decode(RecentFileReference.self, from: JSONSerialization.data(withJSONObject: object))
        let resolver = RecentFileResolver(resolveBookmark: { _ in throw CocoaError(.fileReadUnknown) })
        assertIssue(.offline, from: resolver.resolve(offline))
    }

    func testDeniedFileIsClassifiedWithoutReadingItsContents() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reference = try RecentFileReference.capture(at: fixture.saved, role: .savedCopy)
        XCTAssertEqual(chmod(fixture.saved.path, 0), 0)
        defer { _ = chmod(fixture.saved.path, 0o600) }
        let resolver = RecentFileResolver(resolveBookmark: { _ in (fixture.saved, false) })
        assertIssue(.denied, from: resolver.resolve(reference))
    }

    func testSourceAndSavedCopyRemainDistinct() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try RecentFileReference.capture(at: fixture.source, role: .source)
        let saved = try RecentFileReference.capture(at: fixture.saved, role: .savedCopy)
        guard case let .available(sourceFile) = RecentFileResolver().resolve(source),
              case let .available(savedFile) = RecentFileResolver().resolve(saved) else {
            return XCTFail("Both fixture files should resolve")
        }
        XCTAssertEqual(sourceFile.role, .source)
        XCTAssertEqual(savedFile.role, .savedCopy)
        XCTAssertEqual(sourceFile.validatedData, fixture.bytes)
        XCTAssertEqual(savedFile.validatedData, fixture.bytes)
    }

    func testOversizedFileCannotBeCaptured() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let descriptor = open(fixture.saved.path, O_WRONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { close(descriptor) } }
        XCTAssertEqual(ftruncate(descriptor, off_t(RecentFileReference.maximumFileBytes + 1)), 0)
        XCTAssertThrowsError(try RecentFileReference.capture(at: fixture.saved, role: .savedCopy))
    }

    func testInvalidDecodedBookmarkAndHashAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reference = try RecentFileReference.capture(at: fixture.saved, role: .savedCopy)
        let encoded = try JSONEncoder().encode(reference)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["bookmarkData"] = Data(repeating: 0, count: RecentFileReference.maximumBookmarkBytes + 1).base64EncodedString()
        XCTAssertThrowsError(try JSONDecoder().decode(RecentFileReference.self, from: JSONSerialization.data(withJSONObject: object)))
        object["bookmarkData"] = reference.bookmarkData.base64EncodedString()
        object["sha256"] = "not-a-digest"
        XCTAssertThrowsError(try JSONDecoder().decode(RecentFileReference.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    private func assertIssue(_ expected: RecentFileIssue, from result: RecentFileResolution,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard case let .unavailable(actual) = result else {
            return XCTFail("Expected \(expected)", file: file, line: line)
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let saved: URL
        let bytes = Data("small fixture image".utf8)

        init() throws {
            guard let physicalTemporary = realpath(FileManager.default.temporaryDirectory.path, nil) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { free(physicalTemporary) }
            root = URL(fileURLWithPath: String(cString: physicalTemporary), isDirectory: true)
                .appendingPathComponent("ShotDrop-RecentFile-\(UUID().uuidString)", isDirectory: true)
            source = root.appendingPathComponent("source.png")
            saved = root.appendingPathComponent("saved.png")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try bytes.write(to: source)
            try bytes.write(to: saved)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
