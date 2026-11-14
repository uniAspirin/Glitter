import AppKit

extension NotchPanelController {
    static func checkHoverEntry() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            count += 1
        }
        let defaults = MemoryDefaults()
        let (store, _) = TaskStore.todayFixture()
        let c = NotchPanelController(store: store, defaults: defaults)
        c.hoverTimer?.invalidate()
        c.screensChanged([TestScreen(id: 1001, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: 185)])
        defer { c.panel.orderOut(nil) }
        func finish() {
            for _ in 0..<10 {
                guard let motion = c.motion else { break }
                c.advanceAnimation(at: motion.started + motion.duration + 0.01)
            }
        }
        func close(on mode: String) {
            c.state.pinned = false
            c.collapse()
            finish()
            store.setExpandedMode(mode)
            finish()
        }
        func entry(_ offset: CGFloat) -> NSPoint {
            let frame = c.state.geometry.collapsedRect
            return NSPoint(x: frame.midX + offset, y: frame.midY)
        }

        check(!c.alwaysShowsTodayOnHover, "Directional hover is the default")
        close(on: "month")
        c.pollCursor(at: entry(-0.25))
        check(c.state.expanded && store.expandedMode == "today", "Entry immediately left of center opens Today")
        check(c.state.monthProgress == 0, "Left entry prepares Today before expansion begins")
        c.pollCursor(at: entry(1))
        check(store.expandedMode == "today", "Crossing the center during opening does not switch pages")
        finish()
        c.pollCursor(at: entry(1))
        check(store.expandedMode == "today", "Crossing the center while expanded keeps the selected page")

        close(on: "today")
        c.pollCursor(at: entry(0.25))
        check(c.state.expanded && store.expandedMode == "month", "Entry immediately right of center opens Month")
        check(c.state.monthProgress == 1, "Right entry prepares Month without flashing Today first")
        finish()
        close(on: "today")
        c.pollCursor(at: entry(0))
        finish()
        check(store.expandedMode == "month", "The exact center belongs to the right half")

        c.setAlwaysShowTodayOnHover(true)
        check(c.alwaysShowsTodayOnHover && defaults.object(forKey: "Glitter.alwaysShowTodayOnHover") as? Bool == true,
              "The Today option is persisted")
        check(store.expandedMode == "month", "Changing the option waits for the next hover entry")
        close(on: "month")
        c.pollCursor(at: entry(30))
        finish()
        check(store.expandedMode == "today", "The Today option overrides entry from the right")
        c.state.onSelectMonth?()
        finish()
        check(store.expandedMode == "month", "Manual Month navigation still works with the Today option enabled")
        c.pollCursor(at: entry(-30))
        check(store.expandedMode == "month", "The option applies to entry rather than ongoing pointer motion")
        close(on: "month")
        c.forceExpandedForDebug()
        finish()
        check(c.state.pinned && store.expandedMode == "month", "Programmatic pinning preserves the manually selected page")
        let restored = NotchPanelController(store: TaskStore.todayFixture().0, defaults: defaults)
        restored.hoverTimer?.invalidate()
        defer { restored.panel.orderOut(nil) }
        check(restored.alwaysShowsTodayOnHover, "The Today option survives relaunch")

        c.setAlwaysShowTodayOnHover(false)
        close(on: "today")
        c.pollCursor(at: entry(20))
        finish()
        check(store.expandedMode == "month", "Disabling the option restores directional entry")
        c.collapse()
        if let motion = c.motion { c.advanceAnimation(at: motion.started + 0.025) }
        let before = c.interactionFrame
        c.pollCursor(at: NSPoint(x: before.midX - 1, y: before.maxY - 10))
        check(c.state.expanded && store.expandedMode == "today", "Re-entry during collapse selects the new entry side")
        check(c.interactionFrame == before, "Reversing collapse preserves the current visible frame")
        finish()
        check(c.state.monthProgress == 0, "Re-entry settles on the requested page")

        close(on: "month")
        c.isDragging = true
        c.pollCursor(at: entry(-20))
        check(!c.state.expanded && store.expandedMode == "month", "Dragging does not trigger directional hover")
        c.isDragging = false
        c.state.geometry.horizontalOffset = c.state.geometry.settledOffset(400)
        c.refreshGeometry()
        check(c.state.geometry.collapsedWidth < c.state.geometry.expandedWidth, "Off-notch fixture uses the compact header")
        c.pollCursor(at: entry(-1))
        finish()
        check(store.expandedMode == "today", "Off-notch hover uses the moved panel's center")
        close(on: "today")
        c.screensChanged([TestScreen(id: 2002, frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080))])
        c.pollCursor(at: entry(1))
        finish()
        check(store.expandedMode == "month", "External-display hover uses that panel's center")

        let demoDefaults = DemoDefaults()
        let demo = NotchPanelController(store: TaskStore.todayFixture().0, defaults: demoDefaults)
        demo.hoverTimer?.invalidate()
        defer { demo.panel.orderOut(nil) }
        demo.setAlwaysShowTodayOnHover(true)
        check(demoDefaults.object(forKey: "Glitter.alwaysShowTodayOnHover") as? Bool == true,
              "Demo keeps the Today option in its in-memory settings")
        check(DemoDefaults().object(forKey: "Glitter.alwaysShowTodayOnHover") == nil,
              "A new Demo session has isolated hover preferences")
        print("PASS \(count) directional hover, preference and animation-reversal checks")
    }
}
