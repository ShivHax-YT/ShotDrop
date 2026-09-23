import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShotDrop

final class ScreenshotFileSystemTests: XCTestCase {
    func testResolverFallsBackForAbsentBlankAndRelativeLocations() {
        let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        for location in [nil, "", " \n ", "Pictures/Shots", "~someone/Shots", "bad\0path"] as [String?] {
            XCTAssertEqual(ScreenshotDirectoryResolver.resolve(location: location, homeDirectory: home), desktop)
        }
    }

    func testResolverExpandsHomeAndNormalizesAbsolutePaths() {
        let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
        XCTAssertEqual(ScreenshotDirectoryResolver.resolve(location: "~", homeDirectory: home), home)
        XCTAssertEqual(ScreenshotDirectoryResolver.resolve(location: "~/Pictures/Shots", homeDirectory: home).path,
                       "/Users/fixture/Pictures/Shots")
        XCTAssertEqual(ScreenshotDirectoryResolver.resolve(location: " /tmp/one/../Shots\n", homeDirectory: home).path,
                       "/tmp/Shots")
    }

    func testFilterAcceptsOnlyVisibleImageCandidates() {
        for name in ["Shot.PNG", "Shot.jpg", "Shot.JPEG", "Shot.heic"] {
            XCTAssertTrue(ScreenshotFileFilter.accepts(URL(fileURLWithPath: "/tmp/\(name)")))
        }
        for name in [".Shot.png", "Shot.png.tmp", "Shot.gif", "Shot", "._Shot.jpg"] {
            XCTAssertFalse(ScreenshotFileFilter.accepts(URL(fileURLWithPath: "/tmp/\(name)")))
        }
        XCTAssertFalse(ScreenshotFileFilter.accepts(URL(fileURLWithPath: "/tmp/folder.png", isDirectory: true)))
        XCTAssertFalse(ScreenshotFileFilter.accepts(URL(string: "https://example.test/shot.png")!))
    }

    func testCompleteImageWithTrueOrIntegerMetadataIsRecognized() throws {
        try withDirectory { directory in
            let reader = LocalScreenshotFileSystem()
            for (index, marker) in [NSNumber(value: true), NSNumber(value: 1)].enumerated() {
                let file = directory.appendingPathComponent("shot-\(index).png")
                try writeImage(to: file)
                try setMetadata(marker, at: file)
                let snapshot = try XCTUnwrap(reader.snapshot(at: file))
                XCTAssertTrue(snapshot.isScreenshot)
                XCTAssertTrue(snapshot.isCompleteImage)
                XCTAssertGreaterThan(snapshot.size, 0)
                XCTAssertEqual(try reader.identity(at: file), snapshot.identity)
                XCTAssertEqual(try reader.snapshot(at: file), snapshot)
            }
        }
    }

    func testMissingFalseMalformedAndOversizeMetadataAreRejected() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("shot.png")
            try writeImage(to: file)
            let reader = LocalScreenshotFileSystem()
            XCTAssertFalse(try XCTUnwrap(reader.snapshot(at: file)).isScreenshot)
            for marker: Any in [false, 0, 2, "true", ["value": true]] {
                try setMetadata(marker, at: file)
                let snapshot = try XCTUnwrap(reader.snapshot(at: file))
                XCTAssertFalse(snapshot.isScreenshot)
                XCTAssertFalse(snapshot.isCompleteImage)
            }
            for data in [Data("not a plist".utf8), Data(repeating: 1, count: 8_192)] {
                try setRawMetadata(data, at: file)
                XCTAssertFalse(try XCTUnwrap(reader.snapshot(at: file)).isScreenshot)
            }
            let xml = try PropertyListSerialization.data(fromPropertyList: true, format: .xml, options: 0)
            try setRawMetadata(xml, at: file)
            XCTAssertFalse(try XCTUnwrap(reader.snapshot(at: file)).isScreenshot)
        }
    }

    func testIncompleteMarkedImageIsNotReady() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("incomplete.png")
            try writeImage(to: file)
            let data = try Data(contentsOf: file)
            try Data(data.prefix(24)).write(to: file)
            try setMetadata(true, at: file)
            let snapshot = try XCTUnwrap(LocalScreenshotFileSystem().snapshot(at: file))
            XCTAssertTrue(snapshot.isScreenshot)
            XCTAssertFalse(snapshot.isCompleteImage)
        }
    }

    func testOutputTokenIsReadFromScreenshotAndSurvivesRename() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("output.png")
            let token = UUID()
            try writeImage(to: file)
            try setMetadata(true, at: file)
            try setOutputMarker(Data(token.uuidString.utf8), at: file)
            let reader = LocalScreenshotFileSystem()
            let snapshot = try XCTUnwrap(reader.snapshot(at: file))
            XCTAssertEqual(snapshot.outputToken, token)
            XCTAssertTrue(snapshot.isScreenshot)
            XCTAssertTrue(snapshot.isCompleteImage)
            let renamed = directory.appendingPathComponent("renamed.png")
            try FileManager.default.moveItem(at: file, to: renamed)
            XCTAssertEqual(try reader.snapshot(at: renamed)?.outputToken, token)
        }
    }

    func testMissingMalformedAndOversizeOutputMarkersDoNotSuppressScreenshotMetadata() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("shot.png")
            try writeImage(to: file)
            try setMetadata(true, at: file)
            let reader = LocalScreenshotFileSystem()
            XCTAssertNil(try reader.snapshot(at: file)?.outputToken)
            for marker in [Data(), Data("invalid".utf8), Data(repeating: 65, count: 36),
                           Data(repeating: 255, count: 36), Data(repeating: 65, count: 8_192),
                           Data((UUID().uuidString + "\0").utf8)] {
                try setOutputMarker(marker, at: file)
                let snapshot = try XCTUnwrap(reader.snapshot(at: file))
                XCTAssertNil(snapshot.outputToken)
                XCTAssertTrue(snapshot.isScreenshot)
                XCTAssertTrue(snapshot.isCompleteImage)
            }
        }
    }

    func testSymlinksDirectoriesAndMissingFilesAreNotCandidates() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("shot.png")
            try writeImage(to: file)
            try setMetadata(true, at: file)
            let link = directory.appendingPathComponent("link.png")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            let folder = directory.appendingPathComponent("folder.png")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let reader = LocalScreenshotFileSystem()
            for url in [link, folder, directory.appendingPathComponent("missing.png")] {
                XCTAssertNil(try reader.snapshot(at: url))
                XCTAssertNil(try reader.identity(at: url))
            }
        }
    }

    func testDirectoryContentsAreFlatAndExcludeHiddenStagingFiles() throws {
        try withDirectory { directory in
            try Data().write(to: directory.appendingPathComponent("shot.PNG"))
            try Data().write(to: directory.appendingPathComponent(".staging.png"))
            try Data().write(to: directory.appendingPathComponent("notes.txt"))
            let nested = directory.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            try Data().write(to: nested.appendingPathComponent("nested.png"))
            XCTAssertEqual(try LocalScreenshotFileSystem().contents(of: directory).map(\.lastPathComponent), ["shot.PNG"])
        }
    }

    func testIdentitySurvivesRenameButChangesForReplacement() throws {
        try withDirectory { directory in
            let original = directory.appendingPathComponent("shot.png")
            try writeImage(to: original)
            let reader = LocalScreenshotFileSystem()
            let identity = try XCTUnwrap(reader.identity(at: original))
            let moved = directory.appendingPathComponent("renamed.png")
            try FileManager.default.moveItem(at: original, to: moved)
            XCTAssertEqual(try reader.identity(at: moved), identity)
            try writeImage(to: original)
            XCTAssertNotEqual(try reader.identity(at: original), identity)
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotDropFixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func writeImage(to url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
                                                                       UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func setMetadata(_ value: Any, at url: URL) throws {
        try setRawMetadata(PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0), at: url)
    }

    private func setRawMetadata(_ data: Data, at url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { path in
            data.withUnsafeBytes { bytes in
                setxattr(path!, "com.apple.metadata:kMDItemIsScreenCapture", bytes.baseAddress, bytes.count, 0, 0)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func setOutputMarker(_ data: Data, at url: URL) throws {
        let result = data.withUnsafeBytes { bytes in
            setxattr(url.path, ScreenshotOutputMarker.attributeName, bytes.baseAddress, bytes.count, 0, 0)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
