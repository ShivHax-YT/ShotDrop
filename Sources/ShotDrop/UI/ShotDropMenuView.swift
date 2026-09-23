import AppKit
import SwiftUI

@MainActor
struct ShotDropMenuView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("ShotDrop")
        Text("Screenshot capture is not active yet")
            .foregroundStyle(.secondary)

        Divider()

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
