import AppKit
import SwiftUI

@MainActor
struct ShotDropMenuView: View {
    @Environment(\.openSettings) private var openSettings
    var controller: RecentMenuController
    var preferredCopyMode: CopyMode
    var onFinishSetup: () -> Void

    var body: some View {
        RecentMenuPanel(rows: controller.rows, status: controller.status,
                        historyUnavailable: controller.historyUnavailable,
                        preferredCopyMode: preferredCopyMode,
                        onAction: controller.perform,
                        onClearHistory: controller.clearHistory,
                        onFinishSetup: onFinishSetup,
                        onOpenSettings: {
                            NSApplication.shared.activate(ignoringOtherApps: true)
                            openSettings()
                        },
                        onPanelVisible: controller.panelVisible,
                        onRowVisible: controller.rowVisible,
                        textCopyStates: controller.textCopy.states,
                        isRecognizingText: controller.textCopy.activeID != nil)
    }
}
