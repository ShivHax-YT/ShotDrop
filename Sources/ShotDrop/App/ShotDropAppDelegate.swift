import AppKit
import OSLog

@MainActor
final class ShotDropAppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.macfleet.shotdrop", category: "App")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        logger.info("ShotDrop started. Screenshot processing is not active in this scaffold build.")
    }
}
