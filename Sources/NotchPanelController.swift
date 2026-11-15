import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PanelSurfaceView: NSView {
    var onPointerChanged: (() -> Void)?
    var blocksContentInput = false
    var visibleContentRect: NSRect?

    private let outlineMask = CAShapeLayer()

    func applyVisibleFrame(_ rect: NSRect, corner: CGFloat) {
        let r = min(corner, rect.width / 2, rect.height / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                    startAngle: 0, endAngle: -.pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                    startAngle: -.pi / 2, endAngle: -.pi, clockwise: true)
        path.closeSubpath()
        outlineMask.frame = bounds
        outlineMask.contentsScale = window?.backingScaleFactor ?? 1
        outlineMask.path = path
        layer?.mask = outlineMask
    }

    func containsVisiblePoint(_ point: NSPoint) -> Bool {
        outlineMask.path?.contains(point) ?? bounds.contains(point)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard containsVisiblePoint(point) else { return nil }
        if blocksContentInput { return self }
        return super.hitTest(point)
    }
    private var pointerTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        if pointerTracking == nil {
            let area = NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(area)
            pointerTracking = area
        }
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onPointerChanged?() }
    override func mouseExited(with event: NSEvent) { onPointerChanged?() }
    override func mouseMoved(with event: NSEvent) { onPointerChanged?() }
}

@MainActor
private final class AnimationDisplayLinkTarget: NSObject {
    var onFrame: ((CADisplayLink) -> Void)?

    @objc func tick(_ link: CADisplayLink) {
        onFrame?(link)
    }
}

@MainActor
final class NotchPanelController: ObservableObject {
    private enum Keys {
        static let display = "SandNotch.displayID"
        static let offset = "SandNotch.horizontalOffset"
        static let menuBarIcon = "Glitter.showMenuBarIcon"
    }

    private(set) var panel: NotchPanel
    let state: PanelState
    private let store: TaskStore

    var onDataChanged: (() -> Void)?

    @Published private(set) var selectedDisplayID: CGDirectDisplayID?
    @Published private(set) var screens: [NSScreen]
    @Published private(set) var showsMenuBarIcon: Bool

    private var hoverTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var collapseWork: DispatchWorkItem?
    // 依次表示 (中心 X, 顶边)、(宽, 高)、(展开进度, 月视图进度)。
    private typealias MotionPair = AnimatablePair<Double, Double>
    private typealias MotionVector = AnimatablePair<MotionPair, AnimatablePair<MotionPair, MotionPair>>
    private struct Motion {
        let start: MotionVector
        let target: MotionVector
        let velocity: MotionVector
        let started: CFTimeInterval
        let duration: TimeInterval
    }
    private static let motionDuration: TimeInterval = 0.10
    private static let expansionDuration: TimeInterval = 0.12
    private let displayLinkTarget = AnimationDisplayLinkTarget()
    private var animationDisplayLink: CADisplayLink?
    private var motion: Motion?
    private var animationElapsed: TimeInterval = 0
    private var presentedVector: MotionVector?
    private let surfaceView = PanelSurfaceView()
    private let renderCache = PanelRenderCache()
    private var snapshotLayer: PanelSnapshotLayer!
    private var headerHosting: NSHostingView<PanelHeaderView>!
    private var snapshotWork: DispatchWorkItem?
    private var pendingDataChange = false
    private var pointerGlobalMonitor: Any?
    private let defaults: UserDefaults

    private var isDragging = false
    private var lastDragEndedAt = Date.distantPast
    private var dragStartMouseX: CGFloat = 0
    private var dragStartOffset: CGFloat = 0

    init(store: TaskStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        showsMenuBarIcon = defaults.object(forKey: Keys.menuBarIcon) as? Bool ?? true
        let availableScreens = NSScreen.screens
        screens = availableScreens
        let savedDisplayID = defaults.object(forKey: Keys.display) == nil
            ? nil : CGDirectDisplayID(defaults.integer(forKey: Keys.display))
        selectedDisplayID = savedDisplayID
        let savedOffset = CGFloat(defaults.double(forKey: Keys.offset))

        let screen = Self.screen(for: savedDisplayID, screens: availableScreens)
        let stat = store.todayStat
        var geometry = NotchGeometry.make(for: screen, rows: store.expandedRows, offset: savedOffset,
                                           scoreText: "\(stat.done)/\(stat.due)",
                                           showingMonth: store.expandedMode == "month",
                                           referenceNotchWidth: NotchGeometry.referenceNotchWidth(in: availableScreens))
        if screen == nil {
            geometry.horizontalOffset = savedOffset
        }
        geometry.showsCalendar = store.hasStatistics
        geometry.noticeHeight = store.panelNotice.map { $0.height(width: geometry.contentWidth, compact: true) + geometry.padding } ?? 0
        if store.hasStatistics && !store.todayTasks.isEmpty {
            geometry.measureToday(tasks: store.presentationTasks, error: nil, summary: store.presentationSummary)
        } else {
            geometry.measureMessage(store.panelMessage)
        }
        state = PanelState(geometry: geometry, mode: store.expandedMode)

        panel = NotchPanel(
            contentRect: geometry.collapsedRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        // 一直接收点击：折叠时窗口只有胶囊那么大，所以不会挡住别的地方
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true

        let hosting = NSHostingView(rootView: NotchPanelView(store: store, state: state))
        // 原生黑色底层随窗口立即铺满，SwiftUI 内容在同一层内裁切。
        surfaceView.wantsLayer = true
        surfaceView.layer?.backgroundColor = NSColor.black.cgColor
        surfaceView.layer?.masksToBounds = true
        panel.contentView = surfaceView
        hosting.sizingOptions = []
        hosting.frame = surfaceView.bounds
        hosting.autoresizingMask = [.width, .height]
        surfaceView.addSubview(hosting)
        snapshotLayer = PanelSnapshotLayer(surface: surfaceView, hosting: hosting)
        headerHosting = NSHostingView(rootView: PanelHeaderView(store: store, state: state))
        headerHosting.wantsLayer = true
        headerHosting.layer?.zPosition = 20
        surfaceView.addSubview(headerHosting)
        headerHosting.sizingOptions = []
        surfaceView.applyVisibleFrame(surfaceView.bounds, corner: state.cornerRadius)
        layoutHeader(frame: surfaceView.bounds)
        renderCache.prepare(store: store, state: state)
        surfaceView.onPointerChanged = { [weak self] in self?.pollCursor() }

        displayLinkTarget.onFrame = { [weak self] link in
            guard let self, self.animationDisplayLink === link else { return }
            self.advanceAnimation(at: link.targetTimestamp)
        }
        state.onTogglePinned = { [weak self] in self?.togglePinned() }
        state.onSelectDay = { [weak self] in self?.selectMode("today") }
        state.onSelectMonth = { [weak self] in self?.selectMode("month") }
        state.onDragChanged = { [weak self] in self?.dragChanged() }
        state.onDragEnded = { [weak self] in self?.dragEnded() }

        store.onUpdate = { [weak self] in self?.dataChanged() }
        startHoverWatch()
        observeScreens()

    }

    deinit {
        animationDisplayLink?.invalidate()
        hoverTimer?.invalidate()
        collapseWork?.cancel()
        snapshotWork?.cancel()
        if let pointerGlobalMonitor { NSEvent.removeMonitor(pointerGlobalMonitor) }
        if let observer = screenObserver { NotificationCenter.default.removeObserver(observer) }
    }

    func show() {
        guard currentScreen != nil else { return }
        panel.orderFrontRegardless()
    }

    // MARK: - 展开 / 收起

    func expand() {
        guard !state.expanded else { return }
        cancelScheduledCollapse()
        store.setExpandedMode("today")
        state.expanded = true
        updateWindowFrame(expanded: true, animated: true)
        show()
    }

    func collapse() {
        guard state.expanded, !state.pinned, !isDragging else { return }
        cancelScheduledCollapse()
        state.expanded = false
        state.headerHovered = false
        state.blockHovered = false
        state.hoveredTaskID = nil
        updateWindowFrame(expanded: false, animated: true)
    }

    private func updateWindowFrame(expanded: Bool, animated: Bool = false) {
        let target = Self.vector(rect: state.geometry.rect(expanded: expanded),
                                 expansion: expanded ? 1 : 0, month: store.expandedMode == "month" ? 1 : 0)
        if animated, animationDisplayLink != nil, motion?.target == target { return }

        let start = presentedVector ?? Self.vector(rect: panel.frame, expansion: state.expansionProgress, month: state.monthProgress)
        let velocity = motion.map { Self.motionVelocity($0, elapsed: animationElapsed) } ?? .zero
        // Preserve the visible scroll position when the Day page leaves the screen.
        let sourceDay = !snapshotLayer.isVisible && state.geometry.dayScrolls
            && start.second.second.first > 0.999 && start.second.second.second < 0.001
            ? snapshotLayer.captureLive(headerHeight: state.geometry.collapsedHeight) : nil
        stopAnimation(flushUpdates: false)
        guard animated, currentScreen != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              start != target else {
            present(vector: target)
            finishPresentation()
            return
        }

        presentedVector = start
        if let day = renderCache.snapshot(page: .day, store: store, state: state),
           let month = renderCache.snapshot(page: .month, store: store, state: state) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            snapshotLayer.show(day: sourceDay ?? day, month: month)
            surfaceView.blocksContentInput = true
            // Prepare the hidden destination once, so the final frame only restores it.
            withTransaction(Transaction(animation: nil)) {
                state.present(size: presentationRect(target).size, expansion: expanded ? 1 : 0,
                              month: store.expandedMode == "month" ? 1 : 0)
            }
            snapshotLayer.prepareLive(size: presentationRect(target).size)
            // The retained ScrollView can be below its initial offset. Capture its prepared
            // viewport so the animation and the live handoff show the same rows.
            if expanded, !state.geometry.showingMonth, state.geometry.dayScrolls,
               let scrolledDay = snapshotLayer.captureLive(headerHeight: state.geometry.collapsedHeight) {
                snapshotLayer.show(day: scrolledDay, month: month)
            }
            let animationBounds = presentationRect(start).union(presentationRect(target))
            panel.setFrame(animationBounds, display: false)
            let visible = presentationRect(start).offsetBy(dx: -animationBounds.minX, dy: -animationBounds.minY)
            let collapsed: CGFloat = state.geometry.hasNotch ? 12 : 16
            snapshotLayer.layout(frame: visible, monthProgress: start.second.second.second)
            surfaceView.applyVisibleFrame(visible, corner: collapsed + (26 - collapsed) * start.second.second.first)
            layoutHeader(frame: visible)
            surfaceView.visibleContentRect = visible
            panel.ignoresMouseEvents = !presentationRect(start).contains(NSEvent.mouseLocation)
            CATransaction.commit()
        }
        snapshotWork?.cancel()
        store.setPresentationDeferred(true)
        let changesExpansion = start.second.second.first != target.second.second.first
        let duration = changesExpansion ? Self.expansionDuration : Self.motionDuration
        motion = Motion(start: start, target: target,
                        velocity: Self.boundedVelocity(velocity, displacement: target - start, duration: duration),
                        started: CACurrentMediaTime(), duration: duration)
        if pointerGlobalMonitor == nil && snapshotLayer.isVisible {
            pointerGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollCursor() }
            }
        }
        // 窗口的 displayLink 会自动跟随显示器变化，回调只在动画期间启用。
        let link = animationDisplayLink ?? panel.displayLink(target: displayLinkTarget, selector: #selector(AnimationDisplayLinkTarget.tick(_:)))
        let screenRate = currentScreen?.maximumFramesPerSecond ?? 60
        let maximum = Float(screenRate > 0 ? screenRate : 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: maximum, maximum: maximum, preferred: maximum)
        if animationDisplayLink == nil {
            animationDisplayLink = link
            link.add(to: .main, forMode: .common)
        }
        link.isPaused = false
    }

    private func advanceAnimation(at timestamp: CFTimeInterval) {
        guard let motion else { return }
        let elapsed = max(0, timestamp - motion.started)
        animationElapsed = elapsed
        if elapsed >= motion.duration {
            let target = motion.target
            stopAnimation(flushUpdates: false)
            present(vector: target)
            finishPresentation()
            return
        }
        let t = elapsed / motion.duration
        var displacement = motion.target - motion.start
        displacement.scale(by: t * t * (3 - 2 * t))
        var carriedVelocity = motion.velocity
        carriedVelocity.scale(by: motion.duration * t * (1 - t) * (1 - t))
        present(vector: motion.start + displacement + carriedVelocity)
    }

    /// Cubic Hermite easing preserves velocity on reversal and reaches its exact endpoint.
    private static func motionVelocity(_ motion: Motion, elapsed: TimeInterval) -> MotionVector {
        let t = min(1, max(0, elapsed / motion.duration))
        var displacement = motion.target - motion.start
        displacement.scale(by: 6 * t * (1 - t) / motion.duration)
        var velocity = motion.velocity
        velocity.scale(by: (1 - t) * (1 - 3 * t))
        return displacement + velocity
    }

    private static func boundedVelocity(_ velocity: MotionVector, displacement: MotionVector, duration: TimeInterval) -> MotionVector {
        func component(_ speed: Double, _ distance: Double) -> Double {
            guard distance != 0 else { return 0 }
            // Initial slope in [0, 3] makes the cubic monotonic, including interrupted closes.
            return min(3 / duration, max(0, speed / distance)) * distance
        }
        func pair(_ speed: MotionPair, _ distance: MotionPair) -> MotionPair {
            MotionPair(component(speed.first, distance.first), component(speed.second, distance.second))
        }
        return MotionVector(pair(velocity.first, displacement.first),
                            AnimatablePair(pair(velocity.second.first, displacement.second.first),
                                           pair(velocity.second.second, displacement.second.second)))
    }

    private func stopAnimation(flushUpdates: Bool = true) {
        animationDisplayLink?.isPaused = true
        motion = nil
        animationElapsed = 0
        if flushUpdates { finishPresentation() }
    }

    private func finishPresentation() {
        snapshotLayer?.hide(size: panel.frame.size)
        surfaceView.blocksContentInput = false
        surfaceView.visibleContentRect = nil
        if let pointerGlobalMonitor { NSEvent.removeMonitor(pointerGlobalMonitor); self.pointerGlobalMonitor = nil }
        panel.ignoresMouseEvents = false
        store.setPresentationDeferred(false)
        if pendingDataChange {
            pendingDataChange = false
            refreshGeometry(animated: state.expanded)
        }
        scheduleSnapshotPreparation(invalidate: false)
    }

    private func scheduleSnapshotPreparation(invalidate: Bool = true) {
        if invalidate { renderCache.invalidate() }
        snapshotWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.motion == nil, !self.store.isMutating else { return }
            self.renderCache.prepare(store: self.store, state: self.state)
        }
        snapshotWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private static func vector(rect: NSRect, expansion: CGFloat, month: CGFloat) -> MotionVector {
        MotionVector(MotionPair(Double(rect.midX), Double(rect.maxY)),
                     AnimatablePair(MotionPair(Double(rect.width), Double(rect.height)),
                                    MotionPair(Double(expansion), Double(month))))
    }

    private func presentationRect(_ vector: MotionVector) -> NSRect {
        let position = vector.first
        let size = vector.second.first
        let width = max(1, size.first)
        let height = max(Double(state.geometry.collapsedHeight), size.second)
        return NSRect(x: position.first - width / 2, y: position.second - height, width: width, height: height)
    }

    private var interactionFrame: NSRect {
        if motion != nil, let presentedVector { return presentationRect(presentedVector) }
        return panel.frame
    }

    private func present(vector: MotionVector) {
        presentedVector = vector
        let progress = vector.second.second
        present(rect: presentationRect(vector), expansion: min(max(progress.first, 0), 1), month: min(max(progress.second, 0), 1))
    }

    private func present(rect: NSRect, expansion: CGFloat, month: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let collapsed: CGFloat = state.geometry.hasNotch ? 12 : 16
        let corner = collapsed + (26 - collapsed) * expansion
        if motion != nil && snapshotLayer.isVisible {
            let visible = rect.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
            snapshotLayer.layout(frame: visible, monthProgress: month)
            surfaceView.applyVisibleFrame(visible, corner: corner)
            layoutHeader(frame: visible)
            surfaceView.visibleContentRect = visible
            panel.ignoresMouseEvents = !rect.contains(NSEvent.mouseLocation)
        } else {
            let contentWasPrepared = snapshotLayer.isVisible
            panel.setFrame(rect, display: false)
            withTransaction(Transaction(animation: nil)) {
                state.present(size: rect.size, expansion: expansion, month: month)
            }
            snapshotLayer.hide(size: rect.size)
            surfaceView.applyVisibleFrame(surfaceView.bounds, corner: corner)
            layoutHeader(frame: surfaceView.bounds)
            if !contentWasPrepared { surfaceView.layoutSubtreeIfNeeded() }
        }
        CATransaction.commit()
    }

    private func layoutHeader(frame: NSRect) {
        let height = state.geometry.collapsedHeight
        let rect = NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
        if headerHosting.frame != rect { headerHosting.frame = rect }
    }

    func togglePinned() {
        state.pinned.toggle()
        if state.pinned {
            expand()
        } else {
            pollCursor()
        }
        onDataChanged?()
    }

    func setMenuBarIconVisible(_ visible: Bool) {
        guard visible != showsMenuBarIcon else { return }
        showsMenuBarIcon = visible
        defaults.set(visible as Any, forKey: Keys.menuBarIcon)
        onDataChanged?()
    }

    func forceExpandedForDebug() {
        state.pinned = true
        expand()
    }

    // MARK: - 显示器

    var currentScreen: NSScreen? { Self.screen(for: selectedDisplayID, screens: screens) }

    func selectDisplay(_ id: CGDirectDisplayID) {
        guard screens.contains(where: { $0.displayID == id }) else { return }
        dragEnded()
        cancelScheduledCollapse()
        selectedDisplayID = id
        defaults.set(Int(id), forKey: Keys.display)
        refreshGeometry()
        onDataChanged?()
    }

    func resetOffset() {
        isDragging = false
        state.geometry.horizontalOffset = 0
        defaults.set(0.0, forKey: Keys.offset)
        updateWindowFrame(expanded: state.expanded)
        onDataChanged?()
    }

    // MARK: - 点击 / 拖动

    private var acceptsClick: Bool {
        !isDragging && Date().timeIntervalSince(lastDragEndedAt) > 0.15
    }

    private func selectMode(_ mode: String) {
        guard state.expanded, acceptsClick else { return }
        cancelScheduledCollapse()
        store.setExpandedMode(mode)
    }

    private func dragChanged() {
        guard state.expanded else { return }
        if !isDragging {
            state.headerHovered = false
            isDragging = true
            dragStartMouseX = NSEvent.mouseLocation.x
            dragStartOffset = state.geometry.horizontalOffset
            cancelScheduledCollapse()
        }

        let delta = NSEvent.mouseLocation.x - dragStartMouseX
        let offset = state.geometry.clampedOffset(dragStartOffset + delta)

        guard offset != state.geometry.horizontalOffset else { return }
        state.geometry.horizontalOffset = offset
        updateWindowFrame(expanded: state.expanded)
    }

    private func dragEnded() {
        guard isDragging else { return }
        lastDragEndedAt = Date()
        isDragging = false
        state.geometry.horizontalOffset = state.geometry.settledOffset(state.geometry.horizontalOffset)
        updateWindowFrame(expanded: state.expanded)
        defaults.set(Double(state.geometry.horizontalOffset), forKey: Keys.offset)
    }

    // MARK: - 悬停

    private func startHoverWatch() {
        guard hoverTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollCursor() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func pollCursor(at point: NSPoint = NSEvent.mouseLocation) {
        guard !isDragging else {
            state.headerHovered = false
            state.hoveredTaskID = nil
            return
        }
        let g = state.geometry
        let visibleFrame = interactionFrame
        let hovered = state.expanded && g.headerInteractionRect(in: visibleFrame).contains(point)
        let blockHovered = state.expanded && g.blockInteractionRect(in: visibleFrame).contains(point)
        if state.headerHovered != hovered { state.headerHovered = hovered }
        if state.blockHovered != blockHovered { state.blockHovered = blockHovered }
        if motion != nil {
            panel.ignoresMouseEvents = !visibleFrame.contains(point)
            if state.expanded && !state.pinned {
                if visibleFrame.insetBy(dx: -2, dy: -2).contains(point) { cancelScheduledCollapse() }
                else { scheduleCollapse() }
            } else if !state.expanded && visibleFrame.contains(point) { expand() }
            return
        }
        let taskHovered = state.expanded && store.canCompleteTasks && !store.isMutating
            ? g.taskInteractionRects(tasks: store.presentationTasks, in: visibleFrame).first(where: { $0.rect.contains(point) })?.id : nil
        if state.hoveredTaskID != taskHovered { state.hoveredTaskID = taskHovered }

        if state.expanded {
            guard !state.pinned else { return }
            if visibleFrame.insetBy(dx: -2, dy: -2).contains(point) {
                cancelScheduledCollapse()
            } else {
                scheduleCollapse()
            }
        } else if (state.expansionProgress > 0 ? visibleFrame : g.hotZone).contains(point) {
            expand()
        }
    }

    private func scheduleCollapse() {
        guard collapseWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseWork = nil
            if !self.state.pinned && !self.isDragging { self.collapse() }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    private func cancelScheduledCollapse() {
        collapseWork?.cancel()
        collapseWork = nil
    }

    // MARK: - 屏幕 / 数据变化

    private func observeScreens() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        }
    }

    private func screensChanged(_ availableScreens: [NSScreen] = NSScreen.screens) {
        dragEnded()
        screens = availableScreens
        refreshGeometry()
        onDataChanged?()
    }

    private func dataChanged() {
        let modeChanged = state.geometry.showingMonth != (store.expandedMode == "month")
        if modeChanged {
            // Both pages already have measured geometry and cached images.
            state.geometry.showingMonth = store.expandedMode == "month"
            if state.expanded {
                updateWindowFrame(expanded: true, animated: true)
            } else if motion == nil {
                // Select the hidden page without laying out the collapsed window again.
                let month: CGFloat = state.geometry.showingMonth ? 1 : 0
                presentedVector = Self.vector(rect: panel.frame, expansion: 0, month: month)
                state.present(size: panel.frame.size, expansion: 0, month: month)
            }
            return
        }
        renderCache.invalidate()
        if motion != nil {
            pendingDataChange = true
        } else {
            refreshGeometry(animated: state.expanded)
            scheduleSnapshotPreparation(invalidate: false)
        }
        onDataChanged?()
    }

    private func refreshGeometry(animated: Bool = false) {
        let rows = store.expandedRows
        guard let screen = currentScreen else {
            stopAnimation()
            panel.orderOut(nil)
            return
        }
        let offset = state.geometry.horizontalOffset
        let stat = store.todayStat
        var geometry = NotchGeometry.make(for: screen, rows: rows, offset: offset,
                                          scoreText: "\(stat.done)/\(stat.due)",
                                           showingMonth: store.expandedMode == "month",
                                           referenceNotchWidth: NotchGeometry.referenceNotchWidth(in: screens) ?? state.geometry.notchWidth)
        geometry.showsCalendar = store.hasStatistics
        geometry.noticeHeight = store.panelNotice.map { $0.height(width: geometry.contentWidth, compact: true) + geometry.padding } ?? 0
        if store.hasStatistics && !store.todayTasks.isEmpty {
            geometry.measureToday(tasks: store.presentationTasks, error: nil, summary: store.presentationSummary)
        } else {
            geometry.measureMessage(store.panelMessage)
        }
        if isDragging {
            geometry.horizontalOffset = geometry.clampedOffset(offset)
        }

        state.geometry = geometry
        updateWindowFrame(expanded: state.expanded, animated: animated)
        if !panel.isVisible { show() }
    }

    private static func screen(for id: CGDirectDisplayID?, screens: [NSScreen]) -> NSScreen? {
        if let id, let match = screens.first(where: { $0.displayID == id }) {
            return match
        }
        if let notched = screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        let mainID = NSScreen.main?.displayID
        return screens.first(where: { $0.displayID == mainID }) ?? screens.first
    }

    // MARK: - 调试

    func runHoverSelfTest() {
        let g = state.geometry
        let hot = NSPoint(x: g.hotZone.midX, y: g.hotZone.minY + 6)
        warp(hot)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let away = NSPoint(x: g.screenFrame.midX, y: g.screenFrame.midY)
            self.warp(away)
        }
    }

    private func warp(_ point: NSPoint) {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: mainHeight - point.y))
    }
}
