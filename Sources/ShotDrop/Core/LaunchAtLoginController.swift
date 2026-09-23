import Foundation
import Observation
import os
import ServiceManagement

@MainActor
protocol LaunchAtLoginService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
private struct SystemLaunchAtLoginService: LaunchAtLoginService {
    var status: SMAppService.Status { SMAppService.mainApp.status }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Reports macOS's actual state; creating this object never changes login items.
@MainActor
@Observable
final class LaunchAtLoginController {
    private(set) var isEnabled = false
    private(set) var requiresApproval = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let service: any LaunchAtLoginService
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.macfleet.shotdrop", category: "LaunchAtLogin"
    )

    convenience init() {
        self.init(service: SystemLaunchAtLoginService())
    }

    init(service: any LaunchAtLoginService) {
        self.service = service
        refresh()
    }

    func refresh() {
        let status = service.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
        errorMessage = status == .notFound
            ? "macOS could not find ShotDrop's login item. Try moving ShotDrop to Applications."
            : nil
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        let status = service.status
        // A pending registration already exists. Approval must be given in System Settings.
        if enabled && (status == .enabled || status == .requiresApproval) { return }
        if !enabled && status == .notRegistered { return }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            refresh()
        } catch {
            refresh()
            errorMessage = error.localizedDescription
            logger.error("Could not update launch at login: \(error.localizedDescription, privacy: .public)")
        }
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
