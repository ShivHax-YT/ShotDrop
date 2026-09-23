import Foundation
import XCTest
@testable import ShotDrop

final class AppSettingsTests: XCTestCase {
    @MainActor
    func testFreshSettingsUseProductDefaults() async throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            XCTAssertEqual(settings.destinationPath, FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures/ShotDrop", isDirectory: true).path)
            XCTAssertEqual(settings.renameTemplate, "{app}-{date}-{time}")
            XCTAssertEqual(settings.copyMode, .both)
            XCTAssertFalse(settings.organizeByDate)
            XCTAssertFalse(settings.playSound)
            XCTAssertFalse(settings.hasPresentedSetup)
            XCTAssertTrue(settings.showShotDropThumbnail)
        }
    }

    @MainActor
    func testChangesSurviveReloadAndBooleanReset() async throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.destinationPath = "/tmp/ShotDrop Test Destination"
            settings.renameTemplate = "{date} {time}"
            settings.copyMode = .file
            settings.organizeByDate = true
            settings.playSound = true
            settings.hasPresentedSetup = true
            settings.showShotDropThumbnail = false

            let reloaded = AppSettings(defaults: defaults)
            XCTAssertEqual(reloaded.destinationPath, settings.destinationPath)
            XCTAssertEqual(reloaded.renameTemplate, settings.renameTemplate)
            XCTAssertEqual(reloaded.copyMode, .file)
            XCTAssertTrue(reloaded.organizeByDate)
            XCTAssertTrue(reloaded.playSound)
            XCTAssertTrue(reloaded.hasPresentedSetup)
            XCTAssertFalse(reloaded.showShotDropThumbnail)

            reloaded.organizeByDate = false
            reloaded.playSound = false
            reloaded.copyMode = .image
            reloaded.showShotDropThumbnail = true
            let reset = AppSettings(defaults: defaults)
            XCTAssertFalse(reset.organizeByDate)
            XCTAssertFalse(reset.playSound)
            XCTAssertEqual(reset.copyMode, .image)
            XCTAssertTrue(reset.showShotDropThumbnail)
        }
    }

    @MainActor
    func testUnrecognizedCopyModeFallsBackWithoutLosingOtherSettings() async throws {
        try withDefaults { defaults in
            defaults.set("future-mode", forKey: AppSettings.Key.copyMode)
            defaults.set("{date}", forKey: AppSettings.Key.renameTemplate)
            let settings = AppSettings(defaults: defaults)
            XCTAssertEqual(settings.copyMode, .both)
            XCTAssertEqual(settings.renameTemplate, "{date}")
        }
    }

    @MainActor
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "com.macfleet.shotdrop.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
