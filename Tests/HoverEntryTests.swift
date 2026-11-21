import AppKit
import XCTest
@testable import Glitter

@MainActor
final class HoverEntryTests: XCTestCase {
    func testTodayOnlyHoverCubeNavigationAndCache() async {
        let defaults = MemoryDefaults()
        let (store, _) = TaskStore.todayFixture()
        let c = NotchPanelController(store: store, defaults: defaults)
        c.screensChanged([DisplayMetrics.fixture(id: 1001, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: 185)])
        defer { c.panel.orderOut(nil) }

        func close(on mode: String) {
            c.state.pinned = false
            c.collapse()
            finishAnimation(on: c)
            store.setExpandedMode(mode)
            finishAnimation(on: c)
        }

        func entry(_ offset: CGFloat) -> NSPoint {
            let rect = c.state.geometry.collapsedRect
            return NSPoint(x: rect.midX + offset, y: rect.midY)
        }

        close(on: "month")
        let cachedDay = c.renderCache.snapshot(page: .day, store: store, state: c.state)
        let cachedMonth = c.renderCache.snapshot(page: .month, store: store, state: c.state)
        XCTAssertNotNil(cachedDay)
        XCTAssertNotNil(cachedMonth)

        var menuUpdates = 0
        c.onDataChanged = { menuUpdates += 1 }
        var taskUpdates = 0
        let subscription = store.objectWillChange.sink { taskUpdates += 1 }

        for offset in [-120.0, -0.25, 0.0, 0.25, 120.0] {
            close(on: "month")
            c.pollCursor(at: entry(offset))
            c.hoverTimer?.invalidate()
            XCTAssertTrue(c.state.expanded && store.expandedMode == "today")
            XCTAssertEqual(c.state.monthProgress, 0)
            XCTAssertEqual(c.motion?.start.second.second.second, c.motion?.target.second.second.second)
            finishAnimation(on: c)
        }
        XCTAssertEqual(menuUpdates, 0)
        XCTAssertEqual(taskUpdates, 0)
        subscription.cancel()

        XCTAssertTrue(c.renderCache.snapshot(page: .day, store: store, state: c.state)?.body === cachedDay?.body)
        XCTAssertTrue(c.renderCache.snapshot(page: .month, store: store, state: c.state)?.body === cachedMonth?.body)

        c.state.pinned = true
        let right = c.state.geometry.blockInteractionRect(in: c.panel.frame)
        let left = c.state.geometry.headerInteractionRect(in: c.panel.frame)
        c.pollCursor(at: NSPoint(x: right.midX, y: right.midY))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(store.expandedMode == "today" && c.state.blockHovered)
        c.state.onSelectMonth?()
        XCTAssertEqual(c.state.pressedHeaderButton, .month)
        finishAnimation(on: c)
        try? await Task.sleep(for: .milliseconds(180))
        XCTAssertNil(c.state.pressedHeaderButton)
        XCTAssertEqual(store.expandedMode, "month")

        c.pollCursor(at: NSPoint(x: left.midX, y: left.midY))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(store.expandedMode == "month" && c.state.headerHovered)
        c.state.onSelectDay?()
        finishAnimation(on: c)
        XCTAssertEqual(store.expandedMode, "today")

        c.state.onSelectMonth?()
        finishAnimation(on: c)
        c.state.pinned = false
        c.collapse()
        if let motion = c.motion { c.advanceAnimation(at: motion.started + motion.duration * 0.4) }
        let before = c.interactionFrame
        c.pollCursor(at: NSPoint(x: before.maxX - 2, y: before.maxY - 10))
        c.hoverTimer?.invalidate()
        XCTAssertTrue(c.state.expanded && store.expandedMode == "today")
        XCTAssertEqual(c.interactionFrame, before)
        finishAnimation(on: c)
        XCTAssertEqual(c.state.monthProgress, 0)

        close(on: "month")
        c.isDragging = true
        c.pollCursor(at: entry(-20))
        XCTAssertFalse(c.state.expanded)
        c.isDragging = false
        c.state.geometry.horizontalOffset = c.state.geometry.settledOffset(400)
        c.refreshGeometry()
        c.pollCursor(at: entry(1))
        c.hoverTimer?.invalidate()
        finishAnimation(on: c)
        XCTAssertEqual(store.expandedMode, "today")

        close(on: "month")
        c.screensChanged([DisplayMetrics.fixture(id: 2002, frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080))])
        c.pollCursor(at: entry(1))
        c.hoverTimer?.invalidate()
        finishAnimation(on: c)
        XCTAssertEqual(store.expandedMode, "today")

        close(on: "month")
        c.forceExpandedForDebug()
        XCTAssertFalse(c.state.pinned || c.state.expanded)
        c.expand()
        c.hoverTimer?.invalidate()
        finishAnimation(on: c)
        XCTAssertTrue(!c.state.pinned && store.expandedMode == "today")
        c.state.onSelectMonth?()
        finishAnimation(on: c)
        c.expand()
        XCTAssertEqual(store.expandedMode, "month")

        for screen in [
            DisplayMetrics.fixture(id: 3001, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: 185),
            DisplayMetrics.fixture(id: 3002, frame: NSRect(x: 0, y: 0, width: 1920, height: 1080))
        ] {
            close(on: "today")
            c.screensChanged([screen])
            c.state.geometry.horizontalOffset = 400
            c.refreshGeometry()
            let folded = c.state.geometry.collapsedRect
            let pointer = NSPoint(x: folded.midX + 1, y: folded.midY)
            c.pollCursor(at: pointer)
            c.hoverTimer?.invalidate()
            guard let opening = c.motion else {
                XCTFail("Pill hover must start an expansion animation")
                return
            }
            for step in 0...20 {
                c.advanceAnimation(at: opening.started + opening.duration * Double(step) / 20)
                let visible = c.interactionFrame
                let left = c.state.geometry.headerInteractionRect(in: visible)
                let right = c.state.geometry.blockInteractionRect(in: visible)
                XCTAssertLessThanOrEqual(left.maxX, right.minX + 0.000001)
                XCTAssertEqual(left.width, visible.width / 2)
                XCTAssertEqual(right.width, visible.width / 2)
                c.pollCursor(at: pointer)
                XCTAssertFalse(c.state.blockHovered || c.state.headerHovered)
            }
            finishAnimation(on: c)
            c.resetHeaderHover(at: pointer)
            c.pollCursor(at: pointer)
            c.pollCursor(at: NSPoint(x: pointer.x + 2, y: pointer.y))
            XCTAssertFalse(c.state.blockHovered || c.state.headerHovered)
            let outside = NSPoint(x: c.panel.frame.midX, y: c.panel.frame.minY + 5)
            c.pollCursor(at: outside)
            c.pollCursor(at: pointer)
            XCTAssertTrue(c.state.blockHovered && !c.state.headerHovered)
            c.isDragging = true
            c.pollCursor(at: pointer)
            XCTAssertFalse(c.state.headerHovered || c.state.blockHovered)
            c.isDragging = false
        }

        for legacyValue in [false, true] {
            let legacy = MemoryDefaults()
            legacy.set(legacyValue, forKey: "Glitter.alwaysShowTodayOnHover")
            let restored = NotchPanelController(store: TaskStore.todayFixture().0, defaults: legacy)
            restored.expand()
            restored.hoverTimer?.invalidate()
            XCTAssertEqual(restored.store.expandedMode, "today")
            restored.stopAnimation()
            restored.panel.orderOut(nil)
        }

        let previousDay = c.renderCache.snapshot(page: .day, store: store, state: c.state)
        let previousMonth = c.renderCache.snapshot(page: .month, store: store, state: c.state)
        store.fixtureTasks(count: 5, completed: 3)
        finishAnimation(on: c)
        XCTAssertTrue(c.renderCache.snapshot(page: .day, store: store, state: c.state)?.body !== previousDay?.body)
        XCTAssertTrue(c.renderCache.snapshot(page: .month, store: store, state: c.state)?.body !== previousMonth?.body)
    }
}
