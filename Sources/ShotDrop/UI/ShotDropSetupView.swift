import AppKit
import SwiftUI

/// Folder selection and guidance only. The model owns every access and readiness gate.
@MainActor
struct ShotDropSetupView: View {
    let model: ShotDropSetupModel
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title2) private var titleSize = 22.0
    @ScaledMetric(relativeTo: .body) private var bodySize = 13.0
    @ScaledMetric(relativeTo: .caption) private var pathSize = 12.0
    @ScaledMetric(relativeTo: .body) private var buttonHeight = 32.0
    @State private var movingForward = true
    @State private var choosingFolder = false
    @State private var needsStepKeyboardFocus = false
    @State private var windowReference = SetupWindowReference()
    @FocusState private var keyboardFocus: Control?
    @AccessibilityFocusState private var accessibilityFocus: AccessibilityTarget?

    private enum Control: Hashable {
        case destinationPicker, sourcePicker, sourceConfirmation, primary
    }

    private enum AccessibilityTarget: Hashable {
        case heading(Int), destinationPicker, sourcePicker, status
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Step \(model.step.rawValue + 1) of 4")
                        .font(.system(size: pathSize))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.system(size: titleSize, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($accessibilityFocus, equals: .heading(model.step.rawValue))
                        .accessibilityIdentifier("setup.heading")
                    stepContent
                    if let message = recoveryMessage ?? model.statusMessage, !message.isEmpty {
                        Label {
                            Text(message)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: "info.circle")
                        }
                        .accessibilityIdentifier("setup.status")
                        .accessibilityFocused($accessibilityFocus, equals: .status)
                    }
                    if hasAccessDenial {
                        accessRecovery
                    }
                    if model.isBusy {
                        ProgressView("Checking folder access…")
                            .controlSize(.small)
                            .accessibilityIdentifier("setup.progress")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .id(model.step)
                .transition(stepTransition)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.step)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    secondaryActions
                    Spacer(minLength: 16)
                    primaryAction
                }
                VStack(alignment: .leading, spacing: 8) {
                    secondaryActions
                    primaryAction
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .font(.system(size: bodySize))
        .controlSize(.large)
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(SetupWindowReader(reference: windowReference).frame(width: 0, height: 0))
        .onAppear { focusCurrentStep() }
        .onChange(of: model.step) { _, _ in focusCurrentStep() }
        .onChange(of: model.defaultPreparationResult) { _, result in
            if result != nil { accessibilityFocus = .status }
            if model.showsPausedSetup { keyboardFocus = .primary }
        }
        .onChange(of: model.isBusy) { _, busy in
            if !busy, needsStepKeyboardFocus { focusStepControl() }
        }
        .accessibilityAction(.escape) { deferSetup() }
    }

    private var title: String {
        switch model.step {
        case .welcome: "Prepare your screenshot folders"
        case .destination: "Where should screenshots go?"
        case .source:
            if model.showsPausedSetup { "Saving is paused" }
            else if model.sourceIssue == .denied { "Screenshot folder access needed" }
            else if model.sourceIssue == .missing || model.sourceIssue == .changed { "Screenshot folder unavailable" }
            else { model.isSourceLocationUnknown ? "Screenshot location unknown" : "Allow access to your screenshot folder." }
        case .test: model.canRunTest ? "Take a screenshot to try it." : "Saving checks are pending"
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .welcome:
            paragraph("ShotDrop is designed to copy each screenshot and save it in your chosen folder, so it is ready to paste and easy to find.")
            paragraph("Automatic copying and saving are not available in this build. You can keep your save destination for later.")
            paragraph("Your original screenshots stay where they are. You can return to setup from the ShotDrop menu.")
                .foregroundStyle(.secondary)
        case .destination:
            paragraph(model.proposesSupportedDefault
                ? "Pictures/ShotDrop is the proposed default on supported local setups. After you confirm the screenshot source, ShotDrop can check and prepare this folder. Saving stays paused until the remaining setup checks and automatic processing are complete."
                : "This folder is selected for review. Choosing it does not approve automatic saving. ShotDrop will check access when you continue; macOS may ask for permission.")
            if let destination = model.destinationURL {
                path(destination, label: model.destinationStatusLabel)
            }
            Button("Choose Another Folder…") { chooseFolder(.destinationPicker) }
                .frame(minHeight: buttonHeight)
                .disabled(model.isBusy || choosingFolder)
                .focused($keyboardFocus, equals: .destinationPicker)
                .accessibilityFocused($accessibilityFocus, equals: .destinationPicker)
                .accessibilityIdentifier("setup.chooseDestination")
            paragraph("The folder picker opens only when you choose it. No new folder is created by this step.")
                .foregroundStyle(.secondary)
        case .source:
            paragraph("Press Shift–Command–5, then look in Options > Save to. Confirm that the folder below is where macOS currently saves your screenshots.")
            if model.proposesSupportedDefault {
                paragraph("Prepare Default Folder may create Pictures/ShotDrop after its checks pass. Existing or interrupted setup folders are kept for review. Your originals stay in place.")
            }
            if let source = model.sourceURL {
                paragraph("ShotDrop needs to read this folder to find new screenshots. macOS may ask for access when you continue.")
                path(source, label: model.isSourceLocationUnknown ? "Previously selected screenshot folder" : "Screenshot folder to confirm")
                Toggle("This is my current screenshot folder", isOn: Binding(
                    get: { model.sourceConfirmedByUser },
                    set: { model.confirmCurrentSource($0) }
                ))
                .toggleStyle(.checkbox)
                .disabled(model.isBusy || choosingFolder)
                .focused($keyboardFocus, equals: .sourceConfirmation)
                .accessibilityIdentifier("setup.confirmSource")
            } else {
                paragraph("Choose the current folder to check access. ShotDrop cannot confirm it automatically.")
            }
            Button("Select Current Screenshot Folder…") { chooseFolder(.sourcePicker) }
                .frame(minHeight: buttonHeight)
                .disabled(model.isBusy || choosingFolder)
                .focused($keyboardFocus, equals: .sourcePicker)
                .accessibilityFocused($accessibilityFocus, equals: .sourcePicker)
                .accessibilityIdentifier("setup.chooseSource")
            if model.isSourceLocationUnknown || model.sourceURL == nil {
                Button("Check Again") {
                    Task { @MainActor in await model.retrySourceDiscovery() }
                }
                .frame(minHeight: buttonHeight)
                .disabled(model.isBusy || choosingFolder)
                .help("Check the macOS screenshot-location setting again. This does not request folder access.")
                .accessibilityIdentifier("setup.retryDiscovery")
            }
            paragraph("Choosing a folder here does not change where macOS saves screenshots.")
                .foregroundStyle(.secondary)
            if let destination = model.destinationURL {
                path(destination, label: model.destinationStatusLabel)
            }
        case .test:
            if model.canRunTest {
                paragraph("Use Shift–Command–3 for the screen or Shift–Command–4 for a selection. Then check for a saved copy in your chosen folder and try pasting the image.")
                paragraph("Folder checks alone do not confirm that a screenshot was copied and saved.")
                    .foregroundStyle(.secondary)
            } else {
                paragraph("Automatic copying and saving are not available in this build. Your save destination can be kept for later.")
            }
            if let destination = model.destinationURL {
                path(destination, label: model.destinationStatusLabel)
            }
            if let source = model.sourceURL {
                path(source, label: "macOS screenshot folder")
            }
        }
    }

    private var recoveryMessage: String? {
        if let issue = model.sourceIssue, model.step == .source, let source = model.sourceURL {
            switch issue {
            case .denied:
                return "ShotDrop can’t read screenshots saved to \(source.path). Your screenshots remain there."
            case .missing, .changed:
                return model.requiresSourceSelection
                    ? "The macOS screenshot location changed. Check Shift–Command–5 > Options > Save to, then select the current folder explicitly."
                    : "The folder macOS uses for screenshots moved or is unavailable. Retry checks the same folder; it does not choose a replacement."
            default: break
            }
        }
        if model.destinationIssue != nil, model.step != .welcome, let destination = model.destinationURL {
            return "Can’t save to \(destination.path). Choose another folder or retry. The original screenshot will remain in its source folder if saving fails."
        }
        return nil
    }

    private var hasAccessDenial: Bool {
        switch model.step {
        case .destination: model.destinationIssue == .denied
        case .source: model.sourceIssue == .denied || model.destinationIssue == .denied
        case .welcome, .test: false
        }
    }

    private var accessRecovery: some View {
        VStack(alignment: .leading, spacing: 8) {
            paragraph("In System Settings, open Privacy & Security > Files and Folders. If ShotDrop is listed, allow access to the selected folder, then return here and retry.")
            Button("Open System Settings") {
                if let settingsURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
                    NSWorkspace.shared.open(settingsURL)
                }
            }
            .frame(minHeight: buttonHeight)
            .disabled(model.isBusy || choosingFolder)
            .accessibilityIdentifier("setup.openSystemSettings")
            paragraph("If Settings does not open, open it from the Apple menu. Retrying checks folder access; it may not show the macOS permission request again.")
                .foregroundStyle(.secondary)
        }
    }

    private var secondaryActions: some View {
        HStack(spacing: 12) {
            if model.canGoBack {
                Button("Back") {
                    movingForward = false
                    model.goBack()
                }
                .disabled(choosingFolder)
                .accessibilityIdentifier("setup.back")
            }
            Button("Not Now") { deferSetup() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("setup.notNow")
        }
        .frame(minHeight: buttonHeight)
    }

    private var primaryAction: some View {
        Button(model.showsPausedSetup ? "Close Setup" : model.primaryTitle) {
            if model.showsPausedSetup {
                deferSetup()
                return
            }
            movingForward = true
            Task { @MainActor in
                await model.continueSetup()
                if !model.isPresented && !model.isDeferred { onClose() }
            }
        }
        .buttonStyle(.borderedProminent)
        .frame(minHeight: buttonHeight)
        .keyboardShortcut(.defaultAction)
        .disabled((!model.showsPausedSetup && !model.canContinue) || model.isBusy || choosingFolder)
        .focused($keyboardFocus, equals: .primary)
        .accessibilityIdentifier("setup.continue")
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).fixedSize(horizontal: false, vertical: true)
    }

    private func path(_ url: URL, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .fontWeight(.medium)
                .accessibilityHidden(true)
            Text(url.path)
                .font(.system(size: pathSize))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .help(url.path)
                .accessibilityLabel(label)
                .accessibilityValue(url.path)
        }
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        let distance: CGFloat = movingForward ? 8 : -8
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: distance)),
            removal: .opacity.combined(with: .offset(x: -distance))
        )
    }

    private func focusCurrentStep() {
        // Focus follows the new step immediately; it never waits for the transition.
        accessibilityFocus = .heading(model.step.rawValue)
        needsStepKeyboardFocus = model.isBusy
        if !model.isBusy { focusStepControl() }
    }

    private func focusStepControl() {
        needsStepKeyboardFocus = false
        switch model.step {
        case .welcome, .test: keyboardFocus = .primary
        case .destination: keyboardFocus = .destinationPicker
        case .source: keyboardFocus = model.sourceURL == nil ? .sourcePicker : .sourceConfirmation
        }
    }

    private func deferSetup() {
        model.notNow()
        onClose()
    }

    private func chooseFolder(_ control: Control) {
        guard !choosingFolder, !model.isBusy else { return }
        choosingFolder = true
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        let choosingDestination = control == .destinationPicker
        panel.title = choosingDestination ? "Choose a Folder for Copies" : "Choose the Current Screenshot Folder"
        panel.message = choosingDestination
            ? "Choose an existing folder for ShotDrop copies. Your original screenshots stay where they are."
            : "Choose the folder currently shown in Screenshot’s Options > Save to. This does not change the macOS setting."
        panel.prompt = "Choose"
        panel.directoryURL = choosingDestination ? model.destinationURL : model.sourceURL
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            choosingFolder = false
            guard model.isPresented else { return }
            if response == .OK, let url = panel.url {
                if choosingDestination { model.selectDestination(url) }
                else { model.selectSource(url) }
            }
            keyboardFocus = control
            accessibilityFocus = choosingDestination ? .destinationPicker : .sourcePicker
        }
        if let window = windowReference.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}

@MainActor
private final class SetupWindowReference {
    weak var window: NSWindow?
}

private struct SetupWindowReader: NSViewRepresentable {
    let reference: SetupWindowReference

    func makeNSView(context: Context) -> SetupWindowTrackingView {
        SetupWindowTrackingView(reference: reference)
    }

    func updateNSView(_ nsView: SetupWindowTrackingView, context: Context) {}
}

@MainActor
private final class SetupWindowTrackingView: NSView {
    let reference: SetupWindowReference

    init(reference: SetupWindowReference) {
        self.reference = reference
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reference.window = window
    }
}
