import AppKit
import SwiftUI

@main
@MainActor
struct ShotDropApp: App {
    @NSApplicationDelegateAdaptor(ShotDropAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("ShotDrop", systemImage: "rectangle.on.rectangle") {
            ShotDropMenuView(controller: appDelegate.recentController,
                             preferredCopyMode: appDelegate.settings.copyMode,
                             onFinishSetup: appDelegate.setupController.show)
        }
        .menuBarExtraStyle(.window)

        Settings {
            ShotDropSettingsView(settings: appDelegate.settings,
                                 launchAtLogin: appDelegate.launchAtLogin,
                                 onFinishSetup: appDelegate.setupController.show,
                                 onDestinationChange: appDelegate.setupController.destinationChangedInSettings)
        }
        .defaultSize(width: 520, height: 560)
    }
}
