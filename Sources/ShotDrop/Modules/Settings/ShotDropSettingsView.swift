import AppKit
import SwiftUI

@MainActor
struct ShotDropSettingsView: View {
    var runtime: ShotDropRuntime
    @Bindable var settings: AppSettings
    @Bindable var launchAtLogin: LaunchAtLoginController
    var onFinishSetup: () -> Void
    var onDestinationChange: (URL) -> Void

    @State private var isChoosingFolder = false

    var body: some View {
        Form {
            Section {
                Label(runtime.status, systemImage: runtime.isRunning ? "checkmark.circle" : "info.circle")
                Text("New system screenshots are saved as separate copies. Your originals stay in place.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Finish Setup…", action: onFinishSetup)
            }

            Section("Saving") {
                LabeledContent("Save to") {
                    VStack(alignment: .trailing) {
                        Text(settings.destinationPath)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(settings.destinationPath)
                        Button("Choose Folder…", action: chooseFolder)
                            .disabled(isChoosingFolder)
                    }
                }

                TextField("Filename template", text: $settings.renameTemplate)
                    .textFieldStyle(.roundedBorder)
                    .help("Use {app}, {date}, and {time} to name screenshots.")
                Text("Available fields: {app}, {date}, {time}")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Organize into year and month folders", isOn: $settings.organizeByDate)
            }

            Section("Copying") {
                Picker("Copy to clipboard", selection: $settings.copyMode) {
                    ForEach(CopyMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("General") {
                Toggle("Show ShotDrop Thumbnail", isOn: $settings.showShotDropThumbnail)
                Toggle("Play a sound after saving", isOn: $settings.playSound)
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))

                if launchAtLogin.requiresApproval {
                    Text("Allow ShotDrop in Login Items to finish enabling launch at login.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items…") {
                        launchAtLogin.openSystemSettings()
                    }
                    Button("Cancel Login Request") {
                        launchAtLogin.setEnabled(false)
                    }
                }

                if let message = launchAtLogin.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 540, idealHeight: 560)
        .onAppear {
            NSApplication.shared.activate(ignoringOtherApps: true)
            launchAtLogin.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Save Destination"
        panel.message = "ShotDrop will save screenshots in this folder when automatic saving is available."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: (settings.destinationPath as NSString).expandingTildeInPath)
        isChoosingFolder = true

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            isChoosingFolder = false
            guard response == .OK, let url = panel.url else { return }
            settings.destinationPath = url.path
            onDestinationChange(url)
        }

        if let window = NSApplication.shared.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
