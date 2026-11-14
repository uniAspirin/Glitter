import AppKit
import ServiceManagement
import SwiftUI

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
func checkLoginItems() async {
    var count = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); count += 1 }
    let service = FakeLoginItemService()
    let manager = LoginItemManager(service: service)
    check(!manager.isEnabled && service.registrations == 0, "Startup is off without automatic registration")
    await manager.setEnabled(true)
    check(manager.isEnabled && service.registrations == 1, "Enabling registers the native login item")
    await manager.setEnabled(true)
    check(service.registrations == 1, "Repeated enable does not register twice")
    await manager.setEnabled(false)
    check(!manager.isEnabled && service.removals == 1 && !manager.isUpdating, "Disabling unregisters the item and settles")
    service.nextStatus = .requiresApproval
    await manager.setEnabled(true)
    check(manager.isEnabled && manager.needsApproval, "Pending approval is shown as requested, not silently treated as enabled")
    manager.openSettings()
    check(service.settingsOpened == 1, "Approval shortcut opens Login Items settings")
    let (store, _) = TaskStore.todayFixture()
    let controller = NotchPanelController(store: store, defaults: MemoryDefaults())
    func captureSettings(_ name: String, _ loginItems: LoginItemManager) {
        let host = NSHostingView(rootView: SettingsView(store: store, controller: controller, loginItems: loginItems, onRequestAccess: {}))
        host.frame = NSRect(x: 0, y: 0, width: 380, height: 640)
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let output = ProcessInfo.processInfo.environment["GLITTER_REVIEW_OUTPUT"]!
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(output)/\(name).png"))
    }
    captureSettings("settings-approval", manager)
    service.status = .enabled
    manager.refresh()
    check(!manager.needsApproval && manager.isEnabled, "Returning from System Settings refreshes approval")
    service.removalError = NSError(domain: "Test", code: 1)
    await manager.setEnabled(false)
    check(manager.isEnabled && manager.errorMessage != nil && !manager.isUpdating, "Failed removal keeps the real enabled state")
    service.removalError = nil
    await manager.setEnabled(false)
    service.registrationError = NSError(domain: "Test", code: 2)
    await manager.setEnabled(true)
    check(!manager.isEnabled && manager.errorMessage != nil, "Failed registration does not pretend startup is enabled")
    captureSettings("settings-error", manager)
    service.registrationError = nil
    await manager.setEnabled(true)
    check(manager.errorMessage == nil && manager.needsApproval, "Retry clears the stale error")
    service.status = .notRegistered
    manager.refresh()
    check(!manager.isEnabled, "External removal is reflected without local defaults")
    let demo = LoginItemManager(isDemo: true, service: service)
    let registrations = service.registrations
    let removals = service.removals
    await demo.setEnabled(true)
    await demo.setEnabled(false)
    demo.openSettings()
    check(!demo.isEnabled && service.registrations == registrations && service.removals == removals && service.settingsOpened == 1,
          "Demo cannot register, unregister or open system settings")
    store.loadDemoData()
    store.selectCalendar(store.calendars[1].calendarIdentifier, extendingSelection: true)
    captureSettings("settings-demo", demo)
    controller.panel.orderOut(nil)
    print("PASS \(count) Launch at Login state, failure and Demo isolation checks")
}
