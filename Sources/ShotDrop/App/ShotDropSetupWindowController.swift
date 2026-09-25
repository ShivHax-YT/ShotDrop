import AppKit
import SwiftUI

/// Owns one nonmodal setup window. Presentation never starts screenshot processing.
@MainActor
final class ShotDropSetupWindowController: NSObject, NSWindowDelegate {
    let model: ShotDropSetupModel
    private let settings: AppSettings
    private var window: NSWindow?
    private let onClose: () -> Void
    private var initialDestinationPath: String?

    init(settings: AppSettings, gate: any ShotDropSetupReadinessGating, onClose: @escaping () -> Void) {
        self.settings = settings
        self.onClose = onClose
        model = ShotDropSetupModel(destinationURL: URL(fileURLWithPath: settings.destinationPath,
                                                      isDirectory: true),
                                   service: ProductionSetupAccess(createDefaultIfMissing: true), gate: gate)
        super.init()
    }

    func show() {
        settings.resumeSetupPresentation()
        // Setup is a first-run task with a discoverable Dock presence while open.
        // Closing returns ShotDrop to its normal menu-bar-only presentation.
        NSApplication.shared.setActivationPolicy(.regular)
        if let window, window.isVisible {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let destination = URL(fileURLWithPath: settings.destinationPath, isDirectory: true)
        if model.destinationURL != destination {
            model.selectDestination(destination)
        }
        model.reopen()
        Task { await model.restoreReviewState() }
        initialDestinationPath = settings.destinationPath
        settings.hasPresentedSetup = true
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Set Up ShotDrop"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 420, height: 440)
            window.delegate = self
            window.contentView = NSHostingView(rootView: ShotDropSetupView(model: model) { [weak self] in
                self?.window?.close()
            })
            window.center()
            self.window = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        settings.recordSetupCompletion(ifTerminalSuccess:
            model.step == .test && !model.isPresented && !model.isDeferred)
        if settings.hasCompletedSetup, let source = model.sourceURL { settings.sourcePath = source.path }
        onClose()
        NSApplication.shared.setActivationPolicy(.accessory)
        // Closing the title-bar control is the same reversible deferral as Not Now.
        if model.isPresented {
            model.notNow()
        }
        if model.isDeferred { settings.recordSetupDeferral() }
        if let destination = model.destinationURL,
           settings.destinationPath == initialDestinationPath,
           destination.path != initialDestinationPath {
            settings.destinationPath = destination.path
        }
    }

    func destinationChangedInSettings(_ destination: URL) {
        // Settings and setup are nonmodal. A later explicit choice cancels any stale check.
        model.selectDestination(destination)
        initialDestinationPath = destination.path
    }
}
