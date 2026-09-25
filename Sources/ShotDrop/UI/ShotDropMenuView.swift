import AppKit
import SwiftUI

@MainActor
struct ShotDropMenuView: View {
    @Environment(\.openSettings) private var openSettings
    var runtime: ShotDropRuntime
    var controller: RecentMenuController
    var preferredCopyMode: CopyMode
    var onFinishSetup: () -> Void

    var body: some View {
        VStack(spacing: 0) {
        HStack {
            Button(runtime.settings.isPaused ? "Resume" : "Pause", action: runtime.togglePause)
                .disabled(!runtime.settings.hasCompletedSetup)
            Menu("Capture") {
                Button("Screen · ⌃⌥3") { runtime.capture.capture(.screen) }
                Button("Selection · ⌃⌥4") { runtime.capture.capture(.region) }
                Button("Window · ⌃⌥5") { runtime.capture.capture(.window) }
            }.disabled(!runtime.isRunning)
            Spacer()
            Button("About") { NSApplication.shared.orderFrontStandardAboutPanel(nil) }
        }.padding(.horizontal, 16).padding(.top, 10)
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
                        isRecognizingText: controller.textCopy.activeID != nil,
                        setupTitle: runtime.settings.hasCompletedSetup ? "Setup…" : "Finish Setup…",
                        pinCount: controller.pinItems.count,
                        onManagePins: controller.showPins,
                        pinFeedback: controller.pinFeedback,
                        annotationFeedback: controller.annotationFeedback)
        }
    }
}
