import AppKit
import ServiceManagement
import SwiftUI
import XCTest
@testable import Glitter

@MainActor
final class FakeLoginItemService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var nextStatus: SMAppService.Status = .enabled
    var registrationError: Error?
    var removalError: Error?
    var registrations = 0
    var removals = 0
    var settingsOpened = 0

    func register() throws {
        registrations += 1
        if let registrationError { throw registrationError }
        status = nextStatus
    }

    func unregister() async throws {
        removals += 1
        if let removalError { throw removalError }
        status = .notRegistered
    }

    func openSettings() { settingsOpened += 1 }
}

@MainActor
final class LoginItemTests: XCTestCase {
    func testLoginItemsStateFailureAndDemoIsolation() async {
        let service = FakeLoginItemService()
        let manager = LoginItemManager(service: service)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(service.registrations, 0)
        await manager.setEnabled(true)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(service.registrations, 1)
        await manager.setEnabled(true)
        XCTAssertEqual(service.registrations, 1)
        await manager.setEnabled(false)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(service.removals, 1)
        XCTAssertFalse(manager.isUpdating)

        service.nextStatus = .requiresApproval
        await manager.setEnabled(true)
        XCTAssertTrue(manager.isEnabled && manager.needsApproval)
        manager.openSettings()
        XCTAssertEqual(service.settingsOpened, 1)

        let (store, _) = TaskStore.todayFixture()
        let controller = NotchPanelController(store: store, defaults: MemoryDefaults())
        defer { controller.panel.orderOut(nil) }

        func captureSettings(_ name: String, _ loginItems: LoginItemManager) {
            let host = NSHostingView(rootView: SettingsView(store: store, controller: controller, loginItems: loginItems, onRequestAccess: {}))
            host.frame = NSRect(x: 0, y: 0, width: 380, height: store.isDemo ? 820 : 680)
            ReviewArtifacts.captureView(host, filename: "\(name).png")
        }

        captureSettings("settings-approval", manager)
        service.status = .enabled
        manager.refresh()
        XCTAssertFalse(manager.needsApproval)
        XCTAssertTrue(manager.isEnabled)

        service.removalError = NSError(domain: "Test", code: 1)
        await manager.setEnabled(false)
        XCTAssertTrue(manager.isEnabled && manager.errorMessage != nil && !manager.isUpdating)
        service.removalError = nil
        await manager.setEnabled(false)

        service.registrationError = NSError(domain: "Test", code: 2)
        await manager.setEnabled(true)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertNotNil(manager.errorMessage)
        captureSettings("settings-error", manager)

        service.registrationError = nil
        await manager.setEnabled(true)
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(manager.needsApproval)
        service.status = .notRegistered
        manager.refresh()
        XCTAssertFalse(manager.isEnabled)

        let demo = LoginItemManager(isDemo: true, service: service)
        let registrations = service.registrations
        let removals = service.removals
        await demo.setEnabled(true)
        await demo.setEnabled(false)
        demo.openSettings()
        XCTAssertFalse(demo.isEnabled)
        XCTAssertEqual(service.registrations, registrations)
        XCTAssertEqual(service.removals, removals)
        XCTAssertEqual(service.settingsOpened, 1)

        store.loadDemoData()
        store.selectCalendar(store.calendars[1].calendarIdentifier, extendingSelection: true)
        captureSettings("settings-demo", demo)
    }
}
