import AppKit
import EventKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var controller: NotchPanelController
    @ObservedObject var loginItems: LoginItemManager
    @ObservedObject var language: LanguageManager

    private var displays: [DisplayMetrics] { controller.displays }
    private var l10n: L10n { language.strings }
    let onRequestAccess: () -> Void

    init(store: TaskStore, controller: NotchPanelController, loginItems: LoginItemManager,
         onRequestAccess: @escaping () -> Void) {
        self.store = store
        self.controller = controller
        self.loginItems = loginItems
        self.language = store.language
        self.onRequestAccess = onRequestAccess
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title(l10n.settingsTrackedList)
            subtitle(l10n.settingsTrackedListSubtitle)

            if store.access != .granted {
                HStack(spacing: 10) {
                    Text(l10n.settingsAccessRequired)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(store.access == .denied ? l10n.settingsSystemSettings : l10n.settingsAllowAccess) {
                        onRequestAccess()
                    }
                }
                .padding(.top, 10)
            } else if store.calendars.isEmpty {
                Text(l10n.settingsNoListsFound)
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

            title(l10n.settingsDisplay)
            HStack {
                Text(l10n.settingsScreen).font(.system(size: 13))
                Spacer(minLength: 12)
                if displays.count > 1 {
                    Picker(l10n.settingsScreen, selection: Binding(
                        get: { controller.currentDisplay?.id ?? 0 },
                        set: { controller.selectDisplay($0) }
                    )) {
                        ForEach(displays) { display in
                            Text(label(for: display)).tag(display.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .font(.system(size: 14))
                    .controlSize(.regular)
                    .frame(maxWidth: 220, alignment: .trailing)
                } else {
                    Text(label(for: displays.first))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.top, 12)

            HStack {
                Text(l10n.settingsPanelPosition).font(.system(size: 13))
                Spacer()
                Button(l10n.settingsCenter) { controller.resetOffset() }
                    .font(.system(size: 14))
                    .controlSize(.regular)
            }
            .padding(.top, 12)

            switchRow(l10n.settingsShowMenuBarIcon, isOn: Binding(
                get: { controller.showsMenuBarIcon },
                set: { controller.setMenuBarIconVisible($0) }
            ))
            .padding(.top, 12)

            HStack {
                Text(l10n.settingsLanguage).font(.system(size: 13))
                Spacer(minLength: 12)
                Picker(l10n.settingsLanguage, selection: Binding(
                    get: { language.selection },
                    set: { store.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases, id: \.self) { option in
                        Text(l10n.languageOptionLabel(option)).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(.system(size: 14))
                .controlSize(.regular)
                .frame(maxWidth: 220, alignment: .trailing)
            }
            .padding(.top, 12)

            Divider().padding(.vertical, 18)
            title(l10n.settingsStartup)
            switchRow(l10n.settingsLaunchAtLogin, isOn: Binding(
                get: { loginItems.isEnabled },
                set: { enabled in Task { await loginItems.setEnabled(enabled) } }
            ))
            .disabled(loginItems.isDemo || loginItems.isUpdating)
            .padding(.top, 8)
            subtitle(loginItems.isDemo ? l10n.settingsStartupDemoHint : l10n.settingsStartupHint)
            if loginItems.needsApproval {
                subtitle(l10n.settingsApprovalHint)
                Button(l10n.settingsOpenLoginItems) { loginItems.openSettings() }
                    .padding(.top, 6)
            }
            if let error = loginItems.localizedErrorMessage(with: l10n) {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }

            #if DEBUG || DEMO
            if store.isDemo {
                Divider().padding(.vertical, 16)
                title(l10n.settingsAnimationDemo)
                subtitle("Smooth Slide · 160 ms")
                HStack {
                    Button(l10n.settingsReplayPages) { controller.previewPageTransition() }
                    Button(l10n.settingsReplayNotch) { controller.previewNotchTransition() }
                }
                .padding(.top, 10)
                subtitle("Expand 0.36 / 0.76 · Collapse 0.26 / 0.96")
            }
            #endif

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

    private func label(for display: DisplayMetrics?) -> String {
        guard let display else { return l10n.mainDisplay }
        return display.displayLabel(strings: l10n)
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
        .accessibilityHint(l10n.settingsListAccessibilityHint)
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
    private var titleLabel: NSTextField?
    private var titleItem: NSToolbarItem?
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
            updateLocalizedTitles()
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
        window.title = store.l10n.settingsWindowTitle
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

    func updateLocalizedTitles() {
        let title = store.l10n.settingsWindowTitle
        window?.title = title
        titleLabel?.stringValue = title
        titleItem?.label = title
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
        let title = store.l10n.settingsWindowTitle
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: 180),
            label.heightAnchor.constraint(equalToConstant: 22)
        ])
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = title
        item.isBordered = false
        item.view = label
        titleLabel = label
        titleItem = item
        return item
    }
}
