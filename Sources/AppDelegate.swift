import AppKit

final class DemoDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    override func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let demoMode = CommandLine.arguments.contains("--demo")
        || Bundle.main.object(forInfoDictionaryKey: "GlitterDemoMode") as? Bool == true
    private lazy var appDefaults: UserDefaults = demoMode ? DemoDefaults() : .standard
    private lazy var store = TaskStore(defaults: appDefaults)
    private lazy var loginItems = LoginItemManager(isDemo: demoMode)
    private var controller: NotchPanelController!
    private var settingsWindow: SettingsWindowController!
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if demoMode { store.loadDemoData() } else { store.start() }
        controller = NotchPanelController(store: store, defaults: appDefaults)
        controller.onDataChanged = { [weak self] in self?.rebuildMenu() }
        controller.show()
        settingsWindow = SettingsWindowController(store: store, controller: controller, loginItems: loginItems)
        controller.state.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        setupStatusItem()
        rebuildMenu()



        if demoMode {
            controller.forceExpandedForDebug()
            rebuildMenu()
            return
        }

        if CommandLine.arguments.contains("--expanded") {
            controller.forceExpandedForDebug()
        }

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

        let stat = store.todayStat
        let summary = store.hasStatistics
            ? "\(store.selectedCalendarName)  \(stat.done)/\(stat.due)"
            : store.panelStatus.title
        let head = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
        head.isEnabled = false
        statusMenu.addItem(head)
        if store.panelStatus == .empty {
            let empty = NSMenuItem(title: store.panelStatus.title, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            statusMenu.addItem(empty)
        }

        switch store.access {
        case .denied:
            let item = NSMenuItem(title: "Reminders Access Required…", action: #selector(openPrivacySettings), keyEquivalent: "")
            item.target = self
            statusMenu.addItem(item)
        case .unknown:
            let item = NSMenuItem(title: "Waiting for Access…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            statusMenu.addItem(item)
        case .granted:
            break
        }

        statusMenu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        statusMenu.addItem(settings)

        let todayOnHover = NSMenuItem(title: "Always Show Today on Hover", action: #selector(toggleTodayOnHover), keyEquivalent: "")
        todayOnHover.target = self
        todayOnHover.state = controller.alwaysShowsTodayOnHover ? .on : .off
        statusMenu.addItem(todayOnHover)

        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        let currentScreen = controller.currentScreen
        for screen in NSScreen.screens {
            let suffix = screen.safeAreaInsets.top > 0 ? " (Notch)" : ""
            let item = NSMenuItem(
                title: screen.displayName + suffix,
                action: #selector(selectDisplay(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = Int(screen.displayID ?? 0)
            item.state = (screen.displayID == currentScreen?.displayID) ? .on : .off
            displayMenu.addItem(item)
        }
        displayItem.submenu = displayMenu
        statusMenu.addItem(displayItem)

        let center = NSMenuItem(title: "Center Panel", action: #selector(resetOffset), keyEquivalent: "")
        center.target = self
        statusMenu.addItem(center)

        statusMenu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        statusMenu.addItem(refresh)

        let pinned = NSMenuItem(title: "Keep Expanded", action: #selector(togglePinned), keyEquivalent: "")
        pinned.target = self
        pinned.state = controller.state.pinned ? .on : .off
        statusMenu.addItem(pinned)

        statusMenu.addItem(.separator())

        let openReminders = NSMenuItem(title: "Open Reminders", action: #selector(openReminders), keyEquivalent: "")
        openReminders.target = self
        openReminders.isEnabled = !demoMode
        statusMenu.addItem(openReminders)

        let quit = NSMenuItem(title: "Quit Glitter", action: #selector(quit), keyEquivalent: "q")
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

    @objc private func togglePinned() {
        controller.togglePinned()
        rebuildMenu()
    }

    @objc private func toggleTodayOnHover() {
        controller.setAlwaysShowTodayOnHover(!controller.alwaysShowsTodayOnHover)
    }

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
