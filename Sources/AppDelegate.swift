import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG || DEMO
    private let demoMode = CommandLine.arguments.contains("--demo")
        || Bundle.main.object(forInfoDictionaryKey: "GlitterDemoMode") as? Bool == true
    private lazy var appDefaults: UserDefaults = demoMode ? DemoDefaults() : .standard
    #else
    private let demoMode = false
    private let appDefaults: UserDefaults = .standard
    #endif
    private lazy var store = TaskStore(defaults: appDefaults)
    private lazy var loginItems = LoginItemManager(isDemo: demoMode)
    private var controller: NotchPanelController!
    private var settingsWindow: SettingsWindowController!
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Canvas and XCTest hosts run their own views; do not launch global panels or EventKit.
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        #if DEBUG || DEMO
        if demoMode { store.loadDemoData(taskCount: 30, completedCount: 6) } else { store.start() }
        #else
        store.start()
        #endif
        controller = NotchPanelController(store: store, defaults: appDefaults)
        controller.onDataChanged = { [weak self] in
            self?.rebuildMenu()
            self?.settingsWindow?.updateLocalizedTitles()
        }
        controller.show()
        settingsWindow = SettingsWindowController(store: store, controller: controller, loginItems: loginItems)
        controller.state.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        setupStatusItem()
        rebuildMenu()

        #if DEBUG || DEMO
        if demoMode {
            controller.forceExpandedForDebug()
            rebuildMenu()
            return
        }
        #endif

        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.settingsWindow.show()
            }
        }
        if CommandLine.arguments.contains("--selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.controller.runHoverSelfTest()
            }
        }

        if store.authorizationStatus == .notDetermined {
            NSApp.activate(ignoringOtherApps: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            Task { await self.store.requestAccessAndLoad() }
        }
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "Glitter")
            image?.isTemplate = true
            button.image = image
        }
        statusItem.menu = statusMenu
        statusItem.isVisible = controller.showsMenuBarIcon
    }

    private func rebuildMenu() {
        statusItem?.isVisible = controller.showsMenuBarIcon
        statusMenu.removeAllItems()
        let l10n = store.l10n

        let stat = store.todayStat
        let summary = store.hasStatistics
            ? "\(store.selectedCalendarName)  \(stat.done)/\(stat.due)"
            : store.panelStatus.title(with: l10n)
        let head = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
        head.isEnabled = false
        statusMenu.addItem(head)
        if store.panelStatus == .empty {
            let empty = NSMenuItem(title: store.panelStatus.title(with: l10n), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            statusMenu.addItem(empty)
        }

        switch store.access {
        case .denied:
            let item = NSMenuItem(title: l10n.menuBarRemindersRequired, action: #selector(openPrivacySettings), keyEquivalent: "")
            item.target = self
            statusMenu.addItem(item)
        case .unknown:
            let item = NSMenuItem(title: l10n.menuBarWaitingAccess, action: nil, keyEquivalent: "")
            item.isEnabled = false
            statusMenu.addItem(item)
        case .granted:
            break
        }

        statusMenu.addItem(.separator())

        let settings = NSMenuItem(title: l10n.menuBarSettings, action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        statusMenu.addItem(settings)

        let displayItem = NSMenuItem(title: l10n.menuBarDisplay, action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        let currentDisplay = controller.currentDisplay
        for display in controller.displays {
            let item = NSMenuItem(
                title: display.displayLabel(strings: l10n),
                action: #selector(selectDisplay(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = Int(display.id)
            item.state = (display.id == currentDisplay?.id) ? .on : .off
            displayMenu.addItem(item)
        }
        displayItem.submenu = displayMenu
        statusMenu.addItem(displayItem)

        let center = NSMenuItem(title: l10n.menuBarCenterPanel, action: #selector(resetOffset), keyEquivalent: "")
        center.target = self
        statusMenu.addItem(center)

        statusMenu.addItem(.separator())

        let refresh = NSMenuItem(title: l10n.menuBarRefresh, action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        statusMenu.addItem(refresh)

        #if DEBUG || DEMO
        if store.isDemo {
            let pinned = NSMenuItem(title: l10n.menuKeepExpand, action: #selector(togglePinned), keyEquivalent: "")
            pinned.target = self
            pinned.state = controller.state.pinned ? .on : .off
            statusMenu.addItem(pinned)
        }
        #endif

        statusMenu.addItem(.separator())

        let openReminders = NSMenuItem(title: l10n.menuBarOpenReminders, action: #selector(openReminders), keyEquivalent: "")
        openReminders.target = self
        openReminders.isEnabled = !demoMode
        statusMenu.addItem(openReminders)

        let quit = NSMenuItem(title: l10n.menuQuit, action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        statusMenu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int else { return }
        controller.selectDisplay(CGDirectDisplayID(raw))
        rebuildMenu()
    }

    @objc private func resetOffset() {
        controller.resetOffset()
        rebuildMenu()
    }

    @objc private func refresh() {
        store.retryLoad()
        rebuildMenu()
    }

    #if DEBUG || DEMO
    @objc private func togglePinned() {
        controller.togglePinned()
        rebuildMenu()
    }
    #endif

    @objc private func openReminders() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc private func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
