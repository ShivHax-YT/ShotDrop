import Darwin
import Foundation
import XCTest
@testable import ShotDrop

final class ScreenshotDestinationValidatorTests: XCTestCase {
    private let validator = LocalScreenshotDestinationValidator()

    func testEqualAndBothAncestorDirectionsAreRejected() throws {
        try withFixture { fixture in
            let nested = try fixture.directory("source/nested")
            try expect(.overlap, source: fixture.source, destination: fixture.source)
            try expect(.overlap, source: fixture.source, destination: nested)
            try expect(.overlap, source: nested, destination: fixture.source)
            try expect(.overlap, source: fixture.source, destination: fixture.root)
        }
    }

    func testIndependentSiblingAndPrefixSiblingAreAllowed() throws {
        try withFixture { fixture in
            let sibling = try fixture.directory("source-backup")
            try validator.validate(sourceDirectory: fixture.source, destinationDirectory: fixture.destination)
            try validator.validate(sourceDirectory: fixture.source, destinationDirectory: sibling)
        }
    }

    func testAbsentIndependentDestinationIsAllowedWithoutCreatingIt() throws {
        try withFixture { fixture in
            let proposed = fixture.root.appendingPathComponent("not-created/child/final", isDirectory: true)
            let before = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
            try validator.validate(sourceDirectory: fixture.source, destinationDirectory: proposed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: proposed.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted(), before)
        }
    }

    func testAbsentDestinationInsideSourceIsRejectedWithoutCreatingIt() throws {
        try withFixture { fixture in
            let proposed = fixture.source.appendingPathComponent("missing/child", isDirectory: true)
            try expect(.overlap, source: fixture.source, destination: proposed)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.source.path).isEmpty)
        }
    }

    func testSymlinkAliasesRejectEqualityAndOverlapsInBothDirections() throws {
        try withFixture { fixture in
            let nested = try fixture.directory("source/nested")
            let sourceAlias = try fixture.link("source-alias", to: fixture.source)
            let nestedAlias = try fixture.link("nested-alias", to: nested)
            let rootAlias = try fixture.link("root-alias", to: fixture.root)
            try expect(.overlap, source: fixture.source, destination: sourceAlias)
            try expect(.overlap, source: sourceAlias, destination: fixture.source)
            try expect(.overlap, source: fixture.source, destination: nestedAlias)
            try expect(.overlap, source: nestedAlias, destination: sourceAlias)
            try expect(.overlap, source: sourceAlias, destination: rootAlias)
            try expect(.overlap, source: fixture.source,
                       destination: sourceAlias.appendingPathComponent("missing/child", isDirectory: true))
            try validator.validate(sourceDirectory: sourceAlias, destinationDirectory: fixture.destination)
        }
    }

    func testIndependentSymlinkParentWithAbsentDestinationIsAllowedWithoutMutation() throws {
        try withFixture { fixture in
            let alias = try fixture.link("destination-alias", to: fixture.destination)
            let proposed = alias.appendingPathComponent("missing/child", isDirectory: true)
            try validator.validate(sourceDirectory: fixture.source, destinationDirectory: proposed)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
        }
    }

    func testDanglingSymlinkAndDescendantOfDanglingSymlinkAreRejected() throws {
        try withFixture { fixture in
            let missing = fixture.root.appendingPathComponent("missing", isDirectory: true)
            let dangling = try fixture.link("dangling", to: missing)
            try expect(.destinationUnavailable, source: fixture.source, destination: dangling, posix: ENOENT)
            try expect(.destinationUnavailable, source: fixture.source,
                       destination: dangling.appendingPathComponent("child"), posix: ENOENT)
            try expect(.sourceUnavailable, source: dangling, destination: fixture.destination, posix: ENOENT)
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        }
    }

    func testFilesAndDescendantsOfFilesAreRejected() throws {
        try withFixture { fixture in
            let file = fixture.root.appendingPathComponent("file")
            let data = Data("retained fixture".utf8)
            try data.write(to: file)
            let alias = try fixture.link("file-alias", to: file)
            for destination in [file, alias, file.appendingPathComponent("child")] {
                try expect(.destinationUnavailable, source: fixture.source, destination: destination, posix: ENOTDIR)
            }
            try expect(.sourceUnavailable, source: file, destination: fixture.destination, posix: ENOTDIR)
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func testSymlinkLoopIsRejected() throws {
        try withFixture { fixture in
            let first = fixture.root.appendingPathComponent("loop-first")
            let second = try fixture.link("loop-second", to: first)
            _ = try fixture.link("loop-first", to: second)
            try expect(.destinationUnavailable, source: fixture.source, destination: first, posix: ELOOP)
            try expect(.sourceUnavailable, source: first, destination: fixture.destination, posix: ELOOP)
        }
    }

    func testMissingSourceIsRejected() throws {
        try withFixture { fixture in
            try expect(.sourceUnavailable, source: fixture.root.appendingPathComponent("absent"),
                       destination: fixture.destination, posix: ENOENT)
        }
    }

    func testRemoteAndDotComponentURLsAreRejected() throws {
        try withFixture { fixture in
            let remote = try XCTUnwrap(URL(string: "https://example.invalid/shots"))
            let remoteFile = try XCTUnwrap(URL(string: "file://remote.invalid/shots"))
            let dot = try XCTUnwrap(URL(string: fixture.root.absoluteString + "source/../destination/"))
            for invalid in [remote, remoteFile, dot] {
                try expect(.invalidPath, source: fixture.source, destination: invalid)
                try expect(.invalidPath, source: invalid, destination: fixture.destination)
            }
        }
    }

    func testCaseInsensitiveAliasIsRejectedWhenVolumeSupportsIt() throws {
        try withFixture { fixture in
            let mixed = try fixture.directory("CaseSensitiveName")
            let alias = fixture.root.appendingPathComponent("casesensitivename", isDirectory: true)
            guard FileManager.default.fileExists(atPath: alias.path) else {
                throw XCTSkip("Fixture volume is case sensitive.")
            }
            try expect(.overlap, source: mixed, destination: alias)
        }
    }

    func testPermissionFailureDoesNotFallBackToMoreDistantParent() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root can bypass fixture permission restrictions.") }
        try withFixture { fixture in
            XCTAssertEqual(chmod(fixture.destination.path, 0), 0)
            defer { _ = chmod(fixture.destination.path, 0o700) }
            try expect(.destinationUnavailable, source: fixture.source,
                       destination: fixture.destination.appendingPathComponent("absent"), posix: EACCES)
        }
    }

    private func expect(
        _ code: ScreenshotDestinationValidationFailure.Code, source: URL, destination: URL,
        posix: Int32? = nil, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertThrowsError(try validator.validate(sourceDirectory: source, destinationDirectory: destination),
                             file: file, line: line) { error in
            guard let error = error as? ScreenshotDestinationValidationFailure else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
            XCTAssertEqual(error.code, code, file: file, line: line)
            if let posix { XCTAssertEqual(error.posixCode, posix, file: file, line: line) }
        }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try body(fixture)
    }

    private struct Fixture {
        let root: URL
        var source: URL { root.appendingPathComponent("source", isDirectory: true) }
        var destination: URL { root.appendingPathComponent("destination", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ShotDropDestination-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            _ = try directory("source")
            _ = try directory("destination")
        }

        func directory(_ relativePath: String) throws -> URL {
            let url = root.appendingPathComponent(relativePath, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func link(_ name: String, to target: URL) throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            return url
        }
    }
}
