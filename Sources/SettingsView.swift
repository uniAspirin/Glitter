import AppKit
import EventKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var controller: NotchPanelController
    @ObservedObject var loginItems: LoginItemManager

    private var screens: [NSScreen] { controller.screens }
    let onRequestAccess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Tracked List")
            subtitle("Create a Daily Habit list in Reminders. Set your repeats, then choose your list here. (hold ⌘ to choose more lists)")

            if store.access != .granted {
                HStack(spacing: 10) {
                    Text("Reminders access is required.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(store.access == .denied ? "System Settings" : "Allow Access") { onRequestAccess() }
                }
                .padding(.top, 10)
            } else if store.calendars.isEmpty {
                Text("No reminder lists found.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(store.calendars, id: \.calendarIdentifier) { cal in
                            listRow(cal)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 200)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .padding(.top, 10)
            }

            Divider().padding(.vertical, 18)

            title("Display")
            subtitle("The panel keeps clear of the camera.")
            if screens.count > 1 {
                Picker("", selection: Binding(
                    get: { controller.currentScreen?.displayID ?? 0 },
                    set: { controller.selectDisplay($0) }
                )) {
                    ForEach(screens, id: \.self) { screen in
                        Text(label(for: screen)).tag(screen.displayID ?? 0)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .padding(.top, 8)
            } else {
                Text(label(for: screens.first))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            Button("Center Panel") { controller.resetOffset() }
                .padding(.top, 12)

            Divider().padding(.vertical, 18)
            title("Startup")
            Toggle("Launch at Login", isOn: Binding(
                get: { loginItems.isEnabled },
                set: { enabled in Task { await loginItems.setEnabled(enabled) } }
            ))
            .font(.system(size: 13))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(loginItems.isDemo || loginItems.isUpdating)
            .padding(.top, 8)
            subtitle(loginItems.isDemo ? "Unavailable in Demo." : "Start Glitter when you log in.")
            if loginItems.needsApproval {
                subtitle("Allow Glitter in System Settings to finish enabling.")
                Button("Open Login Items Settings") { loginItems.openSettings() }
                    .padding(.top, 6)
            }
            if let error = loginItems.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }

            Spacer(minLength: 0)

        }
        .padding(22)
        .frame(width: 380, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { loginItems.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItems.refresh()
        }
    }

    private func label(for screen: NSScreen?) -> String {
        guard let screen else { return "Main Display" }
        let suffix = screen.safeAreaInsets.top > 0 ? " (Notch)" : ""
        return screen.displayName + suffix
    }

    private func listRow(_ cal: EKCalendar) -> some View {
        let selected = store.selectedCalendarIDs.contains(cal.calendarIdentifier)
        return Button {
            let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            store.selectCalendar(cal.calendarIdentifier, extendingSelection: modifiers.contains(.command))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 14, height: 14)
                Text(cal.title)
                    .font(.system(size: 13))
                Spacer()
                Text(cal.source?.title ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Hold Command to add or remove this list from your selection.")
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
    }

    private func subtitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }
}


@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: TaskStore
    private let controller: NotchPanelController
    private let loginItems: LoginItemManager

    init(store: TaskStore, controller: NotchPanelController, loginItems: LoginItemManager) {
        self.store = store
        self.controller = controller
        self.loginItems = loginItems
    }

    func show() {
        loginItems.refresh()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(
            store: store,
            controller: controller,
            loginItems: loginItems,
            onRequestAccess: { [weak store] in
                Task { await store?.forceRequestAccess() }
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Glitter Settings"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
