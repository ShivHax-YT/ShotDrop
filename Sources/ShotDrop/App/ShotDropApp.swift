import AppKit
import SwiftUI

@main
@MainActor
struct ShotDropApp: App {
    @NSApplicationDelegateAdaptor(ShotDropAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("ShotDrop", systemImage: "rectangle.on.rectangle") {
            ShotDropMenuView(runtime: appDelegate.runtime, controller: appDelegate.recentController,
                             preferredCopyMode: appDelegate.settings.copyMode,
                             onFinishSetup: appDelegate.setupController.show)
        }
        .menuBarExtraStyle(.window)

        Settings {
            ShotDropSettingsView(runtime: appDelegate.runtime, settings: appDelegate.settings,
                                 launchAtLogin: appDelegate.launchAtLogin,
                                 onFinishSetup: appDelegate.setupController.show,
                                 onDestinationChange: { destination in
                                     appDelegate.runtime.suspend(message: "Save folder changed · Complete Setup")
                                     appDelegate.setupController.destinationChangedInSettings(destination)
                                     appDelegate.setupController.show()
                                 })
        }
        .defaultSize(width: 520, height: 560)
    }
}
