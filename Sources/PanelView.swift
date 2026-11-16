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
                                 compact: true, busy: store.isRefreshing || store.isMutating, action: perform)
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
        }
    }

    private var message: some View {
        PanelMessageView(message: store.panelMessage, width: g.expandedWidth, padding: g.horizontalPadding,
                         busy: store.isRefreshing, demo: store.isDemo, action: perform)
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
                .help("Show Day")
                .accessibilityLabel("Show Day, today \(store.todayStat.done) of \(store.todayStat.due) completed")
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
                .help("Show Month")
                .accessibilityLabel("Show Month")
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
                .help(store.panelStatus.title)
        }
    }

    private var scoreContents: some View {
        ScoreText(numerator: "\(store.todayStat.done)", denominator: "\(store.todayStat.due)", size: NotchGeometry.scoreFontSize, weight: .semibold)
            .scaleEffect(g.scoreScale, anchor: .leading)
            .frame(width: g.collapsedScoreWidth, height: 24, alignment: .leading)
            .clipped()
            .help(store.lastError == nil ? "\(store.todayStat.done)/\(store.todayStat.due)"
                  : "Last update: \(store.todayStat.done)/\(store.todayStat.due). Refresh to continue.")
    }

    private var statusBlock: some View {
        DayBlock(state: store.hasStatistics ? DayState(stat: store.todayStat) : .idle,
                 size: g.blockSize, radius: 3, celebrationToken: store.goldenMoment)
    }

}

private struct PanelMenu: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var state: PanelState
    var body: some View {
        Group {
            Button("Settings") { state.onOpenSettings?() }
            if store.isDemo {
                Toggle("Keep Expand", isOn: Binding(
                    get: { state.pinned },
                    set: { pinned in
                        if pinned != state.pinned { state.onTogglePinned?() }
                    }
                ))
            }
            if store.selectedCalendars.count > 1 {
                Menu("Open Tracked List") {
                    ForEach(store.selectedCalendars, id: \.calendarIdentifier) { list in
                        Button(list.title) { store.openTrackedList(list.calendarIdentifier) }
                    }
                }
                .disabled(store.isDemo)
            } else {
                Button("Open Tracked List") { store.openTrackedList() }
                    .disabled(store.isDemo || !store.canOpenTrackedList)
            }
            Button("Quit Glitter") { NSApp.terminate(nil) }

        }
    }
}

struct TodayContent: View {
    @ObservedObject var store: TaskStore
    let geometry: NotchGeometry
    var hoveredTaskID: String? = nil
    let taskMovement: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.presentationTasks.map { PresentedRow(id: store.rowAnimationID(for: $0), task: $0) }) { row in
                let task = row.task
                let taskRow = TaskRow(task: task, rowHeight: geometry.taskHeight(task), horizontalPadding: geometry.horizontalPadding,
                              locked: store.isMutating || !store.canCompleteTasks,
                              saving: store.savingTaskID == task.id, sampledHover: hoveredTaskID == task.id) {
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
    let rowHeight: CGFloat
    let horizontalPadding: CGFloat
    let locked: Bool
    let saving: Bool
    let sampledHover: Bool
    let onComplete: () -> Void
    @ViewState private var hovered = false
    @ViewState private var showsSpinner = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onComplete) {
            contents.contentShape(Rectangle())
        }
        .buttonStyle(TaskRowStyle())
        .background(Color.white.opacity(saving ? 0.07 : (hovered || sampledHover) && !locked && !task.isCompleted ? 0.10 : 0))
        .disabled(locked || task.isCompleted)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: saving)
        .accessibilityRepresentation {
            if task.isCompleted {
                Text(verbatim: "\(task.title), Completed")
            } else {
                Button(action: onComplete) {
                    Text(verbatim: "\(task.title), \(saving ? "Saving" : "To do")")
                }
                .disabled(locked)
                .accessibilityHint(locked ? "Temporarily unavailable" : "Mark as complete")
            }
        }
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
                } else {
                    Image(systemName: task.isCompleted ? "checkmark" : "circle.fill")
                        .font(.system(size: task.isCompleted ? 9 : 4, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: NotchGeometry.taskMarkerWidth, height: 16, alignment: .leading)
            Text(task.title.isEmpty ? "Untitled reminder" : task.title)
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

struct MonthContent: View {
    @ObservedObject var store: TaskStore
    let geometry: NotchGeometry

    var body: some View {
        VStack(spacing: 0) {
            let month = Text(store.monthTitle).font(.system(size: 18, weight: .heavy))
            let year = Text(String(store.calendar.component(.year, from: store.today)))
                .font(.system(size: 18, weight: .regular))
            Text("\(month) \(year)")
            .foregroundStyle(Color.white.opacity(0.84))
            .help("\(store.monthFullDays) \(store.monthFullDays == 1 ? "Golden Day" : "Golden Days") this month")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(store.monthTitle) \(store.calendar.component(.year, from: store.today)), \(store.monthFullDays) \(store.monthFullDays == 1 ? "Golden Day" : "Golden Days")"))
            .font(.system(size: 13, weight: .medium)).lineLimit(1)
            .frame(width: geometry.gridWidth, height: geometry.monthHeadingHeight, alignment: .leading)
            Color.clear.frame(height: geometry.monthHeadingGap)
            HStack(spacing: geometry.cellGap) {
                ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { _, day in
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
}

/// Every non-ready state gets an explanation and one clear recovery action.
struct PanelMessageView: View {
    let message: PanelMessage
    let width: CGFloat
    let padding: CGFloat
    var compact = false
    var busy = false
    var demo = false
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
                    .help(demo && target == .openList ? "Demo does not open real reminders." : title)
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
