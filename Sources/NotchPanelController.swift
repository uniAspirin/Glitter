import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PanelSurfaceView: NSView {
    var onPointerChanged: (() -> Void)?
    var blocksContentInput = false
    weak var interactiveHeader: NSView?
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
        let local = convert(point, from: superview)
        guard containsVisiblePoint(local) else { return nil }
        if let header = interactiveHeader, let hit = header.hitTest(local) { return hit }
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
    let store: TaskStore

    var onDataChanged: (() -> Void)?

    @Published private(set) var selectedDisplayID: CGDirectDisplayID?
    @Published private(set) var displays: [DisplayMetrics]
    @Published private(set) var showsMenuBarIcon: Bool
    private let mainDisplayID: () -> CGDirectDisplayID?

    #if DEBUG || DEMO
    var demoPreviewWork: DispatchWorkItem?
    #endif

    var hoverTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    var collapseWork: DispatchWorkItem?
    // 依次表示 (中心 X, 顶边)、(宽, 高)、(展开进度, 月视图进度)。
    typealias MotionPair = AnimatablePair<Double, Double>
    typealias MotionVector = AnimatablePair<MotionPair, AnimatablePair<MotionPair, MotionPair>>
    struct Motion {
        let start: MotionVector
        let target: MotionVector
        let velocity: MotionVector
        var started: CFTimeInterval
        let duration: TimeInterval
        let containerDuration: TimeInterval
        let pageDuration: TimeInterval
        let spring: Spring?
    }
    private static let pageDuration: TimeInterval = 0.16
    private static let collapseDelay: TimeInterval = 0.30
    private let displayLinkTarget = AnimationDisplayLinkTarget()
    var animationDisplayLink: CADisplayLink?
    var motion: Motion?
    private var animationElapsed: TimeInterval = 0
    var presentedVector: MotionVector?
    let surfaceView = PanelSurfaceView()
    let renderCache = PanelRenderCache()
    var snapshotLayer: PanelSnapshotLayer!
    var headerHosting: NSHostingView<PanelHeaderView>!
    private var snapshotWork: DispatchWorkItem?
    private var pendingDataChange = false
    private var pointerGlobalMonitor: Any?
    private var dragMonitor: Any?
    var headerPressOrigin: NSPoint?
    private var previousHeaderButton: HeaderButton?
    private var previousHeaderPoint: NSPoint?
    private var headerFeedbackTask: Task<Void, Never>?
    private let defaults: UserDefaults

    var isDragging = false
    var lastDragEndedAt = Date.distantPast
    private var dragStartMouseX: CGFloat = 0
    private var dragStartOffset: CGFloat = 0

    init(store: TaskStore, defaults: UserDefaults = .standard,
         displays: [DisplayMetrics]? = nil,
         mainDisplayID: @escaping () -> CGDirectDisplayID? = { NSScreen.main?.displayID }) {
        self.store = store
        self.defaults = defaults
        self.mainDisplayID = mainDisplayID
        showsMenuBarIcon = defaults.object(forKey: Keys.menuBarIcon) as? Bool ?? true
        let availableDisplays = displays ?? NSScreen.screens.compactMap(DisplayMetrics.init(screen:))
        self.displays = availableDisplays
        let savedDisplayID = defaults.object(forKey: Keys.display) == nil
            ? nil : CGDirectDisplayID(defaults.integer(forKey: Keys.display))
        selectedDisplayID = savedDisplayID
        let savedOffset = CGFloat(defaults.double(forKey: Keys.offset))

        let display = Self.display(for: savedDisplayID, displays: availableDisplays, mainDisplayID: mainDisplayID())
        let stat = store.todayStat
        var geometry = NotchGeometry.make(for: display, rows: store.expandedRows, offset: savedOffset,
                                          scoreText: "\(stat.done)/\(stat.due)",
                                          showingMonth: store.expandedMode == "month",
                                          referenceNotchWidth: NotchGeometry.referenceNotchWidth(in: availableDisplays))
        if display == nil {
            geometry.horizontalOffset = savedOffset
        }
        geometry.showsCalendar = store.hasStatistics
        geometry.noticeHeight = store.panelNotice.map { $0.height(width: geometry.contentWidth, compact: true) + geometry.padding } ?? 0
        if store.hasStatistics && !store.todayTasks.isEmpty {
            geometry.measureToday(tasks: store.presentationTasks, error: nil, summary: store.presentationSummary,
                                  untitledFallback: store.l10n.untitledReminder)
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
        surfaceView.interactiveHeader = headerHosting
        headerHosting.sizingOptions = []
        surfaceView.applyVisibleFrame(surfaceView.bounds, corner: state.cornerRadius)
        layoutHeader(frame: surfaceView.bounds)
        renderCache.prepare(store: store, state: state)
        surfaceView.onPointerChanged = { [weak self] in self?.pollCursor() }

        displayLinkTarget.onFrame = { [weak self] link in
            guard let self, self.animationDisplayLink === link else { return }
            self.advanceAnimation(at: link.targetTimestamp)
        }
        #if DEBUG || DEMO
        if store.isDemo {
            state.onTogglePinned = { [weak self] in self?.togglePinned() }
        }
        #endif
        state.onSelectDay = { [weak self] in self?.selectMode("today") }
        state.onSelectMonth = { [weak self] in self?.selectMode("month") }
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let inPanel = event.window === self.panel
                let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
                self.trackHeaderPointer(type: event.type, point: point, inPanel: inPanel)
            }
            // Let the native button receive its complete press/release sequence.
            return event
        }

        store.onUpdate = { [weak self] in self?.dataChanged() }
        observeScreens()
    }

    deinit {
        animationDisplayLink?.invalidate()
        hoverTimer?.invalidate()
        collapseWork?.cancel()
        snapshotWork?.cancel()
        #if DEBUG || DEMO
        demoPreviewWork?.cancel()
        #endif
        if let pointerGlobalMonitor { NSEvent.removeMonitor(pointerGlobalMonitor) }
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        if let observer = screenObserver { NotificationCenter.default.removeObserver(observer) }
    }

    func show() {
        guard currentDisplay != nil else { return }
        panel.orderFrontRegardless()
    }

    // MARK: - 展开 / 收起

    func expand() {
        guard !state.expanded else { return }
        cancelScheduledCollapse()
        store.setExpandedMode("today")
        state.expanded = true
        updateHoverWatch()
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
        updateHoverWatch()
        updateWindowFrame(expanded: false, animated: true)
    }

    func updateWindowFrame(expanded: Bool, animated: Bool = false) {
        let target = Self.vector(rect: state.geometry.rect(expanded: expanded),
                                 expansion: expanded ? 1 : 0, month: store.expandedMode == "month" ? 1 : 0)
        if animated, animationDisplayLink != nil, motion?.target == target { return }

        resetHeaderHover()
        let start = presentedVector ?? Self.vector(rect: panel.frame, expansion: state.expansionProgress, month: state.monthProgress)
        let velocity = motion.map { Self.motionVelocity($0, elapsed: animationElapsed) } ?? .zero
        // Preserve the visible scroll position when the Day page leaves the screen.
        let sourceDay = !snapshotLayer.isVisible && state.geometry.dayScrolls
            && start.second.second.first > 0.999 && start.second.second.second < 0.001
            ? snapshotLayer.captureLive(headerHeight: state.geometry.collapsedHeight) : nil
        stopAnimation(flushUpdates: false)
        guard animated, let display = currentDisplay, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              start != target else {
            present(vector: target)
            finishPresentation()
            return
        }

        let changesExpansion = start.second.second.first != target.second.second.first
        let spring = changesExpansion ? Spring(response: expanded ? 0.36 : 0.26,
                                                dampingRatio: expanded ? 0.76 : 0.96) : nil
        let baseDuration = Self.pageDuration
        let initialVelocity = spring == nil
            ? Self.boundedVelocity(velocity, displacement: target - start, duration: baseDuration) : velocity
        var containerTarget = target - start
        containerTarget.second.second.second = 0
        var containerVelocity = initialVelocity
        containerVelocity.second.second.second = 0
        let containerDuration = spring.map {
            max($0.response * 1.5, $0.settlingDuration(target: containerTarget, initialVelocity: containerVelocity, epsilon: 1))
        } ?? baseDuration
        let pageDuration = start.second.second.second == target.second.second.second ? 0 : Self.pageDuration
        var boundedInitialVelocity = initialVelocity
        boundedInitialVelocity.second.second.second = Self.boundedVelocity(velocity, displacement: target - start,
                                                                          duration: baseDuration).second.second.second
        let duration = max(containerDuration, pageDuration)
        var nextMotion = Motion(start: start, target: target, velocity: boundedInitialVelocity,
                                started: 0, duration: duration, containerDuration: containerDuration,
                                pageDuration: pageDuration, spring: spring)
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
            let animationBounds = animationBounds(for: nextMotion)
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
        nextMotion.started = CACurrentMediaTime()
        motion = nextMotion
        if pointerGlobalMonitor == nil && snapshotLayer.isVisible {
            pointerGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollCursor() }
            }
        }
        // 窗口的 displayLink 会自动跟随显示器变化，回调只在动画期间启用。
        let link = animationDisplayLink ?? panel.displayLink(target: displayLinkTarget, selector: #selector(AnimationDisplayLinkTarget.tick(_:)))
        let screenRate = display.maximumFramesPerSecond
        let maximum = Float(screenRate > 0 ? screenRate : 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: maximum, maximum: maximum, preferred: maximum)
        if animationDisplayLink == nil {
            animationDisplayLink = link
            link.add(to: .main, forMode: .common)
        }
        link.isPaused = false
    }

    func advanceAnimation(at timestamp: CFTimeInterval) {
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
        present(vector: Self.motionValue(motion, elapsed: elapsed))
    }

    private static func motionValue(_ motion: Motion, elapsed: TimeInterval) -> MotionVector {
        var value = motion.target
        if elapsed < motion.containerDuration {
            if let spring = motion.spring {
                value = motion.start + spring.value(target: motion.target - motion.start,
                                                     initialVelocity: motion.velocity, time: elapsed)
            } else {
                let t = min(1, max(0, elapsed / motion.containerDuration))
                var displacement = motion.target - motion.start
                displacement.scale(by: t * t * (3 - 2 * t))
                var velocity = motion.velocity
                velocity.scale(by: motion.containerDuration * t * (1 - t) * (1 - t))
                value = motion.start + displacement + velocity
            }
        }
        // Page translation has its own timing, even when clicked during the opening spring.
        let t = motion.pageDuration > 0 ? min(1, max(0, elapsed / motion.pageDuration)) : 1
        let start = motion.start.second.second.second
        let distance = motion.target.second.second.second - start
        value.second.second.second = start + distance * t * t * (3 - 2 * t)
            + motion.velocity.second.second.second * motion.pageDuration * t * (1 - t) * (1 - t)
        return value
    }

    /// Cubic Hermite easing preserves velocity on reversal and reaches its exact endpoint.
    private static func motionVelocity(_ motion: Motion, elapsed: TimeInterval) -> MotionVector {
        var result = MotionVector.zero
        if elapsed < motion.containerDuration {
            if let spring = motion.spring {
                result = spring.velocity(target: motion.target - motion.start,
                                         initialVelocity: motion.velocity, time: elapsed)
            } else {
                let t = min(1, max(0, elapsed / motion.containerDuration))
                var displacement = motion.target - motion.start
                displacement.scale(by: 6 * t * (1 - t) / motion.containerDuration)
                var velocity = motion.velocity
                velocity.scale(by: (1 - t) * (1 - 3 * t))
                result = displacement + velocity
            }
        }
        let t = motion.pageDuration > 0 ? min(1, max(0, elapsed / motion.pageDuration)) : 1
        let distance = motion.target.second.second.second - motion.start.second.second.second
        result.second.second.second = motion.pageDuration > 0
            ? distance * 6 * t * (1 - t) / motion.pageDuration
                + motion.velocity.second.second.second * (1 - t) * (1 - 3 * t) : 0
        return result
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

    func stopAnimation(flushUpdates: Bool = true) {
        animationDisplayLink?.isPaused = true
        motion = nil
        animationElapsed = 0
        if flushUpdates { finishPresentation() }
    }

    private func finishPresentation() {
        resetHeaderHover()
        snapshotLayer?.hide(size: panel.frame.size)
        surfaceView.blocksContentInput = false
        surfaceView.visibleContentRect = nil
        if let pointerGlobalMonitor { NSEvent.removeMonitor(pointerGlobalMonitor); self.pointerGlobalMonitor = nil }
        panel.ignoresMouseEvents = false
        updateHoverWatch()
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

    private func animationBounds(for motion: Motion) -> NSRect {
        var bounds = presentationRect(motion.start).union(presentationRect(motion.target))
        guard motion.spring != nil else { return bounds }
        // Reserve the spring's full path once, including overshoot, without resizing each frame.
        for step in 1...60 {
            bounds = bounds.union(presentationRect(Self.motionValue(motion, elapsed: motion.duration * Double(step) / 60)))
        }
        return NSRect(x: floor(bounds.minX), y: floor(bounds.minY),
                      width: ceil(bounds.maxX) - floor(bounds.minX),
                      height: ceil(bounds.maxY) - floor(bounds.minY))
    }

    private static func vector(rect: NSRect, expansion: CGFloat, month: CGFloat) -> MotionVector {
        MotionVector(MotionPair(Double(rect.midX), Double(rect.maxY)),
                     AnimatablePair(MotionPair(Double(rect.width), Double(rect.height)),
                                    MotionPair(Double(expansion), Double(month))))
    }

    func presentationRect(_ vector: MotionVector) -> NSRect {
        let position = vector.first
        let size = vector.second.first
        let width = max(1, size.first)
        let height = max(Double(state.geometry.collapsedHeight), size.second)
        return NSRect(x: position.first - width / 2, y: position.second - height, width: width, height: height)
    }

    var interactionFrame: NSRect {
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

    #if DEBUG || DEMO
    func togglePinned() {
        guard store.isDemo else { return }
        state.pinned.toggle()
        updateHoverWatch()
        if state.pinned {
            expand()
        } else {
            pollCursor()
        }
        onDataChanged?()
    }
    #endif

    func setMenuBarIconVisible(_ visible: Bool) {
        guard visible != showsMenuBarIcon else { return }
        showsMenuBarIcon = visible
        defaults.set(visible as Any, forKey: Keys.menuBarIcon)
        onDataChanged?()
    }

    #if DEBUG || DEMO
    func forceExpandedForDebug() {
        guard store.isDemo else { return }
        state.pinned = true
        updateHoverWatch()
        expand()
    }

    // MARK: - Local animation demo

    func previewPageTransition() {
        guard store.isDemo else { return }
        demoPreviewWork?.cancel()
        state.pinned = true
        updateHoverWatch()
        if !state.expanded {
            expand()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.demoPreviewWork = nil
                self.selectMode("month")
            }
            demoPreviewWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (motion?.duration ?? 0) + 0.08, execute: work)
            return
        }
        selectMode(store.expandedMode == "today" ? "month" : "today")
    }

    func previewNotchTransition() {
        guard store.isDemo else { return }
        demoPreviewWork?.cancel()
        state.pinned = false
        collapse()
        let delay = (motion?.duration ?? 0) + 0.12
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.demoPreviewWork = nil
            self.state.pinned = true
            self.updateHoverWatch()
            self.expand()
        }
        demoPreviewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    #endif

    // MARK: - 显示器

    var currentDisplay: DisplayMetrics? {
        Self.display(for: selectedDisplayID, displays: displays, mainDisplayID: mainDisplayID())
    }

    func selectDisplay(_ id: CGDirectDisplayID) {
        guard displays.contains(where: { $0.id == id }) else { return }
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

    var acceptsClick: Bool {
        !isDragging && Date().timeIntervalSince(lastDragEndedAt) > 0.15
    }

    private func selectMode(_ mode: String) {
        guard state.expanded, acceptsClick else { return }
        cancelScheduledCollapse()
        headerFeedbackTask?.cancel()
        state.pressedHeaderButton = mode == "month" ? .month : .today
        headerFeedbackTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            self?.state.pressedHeaderButton = nil
        }
        store.setExpandedMode(mode)
    }

    func trackHeaderPointer(type: NSEvent.EventType, point: NSPoint, inPanel: Bool) {
        switch type {
        case .leftMouseDown:
            headerPressOrigin = nil
            guard inPanel, state.expanded else { return }
            let header = NSRect(x: interactionFrame.minX, y: interactionFrame.maxY - state.geometry.collapsedHeight,
                                width: interactionFrame.width, height: state.geometry.collapsedHeight)
            if header.contains(point) { headerPressOrigin = point }
        case .leftMouseDragged:
            guard let origin = headerPressOrigin else { return }
            guard isDragging || hypot(point.x - origin.x, point.y - origin.y) >= 3 else { return }
            dragChanged(at: point, origin: origin)
        case .leftMouseUp:
            headerPressOrigin = nil
            dragEnded()
        default:
            break
        }
    }

    private func dragChanged(at point: NSPoint, origin: NSPoint) {
        guard state.expanded else { return }
        if !isDragging {
            resetHeaderHover()
            headerFeedbackTask?.cancel()
            state.pressedHeaderButton = nil
            isDragging = true
            dragStartMouseX = origin.x
            dragStartOffset = state.geometry.horizontalOffset
            cancelScheduledCollapse()
        }

        let delta = point.x - dragStartMouseX
        let offset = state.geometry.clampedOffset(dragStartOffset + delta)

        guard offset != state.geometry.horizontalOffset else { return }
        state.geometry.horizontalOffset = offset
        updateWindowFrame(expanded: state.expanded)
    }

    private func dragEnded() {
        headerPressOrigin = nil
        guard isDragging else { return }
        lastDragEndedAt = Date()
        isDragging = false
        state.geometry.horizontalOffset = state.geometry.settledOffset(state.geometry.horizontalOffset)
        updateWindowFrame(expanded: state.expanded)
        defaults.set(Double(state.geometry.horizontalOffset), forKey: Keys.offset)
    }

    // MARK: - 悬停

    private func updateHoverWatch() {
        if state.expanded && !state.pinned {
            guard hoverTimer == nil else { return }
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pollCursor() }
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            hoverTimer = timer
        } else {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }

    private func headerButton(at point: NSPoint) -> HeaderButton? {
        // Match the live header's presented width, including compact pill transitions.
        let g = state.geometry
        if g.headerInteractionRect(in: interactionFrame).contains(point) { return .today }
        if g.blockInteractionRect(in: interactionFrame).contains(point) { return .month }
        return nil
    }

    func resetHeaderHover(at point: NSPoint = NSEvent.mouseLocation) {
        if state.headerHovered { state.headerHovered = false }
        if state.blockHovered { state.blockHovered = false }
        previousHeaderPoint = point
        previousHeaderButton = headerButton(at: point)
    }

    private func updateHeaderHover(at point: NSPoint) {
        guard state.expanded, motion == nil, acceptsClick else {
            resetHeaderHover(at: point)
            return
        }
        let button = headerButton(at: point)
        // Timer ticks and moving window edges are not deliberate pointer entry.
        if point != previousHeaderPoint, button != previousHeaderButton {
            state.headerHovered = button == .today
            state.blockHovered = button == .month
        }
        previousHeaderPoint = point
        previousHeaderButton = button
    }

    func pollCursor(at point: NSPoint = NSEvent.mouseLocation) {
        guard !isDragging else {
            state.headerHovered = false
            state.blockHovered = false
            state.hoveredTaskID = nil
            return
        }
        let g = state.geometry
        let visibleFrame = interactionFrame
        updateHeaderHover(at: point)
        if motion != nil {
            panel.ignoresMouseEvents = !visibleFrame.contains(point)
            if state.expanded && !state.pinned {
                if visibleFrame.insetBy(dx: -2, dy: -2).contains(point) { cancelScheduledCollapse() }
                else { scheduleCollapse() }
            } else if !state.expanded && visibleFrame.contains(point) { expand() }
            return
        }
        let taskHovered = state.expanded && store.canCompleteTasks && !store.isMutating
            ? g.taskInteractionRects(tasks: store.presentationTasks, in: visibleFrame,
                                     untitledFallback: store.l10n.untitledReminder).first(where: { $0.rect.contains(point) })?.id : nil
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
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDelay, execute: work)
    }

    func cancelScheduledCollapse() {
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
            Task { @MainActor in
                self?.screensChanged(NSScreen.screens.compactMap(DisplayMetrics.init(screen:)))
            }
        }
    }

    func screensChanged(_ availableDisplays: [DisplayMetrics]) {
        dragEnded()
        displays = availableDisplays
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

    func refreshGeometry(animated: Bool = false) {
        let rows = store.expandedRows
        guard let display = currentDisplay else {
            stopAnimation()
            hoverTimer?.invalidate()
            hoverTimer = nil
            panel.orderOut(nil)
            return
        }
        let offset = state.geometry.horizontalOffset
        let stat = store.todayStat
        var geometry = NotchGeometry.make(for: display, rows: rows, offset: offset,
                                          scoreText: "\(stat.done)/\(stat.due)",
                                          showingMonth: store.expandedMode == "month",
                                          referenceNotchWidth: NotchGeometry.referenceNotchWidth(in: displays) ?? state.geometry.notchWidth)
        geometry.showsCalendar = store.hasStatistics
        geometry.noticeHeight = store.panelNotice.map { $0.height(width: geometry.contentWidth, compact: true) + geometry.padding } ?? 0
        if store.hasStatistics && !store.todayTasks.isEmpty {
            geometry.measureToday(tasks: store.presentationTasks, error: nil, summary: store.presentationSummary,
                                  untitledFallback: store.l10n.untitledReminder)
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

    private static func display(for id: CGDirectDisplayID?, displays: [DisplayMetrics],
                                mainDisplayID: CGDirectDisplayID?) -> DisplayMetrics? {
        if let id, let match = displays.first(where: { $0.id == id }) {
            return match
        }
        if let notched = displays.first(where: \.hasNotch) {
            return notched
        }
        return displays.first(where: { $0.id == mainDisplayID }) ?? displays.first
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
        let mainHeight = displays.first?.frame.height ?? NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: mainHeight - point.y))
    }
}
