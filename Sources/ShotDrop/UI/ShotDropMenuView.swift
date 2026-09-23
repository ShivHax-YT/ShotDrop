import AppKit
import SwiftUI

@MainActor
struct ShotDropMenuView: View {
    @Environment(\.openSettings) private var openSettings
    var onFinishSetup: () -> Void

    var body: some View {
        Text("ShotDrop")
        Text("Setup needed")
        Text("ShotDrop is not watching for screenshots.")
            .foregroundStyle(.secondary)

        Divider()

        Button("Finish Setup…", action: onFinishSetup)

        Button("Settings…") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit ShotDrop") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
