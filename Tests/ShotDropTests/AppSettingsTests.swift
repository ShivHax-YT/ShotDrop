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
            XCTAssertFalse(settings.hasCompletedSetup)
            XCTAssertFalse(settings.hasDeferredSetup)
            XCTAssertTrue(settings.shouldPresentSetupOnLaunch)
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
    func testPreviouslyPresentedIncompleteSetupStillAppearsOnLaunchWithoutResettingPreferences() async throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: AppSettings.Key.hasPresentedSetup)
            defaults.set("/tmp/User Selected Destination", forKey: AppSettings.Key.destinationPath)
            defaults.set("{date} screenshot", forKey: AppSettings.Key.renameTemplate)
            defaults.set(CopyMode.file.rawValue, forKey: AppSettings.Key.copyMode)
            defaults.set(false, forKey: AppSettings.Key.showShotDropThumbnail)
            let settings = AppSettings(defaults: defaults)
            XCTAssertTrue(settings.hasPresentedSetup)
            XCTAssertFalse(settings.hasCompletedSetup)
            XCTAssertFalse(settings.hasDeferredSetup)
            XCTAssertTrue(settings.shouldPresentSetupOnLaunch)
            settings.hasPresentedSetup = true
            let reopened = AppSettings(defaults: defaults)
            XCTAssertTrue(reopened.shouldPresentSetupOnLaunch)
            XCTAssertEqual(reopened.destinationPath, "/tmp/User Selected Destination")
            XCTAssertEqual(reopened.renameTemplate, "{date} screenshot")
            XCTAssertEqual(reopened.copyMode, .file)
            XCTAssertFalse(reopened.showShotDropThumbnail)
        }
    }

    @MainActor
    func testOnlyExplicitCompletionSuppressesAutomaticSetupPresentation() async throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.hasPresentedSetup = true
            XCTAssertTrue(settings.shouldPresentSetupOnLaunch)
            settings.recordSetupCompletion(ifTerminalSuccess: false)
            XCTAssertTrue(settings.shouldPresentSetupOnLaunch)
            settings.recordSetupCompletion(ifTerminalSuccess: true)
            XCTAssertTrue(settings.hasCompletedSetup)
            XCTAssertFalse(settings.shouldPresentSetupOnLaunch)
            let reloaded = AppSettings(defaults: defaults)
            XCTAssertTrue(reloaded.hasCompletedSetup)
            XCTAssertFalse(reloaded.shouldPresentSetupOnLaunch)
            XCTAssertTrue(reloaded.hasPresentedSetup)
        }
    }

    @MainActor
    func testExplicitDeferralPersistsWithoutClaimingCompletionAndReopenClearsIt() async throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.hasPresentedSetup = true
            settings.destinationPath = "/tmp/Kept Choice"
            settings.recordSetupDeferral()
            XCTAssertTrue(settings.hasDeferredSetup)
            XCTAssertFalse(settings.hasCompletedSetup)
            XCTAssertFalse(settings.shouldPresentSetupOnLaunch)
            let deferred = AppSettings(defaults: defaults)
            XCTAssertTrue(deferred.hasDeferredSetup)
            XCTAssertFalse(deferred.hasCompletedSetup)
            XCTAssertFalse(deferred.shouldPresentSetupOnLaunch)
            deferred.resumeSetupPresentation()
            let reopened = AppSettings(defaults: defaults)
            XCTAssertFalse(reopened.hasDeferredSetup)
            XCTAssertFalse(reopened.hasCompletedSetup)
            XCTAssertTrue(reopened.shouldPresentSetupOnLaunch)
            XCTAssertEqual(reopened.destinationPath, "/tmp/Kept Choice")
        }
    }

    @MainActor
    func testCompletionClearsDeferralButReopeningDoesNotClearCompletion() async throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.recordSetupDeferral()
            settings.recordSetupCompletion(ifTerminalSuccess: false)
            XCTAssertTrue(settings.hasDeferredSetup)
            XCTAssertFalse(settings.hasCompletedSetup)
            settings.recordSetupCompletion(ifTerminalSuccess: true)
            XCTAssertFalse(settings.hasDeferredSetup)
            XCTAssertTrue(settings.hasCompletedSetup)
            settings.resumeSetupPresentation()
            let reopened = AppSettings(defaults: defaults)
            XCTAssertTrue(reopened.hasCompletedSetup)
            XCTAssertFalse(reopened.hasDeferredSetup)
            XCTAssertFalse(reopened.shouldPresentSetupOnLaunch)
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
