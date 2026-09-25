import AppKit
import Carbon
import Darwin
import Foundation

/// Optional capture commands use the system capture UI. Global hotkeys are registered
/// with Carbon; no keyboard monitor or Accessibility permission is installed.
@MainActor
final class ShotDropCaptureController {
    enum Kind: UInt32, CaseIterable {
        case screen = 1, region = 2, window = 3
        var arguments: [String] {
            switch self { case .screen: ["-m"]; case .region: ["-i", "-s"]; case .window: ["-i", "-w"] }
        }
        var key: UInt32 { switch self { case .screen: UInt32(kVK_ANSI_3); case .region: UInt32(kVK_ANSI_4); case .window: UInt32(kVK_ANSI_5) } }
    }
    private let settings: AppSettings
    private let status: (String) -> Void
    private var process: Process?
    private var hotkeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    init(settings: AppSettings, status: @escaping (String) -> Void) { self.settings = settings; self.status = status }

    func registerShortcuts() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr, let kind = Kind(rawValue: key.id) else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<ShotDropCaptureController>.fromOpaque(context).takeUnretainedValue().capture(kind) }
            return noErr
        }, 1, &type, context, &handler)
        guard result == noErr else { status("Capture shortcuts unavailable; use the menu commands."); return }
        for kind in Kind.allCases {
            var hotkey: EventHotKeyRef?
            if RegisterEventHotKey(kind.key, UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x53484450, id: kind.rawValue),
                                   GetApplicationEventTarget(), 0, &hotkey) == noErr, let hotkey { hotkeys.append(hotkey) }
            else { status("A capture shortcut is already in use. Menu commands remain available.") }
        }
    }

    func capture(_ kind: Kind) {
        guard settings.hasCompletedSetup, !settings.isPaused else { status("Complete setup and resume ShotDrop before capturing."); return }
        guard process == nil else { return }
        let source = URL(fileURLWithPath: settings.sourcePath)
        let output = source.appendingPathComponent("ShotDrop Capture-\(UUID().uuidString).png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = kind.arguments + ["-t", "png", output.path]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] completed in
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                guard completed.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else {
                    self.status("Capture cancelled or unavailable. Check Screen Recording access if capture was denied."); return
                }
                do {
                    let data = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
                    let result = data.withUnsafeBytes { setxattr(output.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, $0.count, 0, 0) }
                    if result != 0 { self.status("Capture saved in the source folder; screenshot metadata could not be set.") }
                } catch { self.status("Capture saved; automatic processing could not be requested.") }
            }
        }
        do { try task.run(); process = task }
        catch { status("Could not start system capture: " + error.localizedDescription) }
    }
    func stop() {
        if let process, process.isRunning { process.terminate() }
        for hotkey in hotkeys { UnregisterEventHotKey(hotkey) }
        hotkeys.removeAll()
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
    isolated deinit { stop() }
}
