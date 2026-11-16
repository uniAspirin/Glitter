import AppKit
import SwiftUI

struct PanelSnapshot {
    let body: CGImage
    let size: CGSize
    let headerHeight: CGFloat

    @MainActor
    static func capture(_ view: NSView, headerHeight: CGFloat, scale: CGFloat) -> PanelSnapshot? {
        guard view.bounds.height > headerHeight,
              let preferred = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        let width = Int(round(view.bounds.width * scale))
        let height = Int(round(view.bounds.height * scale))
        let bitmap: NSBitmapImageRep
        if preferred.pixelsWide == width && preferred.pixelsHigh == height {
            bitmap = preferred
        } else {
            // Preserve Retina resolution when the requested display differs from the backing screen.
            guard let scaled = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            scaled.size = view.bounds.size
            bitmap = scaled
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return nil }
        let headerPixels = Int(round(headerHeight * scale))
        guard let body = image.cropping(to: CGRect(x: 0, y: headerPixels, width: image.width,
                                                  height: image.height - headerPixels)) else { return nil }
        return PanelSnapshot(body: body, size: view.bounds.size, headerHeight: headerHeight)
    }
}

/// Session-local Retina snapshots. Data and display changes invalidate both pages.
@MainActor
final class PanelRenderCache {
    enum Page: CaseIterable { case day, month }
    private var geometry: NotchGeometry?
    private var images: [Page: PanelSnapshot] = [:]

    func invalidate() { images.removeAll() }

    func prepare(store: TaskStore, state: PanelState) {
        for page in Page.allCases {
            _ = snapshot(page: page, store: store, state: state)
        }
    }

    func snapshot(page: Page, store: TaskStore, state: PanelState) -> PanelSnapshot? {
        var key = state.geometry
        key.showingMonth = false
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
        let size = CGSize(width: full.expandedWidth, height: full.expandedHeight)
        guard size.height > full.collapsedHeight else { return nil }
        let rendering = PanelState(geometry: full, mode: full.showingMonth ? "month" : "today")
        rendering.expanded = true
        rendering.present(size: size, expansion: 1, month: full.showingMonth ? 1 : 0)
        let view = NotchPanelView(store: store, state: rendering)
            .environment(\.displayScale, full.displayScale)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        // Use the same AppKit renderer as the live page so shadows retain their appearance.
        // This window stays ordered out and is released after the cached bitmap is ready.
        let frame = NSRect(x: full.screenFrame.minX, y: full.screenFrame.maxY - size.height,
                           width: size.width, height: size.height)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        return PanelSnapshot.capture(hosting, headerHeight: full.collapsedHeight, scale: max(1, full.displayScale))
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

    func captureLive(headerHeight: CGFloat) -> PanelSnapshot? {
        guard let hosting else { return nil }
        let hidden = hosting.isHidden
        hosting.isHidden = false
        defer { hosting.isHidden = hidden }
        return PanelSnapshot.capture(hosting, headerHeight: headerHeight, scale: hosting.window?.backingScaleFactor ?? 1)
    }

    func layout(frame: NSRect, monthProgress: CGFloat) {
        guard let d = daySnapshot, let m = monthSnapshot else { return }
        let size = frame.size
        container.frame = frame
        let progress = min(1, max(0, monthProgress))
        let origin = (size.width - d.size.width) / 2
        day.frame = NSRect(x: origin - d.size.width * progress,
                           y: size.height - d.size.height,
                           width: d.size.width, height: d.size.height - d.headerHeight)
        month.frame = NSRect(x: origin + m.size.width * (1 - progress),
                             y: size.height - m.size.height,
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
