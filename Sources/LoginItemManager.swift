import AppKit
import ServiceManagement
import SwiftUI

@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
    func openSettings()
}

@MainActor
private final class NativeLoginItemService: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() async throws { try await SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var isUpdating = false
    @Published private(set) var errorDetail: String?
    @Published private(set) var errorMessage: String?
    let isDemo: Bool
    private let service: LoginItemService?

    init(isDemo: Bool = false, service: LoginItemService? = nil) {
        self.isDemo = isDemo
        self.service = isDemo ? nil : service ?? NativeLoginItemService()
        refresh()
    }

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func localizedErrorMessage(with l10n: L10n) -> String? {
        errorDetail.map(l10n.loginItemError)
    }

    func refresh() {
        status = service?.status ?? .notRegistered
    }

    func setEnabled(_ enabled: Bool) async {
        guard let service, !isUpdating else { return }
        refresh()
        errorDetail = nil
        errorMessage = nil
        guard enabled != isEnabled else { return }
        isUpdating = true
        defer { refresh(); isUpdating = false }
        do {
            if enabled { try service.register() }
            else { try await service.unregister() }
        } catch {
            refresh()
            // Pending approval has a dedicated explanation and a Settings shortcut.
            if !enabled || !needsApproval {
                let detail = error.localizedDescription
                errorDetail = detail
                errorMessage = L10n(language: AppLanguage.system.resolved()).loginItemError(detail)
            }
        }
    }

    func openSettings() { service?.openSettings() }
}
