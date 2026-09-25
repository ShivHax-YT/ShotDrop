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
        case destinationPicker, sourcePicker, sourceConfirmation, primary, detailsHeading, accessRecovery
    }

    private enum AccessibilityTarget: Hashable {
        case heading(Int), destinationPicker, sourcePicker, status, detailsHeading, primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("ShotDrop").font(.headline)
                Spacer()
                Text("Setup").font(.subheadline).foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    setupProgress
                    Text(title)
                        .font(.system(size: titleSize, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($accessibilityFocus, equals: .heading(model.step.rawValue))
                        .accessibilityIdentifier("setup.heading")
                    stepContent
                    if !model.showsPausedSetup, let message = recoveryMessage ?? model.inlineStatusMessage, !message.isEmpty {
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
                    if model.destinationIssue != nil, model.step == .source {
                        Button("Choose Another Save Folder…") { chooseFolder(.destinationPicker) }
                            .disabled(model.isBusy || choosingFolder)
                            .focused($keyboardFocus, equals: .destinationPicker)
                            .accessibilityIdentifier("setup.recoverDestination")
                    }
                    if model.isBusy {
                        ProgressView(model.busyOperationTitle)
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

            if let hint = nextActionHint {
                Text(hint)
                    .font(.system(size: pathSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setup.nextActionHint")
            }
            Divider()
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
        .onChange(of: model.showsPausedSetup) { _, paused in
            if paused {
                keyboardFocus = .primary
                accessibilityFocus = .heading(model.step.rawValue)
            }
        }
        .onChange(of: model.isBusy) { _, busy in
            if !busy, needsStepKeyboardFocus { focusStepControl() }
            if !busy, let message = announcementMessage,
               let window = windowReference.window {
                let nextAction: String
                if model.showsPausedSetup {
                    nextAction = model.defaultPreparationResult?.detailsActionTitle ?? "View Setup Details"
                } else if model.destinationRequiresReselection {
                    nextAction = "Choose Another Save Folder"
                } else if model.sourceRequiresReselection {
                    nextAction = "Select Current Screenshot Folder"
                } else if model.destinationIssue == .denied || model.sourceIssue == .denied {
                    nextAction = "Open System Settings"
                } else { nextAction = model.primaryTitle }
                NSAccessibility.post(element: window, notification: .announcementRequested,
                                     userInfo: [.announcement: "\(message) \(nextAction)",
                                                .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
            if !busy, model.showsPausedSetup { keyboardFocus = .primary }
            else if !busy, model.destinationRequiresReselection { keyboardFocus = .destinationPicker }
            else if !busy, model.sourceRequiresReselection { keyboardFocus = .sourcePicker }
            else if !busy, model.destinationIssue == .denied || model.sourceIssue == .denied {
                keyboardFocus = .accessRecovery
            } else if !busy, model.destinationIssue == .unavailable || model.sourceIssue == .unavailable {
                keyboardFocus = .primary
            }
        }
        .onChange(of: model.isShowingSetupDetails) { _, shown in
            if !shown {
                keyboardFocus = .primary
                accessibilityFocus = .primary
            }
        }
        .sheet(isPresented: Binding(get: { model.isShowingSetupDetails }, set: { if !$0 { model.dismissSetupDetails() } })) {
            setupDetails
        }
        .accessibilityAction(.escape) { deferSetup() }
    }

    private var setupProgress: some View {
        let names = ["Welcome", "Save location", "Screenshot folder", model.canRunTest ? "Verify" : "Verify (unavailable)"]
        return VStack(alignment: .leading, spacing: 8) {
            Text("Step \(model.step.rawValue + 1) of 4 · \(names[model.step.rawValue])")
                .font(.system(size: pathSize, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                ForEach(0..<4) { index in
                    Capsule()
                        .fill(index == model.step.rawValue ? Color.accentColor : Color(nsColor: .separatorColor))
                        .frame(height: 4)
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("setup.stepProgress")
    }

    private var nextActionHint: String? {
        if choosingFolder { return "Choose a folder in the dialog, or cancel to return to setup." }
        if model.isBusy { return "You can choose Not Now to stop setup." }
        if model.showsPausedSetup { return "Open setup details to see what needs attention. Saving remains paused." }
        if model.destinationRequiresReselection { return "Choose another save folder before continuing." }
        if model.sourceRequiresReselection { return "Select the current screenshot folder again before continuing." }
        if model.step == .source, !model.canContinue {
            if model.requiresSourceSelection || model.sourceURL == nil {
                return "Select the current screenshot folder to continue."
            }
            if !model.sourceConfirmedByUser { return "Confirm that this matches macOS’s Save to folder to continue." }
        }
        if model.step == .test, !model.canRunTest { return "Verification is unavailable until the remaining saving checks pass. You can return later from the ShotDrop menu." }
        return nil
    }

    private func welcomeItem(_ title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                paragraph(detail).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch model.step {
        case .welcome: "Welcome to ShotDrop"
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
            paragraph("Set up a home for your screenshots. ShotDrop is designed to keep a saved copy ready to find and an image ready to paste.")
            VStack(alignment: .leading, spacing: 12) {
                welcomeItem("Choose where copies belong", symbol: "folder", detail: "Select a destination you can find easily.")
                welcomeItem("Confirm your screenshot folder", symbol: "viewfinder", detail: "Match the folder macOS uses, then check access.")
                welcomeItem("Keep your originals", symbol: "doc.on.doc", detail: "Setup leaves your original screenshots in place.")
            }
            .padding(16)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            Label {
                paragraph("Choose your save folder and confirm your screenshot folder. ShotDrop will then copy and save new screenshots automatically.")
            } icon: { Image(systemName: "pause.circle") }
            .accessibilityIdentifier("setup.welcomeAvailability")
        case .destination:
            paragraph(model.proposesSupportedDefault
                ? "Use Pictures/ShotDrop or choose another folder for saved copies. The default folder is prepared only after you confirm your screenshot source and the checks pass."
                : "Choose a folder for saved copies. ShotDrop can create Pictures/ShotDrop for you. Continue to check access; macOS may ask for permission.")
            if let destination = model.destinationURL {
                path(destination, label: model.destinationStatusLabel)
            }
            Button("Choose Another Folder…") { chooseFolder(.destinationPicker) }
                .frame(minHeight: buttonHeight)
                .disabled(model.isBusy || choosingFolder)
                .focused($keyboardFocus, equals: .destinationPicker)
                .accessibilityFocused($accessibilityFocus, equals: .destinationPicker)
                .accessibilityIdentifier("setup.chooseDestination")
            paragraph("The folder picker opens only when you choose it. Continue creates the default save folder if needed.")
                .foregroundStyle(.secondary)
        case .source:
            if model.showsPausedSetup {
                paragraph(model.pausedResultMessage)
                if let destination = model.destinationURL { path(destination, label: model.destinationStatusLabel) }
                paragraph("Open setup details for the next step. You can use Back to review your folders, or Not Now to return to the menu.")
                    .foregroundStyle(.secondary)
            } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Press Shift–Command–5", systemImage: "keyboard")
                    .fontWeight(.medium)
                paragraph("Open Options, then look under Save to. Select that same folder below and confirm it before checking access.")
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
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

    private var announcementMessage: String? {
        model.showsPausedSetup
            ? (model.pausedResultMessage)
            : (recoveryMessage ?? model.statusMessage)
    }

    private var recoveryMessage: String? {
        if let issue = model.sourceIssue, model.step == .source, let source = model.sourceURL {
            switch issue {
            case .denied:
                return "ShotDrop can’t read screenshots saved to \(source.path). Your screenshots remain there."
            case .missing, .changed:
                return model.sourceReselectionMessage
            default: break
            }
        }
        if let issue = model.destinationIssue, model.step != .welcome, let destination = model.destinationURL {
            switch issue {
            case .missing:
                return "The selected save folder is missing: \(destination.path). Choose an existing folder at its current location."
            case .changed:
                return "The selected save folder moved or changed: \(destination.path). Choose its current location again so ShotDrop can check it."
            case .denied:
                return "ShotDrop cannot access the selected save folder: \(destination.path). Review Files and Folders access in System Settings, then retry, or choose another folder."
            case .unsupported:
                return "This save folder is not supported: \(destination.path). Choose a supported local folder; retrying this selection will not make it supported."
            case .unsafe:
                return "The screenshot source and save destination must be separate folders. Choose a different save folder that is not inside your screenshot folder and does not contain it."
            case .unavailable:
                return "The save folder could not be checked: \(destination.path). Make sure it is available, then retry, or choose another folder."
            }
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
            .focused($keyboardFocus, equals: .accessRecovery)
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
        Button(model.showsPausedSetup ? model.defaultPreparationResult?.detailsActionTitle ?? "View Setup Details…" : model.primaryTitle) {
            movingForward = true
            Task { @MainActor in
                await model.performPrimaryAction(
                    chooseDestination: { chooseFolder(.destinationPicker) },
                    chooseSource: { chooseFolder(.sourcePicker) })
                if !model.isPresented && !model.isDeferred { onClose() }
            }
        }
        .buttonStyle(.borderedProminent)
        .frame(minHeight: buttonHeight)
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canPerformPrimaryAction || choosingFolder)
        .focused($keyboardFocus, equals: .primary)
        .accessibilityFocused($accessibilityFocus, equals: .primary)
        .accessibilityIdentifier("setup.continue")
    }

    private var setupDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.defaultPreparationResult?.detailsTitle ?? "Saving is paused")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .focusable()
                .focused($keyboardFocus, equals: .detailsHeading)
                .accessibilityFocused($accessibilityFocus, equals: .detailsHeading)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let result = model.defaultPreparationResult {
                        paragraph(result.message)
                        if let destination = model.destinationURL {
                            path(destination, label: model.destinationStatusLabel)
                        }
                        Text("Next step").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                        paragraph(result.reviewGuidance)
                        paragraph("Share this explanation with the developer through the channel where you received this build. Nothing is sent automatically. This build has no action that can approve this review or turn on saving.")
                            .foregroundStyle(.secondary)
                    } else {
                        paragraph(model.pausedSetupMessage)
                        if let destination = model.destinationURL {
                            path(destination, label: model.destinationStatusLabel)
                        }
                        Text("Next step").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                        paragraph("Keep your selected folders and return after the remaining saving checks are resolved. Repeating Continue cannot approve these checks or enable saving.")
                        paragraph("You can share this explanation with the developer through the channel where you received this build. Nothing is sent automatically.")
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Close Details") { model.dismissSetupDetails() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("setup.details.back")
        }
        .padding(24)
        .frame(minWidth: 340, idealWidth: 440, maxWidth: 480, minHeight: 320, idealHeight: 400, maxHeight: 440)
        .accessibilityIdentifier("setup.details")
        .onAppear {
            keyboardFocus = .detailsHeading
            accessibilityFocus = .detailsHeading
        }
        .onExitCommand { model.dismissSetupDetails() }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).fixedSize(horizontal: false, vertical: true)
    }

    private func path(_ url: URL, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: "folder")
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
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
        case .destination:
            if model.destinationRequiresReselection { keyboardFocus = .destinationPicker }
            else if model.destinationIssue == .denied { keyboardFocus = .accessRecovery }
            else { keyboardFocus = model.proposesSupportedDefault ? .primary : .destinationPicker }
        case .source:
            if model.showsPausedSetup { keyboardFocus = .primary }
            else if model.destinationRequiresReselection { keyboardFocus = .destinationPicker }
            else if model.sourceRequiresReselection || model.sourceURL == nil { keyboardFocus = .sourcePicker }
            else if model.destinationIssue == .denied || model.sourceIssue == .denied { keyboardFocus = .accessRecovery }
            else { keyboardFocus = .sourceConfirmation }
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
