import Foundation
import ServiceManagement
import XCTest
@testable import ShotDrop

final class LaunchAtLoginControllerTests: XCTestCase {
    @MainActor
    func testInitializationOnlyReadsStatus() async {
        let service = FakeLoginService(status: .enabled)
        let controller = LaunchAtLoginController(service: service)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertFalse(controller.requiresApproval)
        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(service.unregisterCount, 0)
    }

    @MainActor
    func testRegisterAndUnregisterReflectSystemStatus() async {
        let service = FakeLoginService()
        let controller = LaunchAtLoginController(service: service)
        controller.setEnabled(true)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(service.registerCount, 1)
        controller.setEnabled(true)
        XCTAssertEqual(service.registerCount, 1)
        controller.setEnabled(false)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(service.unregisterCount, 1)
        controller.setEnabled(false)
        XCTAssertEqual(service.unregisterCount, 1)
    }

    @MainActor
    func testPendingApprovalIsNotReportedAsEnabled() async {
        let service = FakeLoginService()
        service.registrationStatus = .requiresApproval
        let controller = LaunchAtLoginController(service: service)
        controller.setEnabled(true)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.requiresApproval)
        controller.setEnabled(true)
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(service.openSettingsCount, 0)
        controller.openSystemSettings()
        XCTAssertEqual(service.openSettingsCount, 1)
        controller.setEnabled(false)
        XCTAssertFalse(controller.requiresApproval)
        XCTAssertEqual(service.unregisterCount, 1)
    }

    @MainActor
    func testRefreshReflectsExternalChanges() async {
        let service = FakeLoginService(status: .enabled)
        let controller = LaunchAtLoginController(service: service)
        service.status = .requiresApproval
        controller.refresh()
        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.requiresApproval)
        service.status = .notFound
        controller.refresh()
        XCTAssertNotNil(controller.errorMessage)
        service.status = .enabled
        controller.refresh()
        XCTAssertTrue(controller.isEnabled)
        XCTAssertFalse(controller.requiresApproval)
        XCTAssertNil(controller.errorMessage)
    }

    @MainActor
    func testRegistrationFailureKeepsActualStateAndCanRecover() async {
        let service = FakeLoginService()
        service.operationError = LoginTestError.denied
        let controller = LaunchAtLoginController(service: service)
        controller.setEnabled(true)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.errorMessage, "Registration denied for test.")
        service.operationError = nil
        controller.setEnabled(true)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.errorMessage)
    }

    @MainActor
    func testUnregistrationFailureKeepsEnabledState() async {
        let service = FakeLoginService(status: .enabled)
        service.operationError = LoginTestError.denied
        let controller = LaunchAtLoginController(service: service)
        controller.setEnabled(false)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNotNil(controller.errorMessage)
    }
}

private enum LoginTestError: LocalizedError {
    case denied
    var errorDescription: String? { "Registration denied for test." }
}

@MainActor
private final class FakeLoginService: LaunchAtLoginService {
    var status: SMAppService.Status
    var registrationStatus: SMAppService.Status = .enabled
    var operationError: (any Error)?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0

    init(status: SMAppService.Status = .notRegistered) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let operationError { throw operationError }
        status = registrationStatus
    }

    func unregister() throws {
        unregisterCount += 1
        if let operationError { throw operationError }
        status = .notRegistered
    }

    func openSystemSettings() {
        openSettingsCount += 1
    }
}
