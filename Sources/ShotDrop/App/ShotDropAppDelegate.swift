import AppKit
import OSLog

@MainActor
final class ShotDropAppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.macfleet.shotdrop", category: "App")
    let settings = AppSettings()
    let launchAtLogin = LaunchAtLoginController()
    let history = RecentHistoryStore()
    let library = ShotDropLibraryWindow()
    func showLibrary() { library.show(runtime: runtime, recents: recentController, setup: setupController.show) }
    lazy var recentController = RecentMenuController(settings: settings, history: history)
    lazy var runtime = ShotDropRuntime(settings: settings, history: history, recents: recentController)
    lazy var setupController = ShotDropSetupWindowController(settings: settings, gate: ProductionSetupGate(start: { [weak self] binding in
        await self?.runtime.start(binding) ?? false
    }), onClose: { [weak self] in
        guard let self else { return }
        if !self.settings.hasCompletedSetup { self.runtime.suspend(message: "Finish setup to start copying and saving") }
        else { self.showLibrary() }
    })

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        logger.info("ShotDrop started. Screenshot processing starts after folder setup.")
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        runtime.setOpenRecentsHandler { [weak self] in self?.showLibrary() }
        if settings.hasCompletedSetup { runtime.resume() }
        if settings.shouldPresentSetupOnLaunch {
            setupController.show()
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return .terminateNow }
        guard recentController.prepareToQuit() else { return .terminateCancel }
        Task { await runtime.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if settings.hasCompletedSetup { showLibrary() } else { setupController.show() }
        return true
    }
}
