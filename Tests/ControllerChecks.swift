import AppKit
import SwiftUI
import Combine

extension NotchPanelController {
    static func checkTodayInteraction() {
        _ = NSApplication.shared
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            count += 1
        }
        let (store, workspace) = TaskStore.todayFixture()
        let c = NotchPanelController(store: store, defaults: MemoryDefaults())
        c.hoverTimer?.invalidate()
        let builtIn = TestScreen(id: 1001, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: 185)
        let external = TestScreen(id: 2002, frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080))
        c.screensChanged([builtIn])
        func finish() {
            for _ in 0..<10 {
                guard let motion = c.motion else { break }
                c.advanceAnimation(at: motion.started + motion.duration + 0.01)
            }
        }
        @discardableResult
        func capture(_ name: String) -> NSBitmapImageRep {
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            let host = c.surfaceView
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let output = ProcessInfo.processInfo.environment["GLITTER_REVIEW_OUTPUT"]!
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(output)/horizontal-\(name).png"))
            return bitmap
        }
        func sample(_ bitmap: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> [Int] {
            var pixel = [Int](repeating: 0, count: bitmap.samplesPerPixel)
            bitmap.getPixel(&pixel, atX: Int(x), y: Int(y))
            return pixel
        }
        let reserved = NotchGeometry.make(for: builtIn, rows: 6, offset: 0, scoreText: "99/99")
        check(reserved.horizontalPadding == 12 && reserved.padding == 12,
              "Horizontal padding is 12pt and vertical padding returns to 12pt")
        check(reserved.collapsedHeight == 32,
              "The folded header returns to the physical notch height")
        check(reserved.expandedWidth == 286 && reserved.contentWidth == 262,
              "The wider horizontal padding preserves the original content width")
        let unnotched = NotchGeometry.make(for: external, rows: 6, offset: 0, referenceNotchWidth: 185)
        check(unnotched.collapsedHeight == 34,
              "External displays retain the original folded header height")
        check(unnotched.collapsedWidth == ceil((NotchGeometry.reservedScoreWidth + unnotched.blockSize + 24 + 16) / 2) * 2,
              "Compact folded layout uses 12pt outer padding and its original 16pt inner gap")
        check(reserved.monthTop - reserved.collapsedHeight == 12,
              "Expanded content returns to its original top padding")
        var monthGeometry = reserved
        monthGeometry.showingMonth = true
        check(abs(monthGeometry.expandedHeight - monthGeometry.monthTop - monthGeometry.monthViewportHeight - 12) < 1,
              "Month returns to its original bottom padding")
        check(reserved.taskHeight(TrackedTask(id: "single-line", title: "A reminder", dueDay: nil,
                                             completedDay: nil, isCompleted: false)) == 26,
              "Single-line reminders retain the workspace 26pt hit area")
        check(reserved.taskHeight(TrackedTask(id: "wrapped", title: String(repeating: "Long reminder title ", count: 8),
                                             dueDay: nil, completedDay: nil, isCompleted: false)) > 26,
              "Wrapped reminders grow beyond 26pt to retain their full titles")
        check(reserved.horizontalPadding == reserved.headerPadding, "Body and header share horizontal content insets")
        check(abs(reserved.gridOriginX - reserved.headerPadding) < 0.001,
              "Calendar leading edge aligns with the score")
        check(abs(reserved.gridOriginX + reserved.gridWidth - (reserved.expandedWidth - reserved.headerPadding)) < 0.001,
              "Calendar trailing edge aligns with the status cube")
        for score in ["0/0", "2/5", "9/9", "10/10", "99/99", "1000/1000"] {
            let geometry = NotchGeometry.make(for: builtIn, rows: 6, offset: 0, scoreText: score)
            check(geometry.expandedWidth == reserved.expandedWidth && geometry.collapsedWidth == reserved.collapsedWidth,
                  "Score digits never resize the container")
            check(geometry.headerButtonWidth == reserved.headerButtonWidth, "Score digits never move notch hover boundary")
            check(score == "1000/1000" ? geometry.scoreScale < 1 : geometry.scoreScale == 1,
                  "99/99 fits reserved space and longer scores shrink inside it")
        }
        var offNotch = reserved
        offNotch.horizontalOffset = offNotch.settledOffset(400)
        check(offNotch.headerButtonWidth * 2 == offNotch.expandedWidth, "Off-notch header retains two full-width halves")
        print("ALIGNMENT AFTER", "native", c.panel.frame, "requested", c.state.geometry.collapsedRect, "screenCenter", c.state.geometry.screenFrame.midX)
        let width = c.panel.frame.width
        let top = c.panel.frame.maxY
        c.state.onSelectMonth?()
        check(store.expandedMode == "today", "Collapsed block does not change the page")
        capture("folded")
        c.expand()
        check(abs((c.motion?.spring?.response ?? 0) - 0.36) < 0.000001, "Hover expansion uses the selected spring")
        finish()
        check(c.panel.frame.midX == builtIn.frame.midX, "Native window centers exactly on the 185pt notch")
        var dayHeight = c.panel.frame.height
        capture("day")
        check(c.panel.frame.width == width && c.panel.frame.maxY == top, "Expansion preserves notch width and top edge")
        check(!c.state.geometry.dayScrolls, "Short Day has no disclosure")
        c.state.onSelectMonth?()
        check(c.motion?.pageDuration == 0.16, "Changing pages takes 160ms")
        finish()
        check(store.expandedMode == "month", "Right block selects Month")
        check(c.panel.frame.height > dayHeight, "Short Day fits its content while Month retains calendar height")
        check(c.state.geometry.taskInteractionRects(tasks: store.todayTasks, in: c.panel.frame).isEmpty, "Hidden Day has no task hover targets")
        c.state.onSelectDay?()
        finish()
        check(store.expandedMode == "today", "Score selects Day")
        check(workspace.openedURLs.isEmpty, "Page buttons do not launch Reminders")
        c.isDragging = true
        c.state.onSelectMonth?()
        check(store.expandedMode == "today", "Dragging suppresses page click")
        c.isDragging = false
        c.lastDragEndedAt = Date()
        c.state.onSelectMonth?()
        check(store.expandedMode == "today", "Drag release suppresses accidental navigation")
        c.lastDragEndedAt = .distantPast
        let score = c.state.geometry.headerInteractionRect(in: c.panel.frame)
        let block = c.state.geometry.blockInteractionRect(in: c.panel.frame)
        check(score.minX == c.panel.frame.minX && score.maxY == c.panel.frame.maxY && score.height == c.state.geometry.collapsedHeight,
              "Score button meets outer and top edges with full header height")
        check(block.maxX == c.panel.frame.maxX && block.maxY == c.panel.frame.maxY && block.height == score.height,
              "Cube button meets outer and top edges with full header height")
        check(block.minX - score.maxX == 185, "Header leaves exactly 185pt for the physical notch")
        check((block.minX - score.maxX) * c.state.geometry.displayScale == 370, "2x Retina notch gap is exactly 370 physical pixels")
        check(block.width == score.width && block.width > c.state.geometry.blockSize + 10,
              "Header targets are symmetric and expand the cube hit area")
        check(score.maxX == c.panel.frame.midX - c.state.geometry.notchWidth / 2,
              "Score background ends at the physical notch edge")
        c.pollCursor(at: NSPoint(x: score.midX, y: score.midY))
        check(c.state.headerHovered && !c.state.blockHovered, "Score hover stays isolated")
        let leftHover = capture("left-button-hover")
        let inner = c.state.geometry.headerButtonWidth
        check(sample(leftHover, x: 2, y: 2)[0] < 20 && sample(leftHover, x: 2, y: score.height - 2)[0] < 20,
              "Score hover leaves the large button background black")
        check(sample(leftHover, x: inner - 1, y: 1)[0] < 20 && sample(leftHover, x: inner - 1, y: score.height - 1)[0] < 20,
              "Left hover has matching upper and lower inner rounded corners")
        c.pollCursor(at: NSPoint(x: block.midX, y: block.midY))
        check(c.state.blockHovered && !c.state.headerHovered, "Block has separate hover feedback")
        let rightHover = capture("right-button-hover")
        check(sample(rightHover, x: c.panel.frame.width - 3, y: 2)[0] < 20,
              "Cube hover leaves the large button background black")
        check(sample(rightHover, x: c.panel.frame.width - inner + 1, y: score.height - 1)[0] < 20,
              "Right hover mirrors the inner lower rounded corner")
        c.pollCursor(at: NSPoint(x: c.panel.frame.midX, y: score.midY))
        check(!c.state.headerHovered && !c.state.blockHovered, "Notch gap does not highlight")
        c.state.onSelectMonth?()
        finish()
        check(store.expandedMode == "month", "The cube opens Month")
        c.collapse()
        check(abs((c.motion?.spring?.response ?? 0) - 0.26) < 0.000001, "Hover collapse uses the selected close spring")
        finish()
        check(store.expandedMode == "month", "Hover collapse retains selected page")
        check(c.panel.frame.height == c.state.geometry.collapsedHeight, "Collapse settles at exact header height")
        c.expand()
        finish()
        check(c.state.monthProgress == 0, "Re-expansion always starts with Today")
        c.state.onSelectDay?()
        finish()
        store.fixtureTasks(count: 1, completed: 0)
        finish()
        let singleHeight = c.panel.frame.height
        check(singleHeight < dayHeight && !c.state.geometry.dayScrolls, "Single task uses a compact content-fitting Day")
        store.fixtureTasks(count: 7, completed: 0)
        finish()
        check(!c.state.geometry.dayScrolls, "Seven tasks fit directly when below the Month height")
        check(c.panel.frame.height > singleHeight, "Day grows with its task content")
        let rowTargets = c.state.geometry.taskInteractionRects(tasks: store.todayTasks, in: c.panel.frame)
        check(rowTargets[0].rect.minY == rowTargets[1].rect.maxY, "Adjacent task hit regions meet without external margins")
        let firstTarget = rowTargets[0]
        check(firstTarget.rect.minX == c.panel.frame.minX && firstTarget.rect.width == c.panel.frame.width,
              "Task hit area spans the full container width")
        c.pollCursor(at: NSPoint(x: firstTarget.rect.minX + 1, y: firstTarget.rect.midY))
        check(c.state.hoveredTaskID == firstTarget.id, "Task responds at the far left edge")
        c.pollCursor(at: NSPoint(x: firstTarget.rect.maxX - 1, y: firstTarget.rect.midY))
        check(c.state.hoveredTaskID == firstTarget.id, "Task responds at the far right edge")
        store.fixtureTasks(count: 12, completed: 3, longTitles: true)
        finish()
        let g = c.state.geometry
        check(g.dayScrolls && g.todayContentHeight > g.dayViewportHeight, "Long Day scrolls its full task list")
        dayHeight = c.panel.frame.height
        check(dayHeight == g.maximumExpandedHeight, "Long Day reaches exactly the Month height")
        check(g.taskInteractionRects(tasks: store.todayTasks, in: c.panel.frame).isEmpty,
              "Scrolling rows use native hover instead of stale sampled coordinates")
        capture("long-scroll")
        func findScrollView(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScrollView($0) }.first
        }
        let scrollView = findScrollView(c.surfaceView)
        check(scrollView != nil, "Long Day contains a native scrolling viewport")
        check(scrollView?.scrollerStyle == .overlay, "Scrolling does not reserve a gutter beside the tasks")
        check(abs((scrollView?.contentView.bounds.width ?? 0) - c.state.geometry.expandedWidth) < 0.5,
              "The scrolling list retains the same content width as short Day")
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
        check(NSBitmapImageRep(cgImage: animatedDay).tiffRepresentation == NSBitmapImageRep(cgImage: currentDay.body).tiffRepresentation,
              "The outgoing animation starts with the currently scrolled rows")
        finish()
        check(c.panel.frame.height == dayHeight, "Month and capped Day have exactly equal height")
        c.state.onSelectDay?()
        finish()
        check(c.panel.frame.height == dayHeight, "Returning to long Day keeps the shared maximum height")
        check(scrollView?.contentView.bounds.origin == scrollOrigin, "Page switching preserves the Day scroll position")
        store.fixtureTasks(count: 0, completed: 0)
        finish()
        dayHeight = c.state.geometry.expandedHeight
        check(!c.state.geometry.dayScrolls && abs(c.panel.frame.height - dayHeight) <= 0.5, "Empty Day returns to default size")
        capture("empty")
        store.loadDemoData()
        c.state.onSelectMonth?()
        finish()
        let month = capture("month")
        let raster = c.renderCache.snapshot(page: .month, store: store, state: c.state)!
        check(raster.body.width == Int(width * c.state.geometry.displayScale),
              "Cached raster and native view have identical physical pixel width")
        var colors = Set<UInt32>()
        var neutral = 0
        for (rowIndex, row) in store.monthRows.enumerated() {
            for (columnIndex, day) in row.enumerated() {
                guard let day, let date = store.date(inMonth: day) else { continue }
                let g = c.state.geometry
                let x = g.gridOriginX + CGFloat(columnIndex) * (g.cell + g.cellGap) + g.cell / 2
                let y = g.monthTop + g.monthHeadingHeight + g.monthHeadingGap + g.monthWeekdayHeight + CGFloat(rowIndex) * (g.cell + g.cellGap) + g.cell / 2
                let pixel = sample(month, x: x, y: y)
                if date == store.today {
                    check(pixel[0] > 245 && pixel[1] > 245 && pixel[2] > 245, "Today has a solid white center dot")
                    continue
                }
                let hex = UInt32(pixel[0] << 16 | pixel[1] << 8 | pixel[2])
                if date > store.today || store.stat(for: date).done == 0 {
                    check(hex == 0x141414, "Zero and future cells retain #141414")
                    neutral += 1
                } else {
                    check(hex == Theme.paletteHex[Theme.level(for: store.stat(for: date).ratio)], "Cell retains its eight-level completion color")
                    colors.insert(hex)
                }
            }
        }
        check(neutral > 0 && colors.count >= 7, "Demo covers neutral dates and gold completion bands")
        for index in 0..<30 {
            store.setExpandedMode(index % 2 == 0 ? "today" : "month")
            if let motion = c.motion { c.advanceAnimation(at: motion.started + 0.04) }
            check(c.panel.frame.width == width && c.panel.frame.maxY == top, "Rapid reversals preserve fixed width and anchor")
            check(c.interactionFrame.midX == builtIn.frame.midX, "Visible animation center does not drift horizontally")
            check(c.headerHosting.frame.midX + c.panel.frame.minX == builtIn.frame.midX,
                  "Persistent header stays centered during the cached/live transition")
        }
        finish()
        check(c.motion == nil && c.animationDisplayLink?.isPaused != false, "Settled animation pauses display callbacks")
        c.collapse()
        finish()
        c.state.geometry.horizontalOffset = c.state.geometry.settledOffset(200)
        c.updateWindowFrame(expanded: false)
        check(c.panel.frame.width < width, "Off-notch collapse remains compact")
        c.expand()
        finish()
        check(c.panel.frame.width == width, "Off-notch expansion uses reference width")
        check(c.panel.frame.midX == c.state.geometry.alignedCenterX,
              "Off-notch animation also settles at its requested integral center")
        c.screensChanged([builtIn, external])
        c.selectDisplay(2002)
        finish()
        check(c.panel.frame.width == width, "External display preserves reference width")
        c.state.pinned = true
        c.expand()
        finish()
        c.state.pinned = false
        c.collapse()
        check(c.snapshotLayer.isVisible && c.surfaceView.blocksContentInput, "Animation uses cached native layers and blocks stale controls")
        let animatedWindow = c.panel.frame
        var changes = 0
        let subscription = c.state.objectWillChange.sink { changes += 1 }
        var previousHeight = c.interactionFrame.height
        let closing = c.motion!
        for frame in 1..<20 {
            c.advanceAnimation(at: closing.started + closing.duration * Double(frame) / 20)
            check(NSColor(cgColor: c.surfaceView.layer!.backgroundColor!) == NSColor.black, "Animation backing stays black")
            check(c.surfaceView.layer!.borderWidth == 0, "Animation has no switching white outline")
            check(!c.headerHosting.isHidden, "Header remains live through the body handoff")
            check(c.panel.frame == animatedWindow, "Animation does not resize the hosting window each frame")
            let visible = c.interactionFrame.height
            check(visible <= previousHeight + 0.001 && visible >= c.state.geometry.collapsedHeight,
                  "Close is monotonic and never shrinks below notch height")
            previousHeight = visible
        }
        check(changes == 0, "Layer animation publishes no SwiftUI state on intermediate frames")
        finish()
        check(c.panel.frame.height == c.state.geometry.collapsedHeight, "Final height exactly matches notch height")
        check(!c.snapshotLayer.isVisible && !c.surfaceView.blocksContentInput, "Live interaction restores at animation endpoint")
        subscription.cancel()
        c.expand()
        let beforeFirstTick = c.interactionFrame.height
        c.collapse()
        check(abs(c.interactionFrame.height - beforeFirstTick) < 0.001, "Reversal before first display tick preserves visible height")
        finish()
        c.expand()
        if let opening = c.motion { c.advanceAnimation(at: opening.started + opening.duration * 0.4) }
        let interruptedHeight = c.interactionFrame.height
        c.collapse()
        check(abs(c.interactionFrame.height - interruptedHeight) < 0.001, "Reversing animation preserves current visible height")
        finish()
        check(c.panel.frame.height == c.state.geometry.collapsedHeight, "Interrupted close still reaches exact header height")
        c.expand()
        finish()
        let beforeDeferred = store.todayTasks
        c.collapse()
        store.fixtureTasks(count: 2, completed: 0)
        check(store.todayTasks == beforeDeferred, "Data arriving during animation waits for the endpoint")
        finish()
        check(store.todayTasks.count == 2 && c.panel.frame.height == c.state.geometry.collapsedHeight,
              "Deferred data applies after closing without a height jump")
        var hugeDay = c.state.geometry
        hugeDay.showingMonth = false
        hugeDay.measureToday(tasks: Array(repeating: store.todayTasks[0], count: 100), error: nil, summary: nil)
        check(hugeDay.expandedHeight <= hugeDay.screenFrame.height - 8, "Extreme Day expansion stays inside screen")
        check(hugeDay.dayViewportHeight < hugeDay.todayContentHeight, "Extreme Day retains all content in a bounded scrolling viewport")
        c.panel.orderOut(nil)
        print("PASS \(count) horizontal pages, overflow, gesture and rendering checks")
    }
}

extension NotchPanelController {
    static func checkCraftPresentation() async {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1
        }
        let (store, _) = TaskStore.todayFixture()
        store.loadDemoData()
        let c = NotchPanelController(store: store, defaults: MemoryDefaults())
        c.hoverTimer?.invalidate()
        c.screensChanged([TestScreen(id: 1001, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: 185)])
        c.state.pinned = true
        c.expand()
        // A simulated NSScreen has no native display-link source in this CLI runner.
        // Drive only the window timeline here; the performance probe uses real display callbacks.
        let animationClock = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated { c.advanceAnimation(at: CACurrentMediaTime()) }
        }
        RunLoop.main.add(animationClock, forMode: .common)
        defer { animationClock.invalidate() }
        func finish() {
            for _ in 0..<10 {
                guard let motion = c.motion else { break }
                c.advanceAnimation(at: motion.started + motion.duration + 0.01)
            }
        }
        func capture(_ name: String, settle: Bool = true) async {
            if settle { finish(); try? await Task.sleep(nanoseconds: 180_000_000) }
            let host = c.surfaceView
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let output = ProcessInfo.processInfo.environment["GLITTER_REVIEW_OUTPUT"]!
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(output)/craft-\(name).png"))
        }
        for (name, status): (String, TaskStore.PanelStatus) in [
            ("access", .denied), ("choose-list", .unselected), ("unavailable", .unavailable),
            ("loading", .loading), ("load-failed", .failed)] {
            store.loadStatusDemoData(status)
            store.setExpandedMode("today")
            finish()
            check(!c.state.geometry.dayScrolls && !c.state.geometry.showsCalendar, "Connection messages fit their measured content")
            await capture(name)
            store.setExpandedMode("month")
            finish()
            check(c.state.geometry.monthViewportHeight == c.state.geometry.todayContentHeight, "Month uses the same recovery surface when data is unavailable")
            if status == .failed { await capture("month-unavailable") }
        }
        store.retryLoad()
        finish()
        check(c.state.geometry.showsCalendar && store.hasStatistics, "A recovery refresh restores geometry as well as model data")
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
        check(c.state.geometry.noticeHeight > 0 && store.todayTasks.count == 5, "Stale Day keeps its content beneath the recovery message")
        store.setExpandedMode("month")
        await capture("stale-month")
        store.retryLoad()
        finish()
        check(c.state.geometry.noticeHeight == 0, "Successful recovery removes the message and its layout space")
        store.setExpandedMode("today")
        store.loadSaveFailureDemoData(taskCount: 12)
        finish()
        await store.completeTask(store.pendingTasks[0].id)
        await capture("save-failed-long-day")
        check(c.state.geometry.dayScrolls && c.state.geometry.noticeHeight > 0,
              "Save errors remain visible above the scrolling task list")
        await store.retryCompletion()
        finish()
        check(store.taskError == nil && c.state.geometry.noticeHeight == 0, "Retry restores the original task layout")
        store.loadUnconfirmedSaveDemoData()
        finish()
        await store.completeTask(store.pendingTasks[0].id)
        await capture("saved-awaiting-refresh")
        store.retryLoad()
        await capture("saved-recovered")
        store.loadDemoData(taskCount: 6, completedCount: 6)
        finish()
        check(!c.state.geometry.dayScrolls, "Six completed rows and their summary fit directly")
        await capture("six-completed")

        store.loadLongTitleDemoData()
        finish()
        let g = c.state.geometry
        check(g.todayContentHeight == g.taskHeight(store.presentationTasks[0]),
              "A multiline reminder retains its complete measured height")
        check(c.panel.frame.height <= g.maximumExpandedHeight,
              "A multiline reminder respects the Month height limit")
        check(g.dayViewportHeight == min(g.todayContentHeight, g.maximumExpandedHeight - g.monthTop - g.padding),
              "A multiline reminder uses available space before scrolling")
        await capture("long-title-scroll")

        for month in [2, 4, 11] {
            store.loadDemoMonthFixture(month: month)
            store.setExpandedMode("month")
            finish()
            check(c.state.geometry.monthViewportHeight == c.state.geometry.monthContentHeight,
                  "Four-, five- and six-week months fit their actual content")
            check((c.state.geometry.cell * c.state.geometry.displayScale).rounded() == c.state.geometry.cell * c.state.geometry.displayScale,
                  "Month cells align to physical pixels")
            await capture("month-\(month)")
        }
        store.loadDemoData(taskCount: 5, completedCount: 2)
        store.setExpandedMode("today")
        finish()
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
        check(!c.snapshotLayer.isVisible && c.animationDisplayLink?.isPaused != false,
              "Completion settles back to the live view with no running window animation")
        c.panel.orderOut(nil)
        print("PASS \(checks) native recovery layout, month layout and completion presentation checks")
    }
}
