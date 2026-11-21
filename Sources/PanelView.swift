import SwiftUI

// Select the property-wrapper type; the CLT SDK also exports an unavailable State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>

enum HeaderButton {
    case today, month
}

@MainActor
final class PanelState: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false
    @Published var geometry: NotchGeometry
    private(set) var presentationSize: CGSize
    private(set) var expansionProgress: CGFloat = 0
    private(set) var monthProgress: CGFloat
    @Published var headerHovered = false
    @Published var blockHovered = false
    @Published var pressedHeaderButton: HeaderButton?
    @Published var hoveredTaskID: String?

    var onOpenSettings: (() -> Void)?
    var onSelectDay: (() -> Void)?
    var onSelectMonth: (() -> Void)?
    var onTogglePinned: (() -> Void)?

    init(geometry: NotchGeometry, mode: String = "today") {
        self.geometry = geometry
        presentationSize = geometry.collapsedRect.size
        monthProgress = mode == "month" ? 1 : 0
    }

    func present(size: CGSize, expansion: CGFloat, month: CGFloat) {
        guard presentationSize != size || expansionProgress != expansion || monthProgress != month else { return }
        objectWillChange.send()
        presentationSize = size
        expansionProgress = expansion
        monthProgress = month
    }

    var cornerRadius: CGFloat {
        let collapsed: CGFloat = geometry.hasNotch ? 12 : 16
        return collapsed + (26 - collapsed) * expansionProgress
    }
}

struct NotchPanelView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var state: PanelState
    private var g: NotchGeometry { state.geometry }
    private var dayGeometry: NotchGeometry {
        var geometry = g
        geometry.showingMonth = false
        return geometry
    }
    private var monthGeometry: NotchGeometry {
        var geometry = g
        geometry.showingMonth = true
        return geometry
    }
    @Namespace private var taskMovement

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            expandedContent
                .frame(width: g.expandedWidth, height: state.presentationSize.height, alignment: .top)
                .opacity(state.expansionProgress)
                .allowsHitTesting(state.expanded)
                .accessibilityHidden(!state.expanded)

        }
        .frame(width: state.presentationSize.width, height: state.presentationSize.height, alignment: .top)
        .contextMenu { PanelMenu(store: store, state: state) }
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            if let notice = store.panelNotice {
                PanelMessageView(message: notice, width: g.expandedWidth, padding: g.horizontalPadding,
                                 compact: true, busy: store.isRefreshing || store.isMutating,
                                 l10n: store.l10n, action: perform)
                    .frame(height: g.noticeHeight - g.padding, alignment: .top)
                    .padding(.bottom, g.padding)
            }
            pages
        }
        .padding(.top, g.collapsedHeight + g.padding)
    }

    private func perform(_ action: PanelAction) {
        switch action {
        case .settings: state.onOpenSettings?()
        case .refresh: store.retryLoad()
        case .openList: store.openTrackedList()
        case .retryCompletion: Task { await store.retryCompletion() }
        case .retryUndo: Task { await store.retryUndo() }
        }
    }

    private var message: some View {
        PanelMessageView(message: store.panelMessage, width: g.expandedWidth, padding: g.horizontalPadding,
                         busy: store.isRefreshing, demo: store.isDemo, l10n: store.l10n, action: perform)
    }

    private var pages: some View {
        // Keep both view trees alive across hover and page changes.
        HStack(alignment: .top, spacing: 0) {
            dayPage
                .frame(width: g.expandedWidth, alignment: .top)
                .allowsHitTesting(!g.showingMonth && state.monthProgress < 0.01)
                .accessibilityHidden(g.showingMonth)
            Group {
                if store.hasStatistics {
                    MonthContent(store: store, geometry: monthGeometry)
                } else {
                    message
                }
            }
            .frame(width: g.expandedWidth, height: g.monthViewportHeight, alignment: .top)
            .allowsHitTesting(g.showingMonth && state.monthProgress > 0.99)
            .accessibilityHidden(!g.showingMonth)
        }
        .frame(width: g.expandedWidth * 2, alignment: .leading)
        .offset(x: -g.expandedWidth * state.monthProgress)
        .frame(width: g.expandedWidth, alignment: .leading)
        .clipped()
    }

    private var tasksContent: some View {
        TodayContent(store: store, geometry: dayGeometry,
                     panelExpanded: state.expanded,
                     hoveredTaskID: g.dayScrolls ? nil : state.hoveredTaskID,
                     taskMovement: taskMovement)
    }

    private var dayPage: some View {
        Group {
            if store.hasStatistics && !store.todayTasks.isEmpty {
                if g.dayScrolls {
                    ScrollView(.vertical) {
                        tasksContent.background(OverlayScrollbars())
                    }
                } else {
                    tasksContent
                }
            } else {
                message
            }
        }
        .frame(width: g.expandedWidth, height: g.dayViewportHeight, alignment: .top)
        .clipped()
    }

}

private struct OverlayScrollbars: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollbarStyleView { ScrollbarStyleView() }
    func updateNSView(_ view: ScrollbarStyleView, context: Context) { view.configure() }

    final class ScrollbarStyleView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configure()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }

        func configure() {
            guard let scroll = enclosingScrollView else { return }
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            scroll.autohidesScrollers = true
        }
    }
}

struct PanelHeaderView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var state: PanelState
    private var g: NotchGeometry { state.geometry }
    private var l10n: L10n { store.l10n }

    var body: some View {
        GeometryReader { proxy in
            statusBar(width: proxy.size.width)
                .frame(width: proxy.size.width, height: g.collapsedHeight)
                .contentShape(Rectangle())
        }
        .background(Color.black)
        .contextMenu { PanelMenu(store: store, state: state) }
    }

    private func statusBar(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if state.expanded {
                Button(action: { state.onSelectDay?() }) {
                    headerScore
                        .brightness(state.headerHovered ? 0.10 : 0)
                        .scaleEffect(state.pressedHeaderButton == .today ? 0.94 : 1, anchor: .leading)
                        .opacity(state.pressedHeaderButton == .today ? 0.78 : 1)
                        .animation(.easeOut(duration: 0.08), value: state.headerHovered)
                        .animation(.easeOut(duration: 0.08), value: state.pressedHeaderButton)
                        .padding(.leading, g.headerPadding)
                        .frame(width: g.headerButtonWidth(in: width), height: g.collapsedHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(l10n.showDayHelp)
                .accessibilityLabel(l10n.showDayAccessibility(done: store.todayStat.done, due: store.todayStat.due))
                Spacer(minLength: 0)
                Button(action: { state.onSelectMonth?() }) {
                    statusBlock
                        .brightness(state.blockHovered ? 0.10 : 0)
                        .scaleEffect(state.pressedHeaderButton == .month ? 0.94 : 1, anchor: .trailing)
                        .opacity(state.pressedHeaderButton == .month ? 0.78 : 1)
                        .animation(.easeOut(duration: 0.08), value: state.blockHovered)
                        .animation(.easeOut(duration: 0.08), value: state.pressedHeaderButton)
                        .padding(.trailing, g.headerPadding)
                        .frame(width: g.headerButtonWidth(in: width), height: g.collapsedHeight, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(l10n.showMonthHelp)
                .accessibilityLabel(l10n.showMonthHelp)
            } else {
                headerScore
                Spacer(minLength: 0)
                statusBlock
            }
        }
        .padding(.horizontal, state.expanded ? 0 : g.headerPadding)
    }

    @ViewBuilder
    private var headerScore: some View {
        if store.hasStatistics {
            scoreContents
        } else {
            Image(systemName: store.panelStatus.symbol)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                .help(store.panelStatus.title(with: l10n))
        }
    }

    private var scoreContents: some View {
        ScoreText(numerator: "\(store.todayStat.done)", denominator: "\(store.todayStat.due)", size: NotchGeometry.scoreFontSize, weight: .semibold)
            .scaleEffect(g.scoreScale, anchor: .leading)
            .frame(width: g.collapsedScoreWidth, height: 24, alignment: .leading)
            .clipped()
            .help(store.lastError == nil ? "\(store.todayStat.done)/\(store.todayStat.due)"
                  : l10n.staleScoreHelp(done: store.todayStat.done, due: store.todayStat.due))
    }

    private var statusBlock: some View {
        DayBlock(state: store.hasStatistics ? DayState(stat: store.todayStat) : .idle,
                 size: g.blockSize, radius: 3, celebrationToken: store.goldenMoment)
    }

}

private struct PanelMenu: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var state: PanelState
    private var l10n: L10n { store.l10n }

    var body: some View {
        Group {
            Button(l10n.menuSettings) { state.onOpenSettings?() }
            #if DEBUG || DEMO
            if store.isDemo {
                Toggle(l10n.menuKeepExpand, isOn: Binding(
                    get: { state.pinned },
                    set: { pinned in
                        if pinned != state.pinned { state.onTogglePinned?() }
                    }
                ))
            }
            #endif
            if store.selectedCalendars.count > 1 {
                Menu(l10n.menuOpenTrackedList) {
                    ForEach(store.selectedCalendars, id: \.calendarIdentifier) { list in
                        Button(list.title) { store.openTrackedList(list.calendarIdentifier) }
                    }
                }
                .disabled(store.isDemo)
            } else {
                Button(l10n.menuOpenTrackedList) { store.openTrackedList() }
                    .disabled(store.isDemo || !store.canOpenTrackedList)
            }
            Button(l10n.menuQuit) { NSApp.terminate(nil) }

        }
    }
}

struct TodayContent: View {
    @ObservedObject var store: TaskStore
    let geometry: NotchGeometry
    var panelExpanded = true
    var hoveredTaskID: String? = nil
    let taskMovement: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let l10n = store.l10n
        let undoTaskID = store.hasStatistics ? store.presentationUndo?.taskID : nil
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.presentationTasks.map { PresentedRow(id: store.rowAnimationID(for: $0), task: $0) }) { row in
                let task = row.task
                let taskRow = TaskRow(
                    task: task,
                    overdue: task.isOverdue(on: store.today),
                    rowHeight: geometry.taskHeight(task, untitledFallback: l10n.untitledReminder),
                    horizontalPadding: geometry.horizontalPadding,
                    locked: store.isMutating || !store.canCompleteTasks,
                    saving: store.savingTaskID == task.id,
                    sampledHover: hoveredTaskID == task.id,
                    showsUndo: task.isCompleted && undoTaskID == task.id,
                    panelExpanded: panelExpanded,
                    l10n: l10n,
                    onUndoHover: { store.setUndoHoverPaused($0) },
                    onUndo: { Task { await store.undoLastCompletion() } }
                ) {
                    Task { await store.completeTask(task.id) }
                }
                taskRow.matchedGeometryEffect(id: row.id, in: taskMovement)
                .opacity(store.movingTaskID == task.id ? 0 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: store.movingTaskID == nil
                    ? CompletionTiming.fadeIn : TimeInterval(CompletionTiming.fadeOut) / 1_000_000_000), value: store.movingTaskID)
                .transition(.identity)
            }
            if !store.todayTasks.isEmpty, let summary = store.presentationSummary {
                Text(summary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.gold.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 16)
                    .padding(.top, NotchGeometry.messageGap)
                    .padding(.leading, geometry.taskTextInset)
                    .padding(.trailing, geometry.horizontalPadding)
            }
        }
        .frame(width: geometry.expandedWidth, height: geometry.todayContentHeight, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: CompletionTiming.movement), value: store.presentationTasks)
    }
}

private struct PresentedRow: Identifiable {
    let id: String
    let task: TrackedTask
}

private struct TaskRow: View {
    let task: TrackedTask
    let overdue: Bool
    let rowHeight: CGFloat
    let horizontalPadding: CGFloat
    let locked: Bool
    let saving: Bool
    let sampledHover: Bool
    let showsUndo: Bool
    let panelExpanded: Bool
    let l10n: L10n
    let onUndoHover: (Bool) -> Void
    let onUndo: () -> Void
    let onComplete: () -> Void
    @ViewState private var hovered = false
    @ViewState private var undoRowHovered = false
    @ViewState private var showsSpinner = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var undoInteractive: Bool { panelExpanded && task.isCompleted && showsUndo && !locked }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onComplete) {
                contents.contentShape(Rectangle())
            }
            .buttonStyle(TaskRowStyle())
            .disabled(locked || task.isCompleted)
            .accessibilityRepresentation {
                if task.isCompleted {
                    Text(verbatim: l10n.taskCompletedAccessibility(task.title))
                } else {
                    Button(action: onComplete) {
                        Text(verbatim: l10n.taskPendingAccessibility(task.title, saving: saving, overdue: overdue))
                    }
                    .disabled(locked)
                    .accessibilityHint(l10n.taskActionHint(locked: locked))
                }
            }
            if task.isCompleted {
                InlineUndoButton(
                    title: task.title.isEmpty ? l10n.untitledReminder : task.title,
                    shows: showsUndo,
                    locked: locked,
                    highlighted: undoRowHovered,
                    horizontalPadding: horizontalPadding,
                    l10n: l10n,
                    onUndo: onUndo
                )
            }
        }
        .background(Color.white.opacity(saving ? 0.07 : (hovered || sampledHover) && !locked && !task.isCompleted ? 0.10 : 0))
        .background {
            if task.isCompleted {
                ActiveHoverMonitor(active: undoInteractive) { hovering in
                    if undoRowHovered != hovering { undoRowHovered = hovering }
                    onUndoHover(hovering)
                }
            }
        }
        .onHover { hovered = $0 }
        .onChange(of: undoInteractive) { _, interactive in
            if !interactive && undoRowHovered { undoRowHovered = false }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: saving)
        .task(id: saving) {
            showsSpinner = false
            guard saving else { return }
            do {
                try await Task.sleep(nanoseconds: CompletionTiming.spinnerDelay)
                guard !Task.isCancelled else { return }
                showsSpinner = true
            } catch { }
        }
    }

    private var contents: some View {
        HStack(alignment: .top, spacing: NotchGeometry.taskMarkerGap) {
            Group {
                if saving && showsSpinner {
                    ProgressView().controlSize(.mini).scaleEffect(0.65)
                } else if task.isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                } else {
                    Circle()
                        .fill(overdue ? Theme.overdue : Theme.secondary)
                        .frame(width: 4, height: 4)
                }
            }
            .frame(width: NotchGeometry.taskMarkerWidth, height: 16, alignment: .center)
            Text(task.title.isEmpty ? l10n.untitledReminder : task.title)
                .font(.system(size: NotchGeometry.taskFontSize))
                .foregroundStyle(task.isCompleted ? Theme.secondary : Theme.primary)
                .strikethrough(task.isCompleted, color: Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: NotchGeometry.taskRowHeight, alignment: .leading)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, NotchGeometry.taskRowPadding)
        .frame(height: rowHeight, alignment: .topLeading)
    }
}

private struct TaskRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // Lock input during movement without dimming every other task in the list.
        configuration.label.opacity(configuration.isPressed ? 0.85 : 1)
    }
}

private struct UndoIconShape: Shape {
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let scaleX = inset.width / 16
        let scaleY = inset.height / 16
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: inset.minX + (x - 4) * scaleX, y: inset.minY + (y - 4) * scaleY)
        }
        var path = Path()
        // Arrowhead: M9 14 L4 9 L9 4
        path.move(to: pt(9, 14))
        path.addLine(to: pt(4, 9))
        path.addLine(to: pt(9, 4))
        // Curved U-turn: M4 9 H14.5 A5.5 5.5 0 0 1 14.5 20 H11
        path.move(to: pt(4, 9))
        path.addLine(to: pt(14.5, 9))
        path.addArc(
            center: pt(14.5, 14.5),
            radius: 5.5 * min(scaleX, scaleY),
            startAngle: .degrees(-90),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: pt(11, 20))
        return path
    }
}

private struct UndoIconButtonStyle: ButtonStyle {
    let trailingPadding: CGFloat
    let hitWidth: CGFloat
    let hitHeight: CGFloat
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .opacity(configuration.isPressed ? 0.78 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
        }
        .padding(.trailing, trailingPadding)
        .frame(width: hitWidth, height: hitHeight)
        .contentShape(Rectangle())
    }
}

private struct InlineUndoButton: View {
    let title: String
    let shows: Bool
    let locked: Bool
    let highlighted: Bool
    let horizontalPadding: CGFloat
    let l10n: L10n
    let onUndo: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isInteractive: Bool { shows && !locked }
    private var hitWidth: CGFloat { horizontalPadding + 23 }
    private var hitHeight: CGFloat { NotchGeometry.taskRowHeight + 2 * NotchGeometry.taskRowPadding }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 14, height: hitHeight)
                Color.black
                    .frame(width: horizontalPadding + 17, height: hitHeight)
            }
            .allowsHitTesting(false)

            Button(action: onUndo) {
                UndoIconShape(lineWidth: 1.5)
                    .stroke(
                        isInteractive && highlighted ? Color.white.opacity(0.92) : Color.white.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: 13, height: 13)
            }
            .buttonStyle(UndoIconButtonStyle(
                trailingPadding: horizontalPadding,
                hitWidth: hitWidth,
                hitHeight: hitHeight,
                reduceMotion: reduceMotion
            ))
            .disabled(!isInteractive)
            .accessibilityLabel(l10n.undoAccessibilityLabel(title))
        }
        .opacity(shows ? 1 : 0)
        .allowsHitTesting(isInteractive)
        .accessibilityHidden(!shows)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: highlighted)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: shows)
    }
}

private struct ActiveHoverMonitor: NSViewRepresentable {
    let active: Bool
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingView {
        let view = HoverTrackingView()
        view.onHover = onHover
        view.isActive = active
        return view
    }

    func updateNSView(_ view: HoverTrackingView, context: Context) {
        view.onHover = onHover
        if view.isActive != active {
            view.isActive = active
        }
        view.refreshHoverState()
    }

    final class HoverTrackingView: NSView {
        var onHover: ((Bool) -> Void)?
        var isActive = false {
            didSet {
                if !isActive { setHovered(false) }
            }
        }
        private var trackingArea: NSTrackingArea?
        private var isHovered = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            clipsToBounds = true
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            clipsToBounds = true
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
            super.updateTrackingAreas()
            refreshHoverState()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refreshHoverState()
        }

        override func viewDidHide() {
            super.viewDidHide()
            setHovered(false)
        }

        override func mouseEntered(with event: NSEvent) {
            refreshHoverState()
        }

        override func mouseExited(with event: NSEvent) {
            setHovered(false)
        }

        override func mouseMoved(with event: NSEvent) {
            refreshHoverState()
        }

        func refreshHoverState() {
            guard isActive, let window, window.isVisible, !isHiddenOrHasHiddenAncestor else {
                setHovered(false)
                return
            }
            let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            let visible = bounds.intersection(visibleRect)
            let inside = !visible.isEmpty && visible.contains(local)
            setHovered(inside)
        }

        private func setHovered(_ hovering: Bool) {
            guard hovering != isHovered else { return }
            isHovered = hovering
            let callback = onHover
            Task { @MainActor in callback?(hovering) }
        }
    }
}

struct MonthContent: View {
    @ObservedObject var store: TaskStore
    let geometry: NotchGeometry

    var body: some View {
        let l10n = store.l10n
        let yearNumber = store.calendar.component(.year, from: store.today)
        VStack(spacing: 0) {
            monthHeading(year: yearNumber)
                .help(l10n.goldenDaysHelp(store.monthFullDays))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: l10n.monthYearAccessibleLabel(
                    monthTitle: store.monthTitle, year: yearNumber, goldenDays: store.monthFullDays)))
                .lineLimit(1)
                .frame(width: geometry.gridWidth, height: geometry.monthHeadingHeight, alignment: .leading)
            Color.clear.frame(height: geometry.monthHeadingGap)
            HStack(spacing: geometry.cellGap) {
                ForEach(Array(l10n.weekdaySymbols.enumerated()), id: \.offset) { _, day in
                    Text(day).font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: geometry.cell)
                }
            }
            .frame(height: geometry.monthWeekdayHeight, alignment: .top)
            .accessibilityHidden(true)
            VStack(spacing: geometry.cellGap) {
                ForEach(Array(store.monthRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: geometry.cellGap) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, day in
                            if let day, let date = store.date(inMonth: day) {
                                let stat = store.stat(for: date)
                                let label = store.monthDetail(for: date)
                                DayBlock(state: DayState(stat: stat, isFuture: date > store.today),
                                         size: geometry.cell, radius: 4, celebratesGold: true,
                                         isToday: date == store.today,
                                         celebrationToken: date == store.today ? store.goldenMoment : 0)
                                    .help(label)
                                    .accessibilityLabel(label)
                            } else {
                                Color.clear.frame(width: geometry.cell, height: geometry.cell)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: geometry.gridWidth, height: geometry.monthContentHeight, alignment: .top)
    }

    private func monthHeading(year: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(store.monthTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primary)
            Text(verbatim: String(year))
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Theme.secondary)
                .monospacedDigit()
        }
    }
}

/// Every non-ready state gets an explanation and one clear recovery action.
struct PanelMessageView: View {
    let message: PanelMessage
    let width: CGFloat
    let padding: CGFloat
    var compact = false
    var busy = false
    var demo = false
    var l10n = L10n(language: .english)
    let action: (PanelAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(message.title)
                .font(.system(size: compact ? 12 : 13, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, padding)
            Text(message.detail)
                .font(.system(size: compact ? 11 : 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, padding)
                .padding(.top, 5)
            if let target = message.action, let title = message.actionTitle {
                FeedbackButton(title: title, busy: busy || (demo && target == .openList)) { action(target) }
                    .help(demo && target == .openList ? l10n.demoOpenListDisabledHelp : title)
                    .padding(.top, 8)
            }
        }
        .frame(width: width, alignment: .topLeading)
    }
}

private struct FeedbackButton: View {
    let title: String
    let busy: Bool
    let action: () -> Void
    @ViewState private var hovered = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.primary.opacity(busy ? 0.5 : 1))
                .frame(maxWidth: .infinity).frame(height: 28)
                .background(Color.white.opacity(hovered && !busy ? 0.12 : 0.045))
                .contentShape(Rectangle())
        }
        .buttonStyle(TaskRowStyle())
        .disabled(busy)
        .onHover { hovered = $0 }
    }
}
