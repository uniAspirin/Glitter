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
        func swipe(dx: CGFloat, dy: CGFloat = 0, inverted: Bool = true, precise: Bool = true) {
            let point = NSPoint(x: c.panel.frame.midX, y: c.panel.frame.maxY - 60)
            _ = c.handleScroll(phase: .began, momentum: [], deltaX: 0, deltaY: 0, precise: precise, inverted: inverted, point: point)
            _ = c.handleScroll(phase: .changed, momentum: [], deltaX: dx, deltaY: dy, precise: precise, inverted: inverted, point: point)
            _ = c.handleScroll(phase: .ended, momentum: [], deltaX: 0, deltaY: 0, precise: precise, inverted: inverted, point: point)
            finish()
        }
        let reserved = NotchGeometry.make(for: builtIn, rows: 6, offset: 0, scoreText: "99/99")
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
        let hoverDuration = c.motion!.duration
        check(hoverDuration == 0.12, "Hover expansion takes 120ms")
        finish()
        check(c.panel.frame.midX == builtIn.frame.midX, "Native window centers exactly on the 185pt notch")
        var dayHeight = c.panel.frame.height
        capture("day")
        check(c.panel.frame.width == width && c.panel.frame.maxY == top, "Expansion preserves notch width and top edge")
        check(!c.state.geometry.dayOverflows, "Short Day has no disclosure")
        c.state.onSelectMonth?()
        check(c.motion?.duration == 0.14, "Changing pages retains its existing motion duration")
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
        check(sample(leftHover, x: 2, y: 2)[0] > 35 && sample(leftHover, x: 2, y: score.height - 2)[0] > 35,
              "Left hover has square outer corners and zero margin")
        check(sample(leftHover, x: inner - 1, y: 1)[0] < 20 && sample(leftHover, x: inner - 1, y: score.height - 1)[0] < 20,
              "Left hover has matching upper and lower inner rounded corners")
        c.pollCursor(at: NSPoint(x: block.midX, y: block.midY))
        check(c.state.blockHovered && !c.state.headerHovered, "Block has separate hover feedback")
        let rightHover = capture("right-button-hover")
        check(sample(rightHover, x: c.panel.frame.width - 3, y: 2)[0] > 35,
              "Right hover reaches software right edge")
        check(sample(rightHover, x: c.panel.frame.width - inner + 1, y: score.height - 1)[0] < 20,
              "Right hover mirrors the inner lower rounded corner")
        c.pollCursor(at: NSPoint(x: c.panel.frame.midX, y: score.midY))
        check(!c.state.headerHovered && !c.state.blockHovered, "Notch gap does not highlight")
        swipe(dx: -30)
        check(store.expandedMode == "month", "Natural leftward push selects right-hand Month")
        swipe(dx: 30)
        check(store.expandedMode == "today", "Natural rightward push selects left-hand Day")
        swipe(dx: -5, dy: 50)
        check(store.expandedMode == "today", "Vertical gestures do not change page")
        swipe(dx: -30, dy: 30)
        check(store.expandedMode == "today", "Diagonal gestures do not accidentally change page")
        swipe(dx: -50, precise: false)
        check(store.expandedMode == "today", "Mouse wheel does not switch pages")
        swipe(dx: 30, inverted: false)
        check(store.expandedMode == "month", "Non-natural scroll setting preserves physical push direction")
        c.collapse()
        check(c.motion?.duration == hoverDuration, "Hover collapse and expansion use the same duration")
        finish()
        check(store.expandedMode == "month", "Hover collapse retains selected page")
        check(c.panel.frame.height == c.state.geometry.collapsedHeight, "Collapse settles at exact header height")
        c.expand()
        finish()
        check(c.state.monthProgress == 1, "Re-expansion restores Month")
        c.state.onSelectDay?()
        finish()
        store.fixtureTasks(count: 1, completed: 0)
        finish()
        let singleHeight = c.panel.frame.height
        check(singleHeight < dayHeight && !c.state.geometry.dayOverflows, "Single task uses a compact content-fitting Day")
        store.fixtureTasks(count: 6, completed: 0)
        finish()
        check(!c.state.geometry.dayOverflows && c.state.geometry.previewTaskCount == 6, "Six single-line tasks fit without disclosure")
        store.fixtureTasks(count: 7, completed: 0)
        finish()
        check(c.state.geometry.dayOverflows && c.state.geometry.previewTaskCount == 6, "Seventh single-line task reveals disclosure")
        store.fixtureTasks(count: 12, completed: 3, longTitles: true)
        finish()
        let g = c.state.geometry
        check(g.dayOverflows && g.previewTaskCount < store.todayTasks.count, "Long Day detects overflow")
        dayHeight = g.expandedHeight
        check(abs(c.panel.frame.height - dayHeight) <= 0.5, "Long Day initially uses fixed viewport")
        swipe(dx: 0, dy: 30)
        check(c.state.dayExpanded && store.expandedMode == "today", "Downward Day gesture expands overflow without opening Month")
        swipe(dx: 0, dy: -30)
        check(!c.state.dayExpanded && store.expandedMode == "today", "Upward Day gesture collapses overflow")
        swipe(dx: 0, dy: 40, precise: false)
        check(!c.state.dayExpanded, "Mouse wheel does not toggle Day overflow")
        swipe(dx: 0, dy: -30, inverted: false)
        check(c.state.dayExpanded, "Non-natural setting preserves downward expansion")
        swipe(dx: 0, dy: 30, inverted: false)
        check(!c.state.dayExpanded, "Non-natural setting preserves upward collapse")
        let rowTargets = g.taskInteractionRects(tasks: store.todayTasks, in: c.panel.frame)
        check(rowTargets[0].rect.minY == rowTargets[1].rect.maxY, "Adjacent task hit regions touch with no external gap")
        check(g.taskHeight(store.todayTasks[0]) >= NotchGeometry.taskRowHeight + 5,
              "Task target includes 2.5pt vertical padding on each side")
        let previewFrame = c.panel.frame
        let footerBand = g.toggleInteractionRect(in: previewFrame)
        check(footerBand.minX == previewFrame.minX && footerBand.maxX == previewFrame.maxX,
              "Disclosure fills container width")
        check(abs(footerBand.minY - previewFrame.minY) < 0.01 && footerBand.height == 26,
              "Preview disclosure occupies the bottom corner band with no bottom margin")
        let firstTarget = g.taskInteractionRects(tasks: store.todayTasks, in: previewFrame)[0]
        check(firstTarget.rect.minX == previewFrame.minX && firstTarget.rect.width == previewFrame.width,
              "Task hit area spans the full container width")
        c.pollCursor(at: NSPoint(x: firstTarget.rect.minX + 1, y: firstTarget.rect.midY))
        check(c.state.hoveredTaskID == firstTarget.id, "Task responds at the far left container edge")
        c.pollCursor(at: NSPoint(x: firstTarget.rect.maxX - 1, y: firstTarget.rect.midY))
        check(c.state.hoveredTaskID == firstTarget.id, "Task responds at the far right container edge")
        let toggle = g.toggleInteractionRect(in: c.panel.frame)
        capture("long-collapsed")
        c.state.onToggleDay?()
        finish()
        check(c.panel.frame.height > dayHeight, "Day disclosure reveals remaining tasks")
        check(c.state.geometry.toggleInteractionRect(in: c.panel.frame) == toggle, "Disclosure stays at original screen position")
        let expandedBand = c.state.geometry.toggleInteractionRect(in: c.panel.frame)
        check(expandedBand.minY > c.panel.frame.minY + 26, "Expanded disclosure stays in original band above extra tasks")
        c.pollCursor(at: NSPoint(x: expandedBand.minX + 1, y: expandedBand.midY))
        check(c.state.toggleHovered, "Expanded disclosure is a full-width rectangular target")
        capture("long-expanded")
        c.state.onSelectMonth?()
        finish()
        check(abs(c.panel.frame.height - c.state.geometry.expandedHeight) <= 0.5, "Month uses its own calendar height after expanding Day")
        c.state.onSelectDay?()
        finish()
        check(c.state.dayExpanded && c.panel.frame.height > dayHeight, "Returning to Day restores its expansion state")
        c.state.onToggleDay?()
        finish()
        c.pollCursor(at: NSPoint(x: toggle.midX, y: toggle.midY))
        check(c.state.toggleHovered && c.collapseWork == nil, "Collapsing Day leaves pointer inside on the same button")
        store.fixtureTasks(count: 0, completed: 0)
        finish()
        dayHeight = c.state.geometry.expandedHeight
        check(!c.state.geometry.dayOverflows && abs(c.panel.frame.height - dayHeight) <= 0.5, "Empty Day returns to default size")
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
        check(c.motion == nil && c.animationDisplayLink == nil, "Settled animation releases display link")
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
        hugeDay.dayExpanded = true
        hugeDay.measureToday(tasks: Array(repeating: store.todayTasks[0], count: 100), error: nil, summary: nil)
        check(hugeDay.expandedHeight <= hugeDay.screenFrame.height - 8, "Extreme Day expansion stays inside screen")
        check(hugeDay.overflowViewportHeight < hugeDay.overflowHeight, "Extreme Day retains a scrollable overflow region")
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
            check(!c.state.geometry.dayOverflows && !c.state.geometry.showsCalendar, "Connection messages never masquerade as a calendar or overflow list")
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
        check(c.state.geometry.dayOverflows && c.state.geometry.noticeHeight > 0,
              "Save errors remain visible above a six-row preview")
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
        check(!c.state.geometry.dayOverflows, "The closing message does not create a disclosure button for six completed rows")
        await capture("six-completed")

        store.loadLongTitleDemoData()
        finish()
        let g = c.state.geometry
        check(g.dayOverflows && g.previewTaskCount == 1 && g.previewOverflowOffset > 0,
              "One very tall reminder still has visible preview text")
        check(abs(g.previewContentHeight + g.overflowHeight - g.todayContentHeight) < 0.01,
              "A split reminder loses no content height")
        let previewTargets = g.taskInteractionRects(tasks: store.presentationTasks, in: c.panel.frame)
        check(previewTargets.count == 1 && previewTargets[0].rect.height == g.previewContentHeight,
              "The partial reminder hit area stops before the disclosure")
        await capture("long-title-preview")
        let footer = g.toggleInteractionRect(in: c.panel.frame)
        c.state.onToggleDay?()
        finish()
        check(c.state.geometry.toggleInteractionRect(in: c.panel.frame) == footer, "A tall reminder reveals its continuation without moving the disclosure")
        check(c.state.geometry.overflowStartIndex == 0, "Overflow continues the same reminder, not an empty list")
        await capture("long-title-expanded")

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
        check(!c.snapshotLayer.isVisible && c.animationDisplayLink == nil,
              "Completion settles back to the live view with no running window animation")
        c.panel.orderOut(nil)
        print("PASS \(checks) native recovery layout, month layout and completion presentation checks")
    }
}
