import AppKit
import SwiftUI

@main
@MainActor
struct ShotDropApp: App {
    @NSApplicationDelegateAdaptor(ShotDropAppDelegate.self) private var appDelegate
    @State private var settings = AppSettings()
    @State private var launchAtLogin = LaunchAtLoginController()

    var body: some Scene {
        MenuBarExtra("ShotDrop", systemImage: "rectangle.on.rectangle") {
            ShotDropMenuView()
        }

        Settings {
            ShotDropSettingsView(settings: settings, launchAtLogin: launchAtLogin)
        }
        .defaultSize(width: 520, height: 560)
    }
}
