import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import ShotDrop

final class ScreenshotClipboardPreparationTests: XCTestCase {
    func testPNGPreparationRetainsExactEncodedBytesAndSelectedMode() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        for mode in CopyMode.allCases {
            let prepared = try await ScreenshotClipboardPreparer().prepare(fixture.request(mode))
            XCTAssertEqual(prepared.mode, mode)
            XCTAssertEqual(prepared.pngData, mode == .file ? nil : fixture.png)
            XCTAssertEqual(prepared.fileURL, mode == .image ? nil : fixture.saved)
            try await prepared.validateFileForPublication()
        }
    }

    func testJPEGBytesWithPNGFilenameAreNotMislabeled() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        try ClipboardTestFixture.imageData(type: .jpeg).write(to: fixture.source)
        await assertFailure(.unsupportedImage) {
            _ = try await ScreenshotClipboardPreparer().prepare(fixture.request(.image))
        }
        let file = try await ScreenshotClipboardPreparer().prepare(fixture.request(.file))
        XCTAssertNil(file.pngData)
        XCTAssertEqual(file.fileURL, fixture.saved)
    }

    func testIncompleteAndMalformedPNGsAreRejected() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        for bytes in [Data(), Data(fixture.png.prefix(24)), Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 0])] {
            try bytes.write(to: fixture.source)
            await assertFailure(.invalidImage) {
                _ = try await ScreenshotClipboardPreparer().prepare(fixture.request(.image))
            }
        }
    }

    func testSizeLimitFailsBeforeAllocatingImageBytes() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        await assertFailure(.imageTooLarge) {
            _ = try await ScreenshotClipboardPreparer(maximumPNGBytes: fixture.png.count - 1).prepare(fixture.request(.image))
        }
        let exact = try await ScreenshotClipboardPreparer(maximumPNGBytes: fixture.png.count).prepare(fixture.request(.image))
        XCTAssertEqual(exact.pngData, fixture.png)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.png)
    }

    func testSourceIdentityMismatchIsRejected() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        var request = fixture.request(.image)
        request.expectedIdentity = ScreenshotFileIdentity(device: 0, inode: 0, birthNanoseconds: 0)
        let invalid = request
        await assertFailure(.sourceChanged) {
            _ = try await ScreenshotClipboardPreparer().prepare(invalid)
        }
    }

    func testFileModeRequiresExplicitSurvivingURL() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        for mode in [CopyMode.file, .both] {
            let request = ScreenshotClipboardRequest(sourceURL: fixture.source, mode: mode)
            await assertFailure(.fileUnavailable) {
                _ = try await ScreenshotClipboardPreparer().prepare(request)
            }
        }
    }

    func testMissingRemoteDirectoryAndSymlinkFilesAreRejected() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        let link = fixture.root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.source)
        let badURLs = [fixture.root.appendingPathComponent("missing.png"), fixture.root,
                       link, try XCTUnwrap(URL(string: "https://example.invalid/shot.png"))]
        for url in badURLs {
            let source = ScreenshotClipboardRequest(sourceURL: url, mode: .image)
            await assertFailure(.invalidSource) {
                _ = try await ScreenshotClipboardPreparer().prepare(source)
            }
            let file = ScreenshotClipboardRequest(sourceURL: fixture.source, mode: .file, survivingFileURL: url)
            await assertFailure(.fileUnavailable) {
                _ = try await ScreenshotClipboardPreparer().prepare(file)
            }
        }
    }

    func testPreparedImageIsIndependentOfLaterSourceMoveAndChange() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        let prepared = try await ScreenshotClipboardPreparer().prepare(fixture.request(.image))
        let moved = fixture.root.appendingPathComponent("moved.png")
        try FileManager.default.moveItem(at: fixture.source, to: moved)
        try Data("replacement".utf8).write(to: fixture.source)
        XCTAssertEqual(prepared.pngData, fixture.png)
        try await prepared.validateFileForPublication()
        XCTAssertEqual(try Data(contentsOf: moved), fixture.png)
    }

    func testMissingOrReplacedFileAfterPreparationFailsRevalidation() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        let prepared = try await ScreenshotClipboardPreparer().prepare(fixture.request(.both))
        let moved = fixture.root.appendingPathComponent("moved-saved.png")
        try FileManager.default.moveItem(at: fixture.saved, to: moved)
        await assertFailure(.fileUnavailable) { try await prepared.validateFileForPublication() }
        try fixture.png.write(to: fixture.saved)
        await assertFailure(.fileUnavailable) { try await prepared.validateFileForPublication() }
        XCTAssertEqual(prepared.pngData, fixture.png)
    }

    func testSelectedFileIdentityMismatchIsRejected() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        var request = fixture.request(.file)
        request.survivingFileIdentity = try LocalScreenshotFileSystem().identity(at: fixture.source)
        let invalid = request
        await assertFailure(.fileUnavailable) { _ = try await ScreenshotClipboardPreparer().prepare(invalid) }
    }

    func testCancelledPreparationDoesNotReturnPayload() async throws {
        let fixture = try ClipboardTestFixture()
        defer { fixture.cleanUp() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ScreenshotClipboardPreparer().prepare(fixture.request(.image))
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled work must not prepare a publication")
        } catch is CancellationError { }
    }

    private func assertFailure(
        _ code: ScreenshotClipboardFailure.Code,
        operation: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(code)", file: file, line: line)
        } catch let error as ScreenshotClipboardFailure {
            XCTAssertEqual(error.code, code, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
