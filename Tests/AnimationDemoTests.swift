import AppKit
import SwiftUI
import XCTest
@testable import Glitter

@MainActor
final class AnimationDemoTests: XCTestCase {
    func testAnimationDemoSpringCacheBoundsAndReplay() async {
        let (productionStore, _) = TaskStore.todayFixture()
        let production = NotchPanelController(store: productionStore, defaults: MemoryDefaults())
        production.screensChanged([DisplayMetrics.fixture(id: 1002, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: 185)])
        production.expand()
        production.hoverTimer?.invalidate()
        XCTAssertEqual(production.motion?.spring?.response ?? 0, 0.36, accuracy: 0.000001)
        production.stopAnimation()
        production.panel.orderOut(nil)

        let (store, _) = TaskStore.todayFixture()
        store.loadDemoData(taskCount: 5, completedCount: 2)
        let c = NotchPanelController(store: store, defaults: DemoDefaults())
        c.surfaceView.onPointerChanged = nil
        c.screensChanged([DisplayMetrics.fixture(id: 1001, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: 185)])
        defer { c.demoPreviewWork?.cancel(); c.panel.orderOut(nil) }

        func capture(_ name: String) {
            ReviewArtifacts.captureLayer(c.surfaceView.layer!, size: c.surfaceView.bounds.size, filename: "animation-demo-\(name).png")
        }

        c.state.pinned = true
        c.expand()
        let opening = c.motion!
        XCTAssertEqual(opening.spring?.response ?? 0, 0.36, accuracy: 0.000001)
        XCTAssertEqual(opening.spring?.dampingRatio ?? 0, 0.76, accuracy: 0.000001)
        let targetHeight = c.presentationRect(opening.target).height
        var peak = targetHeight
        for step in 0..<120 {
            c.advanceAnimation(at: opening.started + opening.duration * Double(step) / 120)
            let rect = c.interactionFrame
            peak = max(peak, rect.height)
            XCTAssertTrue(c.panel.frame.insetBy(dx: -0.5, dy: -0.5).contains(rect))
            XCTAssertLessThan(abs(rect.maxY - 900), 0.001)
            if step % 30 == 0 { capture("expand-\(step)") }
        }
        XCTAssertGreaterThan(peak, targetHeight + 1)
        finishAnimation(on: c)
        capture("expand-end")
        XCTAssertEqual(c.panel.frame.height, targetHeight)

        c.state.pinned = false
        c.collapse()
        let closing = c.motion!
        XCTAssertEqual(closing.spring?.response ?? 0, 0.26, accuracy: 0.000001)
        XCTAssertEqual(closing.spring?.dampingRatio ?? 0, 0.96, accuracy: 0.000001)
        for step in 0..<80 {
            c.advanceAnimation(at: closing.started + closing.duration * Double(step) / 80)
            XCTAssertGreaterThanOrEqual(c.interactionFrame.height, c.state.geometry.collapsedHeight)
        }
        finishAnimation(on: c)
        XCTAssertEqual(c.panel.frame.height, c.state.geometry.collapsedHeight)

        c.expand()
        c.hoverTimer?.invalidate()
        if let motion = c.motion { c.advanceAnimation(at: motion.started + motion.duration * 0.25) }
        let interrupted = c.interactionFrame
        c.collapse()
        XCTAssertEqual(c.interactionFrame, interrupted)
        finishAnimation(on: c)
        c.state.pinned = true
        c.expand()
        finishAnimation(on: c)

        for _ in 0..<8 {
            c.previewPageTransition()
            let transition = c.motion!
            XCTAssertEqual(transition.pageDuration, 0.16)
            XCTAssertNil(transition.spring)
            XCTAssertTrue(c.snapshotLayer.isVisible)
            for step in 0...20 {
                c.advanceAnimation(at: transition.started + transition.duration * Double(step) / 20)
                XCTAssertEqual(NSColor(cgColor: c.surfaceView.layer!.backgroundColor!), NSColor.black)
                if step == 10 { capture("smoothSlide-mid") }
            }
            finishAnimation(on: c)
            XCTAssertFalse(c.snapshotLayer.isVisible)
            XCTAssertNotEqual(c.animationDisplayLink?.isPaused, false)
        }
        capture("smoothSlide-end")

        c.previewNotchTransition()
        let wait = (c.motion?.duration ?? 0) + 0.16
        finishAnimation(on: c)
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        XCTAssertTrue(c.state.expanded && c.state.pinned && store.expandedMode == "today")
        finishAnimation(on: c)
        XCTAssertNil(c.demoPreviewWork)

        c.state.pinned = false
        c.collapse()
        finishAnimation(on: c)
        c.previewPageTransition()
        XCTAssertTrue(c.state.expanded && c.motion?.spring != nil && store.expandedMode == "today")
        let pageWait = (c.motion?.duration ?? 0) + 0.14
        try? await Task.sleep(nanoseconds: UInt64(pageWait * 1_000_000_000))
        XCTAssertEqual(store.expandedMode, "month")
        finishAnimation(on: c)
    }

    func testAnimationStabilityInputTimingHaloAndGracePeriod() async {
        let (store, _) = TaskStore.todayFixture()
        store.loadDemoData(taskCount: 30, completedCount: 6)
        let c = NotchPanelController(store: store, defaults: DemoDefaults())
        c.surfaceView.onPointerChanged = nil
        c.screensChanged([DisplayMetrics.fixture(id: 1001, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: 185)])
        defer { c.cancelScheduledCollapse(); c.panel.orderOut(nil) }

        c.state.pinned = true
        c.expand()
        let opening = c.motion!
        c.advanceAnimation(at: opening.started + 0.025)
        let before = c.interactionFrame
        let cube = c.state.geometry.blockInteractionRect(in: before)
        let point = NSPoint(x: cube.midX, y: cube.midY)
        let local = NSPoint(x: point.x - c.panel.frame.minX, y: point.y - c.panel.frame.minY)
        let hit = c.surfaceView.hitTest(local)
        XCTAssertTrue(hit === c.headerHosting || hit?.isDescendant(of: c.headerHosting) == true)
        let bodyPoint = NSPoint(x: local.x, y: local.y - c.state.geometry.collapsedHeight)
        XCTAssertTrue(c.surfaceView.hitTest(bodyPoint) === c.surfaceView)

        c.trackHeaderPointer(type: .leftMouseDown, point: point, inPanel: true)
        c.advanceAnimation(at: opening.started + 0.04)
        c.trackHeaderPointer(type: .leftMouseDragged, point: point, inPanel: true)
        c.trackHeaderPointer(type: .leftMouseUp, point: point, inPanel: true)
        XCTAssertFalse(c.isDragging)
        XCTAssertEqual(c.lastDragEndedAt, .distantPast)

        c.state.onSelectMonth?()
        XCTAssertEqual(store.expandedMode, "month")
        let mixed = c.motion!
        XCTAssertTrue(mixed.spring != nil && mixed.pageDuration == 0.16)
        for _ in 0..<100 {
            c.trackHeaderPointer(type: .leftMouseDown, point: point, inPanel: true)
            c.trackHeaderPointer(type: .leftMouseUp, point: point, inPanel: true)
            c.state.onSelectMonth?()
            XCTAssertTrue(c.acceptsClick && store.expandedMode == "month")
            XCTAssertEqual(c.motion?.started, mixed.started)
        }
        c.advanceAnimation(at: mixed.started + 0.161)
        XCTAssertEqual(c.presentedVector?.second.second.second, 1)
        c.state.onSelectDay?()
        XCTAssertEqual(store.expandedMode, "today")
        finishAnimation(on: c)
        XCTAssertTrue(c.state.monthProgress == 0 && c.acceptsClick)

        c.trackHeaderPointer(type: .leftMouseDown, point: point, inPanel: true)
        c.trackHeaderPointer(type: .leftMouseDragged, point: NSPoint(x: point.x + 1, y: point.y + 1), inPanel: true)
        XCTAssertFalse(c.isDragging)
        c.trackHeaderPointer(type: .leftMouseDragged, point: NSPoint(x: point.x + 30, y: point.y), inPanel: true)
        XCTAssertTrue(c.isDragging && !c.acceptsClick)
        c.state.onSelectMonth?()
        XCTAssertEqual(store.expandedMode, "today")
        c.trackHeaderPointer(type: .leftMouseUp, point: point, inPanel: false)
        XCTAssertFalse(c.isDragging || c.headerPressOrigin != nil || c.acceptsClick)
        c.lastDragEndedAt = .distantPast
        c.resetOffset()
        c.state.onSelectMonth?()
        finishAnimation(on: c)
        XCTAssertEqual(store.expandedMode, "month")

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
                    XCTAssertTrue(zip(a, b).allSatisfy { abs($0 - $1) < 0.04 })
                    haloSamples += 1
                }
            }
        }
        XCTAssertGreaterThanOrEqual(haloSamples, 6)

        c.state.pinned = false
        let outside = NSPoint(x: c.interactionFrame.maxX + 40, y: c.interactionFrame.minY - 40)
        c.pollCursor(at: outside)
        XCTAssertNotNil(c.collapseWork)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(c.state.expanded)
        c.pollCursor(at: NSPoint(x: c.interactionFrame.midX, y: c.interactionFrame.maxY - 10))
        XCTAssertNil(c.collapseWork)
        try? await Task.sleep(nanoseconds: 160_000_000)
        XCTAssertTrue(c.state.expanded)
        c.pollCursor(at: outside)
        try? await Task.sleep(nanoseconds: 340_000_000)
        XCTAssertFalse(c.state.expanded)
        finishAnimation(on: c)
        XCTAssertTrue(c.motion == nil && c.animationDisplayLink?.isPaused != false)
    }
}
