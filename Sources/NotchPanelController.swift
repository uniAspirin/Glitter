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
    }

    private(set) var panel: NotchPanel
    let state: PanelState
    private let store: TaskStore

    var onDataChanged: (() -> Void)?

    private var scrollLocalMonitor: Any?
    @Published private(set) var selectedDisplayID: CGDirectDisplayID?
    @Published private(set) var screens: [NSScreen]

    private var hoverTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var scrollMonitor: Any?
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
    private static let motionDuration: TimeInterval = 0.14
    private let displayLinkTarget = AnimationDisplayLinkTarget()
    private var animationDisplayLink: CADisplayLink?
    private var motion: Motion?
    private var animationElapsed: TimeInterval = 0
    private var presentedVector: MotionVector?
    private let surfaceView = PanelSurfaceView()
    private let renderCache = PanelRenderCache()
    private var snapshotLayer: PanelSnapshotLayer!
    private var headerHosting: NSHostingView<PanelHeaderView>!
    private var footerHosting: NSHostingView<PanelFooterView>!
    private var snapshotWork: DispatchWorkItem?
    private var pendingDataChange = false
    private var pointerGlobalMonitor: Any?
    private let defaults: UserDefaults
    private var scrollVerticalDistance: CGFloat = 0
    private var scrollHorizontalDistance: CGFloat = 0
    private var scrollGestureHandled = false
    private var panelScrollActive = false
    private var scrollStartedInOverflow = false

    private var isDragging = false
    private var lastDragEndedAt = Date.distantPast
    private var dragStartMouseX: CGFloat = 0
    private var dragStartOffset: CGFloat = 0

    init(store: TaskStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
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
        footerHosting = NSHostingView(rootView: PanelFooterView(store: store, state: state))
        for overlay in [headerHosting as NSView, footerHosting as NSView] {
            overlay.wantsLayer = true
            overlay.layer?.zPosition = 20
            surfaceView.addSubview(overlay)
        }
        headerHosting.sizingOptions = []
        footerHosting.sizingOptions = []
        surfaceView.applyVisibleFrame(surfaceView.bounds, corner: state.cornerRadius)
        layoutPersistentControls(frame: surfaceView.bounds, expansion: 0, month: state.monthProgress)
        renderCache.prepare(store: store, state: state)
        surfaceView.onPointerChanged = { [weak self] in self?.pollCursor() }

        displayLinkTarget.onFrame = { [weak self] link in
            guard let self, self.animationDisplayLink === link else { return }
            self.advanceAnimation(at: link.targetTimestamp)
        }
        state.onToggleMode = { [weak self] in self?.modeButtonClicked() }
        state.onSelectDay = { [weak self] in self?.selectMode("today") }
        state.onSelectMonth = { [weak self] in self?.selectMode("month") }
        state.onToggleDay = { [weak self] in
            guard let self, self.state.expanded, self.acceptsClick else { return }
            self.setDayExpanded(!self.state.dayExpanded)
        }
        state.onDragChanged = { [weak self] in self?.dragChanged() }
        state.onDragEnded = { [weak self] in self?.dragEnded() }

        store.onUpdate = { [weak self] in self?.dataChanged() }
        startHoverWatch()
        startScrollWatch()
        observeScreens()

    }

    deinit {
        animationDisplayLink?.invalidate()
        hoverTimer?.invalidate()
        collapseWork?.cancel()
        snapshotWork?.cancel()
        if let pointerGlobalMonitor { NSEvent.removeMonitor(pointerGlobalMonitor) }
        if let monitor = scrollLocalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = scrollMonitor { NSEvent.removeMonitor(monitor) }
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
        state.toggleHovered = false
        updateWindowFrame(expanded: false, animated: true)
    }

    private func updateWindowFrame(expanded: Bool, animated: Bool = false) {
        let target = Self.vector(rect: state.geometry.rect(expanded: expanded),
                                 expansion: expanded ? 1 : 0, month: store.expandedMode == "month" ? 1 : 0)
        if animated, animationDisplayLink != nil, motion?.target == target { return }

        let start = presentedVector ?? Self.vector(rect: panel.frame, expansion: state.expansionProgress, month: state.monthProgress)
        let velocity = motion.map { Self.motionVelocity($0, elapsed: animationElapsed) } ?? .zero
        stopAnimation(flushUpdates: false)
        guard animated, currentScreen != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              start != target else {
            present(vector: target)
            finishPresentation()
            return
        }

        presentedVector = start
        let shrinkingDay = !state.geometry.showingMonth && start.second.second.second < 0.001
            && presentationRect(start).height > state.geometry.expandedHeight + 0.5
        let expandedDay = state.geometry.dayOverflows && (state.dayExpanded || shrinkingDay)
        if let day = renderCache.snapshot(page: expandedDay ? .expandedDay : .day, store: store, state: state),
           let month = renderCache.snapshot(page: .month, store: store, state: state) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            snapshotLayer.show(day: day, month: month)
            surfaceView.blocksContentInput = true
            // Prepare the hidden destination once, so the final frame only restores it.
            withTransaction(Transaction(animation: nil)) {
                state.present(size: presentationRect(target).size, expansion: expanded ? 1 : 0,
                              month: store.expandedMode == "month" ? 1 : 0)
            }
            snapshotLayer.prepareLive(size: presentationRect(target).size)
            let animationBounds = presentationRect(start).union(presentationRect(target))
            panel.setFrame(animationBounds, display: false)
            let visible = presentationRect(start).offsetBy(dx: -animationBounds.minX, dy: -animationBounds.minY)
            let collapsed: CGFloat = state.geometry.hasNotch ? 12 : 16
            snapshotLayer.layout(frame: visible, monthProgress: start.second.second.second)
            surfaceView.applyVisibleFrame(visible, corner: collapsed + (26 - collapsed) * start.second.second.first)
            layoutPersistentControls(frame: visible, expansion: start.second.second.first, month: start.second.second.second)
            surfaceView.visibleContentRect = visible
            panel.ignoresMouseEvents = !presentationRect(start).contains(NSEvent.mouseLocation)
            CATransaction.commit()
        }
        snapshotWork?.cancel()
        store.setPresentationDeferred(true)
        let duration = Self.motionDuration
        motion = Motion(start: start, target: target,
                        velocity: Self.boundedVelocity(velocity, displacement: target - start, duration: duration),
                        started: CACurrentMediaTime(), duration: duration)
        if pointerGlobalMonitor == nil && snapshotLayer.isVisible {
            pointerGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollCursor() }
            }
        }
        // 窗口的 displayLink 会自动跟随显示器变化，回调只在动画期间启用。
        let link = panel.displayLink(target: displayLinkTarget, selector: #selector(AnimationDisplayLinkTarget.tick(_:)))
        let screenRate = currentScreen?.maximumFramesPerSecond ?? 60
        let maximum = Float(screenRate > 0 ? screenRate : 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        animationDisplayLink = link
        link.add(to: .main, forMode: .common)
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
        animationDisplayLink?.invalidate()
        animationDisplayLink = nil
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
            layoutPersistentControls(frame: visible, expansion: expansion, month: month)
            surfaceView.visibleContentRect = visible
            panel.ignoresMouseEvents = !rect.contains(NSEvent.mouseLocation)
        } else {
            panel.setFrame(rect, display: false)
            withTransaction(Transaction(animation: nil)) {
                state.present(size: rect.size, expansion: expansion, month: month)
            }
            snapshotLayer.hide(size: rect.size)
            surfaceView.applyVisibleFrame(surfaceView.bounds, corner: corner)
            layoutPersistentControls(frame: surfaceView.bounds, expansion: expansion, month: month)
            surfaceView.layoutSubtreeIfNeeded()
        }
        CATransaction.commit()
    }

    private func layoutPersistentControls(frame: NSRect, expansion: CGFloat, month: CGFloat) {
        let g = state.geometry
        let headerRect = NSRect(x: frame.minX, y: frame.maxY - g.collapsedHeight,
                                width: frame.width, height: g.collapsedHeight)
        if headerHosting.frame != headerRect { headerHosting.frame = headerRect }
        let footerRect = NSRect(x: frame.minX - g.expandedWidth * month,
                                y: frame.maxY - g.toggleTop - g.footerHeight,
                                width: frame.width, height: g.footerHeight)
        if footerHosting.frame != footerRect { footerHosting.frame = footerRect }
        footerHosting.isHidden = !g.dayOverflows || expansion <= 0 || month >= 1
    }

    func togglePinned() {
        state.pinned.toggle()
        if state.pinned {
            expand()
        } else {
            collapse()
        }
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

    private func setDayExpanded(_ expanded: Bool) {
        guard state.geometry.dayOverflows, !state.geometry.showingMonth, state.dayExpanded != expanded else { return }
        cancelScheduledCollapse()
        state.dayExpanded = expanded
        refreshGeometry(animated: true)
    }

    private func selectMode(_ mode: String) {
        guard state.expanded, acceptsClick else { return }
        cancelScheduledCollapse()
        store.setExpandedMode(mode)
    }

    private func modeButtonClicked() {
        guard acceptsClick else { return }
        store.setExpandedMode(store.expandedMode == "today" ? "month" : "today")
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
            state.toggleHovered = false
            return
        }
        let g = state.geometry
        let visibleFrame = interactionFrame
        if motion != nil {
            panel.ignoresMouseEvents = !visibleFrame.contains(point)
            if state.expanded && !state.pinned {
                if visibleFrame.insetBy(dx: -2, dy: -2).contains(point) { cancelScheduledCollapse() }
                else { scheduleCollapse() }
            } else if !state.expanded && visibleFrame.contains(point) { expand() }
            return
        }
        let hovered = state.expanded && store.hasStatistics && g.headerInteractionRect(in: visibleFrame).contains(point)
        if state.headerHovered != hovered { state.headerHovered = hovered }
        let blockHovered = state.expanded && g.blockInteractionRect(in: visibleFrame).contains(point)
        if state.blockHovered != blockHovered { state.blockHovered = blockHovered }
        let taskHovered = state.expanded && store.canCompleteTasks && !store.isMutating
            ? g.taskInteractionRects(tasks: store.presentationTasks, in: visibleFrame).first(where: { $0.rect.contains(point) })?.id : nil
        if state.hoveredTaskID != taskHovered { state.hoveredTaskID = taskHovered }

        let insideOutline = surfaceView.containsVisiblePoint(NSPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY))
        let toggleHovered = insideOutline && state.expanded && !g.showingMonth && g.dayOverflows && g.toggleInteractionRect(in: visibleFrame).contains(point)
        if state.toggleHovered != toggleHovered { state.toggleHovered = toggleHovered }

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

    // MARK: - 横向手势切换 Day / Month

    private func startScrollWatch() {
        scrollLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleScrollEvent(event) ?? false }
            return consumed ? nil : event
        }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handleScrollEvent(event) }
        }
    }

    private func handleScrollEvent(_ event: NSEvent) -> Bool {
        handleScroll(phase: event.phase, momentum: event.momentumPhase,
                     deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                     precise: event.hasPreciseScrollingDeltas, inverted: event.isDirectionInvertedFromDevice,
                     point: NSEvent.mouseLocation)
    }

    private func resetScrollGesture() {
        scrollVerticalDistance = 0
        scrollHorizontalDistance = 0
        scrollGestureHandled = false
        panelScrollActive = false
        scrollStartedInOverflow = false
    }

    private func handleScroll(phase: NSEvent.Phase, momentum: NSEvent.Phase,
                              deltaX: CGFloat, deltaY: CGFloat, precise: Bool, inverted: Bool, point: NSPoint) -> Bool {
        guard precise, !phase.isEmpty else { return false }
        let hitArea = interactionFrame
        if phase.contains(.began) {
            resetScrollGesture()
            panelScrollActive = state.expanded && store.hasStatistics && !isDragging && hitArea.contains(point)
            let g = state.geometry
            scrollStartedInOverflow = g.dayExpanded && g.overflowHeight > g.overflowViewportHeight + 0.5
                && point.y < hitArea.maxY - g.toggleTop - g.footerHeight
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            let consumed = scrollGestureHandled
            resetScrollGesture()
            return consumed
        }
        guard state.expanded, store.hasStatistics, !isDragging, panelScrollActive, momentum.isEmpty else { return false }
        // 一次手势只切换一次，面板缩小后仍消费本次手势的剩余事件。
        if scrollGestureHandled { return true }
        guard hitArea.contains(point) else {
            resetScrollGesture()
            return false
        }
        scrollVerticalDistance += inverted ? deltaY : -deltaY
        // Natural scrolling reports a leftward push as negative deltaX.
        scrollHorizontalDistance += inverted ? deltaX : -deltaX
        if abs(scrollHorizontalDistance) >= 18 && abs(scrollHorizontalDistance) > abs(scrollVerticalDistance) * 1.4 {
            scrollGestureHandled = true
            store.setExpandedMode(scrollHorizontalDistance < 0 ? "month" : "today")
            return true
        }
        guard !state.geometry.showingMonth, state.geometry.dayOverflows, !scrollStartedInOverflow,
              abs(scrollVerticalDistance) >= 12,
              abs(scrollVerticalDistance) > abs(scrollHorizontalDistance) * 1.4 else { return false }
        scrollGestureHandled = true
        setDayExpanded(scrollVerticalDistance > 0)
        return true
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
        if !modeChanged { renderCache.invalidate() }
        if motion != nil && !modeChanged {
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
        geometry.dayExpanded = state.dayExpanded
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
