import AppKit

extension NotchPanelController {
    static func checkHoverEntry() async {
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
            let rect = c.state.geometry.collapsedRect
            return NSPoint(x: rect.midX + offset, y: rect.midY)
        }
        close(on: "month")
        let cachedDay = c.renderCache.snapshot(page: .day, store: store, state: c.state)
        let cachedMonth = c.renderCache.snapshot(page: .month, store: store, state: c.state)
        check(cachedDay != nil && cachedMonth != nil, "Both pages are cached before entering")
        var menuUpdates = 0
        c.onDataChanged = { menuUpdates += 1 }
        var taskUpdates = 0
        let subscription = store.objectWillChange.sink { taskUpdates += 1 }
        for offset in [-120.0, -0.25, 0.0, 0.25, 120.0] {
            close(on: "month")
            c.pollCursor(at: entry(offset))
            check(c.state.expanded && store.expandedMode == "today", "Every entry position opens Today")
            check(c.state.monthProgress == 0, "Month is hidden before the opening begins")
            check(c.motion?.start.second.second.second == c.motion?.target.second.second.second,
                  "Opening Today does not slide from the remembered Month")
            finish()
        }
        check(menuUpdates == 0 && taskUpdates == 0, "Opening pages does not publish task changes or rebuild menus")
        subscription.cancel()
        check(c.renderCache.snapshot(page: .day, store: store, state: c.state)?.body === cachedDay?.body
              && c.renderCache.snapshot(page: .month, store: store, state: c.state)?.body === cachedMonth?.body,
              "Repeated Today openings reuse both cached pages")
        c.state.pinned = true
        let right = c.state.geometry.blockInteractionRect(in: c.panel.frame)
        let left = c.state.geometry.headerInteractionRect(in: c.panel.frame)
        c.pollCursor(at: NSPoint(x: right.midX, y: right.midY))
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(store.expandedMode == "today" && c.state.blockHovered, "Cube hover highlights without switching")
        c.state.onSelectMonth?()
        finish()
        check(store.expandedMode == "month", "Clicking the cube opens Month")
        c.pollCursor(at: NSPoint(x: left.midX, y: left.midY))
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(store.expandedMode == "month" && c.state.headerHovered, "Score hover does not change Month")
        c.state.onSelectDay?()
        finish()
        check(store.expandedMode == "today", "Clicking the score returns to Today")

        c.state.onSelectMonth?()
        finish()
        c.state.pinned = false
        c.collapse()
        if let motion = c.motion { c.advanceAnimation(at: motion.started + motion.duration * 0.4) }
        let before = c.interactionFrame
        c.pollCursor(at: NSPoint(x: before.maxX - 2, y: before.maxY - 10))
        check(c.state.expanded && store.expandedMode == "today", "Right-side re-entry during collapse opens Today")
        check(c.interactionFrame == before, "Reversing collapse preserves the currently visible frame")
        finish()
        check(c.state.monthProgress == 0, "Interrupted collapse settles on Today")

        close(on: "month")
        c.isDragging = true
        c.pollCursor(at: entry(-20))
        check(!c.state.expanded, "Dragging does not trigger expansion")
        c.isDragging = false
        c.state.geometry.horizontalOffset = c.state.geometry.settledOffset(400)
        c.refreshGeometry()
        c.pollCursor(at: entry(1))
        finish()
        check(store.expandedMode == "today", "Off-notch entry also opens Today")
        close(on: "month")
        c.screensChanged([TestScreen(id: 2002, frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080))])
        c.pollCursor(at: entry(1))
        finish()
        check(store.expandedMode == "today", "External-display entry opens Today")
        close(on: "month")
        c.forceExpandedForDebug()
        check(!c.state.pinned && !c.state.expanded, "Regular mode has no debug pin entry point")
        c.expand()
        finish()
        check(!c.state.pinned && store.expandedMode == "today", "Regular hover expansion starts with Today")
        c.state.onSelectMonth?()
        finish()
        c.expand()
        check(store.expandedMode == "month", "An already open Month stays visible until closed or explicitly changed")

        for legacyValue in [false, true] {
            let legacy = MemoryDefaults()
            legacy.set(legacyValue, forKey: "Glitter.alwaysShowTodayOnHover")
            let restored = NotchPanelController(store: TaskStore.todayFixture().0, defaults: legacy)
            restored.hoverTimer?.invalidate()
            restored.expand()
            check(restored.store.expandedMode == "today", "Legacy hover settings do not change the new default")
            restored.stopAnimation()
            restored.panel.orderOut(nil)
        }
        let previousDay = c.renderCache.snapshot(page: .day, store: store, state: c.state)
        let previousMonth = c.renderCache.snapshot(page: .month, store: store, state: c.state)
        store.fixtureTasks(count: 5, completed: 3)
        finish()
        check(c.renderCache.snapshot(page: .day, store: store, state: c.state)?.body !== previousDay?.body
              && c.renderCache.snapshot(page: .month, store: store, state: c.state)?.body !== previousMonth?.body,
              "Changed task data refreshes both cached pages")
        print("PASS \(count) Today-only hover, cube navigation and cache checks")
    }
}
