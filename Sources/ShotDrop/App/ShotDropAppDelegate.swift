import AppKit
import OSLog

@MainActor
final class ShotDropAppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.macfleet.shotdrop", category: "App")
    let settings = AppSettings()
    let launchAtLogin = LaunchAtLoginController()
    lazy var setupController = ShotDropSetupWindowController(settings: settings)
    lazy var recentController = RecentMenuController(settings: settings)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        logger.info("ShotDrop started. Screenshot processing remains inactive pending setup and pipeline acceptance.")
        if settings.shouldPresentSetupOnLaunch {
            setupController.show()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        setupController.show()
        return true
    }
}
