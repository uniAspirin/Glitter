import AppKit
import SwiftUI

extension NotchPanelController {
    static func checkAnimationDemo() async {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            count += 1
        }
        let (productionStore, _) = TaskStore.todayFixture()
        let production = NotchPanelController(store: productionStore, defaults: MemoryDefaults())
        production.hoverTimer?.invalidate()
        production.screensChanged([TestScreen(id: 1002, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: 185)])
        production.expand()
        check(abs((production.motion?.spring?.response ?? 0) - 0.36) < 0.000001,
              "Regular mode uses the selected native spring too")
        production.stopAnimation()
        production.panel.orderOut(nil)

        let (store, _) = TaskStore.todayFixture()
        store.loadDemoData(taskCount: 5, completedCount: 2)
        let c = NotchPanelController(store: store, defaults: DemoDefaults())
        c.hoverTimer?.invalidate()
        c.surfaceView.onPointerChanged = nil
        c.screensChanged([TestScreen(id: 1001, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: 185)])
        defer { c.demoPreviewWork?.cancel(); c.panel.orderOut(nil) }
        func finish() {
            for _ in 0..<10 {
                guard let motion = c.motion else { break }
                c.advanceAnimation(at: motion.started + motion.duration + 0.01)
            }
        }
        func capture(_ name: String) {
            let size = c.surfaceView.bounds.size
            let scale: CGFloat = 2
            let width = Int(size.width * scale), height = Int(size.height * scale)
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.scaleBy(x: scale, y: scale)
            c.surfaceView.layer!.render(in: context)
            let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
            let folder = ProcessInfo.processInfo.environment["GLITTER_REVIEW_OUTPUT"]!
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(folder)/animation-demo-\(name).png"))
        }

        c.state.pinned = true
        c.expand()
        let opening = c.motion!
        check(abs((opening.spring?.response ?? 0) - 0.36) < 0.000001 && abs((opening.spring?.dampingRatio ?? 0) - 0.76) < 0.000001,
              "Notch expansion uses the requested native spring")
        let targetHeight = c.presentationRect(opening.target).height
        var peak = targetHeight
        for step in 0..<120 {
            c.advanceAnimation(at: opening.started + opening.duration * Double(step) / 120)
            let rect = c.interactionFrame
            peak = max(peak, rect.height)
            check(c.panel.frame.insetBy(dx: -0.5, dy: -0.5).contains(rect), "The window reserves room for the spring overshoot")
            check(abs(rect.maxY - 900) < 0.001, "The notch top edge stays fixed during the spring")
            if step % 30 == 0 { capture("expand-\(step)") }
        }
        check(peak > targetHeight + 1, "The expansion rebound is visible rather than clipped")
        finish()
        capture("expand-end")
        check(c.panel.frame.height == targetHeight, "Expansion settles at its exact target height")

        c.state.pinned = false
        c.collapse()
        let closing = c.motion!
        check(abs((closing.spring?.response ?? 0) - 0.26) < 0.000001 && abs((closing.spring?.dampingRatio ?? 0) - 0.96) < 0.000001,
              "Notch collapse uses the requested near-critical spring")
        for step in 0..<80 {
            c.advanceAnimation(at: closing.started + closing.duration * Double(step) / 80)
            check(c.interactionFrame.height >= c.state.geometry.collapsedHeight,
                  "A closing spring never dips below the physical notch height")
        }
        finish()
        check(c.panel.frame.height == c.state.geometry.collapsedHeight, "Collapse ends exactly at notch height")
        c.expand()
        if let motion = c.motion { c.advanceAnimation(at: motion.started + motion.duration * 0.25) }
        let interrupted = c.interactionFrame
        c.collapse()
        check(c.interactionFrame == interrupted, "Reversing the spring preserves the visible frame")
        finish()
        c.state.pinned = true
        c.expand()
        finish()

        for _ in 0..<8 {
            c.previewPageTransition()
            let transition = c.motion!
            check(transition.pageDuration == 0.16 && transition.spring == nil, "Smooth Slide has fixed independent timing")
            check(c.snapshotLayer.isVisible, "Page transitions use cached layers")
            for step in 0...20 {
                c.advanceAnimation(at: transition.started + transition.duration * Double(step) / 20)
                check(NSColor(cgColor: c.surfaceView.layer!.backgroundColor!) == NSColor.black,
                      "Every animation frame retains the black container")
                if step == 10 { capture("smoothSlide-mid") }
            }
            finish()
            check(!c.snapshotLayer.isVisible, "The slide hands off to its live page")
            check(c.animationDisplayLink?.isPaused != false, "No frame callbacks run after settling")
        }
        capture("smoothSlide-end")
        c.previewNotchTransition()
        let wait = (c.motion?.duration ?? 0) + 0.16
        finish()
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        check(c.state.expanded && c.state.pinned && store.expandedMode == "today",
              "Replay Notch opens Today again and keeps it visible")
        finish()
        check(c.demoPreviewWork == nil, "The replay timer is released after its one-shot action")
        c.state.pinned = false
        c.collapse()
        finish()
        c.previewPageTransition()
        check(c.state.expanded && c.motion?.spring != nil && store.expandedMode == "today",
              "Replaying pages from a closed panel first opens with the notch spring")
        let pageWait = (c.motion?.duration ?? 0) + 0.14
        try? await Task.sleep(nanoseconds: UInt64(pageWait * 1_000_000_000))
        check(store.expandedMode == "month", "The selected page transition follows the opening without a jump")
        finish()
        print("PASS \(count) animation-demo spring, cache, bounds and replay checks")
    }
}

extension NotchPanelController {
    static func checkAnimationStability() async {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        let (store, _) = TaskStore.todayFixture()
        store.loadDemoData(taskCount: 30, completedCount: 6)
        let c = NotchPanelController(store: store, defaults: DemoDefaults())
        c.hoverTimer?.invalidate()
        c.surfaceView.onPointerChanged = nil
        c.screensChanged([TestScreen(id: 1001, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: 185)])
        defer { c.cancelScheduledCollapse(); c.panel.orderOut(nil) }
        func finish() {
            for _ in 0..<10 {
                guard let motion = c.motion else { break }
                c.advanceAnimation(at: motion.started + motion.duration + 0.01)
            }
        }
        c.state.pinned = true
        c.expand()
        let opening = c.motion!
        c.advanceAnimation(at: opening.started + 0.025)
        let before = c.interactionFrame
        let cube = c.state.geometry.blockInteractionRect(in: before)
        let point = NSPoint(x: cube.midX, y: cube.midY)
        let local = NSPoint(x: point.x - c.panel.frame.minX, y: point.y - c.panel.frame.minY)
        let hit = c.surfaceView.hitTest(local)
        check(hit === c.headerHosting || hit?.isDescendant(of: c.headerHosting) == true,
              "The live header receives input while the body is a snapshot")
        let bodyPoint = NSPoint(x: local.x, y: local.y - c.state.geometry.collapsedHeight)
        check(c.surfaceView.hitTest(bodyPoint) === c.surfaceView,
              "Moving task rows remain protected during animation")
        c.trackHeaderPointer(type: .leftMouseDown, point: point, inPanel: true)
        c.advanceAnimation(at: opening.started + 0.04)
        c.trackHeaderPointer(type: .leftMouseDragged, point: point, inPanel: true)
        c.trackHeaderPointer(type: .leftMouseUp, point: point, inPanel: true)
        check(!c.isDragging && c.lastDragEndedAt == .distantPast,
              "An animating window never turns a stationary press into a drag")
        c.state.onSelectMonth?()
        check(store.expandedMode == "month", "A cube press during opening selects Month immediately")
        let mixed = c.motion!
        check(mixed.spring != nil && mixed.pageDuration == 0.16,
              "Container spring and Smooth Slide retain independent timing")
        for _ in 0..<100 {
            c.trackHeaderPointer(type: .leftMouseDown, point: point, inPanel: true)
            c.trackHeaderPointer(type: .leftMouseUp, point: point, inPanel: true)
            c.state.onSelectMonth?()
            check(c.acceptsClick && store.expandedMode == "month", "Rapid repeated clicks cannot lock navigation")
            check(c.motion?.started == mixed.started, "Repeated requests do not restart the same transition")
        }
        c.advanceAnimation(at: mixed.started + 0.161)
        check(c.presentedVector?.second.second.second == 1,
              "The page reaches Month after 160ms even while the notch spring continues")
        c.state.onSelectDay?()
        check(store.expandedMode == "today", "The opposite button responds during an unfinished spring")
        finish()
        check(c.state.monthProgress == 0 && c.acceptsClick, "Interrupted animation settles with responsive controls")

        c.trackHeaderPointer(type: .leftMouseDown, point: point, inPanel: true)
        c.trackHeaderPointer(type: .leftMouseDragged, point: NSPoint(x: point.x + 1, y: point.y + 1), inPanel: true)
        check(!c.isDragging, "Small pointer jitter preserves a click")
        c.trackHeaderPointer(type: .leftMouseDragged, point: NSPoint(x: point.x + 30, y: point.y), inPanel: true)
        check(c.isDragging && !c.acceptsClick, "Real screen-coordinate movement still drags the panel")
        c.state.onSelectMonth?()
        check(store.expandedMode == "today", "Dragging never triggers page navigation")
        c.trackHeaderPointer(type: .leftMouseUp, point: point, inPanel: false)
        check(!c.isDragging && c.headerPressOrigin == nil && !c.acceptsClick,
              "Releasing outside the panel clears the drag and protects its release click")
        c.lastDragEndedAt = .distantPast
        c.resetOffset()
        c.state.onSelectMonth?()
        finish()
        check(store.expandedMode == "month", "Navigation remains available after dragging")

        // Match the real backing scale for pixel comparisons, independently of the fake 2x screen.
        c.state.geometry.displayScale = c.panel.backingScaleFactor
        c.updateWindowFrame(expanded: true)
        let cached = c.renderCache.snapshot(page: .month, store: store, state: c.state)!
        let live = c.snapshotLayer.captureLive(headerHeight: c.state.geometry.collapsedHeight)!
        func color(_ snapshot: PanelSnapshot, x: CGFloat, y: CGFloat) -> [Double] {
            let bitmap = NSBitmapImageRep(cgImage: snapshot.body)
            let scale = CGFloat(bitmap.pixelsWide) / snapshot.size.width
            let color = bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))!.usingColorSpace(.sRGB)!
            return [color.redComponent, color.greenComponent, color.blueComponent]
        }
        let g = c.state.geometry
        var haloSamples = 0
        for (rowIndex, row) in store.monthRows.enumerated() {
            for (columnIndex, day) in row.enumerated() {
                guard let day, let date = store.date(inMonth: day), store.stat(for: date).isFull else { continue }
                let x = g.gridOriginX + CGFloat(columnIndex) * (g.cell + g.cellGap) + g.cell / 2
                let top = g.monthTop - g.collapsedHeight + g.monthHeadingHeight + g.monthHeadingGap
                    + g.monthWeekdayHeight + CGFloat(rowIndex) * (g.cell + g.cellGap)
                for distance in [CGFloat(2), 4, 7] {
                    let a = color(cached, x: x, y: top - distance)
                    let b = color(live, x: x, y: top - distance)
                    check(zip(a, b).allSatisfy { abs($0 - $1) < 0.04 },
                          "Cached golden-day halo matches the live native renderer")
                    haloSamples += 1
                }
            }
        }
        check(haloSamples >= 6, "The regression samples multiple golden-day halos")

        c.state.pinned = false
        let outside = NSPoint(x: c.interactionFrame.maxX + 40, y: c.interactionFrame.minY - 40)
        c.pollCursor(at: outside)
        check(c.collapseWork != nil, "Leaving starts the grace period")
        try? await Task.sleep(nanoseconds: 200_000_000)
        check(c.state.expanded, "The panel stays open beyond the old 140ms delay")
        c.pollCursor(at: NSPoint(x: c.interactionFrame.midX, y: c.interactionFrame.maxY - 10))
        check(c.collapseWork == nil, "Re-entry cancels the pending collapse")
        try? await Task.sleep(nanoseconds: 160_000_000)
        check(c.state.expanded, "A cancelled grace period cannot collapse later")
        c.pollCursor(at: outside)
        try? await Task.sleep(nanoseconds: 340_000_000)
        check(!c.state.expanded, "An uninterrupted 300ms leave begins collapse")
        finish()
        check(c.motion == nil && c.animationDisplayLink?.isPaused != false,
              "Completed animations leave no active frame callbacks")
        print("PASS \(checks) animation input, independent timing, halo and grace-period regression checks")
    }
}
