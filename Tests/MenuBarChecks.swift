import AppKit

extension NotchPanelController {
    static func checkMenuBarVisibility() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            count += 1
        }
        func configuredController(defaults: UserDefaults, demo: Bool = false) -> NotchPanelController {
            let (store, _) = TaskStore.todayFixture()
            if demo { store.loadDemoData() }
            let controller = NotchPanelController(store: store, defaults: defaults)
            controller.hoverTimer?.invalidate()
            return controller
        }
        let defaults = MemoryDefaults()
        defaults.set("keep", forKey: "unrelated.setting")
        let controller = configuredController(defaults: defaults)
        defer { controller.panel.orderOut(nil) }
        var updates = 0
        controller.onDataChanged = { updates += 1 }
        check(controller.showsMenuBarIcon, "Existing installations show the menu-bar icon by default")
        controller.setMenuBarIconVisible(false)
        check(!controller.showsMenuBarIcon, "The settings model immediately reflects a hidden icon")
        check(defaults.object(forKey: "Glitter.showMenuBarIcon") as? Bool == false, "Hidden icon preference is persisted")
        check(updates == 1, "A change notifies the app delegate to update the native item")
        controller.setMenuBarIconVisible(false)
        check(updates == 1, "Repeated values do not rebuild the native menu")
        check(defaults.string(forKey: "unrelated.setting") == "keep", "Icon visibility preserves unrelated settings")
        let relaunched = configuredController(defaults: defaults)
        defer { relaunched.panel.orderOut(nil) }
        check(!relaunched.showsMenuBarIcon, "Relaunch restores the hidden preference")
        relaunched.setMenuBarIconVisible(true)
        check(relaunched.showsMenuBarIcon, "Settings can restore the icon")
        check(defaults.object(forKey: "Glitter.showMenuBarIcon") as? Bool == true, "Restored icon preference is persisted")

        check(controller.state.onTogglePinned == nil, "Regular mode has no pin menu action")
        controller.togglePinned()
        controller.forceExpandedForDebug()
        check(!controller.state.pinned && !controller.state.expanded, "Regular mode cannot enable Keep Expand")

        let demoDefaults = DemoDefaults()
        let demo = configuredController(defaults: demoDefaults, demo: true)
        defer { demo.panel.orderOut(nil) }
        demo.state.onTogglePinned?()
        check(demo.state.pinned && demo.state.expanded, "Demo keeps its pin action for visual checks")
        demo.collapse()
        check(demo.state.expanded, "A pinned Demo ignores hover collapse")
        demo.state.onTogglePinned?()
        check(!demo.state.pinned, "Demo can release its pin")
        demo.forceExpandedForDebug()
        check(demo.state.pinned && demo.state.expanded, "Demo can start pinned for development")
        demo.setMenuBarIconVisible(false)
        check(demoDefaults.object(forKey: "Glitter.showMenuBarIcon") as? Bool == false,
              "Demo stores its visibility choice in its in-memory defaults")
        check(DemoDefaults().object(forKey: "Glitter.showMenuBarIcon") == nil,
              "A new Demo session starts with isolated preferences")
        print("PASS \(count) menu-bar preference, persistence, notification and context pin checks")
    }
}
