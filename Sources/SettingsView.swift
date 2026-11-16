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
            HStack {
                Text("Screen").font(.system(size: 13))
                Spacer(minLength: 12)
                if screens.count > 1 {
                    Picker("Screen", selection: Binding(
                        get: { controller.currentScreen?.displayID ?? 0 },
                        set: { controller.selectDisplay($0) }
                    )) {
                        ForEach(screens, id: \.self) { screen in
                            Text(label(for: screen)).tag(screen.displayID ?? 0)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .font(.system(size: 14))
                    .controlSize(.regular)
                    .frame(maxWidth: 220, alignment: .trailing)
                } else {
                    Text(label(for: screens.first))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.top, 12)

            HStack {
                Text("Panel Position").font(.system(size: 13))
                Spacer()
                Button("Center") { controller.resetOffset() }
                    .font(.system(size: 14))
                    .controlSize(.regular)
            }
            .padding(.top, 12)

            switchRow("Show Menu Bar Icon", isOn: Binding(
                get: { controller.showsMenuBarIcon },
                set: { controller.setMenuBarIconVisible($0) }
            ))
            .padding(.top, 12)

            Divider().padding(.vertical, 18)
            title("Startup")
            switchRow("Launch at Login", isOn: Binding(
                get: { loginItems.isEnabled },
                set: { enabled in Task { await loginItems.setEnabled(enabled) } }
            ))
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

            if store.isDemo {
                Divider().padding(.vertical, 16)
                title("Animation Demo")
                subtitle("Smooth Slide · 160 ms")
                HStack {
                    Button("Replay Pages") { controller.previewPageTransition() }
                    Button("Replay Notch") { controller.previewNotchTransition() }
                }
                .padding(.top, 10)
                subtitle("Expand 0.36 / 0.76 · Collapse 0.26 / 0.96")
            }

            Spacer(minLength: 0)

        }
        .padding(22)
        .frame(width: 380, height: store.isDemo ? 820 : 680)
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

    private func switchRow(_ text: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 13))
                .accessibilityHidden(true)
            Spacer(minLength: 12)
            Toggle(text, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
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
final class SettingsWindowController: NSObject, NSToolbarDelegate {
    private let titleItemIdentifier = NSToolbarItem.Identifier("GlitterSettingsTitle")
    private var window: NSWindow?
    private let store: TaskStore
    private let controller: NotchPanelController
    private let loginItems: LoginItemManager

    init(store: TaskStore, controller: NotchPanelController, loginItems: LoginItemManager) {
        self.store = store
        self.controller = controller
        self.loginItems = loginItems
        super.init()
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
            contentRect: NSRect(x: 0, y: 0, width: 380, height: store.isDemo ? 820 : 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Glitter Settings"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        let toolbar = NSToolbar(identifier: "GlitterSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [titleItemIdentifier]
        window.toolbar = toolbar
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, titleItemIdentifier, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == titleItemIdentifier else { return nil }
        let label = NSTextField(labelWithString: "Glitter Settings")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: 150),
            label.heightAnchor.constraint(equalToConstant: 22)
        ])
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Glitter Settings"
        item.isBordered = false
        item.view = label
        return item
    }
}
