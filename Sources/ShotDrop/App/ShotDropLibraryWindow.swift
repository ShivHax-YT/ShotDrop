import AppKit
import SwiftUI

/// Opening the app after setup brings up its library; it never restarts onboarding.
@MainActor
final class ShotDropLibraryWindow {
    private var window: NSWindow?
    func show(runtime: ShotDropRuntime, recents: RecentMenuController, setup: @escaping () -> Void) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "ShotDrop"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 360, height: 420)
            window.contentView = NSHostingView(rootView: ShotDropMenuView(runtime: runtime, controller: recents,
                preferredCopyMode: runtime.settings.copyMode, onFinishSetup: setup))
            window.center(); self.window = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        recents.panelVisible(true)
    }
}
