import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Glitter

@MainActor
final class ControllerTests: XCTestCase {
    func testOnDemandHoverTimerLifecycle() {
        let (store, _) = TaskStore.todayFixture()
        let c = NotchPanelController(store: store, defaults: MemoryDefaults())
        defer { c.panel.orderOut(nil) }
        c.screensChanged([DisplayMetrics.fixture(id: 1001, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: 185)])

        XCTAssertNil(c.hoverTimer, "Collapsed panel keeps hover timer stopped")
        c.expand()
        XCTAssertNotNil(c.hoverTimer, "Expanded unpinned panel runs hover timer")
        finishAnimation(on: c)
        XCTAssertNotNil(c.hoverTimer)

        c.state.pinned = true
        c.collapse() // No-op when pinned, test togglePinned below
        c.state.pinned = false
        c.collapse()
        XCTAssertNil(c.hoverTimer, "Collapsing stops hover timer immediately")
        finishAnimation(on: c)
        XCTAssertNil(c.hoverTimer)

        let (demoStore, _) = TaskStore.todayFixture()
        demoStore.loadDemoData()
        let demo = NotchPanelController(store: demoStore, defaults: DemoDefaults())
        defer { demo.panel.orderOut(nil) }
        demo.screensChanged([DisplayMetrics.fixture(id: 1002, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: 185)])
        demo.forceExpandedForDebug()
        finishAnimation(on: demo)
        XCTAssertNil(demo.hoverTimer, "Pinned demo panel stops hover timer")
        demo.togglePinned()
        XCTAssertNotNil(demo.hoverTimer, "Unpinning expanded demo panel starts hover timer")
        demo.collapse()
        XCTAssertNil(demo.hoverTimer)
    }

    func testHorizontalPagesOverflowGestureAndRendering() {
        let (store, workspace) = TaskStore.todayFixture()
        let c = NotchPanelController(store: store, defaults: MemoryDefaults())
        defer { c.panel.orderOut(nil) }
        let builtIn = DisplayMetrics.fixture(id: 1001, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: 185)
        let external = DisplayMetrics.fixture(id: 2002, frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080))
        c.screensChanged([builtIn])

        @discardableResult
        func capture(_ name: String) -> NSBitmapImageRep {
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            return ReviewArtifacts.captureView(c.surfaceView, filename: "horizontal-\(name).png")
        }

        let reserved = NotchGeometry.make(for: builtIn, rows: 6, offset: 0, scoreText: "99/99")
        XCTAssertTrue(reserved.horizontalPadding == 12 && reserved.padding == 12)
        XCTAssertEqual(reserved.collapsedHeight, 32)
        XCTAssertTrue(reserved.expandedWidth == 286 && reserved.contentWidth == 262)

        let unnotched = NotchGeometry.make(for: external, rows: 6, offset: 0, referenceNotchWidth: 185)
        XCTAssertEqual(unnotched.collapsedHeight, 34)
        XCTAssertEqual(unnotched.collapsedWidth, ceil((NotchGeometry.reservedScoreWidth + unnotched.blockSize + 24 + 16) / 2) * 2)
        XCTAssertEqual(reserved.monthTop - reserved.collapsedHeight, 12)

        var monthGeometry = reserved
        monthGeometry.showingMonth = true
        XCTAssertLessThan(abs(monthGeometry.expandedHeight - monthGeometry.monthTop - monthGeometry.monthViewportHeight - 12), 1)
        XCTAssertEqual(reserved.taskHeight(TrackedTask(id: "single-line", title: "A reminder", dueDay: nil,
                                                       completedDay: nil, isCompleted: false)), 26)
        XCTAssertGreaterThan(reserved.taskHeight(TrackedTask(id: "wrapped", title: String(repeating: "Long reminder title ", count: 8),
                                                             dueDay: nil, completedDay: nil, isCompleted: false)), 26)
        XCTAssertEqual(reserved.horizontalPadding, reserved.headerPadding)
        XCTAssertLessThan(abs(reserved.gridOriginX - reserved.headerPadding), 0.001)
        XCTAssertLessThan(abs(reserved.gridOriginX + reserved.gridWidth - (reserved.expandedWidth - reserved.headerPadding)), 0.001)

        for score in ["0/0", "2/5", "9/9", "10/10", "99/99", "1000/1000"] {
            let geometry = NotchGeometry.make(for: builtIn, rows: 6, offset: 0, scoreText: score)
            XCTAssertEqual(geometry.expandedWidth, reserved.expandedWidth)
            XCTAssertEqual(geometry.collapsedWidth, reserved.collapsedWidth)
            XCTAssertEqual(geometry.headerButtonWidth, reserved.headerButtonWidth)
            if score == "1000/1000" { XCTAssertLessThan(geometry.scoreScale, 1) }
            else { XCTAssertEqual(geometry.scoreScale, 1) }
        }

        var offNotch = reserved
        offNotch.horizontalOffset = offNotch.settledOffset(400)
        XCTAssertEqual(offNotch.headerButtonWidth * 2, offNotch.expandedWidth)

        let width = c.panel.frame.width
        let top = c.panel.frame.maxY
        c.state.onSelectMonth?()
        XCTAssertEqual(store.expandedMode, "today")
        capture("folded")

        c.expand()
        c.hoverTimer?.invalidate()
        XCTAssertEqual(c.motion?.spring?.response ?? 0, 0.36, accuracy: 0.000001)
        finishAnimation(on: c)
        XCTAssertEqual(c.panel.frame.midX, builtIn.frame.midX)
        var dayHeight = c.panel.frame.height
        capture("day")
        XCTAssertEqual(c.panel.frame.width, width)
        XCTAssertEqual(c.panel.frame.maxY, top)
        XCTAssertFalse(c.state.geometry.dayScrolls)

        c.state.onSelectMonth?()
        XCTAssertEqual(c.motion?.pageDuration, 0.16)
        finishAnimation(on: c)
        XCTAssertEqual(store.expandedMode, "month")
        XCTAssertGreaterThan(c.panel.frame.height, dayHeight)
        XCTAssertTrue(c.state.geometry.taskInteractionRects(tasks: store.todayTasks, in: c.panel.frame).isEmpty)

        c.state.onSelectDay?()
        finishAnimation(on: c)
        XCTAssertEqual(store.expandedMode, "today")
        XCTAssertTrue(workspace.openedURLs.isEmpty)

        c.isDragging = true
        c.state.onSelectMonth?()
        XCTAssertEqual(store.expandedMode, "today")
        c.isDragging = false
        c.lastDragEndedAt = Date()
        c.state.onSelectMonth?()
        XCTAssertEqual(store.expandedMode, "today")
        c.lastDragEndedAt = .distantPast

        let score = c.state.geometry.headerInteractionRect(in: c.panel.frame)
        let block = c.state.geometry.blockInteractionRect(in: c.panel.frame)
        XCTAssertEqual(score.minX, c.panel.frame.minX)
        XCTAssertEqual(score.maxY, c.panel.frame.maxY)
        XCTAssertEqual(score.height, c.state.geometry.collapsedHeight)
        XCTAssertEqual(block.maxX, c.panel.frame.maxX)
        XCTAssertEqual(block.maxY, c.panel.frame.maxY)
        XCTAssertEqual(block.height, score.height)
        XCTAssertEqual(block.minX - score.maxX, 185)
        XCTAssertEqual((block.minX - score.maxX) * c.state.geometry.displayScale, 370)
        XCTAssertEqual(block.width, score.width)
        XCTAssertGreaterThan(block.width, c.state.geometry.blockSize + 10)
        XCTAssertEqual(score.maxX, c.panel.frame.midX - c.state.geometry.notchWidth / 2)

        c.pollCursor(at: NSPoint(x: score.midX, y: score.midY))
        XCTAssertTrue(c.state.headerHovered && !c.state.blockHovered)
        let leftHover = capture("left-button-hover")
        let inner = c.state.geometry.headerButtonWidth
        XCTAssertLessThan(ReviewArtifacts.samplePixel(leftHover, x: 2, y: 2)[0], 20)
        XCTAssertLessThan(ReviewArtifacts.samplePixel(leftHover, x: 2, y: score.height - 2)[0], 20)
        XCTAssertLessThan(ReviewArtifacts.samplePixel(leftHover, x: inner - 1, y: 1)[0], 20)
        XCTAssertLessThan(ReviewArtifacts.samplePixel(leftHover, x: inner - 1, y: score.height - 1)[0], 20)

        c.pollCursor(at: NSPoint(x: block.midX, y: block.midY))
        XCTAssertTrue(c.state.blockHovered && !c.state.headerHovered)
        let rightHover = capture("right-button-hover")
        XCTAssertLessThan(ReviewArtifacts.samplePixel(rightHover, x: c.panel.frame.width - 3, y: 2)[0], 20)
        XCTAssertLessThan(ReviewArtifacts.samplePixel(rightHover, x: c.panel.frame.width - inner + 1, y: score.height - 1)[0], 20)

        c.pollCursor(at: NSPoint(x: c.panel.frame.midX, y: score.midY))
        XCTAssertFalse(c.state.headerHovered || c.state.blockHovered)

        c.state.onSelectMonth?()
        finishAnimation(on: c)
        XCTAssertEqual(store.expandedMode, "month")
        c.collapse()
        XCTAssertEqual(c.motion?.spring?.response ?? 0, 0.26, accuracy: 0.000001)
        finishAnimation(on: c)
        XCTAssertEqual(store.expandedMode, "month")
        XCTAssertEqual(c.panel.frame.height, c.state.geometry.collapsedHeight)

        c.expand()
        c.hoverTimer?.invalidate()
        finishAnimation(on: c)
        XCTAssertEqual(c.state.monthProgress, 0)
        c.state.onSelectDay?()
        finishAnimation(on: c)

        store.fixtureTasks(count: 1, completed: 0)
        finishAnimation(on: c)
        let singleHeight = c.panel.frame.height
        XCTAssertLessThan(singleHeight, dayHeight)
        XCTAssertFalse(c.state.geometry.dayScrolls)

        store.fixtureTasks(count: 7, completed: 0)
        finishAnimation(on: c)
        XCTAssertFalse(c.state.geometry.dayScrolls)
        XCTAssertGreaterThan(c.panel.frame.height, singleHeight)

        let rowTargets = c.state.geometry.taskInteractionRects(tasks: store.todayTasks, in: c.panel.frame)
        XCTAssertEqual(rowTargets[0].rect.minY, rowTargets[1].rect.maxY)
        let firstTarget = rowTargets[0]
        XCTAssertEqual(firstTarget.rect.minX, c.panel.frame.minX)
        XCTAssertEqual(firstTarget.rect.width, c.panel.frame.width)
        c.pollCursor(at: NSPoint(x: firstTarget.rect.minX + 1, y: firstTarget.rect.midY))
        XCTAssertEqual(c.state.hoveredTaskID, firstTarget.id)
        c.pollCursor(at: NSPoint(x: firstTarget.rect.maxX - 1, y: firstTarget.rect.midY))
        XCTAssertEqual(c.state.hoveredTaskID, firstTarget.id)

        store.fixtureTasks(count: 12, completed: 3, longTitles: true)
        finishAnimation(on: c)
        let g = c.state.geometry
        XCTAssertTrue(g.dayScrolls && g.todayContentHeight > g.dayViewportHeight)
        dayHeight = c.panel.frame.height
        XCTAssertEqual(dayHeight, g.maximumExpandedHeight)
        XCTAssertTrue(g.taskInteractionRects(tasks: store.todayTasks, in: c.panel.frame).isEmpty)
        capture("long-scroll")

        func findScrollView(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScrollView($0) }.first
        }
        let scrollView = findScrollView(c.surfaceView)
        XCTAssertNotNil(scrollView)
        XCTAssertEqual(scrollView?.scrollerStyle, .overlay)
        XCTAssertLessThan(abs((scrollView?.contentView.bounds.width ?? 0) - c.state.geometry.expandedWidth), 0.5)
        if let scrollView {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        let scrollOrigin = scrollView?.contentView.bounds.origin
        capture("long-scrolled")
        let currentDay = c.snapshotLayer.captureLive(headerHeight: g.collapsedHeight)!
        c.state.onSelectMonth?()
        let bodyLayer = c.surfaceView.layer!.sublayers!.first { $0.zPosition == 10 }!.sublayers!.first!
        let animatedDay = bodyLayer.contents as! CGImage
        XCTAssertEqual(NSBitmapImageRep(cgImage: animatedDay).tiffRepresentation,
                       NSBitmapImageRep(cgImage: currentDay.body).tiffRepresentation)
        finishAnimation(on: c)
        XCTAssertEqual(c.panel.frame.height, dayHeight)
        c.state.onSelectDay?()
        finishAnimation(on: c)
        XCTAssertEqual(c.panel.frame.height, dayHeight)
        XCTAssertEqual(scrollView?.contentView.bounds.origin, scrollOrigin)

        store.fixtureTasks(count: 0, completed: 0)
        finishAnimation(on: c)
        dayHeight = c.state.geometry.expandedHeight
        XCTAssertFalse(c.state.geometry.dayScrolls)
        XCTAssertLessThanOrEqual(abs(c.panel.frame.height - dayHeight), 0.5)
        capture("empty")

        store.loadDemoData()
        c.state.onSelectMonth?()
        finishAnimation(on: c)
        let month = capture("month")
        let raster = c.renderCache.snapshot(page: .month, store: store, state: c.state)!
        XCTAssertEqual(raster.body.width, Int(width * c.state.geometry.displayScale))

        var colors = Set<UInt32>()
        var neutral = 0
        for (rowIndex, row) in store.monthRows.enumerated() {
            for (columnIndex, day) in row.enumerated() {
                guard let day, let date = store.date(inMonth: day) else { continue }
                let g = c.state.geometry
                let x = g.gridOriginX + CGFloat(columnIndex) * (g.cell + g.cellGap) + g.cell / 2
                let y = g.monthTop + g.monthHeadingHeight + g.monthHeadingGap + g.monthWeekdayHeight + CGFloat(rowIndex) * (g.cell + g.cellGap) + g.cell / 2
                let pixel = ReviewArtifacts.samplePixel(month, x: x, y: y)
                if date == store.today {
                    XCTAssertTrue(pixel[0] > 245 && pixel[1] > 245 && pixel[2] > 245)
                    continue
                }
                let hex = UInt32(pixel[0] << 16 | pixel[1] << 8 | pixel[2])
                if date > store.today || store.stat(for: date).done == 0 {
                    XCTAssertEqual(hex, 0x141414)
                    neutral += 1
                } else {
                    XCTAssertEqual(hex, Theme.paletteHex[Theme.level(for: store.stat(for: date).ratio)])
                    colors.insert(hex)
                }
            }
        }
        XCTAssertTrue(neutral > 0 && colors.count >= 7)

        for index in 0..<30 {
            store.setExpandedMode(index % 2 == 0 ? "today" : "month")
            if let motion = c.motion { c.advanceAnimation(at: motion.started + 0.04) }
            XCTAssertTrue(c.panel.frame.width == width && c.panel.frame.maxY == top)
            XCTAssertEqual(c.interactionFrame.midX, builtIn.frame.midX)
            XCTAssertEqual(c.headerHosting.frame.midX + c.panel.frame.minX, builtIn.frame.midX)
        }
        finishAnimation(on: c)
        XCTAssertTrue(c.motion == nil && c.animationDisplayLink?.isPaused != false)

        c.collapse()
        finishAnimation(on: c)
        c.state.geometry.horizontalOffset = c.state.geometry.settledOffset(200)
        c.updateWindowFrame(expanded: false)
        XCTAssertLessThan(c.panel.frame.width, width)
        c.expand()
        c.hoverTimer?.invalidate()
        finishAnimation(on: c)
        XCTAssertEqual(c.panel.frame.width, width)
        XCTAssertEqual(c.panel.frame.midX, c.state.geometry.alignedCenterX)

        c.screensChanged([builtIn, external])
        c.selectDisplay(2002)
        finishAnimation(on: c)
        XCTAssertEqual(c.panel.frame.width, width)

        c.state.pinned = true
        c.expand()
        finishAnimation(on: c)
        c.state.pinned = false
        c.collapse()
        XCTAssertTrue(c.snapshotLayer.isVisible && c.surfaceView.blocksContentInput)
        let animatedWindow = c.panel.frame
        var changes = 0
        let subscription = c.state.objectWillChange.sink { changes += 1 }
        var previousHeight = c.interactionFrame.height
        let closing = c.motion!
        for frame in 1..<20 {
            c.advanceAnimation(at: closing.started + closing.duration * Double(frame) / 20)
            XCTAssertEqual(NSColor(cgColor: c.surfaceView.layer!.backgroundColor!), NSColor.black)
            XCTAssertEqual(c.surfaceView.layer!.borderWidth, 0)
            XCTAssertFalse(c.headerHosting.isHidden)
            XCTAssertEqual(c.panel.frame, animatedWindow)
            let visible = c.interactionFrame.height
            XCTAssertTrue(visible <= previousHeight + 0.001 && visible >= c.state.geometry.collapsedHeight)
            previousHeight = visible
        }
        XCTAssertEqual(changes, 0)
        finishAnimation(on: c)
        XCTAssertEqual(c.panel.frame.height, c.state.geometry.collapsedHeight)
        XCTAssertFalse(c.snapshotLayer.isVisible || c.surfaceView.blocksContentInput)
        subscription.cancel()

        c.expand()
        c.hoverTimer?.invalidate()
        let beforeFirstTick = c.interactionFrame.height
        c.collapse()
        XCTAssertLessThan(abs(c.interactionFrame.height - beforeFirstTick), 0.001)
        finishAnimation(on: c)

        c.expand()
        c.hoverTimer?.invalidate()
        if let opening = c.motion { c.advanceAnimation(at: opening.started + opening.duration * 0.4) }
        let interruptedHeight = c.interactionFrame.height
        c.collapse()
        XCTAssertLessThan(abs(c.interactionFrame.height - interruptedHeight), 0.001)
        finishAnimation(on: c)
        XCTAssertEqual(c.panel.frame.height, c.state.geometry.collapsedHeight)

        c.expand()
        c.hoverTimer?.invalidate()
        finishAnimation(on: c)
        let beforeDeferred = store.todayTasks
        c.collapse()
        store.fixtureTasks(count: 2, completed: 0)
        XCTAssertEqual(store.todayTasks, beforeDeferred)
        finishAnimation(on: c)
        XCTAssertEqual(store.todayTasks.count, 2)
        XCTAssertEqual(c.panel.frame.height, c.state.geometry.collapsedHeight)

        var hugeDay = c.state.geometry
        hugeDay.showingMonth = false
        hugeDay.measureToday(tasks: Array(repeating: store.todayTasks[0], count: 100), error: nil, summary: nil)
        XCTAssertLessThanOrEqual(hugeDay.expandedHeight, hugeDay.screenFrame.height - 8)
        XCTAssertLessThan(hugeDay.dayViewportHeight, hugeDay.todayContentHeight)
    }

    func testCraftPresentation() async {
        let (store, _) = TaskStore.todayFixture()
        store.loadDemoData()
        let c = NotchPanelController(store: store, defaults: MemoryDefaults())
        c.screensChanged([DisplayMetrics.fixture(id: 1001, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: 185)])
        c.state.pinned = true
        c.expand()
        c.hoverTimer?.invalidate()

        let animationClock = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated { c.advanceAnimation(at: CACurrentMediaTime()) }
        }
        RunLoop.main.add(animationClock, forMode: .common)
        defer { animationClock.invalidate(); c.panel.orderOut(nil) }

        func capture(_ name: String, settle: Bool = true) async {
            if settle { finishAnimation(on: c); try? await Task.sleep(nanoseconds: 180_000_000) }
            ReviewArtifacts.captureView(c.surfaceView, filename: "craft-\(name).png")
        }

        for (name, status): (String, TaskStore.PanelStatus) in [
            ("access", .denied), ("choose-list", .unselected), ("unavailable", .unavailable),
            ("loading", .loading), ("load-failed", .failed)
        ] {
            store.loadStatusDemoData(status)
            store.setExpandedMode("today")
            finishAnimation(on: c)
            XCTAssertFalse(c.state.geometry.dayScrolls || c.state.geometry.showsCalendar)
            await capture(name)
            store.setExpandedMode("month")
            finishAnimation(on: c)
            XCTAssertEqual(c.state.geometry.monthViewportHeight, c.state.geometry.todayContentHeight)
            if status == .failed { await capture("month-unavailable") }
        }

        store.retryLoad()
        finishAnimation(on: c)
        XCTAssertTrue(c.state.geometry.showsCalendar && store.hasStatistics)
        await capture("month")

        store.setExpandedMode("today")
        store.loadEmptyListDemoData()
        await capture("empty-list")
        store.loadUndatedDemoData()
        await capture("undated")
        store.loadFutureDemoData()
        await capture("future")
        store.loadDemoData(taskCount: 0, completedCount: 0)
        await capture("unscheduled")
        store.loadStaleDemoData()
        await capture("stale-day")
        XCTAssertTrue(c.state.geometry.noticeHeight > 0 && store.todayTasks.count == 5)
        store.setExpandedMode("month")
        await capture("stale-month")
        store.retryLoad()
        finishAnimation(on: c)
        XCTAssertEqual(c.state.geometry.noticeHeight, 0)

        store.setExpandedMode("today")
        store.loadSaveFailureDemoData(taskCount: 12)
        finishAnimation(on: c)
        await store.completeTask(store.pendingTasks[0].id)
        await capture("save-failed-long-day")
        XCTAssertTrue(c.state.geometry.dayScrolls && c.state.geometry.noticeHeight > 0)
        await store.retryCompletion()
        finishAnimation(on: c)
        XCTAssertTrue(store.taskError == nil && c.state.geometry.noticeHeight == 0)

        store.loadUnconfirmedSaveDemoData()
        finishAnimation(on: c)
        await store.completeTask(store.pendingTasks[0].id)
        await capture("saved-awaiting-refresh")
        store.retryLoad()
        await capture("saved-recovered")

        store.loadDemoData(taskCount: 6, completedCount: 6)
        finishAnimation(on: c)
        XCTAssertFalse(c.state.geometry.dayScrolls)
        await capture("six-completed")

        store.loadLongTitleDemoData()
        finishAnimation(on: c)
        let g = c.state.geometry
        XCTAssertEqual(g.todayContentHeight, g.taskHeight(store.presentationTasks[0]))
        XCTAssertLessThanOrEqual(c.panel.frame.height, g.maximumExpandedHeight)
        XCTAssertEqual(g.dayViewportHeight, min(g.todayContentHeight, g.maximumExpandedHeight - g.monthTop - g.padding))
        await capture("long-title-scroll")

        for month in [2, 4, 11] {
            store.loadDemoMonthFixture(month: month)
            store.setExpandedMode("month")
            finishAnimation(on: c)
            XCTAssertEqual(c.state.geometry.monthViewportHeight, c.state.geometry.monthContentHeight)
            XCTAssertEqual((c.state.geometry.cell * c.state.geometry.displayScale).rounded(),
                           c.state.geometry.cell * c.state.geometry.displayScale)
            await capture("month-\(month)")
        }

        store.loadDemoData(taskCount: 5, completedCount: 2)
        store.setExpandedMode("today")
        finishAnimation(on: c)
        await capture("completion-before")
        let mutation = Task { await store.completeTask(store.pendingTasks[0].id) }
        for _ in 0..<500 {
            if store.completionAnchor != nil { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        await capture("completion-acknowledged", settle: false)
        try? await Task.sleep(nanoseconds: 140_000_000)
        await capture("completion-moving", settle: false)
        await mutation.value
        await capture("completion-settled")
        XCTAssertFalse(c.snapshotLayer.isVisible)
        XCTAssertNotEqual(c.animationDisplayLink?.isPaused, false)
    }
}
