import AppKit
import SwiftUI

struct PanelSnapshot {
    let body: CGImage
    let size: CGSize
    let headerHeight: CGFloat
}

/// Session-local Retina snapshots. Data and display changes invalidate all three pages.
@MainActor
final class PanelRenderCache {
    enum Page: CaseIterable { case day, expandedDay, month }
    private var geometry: NotchGeometry?
    private var images: [Page: PanelSnapshot] = [:]

    func invalidate() { images.removeAll() }

    func prepare(store: TaskStore, state: PanelState) {
        for page in Page.allCases {
            if page == .expandedDay && !state.geometry.dayOverflows { continue }
            _ = snapshot(page: page, store: store, state: state)
        }
    }

    func snapshot(page: Page, store: TaskStore, state: PanelState) -> PanelSnapshot? {
        var key = state.geometry
        key.showingMonth = false
        key.dayExpanded = false
        key.horizontalOffset = 0
        if geometry != key {
            geometry = key
            invalidate()
        }
        if let cached = images[page] { return cached }
        guard let result = autoreleasepool(invoking: { render(page: page, store: store, geometry: key) }) else { return nil }
        images[page] = result
        return result
    }

    private func render(page: Page, store: TaskStore, geometry: NotchGeometry) -> PanelSnapshot? {
        var full = geometry
        full.showingMonth = page == .month
        full.dayExpanded = page == .expandedDay
        let size = CGSize(width: full.expandedWidth, height: full.expandedHeight)
        guard size.height > full.collapsedHeight else { return nil }
        let rendering = PanelState(geometry: full, mode: full.showingMonth ? "month" : "today")
        rendering.expanded = true
        rendering.dayExpanded = full.dayExpanded
        rendering.present(size: size, expansion: 1, month: full.showingMonth ? 1 : 0)
        let view = NotchPanelView(store: store, state: rendering)
            .environment(\.displayScale, full.displayScale)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let renderer = ImageRenderer(content: view)
        let scale = max(1, full.displayScale)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { return nil }
        let headerPixels = Int(round(full.collapsedHeight * scale))
        guard let body = image.cropping(to: CGRect(x: 0, y: headerPixels, width: image.width, height: image.height - headerPixels)) else { return nil }
        let result = PanelSnapshot(body: body, size: size, headerHeight: full.collapsedHeight)
        return result
    }
}

/// Only layers change on display-link ticks. The hosting view stays at a fixed size.
@MainActor
final class PanelSnapshotLayer {
    private let container = CALayer()
    private let day = CALayer()
    private let month = CALayer()
    private weak var hosting: NSView?
    private var daySnapshot: PanelSnapshot?
    private var monthSnapshot: PanelSnapshot?
    private(set) var isVisible = false

    init(surface: NSView, hosting: NSView) {
        self.hosting = hosting
        container.zPosition = 10
        container.isHidden = true
        container.masksToBounds = true
        for layer in [day, month] {
            layer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
            container.addSublayer(layer)
        }
        surface.layer?.addSublayer(container)
    }

    func show(day daySnapshot: PanelSnapshot, month monthSnapshot: PanelSnapshot) {
        if self.daySnapshot?.body !== daySnapshot.body { day.contents = daySnapshot.body }
        if self.monthSnapshot?.body !== monthSnapshot.body { month.contents = monthSnapshot.body }
        self.daySnapshot = daySnapshot
        self.monthSnapshot = monthSnapshot
        let scale = CGFloat(daySnapshot.body.width) / daySnapshot.size.width
        for layer in [container, day, month] { layer.contentsScale = scale }
        hosting?.autoresizingMask = []
        hosting?.isHidden = true
        container.isHidden = false
        isVisible = true
    }

    func prepareLive(size: CGSize) {
        hosting?.frame = NSRect(origin: .zero, size: size)
        hosting?.layoutSubtreeIfNeeded()
    }

    func layout(frame: NSRect, monthProgress: CGFloat) {
        guard let d = daySnapshot, let m = monthSnapshot else { return }
        let size = frame.size
        container.frame = frame
        let origin = (size.width - d.size.width) / 2
        day.frame = NSRect(x: origin - d.size.width * monthProgress, y: size.height - d.size.height,
                           width: d.size.width, height: d.size.height - d.headerHeight)
        month.frame = NSRect(x: origin + m.size.width * (1 - monthProgress), y: size.height - m.size.height,
                             width: m.size.width, height: m.size.height - m.headerHeight)

    }

    func hide(size: CGSize) {
        guard isVisible else { return }
        container.isHidden = true
        isVisible = false
        hosting?.frame = NSRect(origin: .zero, size: size)
        hosting?.autoresizingMask = [.width, .height]
        hosting?.isHidden = false
    }
}
