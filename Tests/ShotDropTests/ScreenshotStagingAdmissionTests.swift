import Darwin
import Foundation
import XCTest
@testable import ShotDrop

final class ScreenshotStagingAdmissionTests: XCTestCase {
    func testMissingRegistryPausesBeforeCreatingDestinationOrMutatingSource() async throws {
        let root = try resolvedStagingTemporaryDirectory().appendingPathComponent("ShotDropAdmission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        let source = sourceDirectory.appendingPathComponent("original.png")
        let original = Data("retained original".utf8)
        try original.write(to: source)
        let registry = root.appendingPathComponent("missing-registry")
        let destination = root.appendingPathComponent("missing-output/nested")
        let pool = ScreenshotStagingPool(registryDirectory: registry)
        let service = ScreenshotSaveService(organizer: ScreenshotOrganizer(
            fileSystem: LocalScreenshotOrganizationFileSystem(pool: pool)))
        let request = ScreenshotSaveRequest(organization: ScreenshotOrganizationRequest(
            sourceURL: source, destinationRoot: destination, template: "capture",
            namingContext: ScreenshotNamingContext(appName: "Fixture", capturedAt: Date(timeIntervalSince1970: 0),
                                                   timeZone: TimeZone(secondsFromGMT: 0)!)),
            sourceDirectoryURL: sourceDirectory, destinationAccess: .userApproved)
        let outcome = await service.save(request)
        guard case .failed(let failure) = outcome else { return XCTFail("Unenrolled staging must pause saving") }
        XCTAssertEqual(failure.reason, .stagingPaused)
        XCTAssertEqual(failure.originalStatus, .available)
        XCTAssertTrue(failure.actions.contains(.revealOriginal))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: registry.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("missing-output").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source"])
    }
}
