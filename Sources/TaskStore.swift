import AppKit
import Combine
import EventKit
import Foundation

/// 调试用：把关键状态写进 build/status.log，方便用 `open` 启动时也能看到结果
enum DebugLog {
    static func write(_ line: String) {
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("status.log")
        let text = line + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(text.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct TrackedTask: Identifiable, Equatable {
    let id: String
    var calendarID: String?
    let title: String
    /// 到期日（本地零点）
    let dueDay: Date?
    /// 完成日（本地零点）
    let completedDay: Date?
    let isCompleted: Bool
    let priority: Int
    let dueDate: Date?
    let completionDate: Date?
    let isRecurring: Bool

    init(id: String, title: String, dueDay: Date?, completedDay: Date?, isCompleted: Bool,
         priority: Int = 0, dueDate: Date? = nil, completionDate: Date? = nil, isRecurring: Bool = false,
         calendarID: String? = nil) {
        self.id = id
        self.calendarID = calendarID
        self.title = title
        self.dueDay = dueDay
        self.completedDay = completedDay
        self.isCompleted = isCompleted
        self.priority = priority
        self.dueDate = dueDate ?? dueDay
        self.completionDate = completionDate ?? completedDay
        self.isRecurring = isRecurring
    }

    var priorityRank: Int {
        switch priority {
        case 1...4: return 0
        case 5: return 1
        case 6...9: return 2
        default: return 3
        }
    }

    static func precedes(_ a: TrackedTask, _ b: TrackedTask) -> Bool {
        if a.isCompleted != b.isCompleted { return !a.isCompleted }
        if !a.isCompleted {
            if a.priorityRank != b.priorityRank { return a.priorityRank < b.priorityRank }
            let left = a.dueDate ?? .distantFuture, right = b.dueDate ?? .distantFuture
            if left != right { return left < right }
        } else {
            let left = a.completionDate ?? .distantPast, right = b.completionDate ?? .distantPast
            if left != right { return left > right }
        }
        let order = a.title.localizedStandardCompare(b.title)
        return order == .orderedSame ? a.id < b.id : order == .orderedAscending
    }
}

struct DayStat {
    let day: Date
    let due: Int
    let done: Int

    var ratio: Double {
        guard due > 0 else { return 0 }
        return min(Double(done) / Double(due), 1)
    }

    var isFull: Bool { due > 0 && done >= due }
    var isEmpty: Bool { due == 0 }

    static func zero(_ day: Date) -> DayStat { DayStat(day: day, due: 0, done: 0) }
}

/// Reminders is the sole source; completion writes are explicit user actions.
@MainActor
final class TaskStore: ObservableObject {
    enum Access {
        case unknown
        case granted
        case denied
    }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var today: Date = Calendar.current.startOfDay(for: Date())
    @Published private(set) var calendars: [EKCalendar] = []
    @Published private(set) var selectedCalendarIDs: Set<String>
    @Published private(set) var statsByDay: [Date: DayStat] = [:]
    @Published private(set) var todayTasks: [TrackedTask] = []
    @Published private(set) var lastError: String?
    @Published private(set) var loaded = false
    @Published private(set) var isRefreshing = false
    /// Today / Month disclosure is retained only in this process.
    @Published private(set) var expandedMode: String

    @Published private(set) var isMutating = false
    @Published private(set) var savingTaskID: String?
    @Published private(set) var taskError: String?
    @Published private(set) var rowIdentityBridge: (old: String, new: String)?
    @Published private(set) var goldenMoment = 0
    /// Presentation only. Native fields remain the sole ordering source.
    @Published private(set) var completionAnchor: (id: String, index: Int)?
    @Published private(set) var movingTaskID: String?

    var onUpdate: (() -> Void)?
    private let mutationService: ReminderMutationService?
    private var sourceTasks: [TrackedTask] = []
    private var appliedDay: Date?
    private var presentationDeferred = false
    private var pendingApply: (tasks: [TrackedTask], request: UUID, calendarIDs: Set<String>, day: Date)?
    private var activeMutationID: UUID?
    private var reloadAfterMutation = false
    private enum DemoWriteBehavior { case normal, slow, failed, unconfirmed }
    private var demoWriteBehavior: DemoWriteBehavior = .normal
    private var demoRecoveryTasks: [TrackedTask]?
    private var demoTasks: [TrackedTask] = []
    private var demoStatus: PanelStatus?
    private var failedTaskID: String?
    private var taskErrorAction: PanelAction = .retryCompletion
    private var needsReconciliation = false
    private var presentationWaiter: CheckedContinuation<Void, Never>?
    static let interactionProtection = CompletionTiming.protection

    var presentationTasks: [TrackedTask] {
        guard let anchor = completionAnchor,
              let index = todayTasks.firstIndex(where: { $0.id == anchor.id }) else { return todayTasks }
        var rows = todayTasks
        let task = rows.remove(at: index)
        rows.insert(task, at: min(anchor.index, rows.count))
        return rows
    }

    var presentationSummary: String? { isMutating ? nil : todaySummary }

    var canCompleteTasks: Bool { hasStatistics && lastError == nil && !needsReconciliation }

    var panelNotice: PanelMessage? {
        if let error = taskError {
            return PanelMessage(title: needsReconciliation ? "Refresh to continue" : "Couldn't complete this reminder",
                                detail: error, action: taskErrorAction,
                                actionTitle: taskErrorAction == .refresh ? "Refresh" : "Try Again")
        }
        if lastError != nil && hasStatistics {
            return PanelMessage(title: "Couldn't refresh", detail: "Showing the last update. Refresh to continue.",
                                action: .refresh, actionTitle: isRefreshing ? "Refreshing…" : "Try Again")
        }
        if hasStatistics && selectedCalendars.count < selectedCalendarIDs.count {
            return PanelMessage(title: "Some lists aren't available", detail: "Showing your available lists. Review your selection in Settings.",
                                action: .settings, actionTitle: "Open Settings")
        }
        return nil
    }

    var panelMessage: PanelMessage {
        switch panelStatus {
        case .awaitingAccess:
            return PanelMessage(title: "Connect to Reminders", detail: "Allow access to see your chosen list here.",
                                action: .settings, actionTitle: "Open Settings")
        case .denied:
            return PanelMessage(title: "Reminders access is off", detail: "Allow access in Settings to bring your list back.",
                                action: .settings, actionTitle: "Open Settings")
        case .unselected:
            return PanelMessage(title: "Choose your list", detail: "Choose lists in Settings to see their due and overdue tasks here.",
                                action: .settings, actionTitle: "Choose a List")
        case .unavailable:
            return PanelMessage(title: "Tracked lists aren't available", detail: "They may have moved or been removed. Choose a list in Settings.",
                                action: .settings, actionTitle: "Choose a List")
        case .loading:
            return PanelMessage(title: "Getting your reminders…", detail: "Your tasks will appear here when they're ready.")
        case .failed:
            return PanelMessage(title: "Couldn't load your reminders", detail: "Your reminders haven't been changed. Try loading them again.",
                                action: .refresh, actionTitle: "Try Again")
        case .empty, .ready:
            if sourceTasks.isEmpty {
                return PanelMessage(title: selectedCalendarIDs.count > 1 ? "Your lists are empty" : "Your list is empty", detail: "Add a reminder with a due date in Reminders.",
                                    action: .openList, actionTitle: "Open Reminders")
            }
            if sourceTasks.contains(where: { !$0.isCompleted && $0.dueDay == nil }) {
                return PanelMessage(title: "Nothing due today", detail: "Undated reminders stay in Reminders. Add a due date to see them here.",
                                    action: .openList, actionTitle: "Open Reminders")
            }
            if let next = sourceTasks.filter({ !$0.isCompleted && ($0.dueDay ?? .distantPast) > today })
                .compactMap(\.dueDay).min() {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone
                formatter.dateFormat = "EEEE, MMM d"
                let date = calendar.isDate(next, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: today)!)
                    ? "tomorrow" : formatter.string(from: next)
                return PanelMessage(title: "You're clear for today", detail: "Your next reminder is due \(date).")
            }
            return PanelMessage(title: "Nothing scheduled today", detail: "A little room in your day. Due and overdue reminders will appear here.")
        }
    }

    func retryLoad() {
        guard !isRefreshing, !isMutating else { return }
        if isDemo {
            if let tasks = demoRecoveryTasks {
                demoRecoveryTasks = nil
                demoWriteBehavior = .normal
                apply(tasks)
            } else {
                loadDemoData()
            }
        } else {
            refreshCalendars()
            reload(preservingContent: hasStatistics)
        }
    }

    func retryCompletion() async {
        guard let id = failedTaskID, taskErrorAction == .retryCompletion else { return }
        if isDemo { demoWriteBehavior = .normal }
        await completeTask(id)
    }

    func rowAnimationID(for task: TrackedTask) -> String {
        rowIdentityBridge?.new == task.id ? rowIdentityBridge!.old : task.id
    }

    private let ek = EKEventStore()
    private let defaults: UserDefaults
    private let workspace: NSWorkspace
    private var loadID = UUID()
    private var storeObserver: NSObjectProtocol?
    private var timer: Timer?
    private var accessTimer: Timer?
    private var debounceTask: Task<Void, Never>?
    private var loadTimeoutTask: Task<Void, Never>?
    private(set) var isDemo = false

    private enum Keys {
        static let calendarID = "SandNotch.trackedCalendar"
        static let calendarIDs = "SandNotch.trackedCalendars"
    }

    init(defaults: UserDefaults = .standard, workspace: NSWorkspace = .shared,
         mutationService: ReminderMutationService? = nil) {
        self.defaults = defaults
        self.workspace = workspace
        self.mutationService = mutationService
        if let ids = defaults.object(forKey: Keys.calendarIDs) as? [String] {
            selectedCalendarIDs = Set(ids.filter { !$0.isEmpty })
        } else {
            selectedCalendarIDs = Set([defaults.string(forKey: Keys.calendarID)].compactMap { $0 })
        }
        expandedMode = "today"
    }

    // MARK: - 日历

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.timeZone = .current
        return c
    }

    var monthDayCount: Int {
        calendar.range(of: .day, in: .month, for: today)?.count ?? 30
    }

    /// 本月 7 列网格（周一开头，空位 nil）
    var monthRows: [[Int?]] {
        guard let first = calendar.dateInterval(of: .month, for: today)?.start else { return [] }
        let weekday = calendar.component(.weekday, from: first)
        let offset = (weekday + 5) % 7
        var cells: [Int?] = Array(repeating: nil, count: offset)
        cells.append(contentsOf: (1...monthDayCount).map { Optional($0) })
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map {
            Array(cells[$0 ..< min($0 + 7, cells.count)])
        }
    }

    func date(inMonth day: Int) -> Date? {
        guard let start = calendar.dateInterval(of: .month, for: today)?.start else { return nil }
        return calendar.date(byAdding: .day, value: day - 1, to: start)
    }

    // MARK: - 统计

    /// Derived in memory from the latest EventKit response; no historical snapshots.
    func stat(for day: Date) -> DayStat {
        let d = calendar.startOfDay(for: day)
        guard hasStatistics else { return .zero(d) }
        return statsByDay[d] ?? .zero(d)
    }

    var todayStat: DayStat { stat(for: today) }

    var todaySummary: String? {
        guard hasStatistics else { return nil }
        if todayStat.isEmpty { return "Nothing scheduled today." }
        return todayStat.isFull ? "All done for today." : nil
    }

    func monthDetail(for date: Date) -> String {
        let day = calendar.startOfDay(for: date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        let title = (day == today ? "Today · " : "") + formatter.string(from: day)
        if day > today { return "\(title)\nUpcoming" }
        let stat = stat(for: day)
        if stat.isEmpty { return "\(title)\nNothing scheduled" }
        let percent = Int((stat.ratio * 100).rounded())
        return "\(title)\n\(stat.done)/\(stat.due) completed · \(percent)%"
    }

    var monthStats: [DayStat] { (0..<monthDayCount).compactMap { date(inMonth: $0 + 1) }.map { stat(for: $0) } }

    /// 几何层需要的日历行数。
    var expandedRows: Int { monthRows.count }
    var pendingTasks: [TrackedTask] { todayTasks.filter { !$0.isCompleted } }
    var completedTasks: [TrackedTask] { todayTasks.filter { $0.isCompleted } }

    var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMMM"
        return formatter.string(from: today)
    }
    var monthFullDays: Int { monthStats.filter { $0.day <= today && $0.isFull }.count }

    var selectedCalendarName: String {
        guard !selectedCalendars.isEmpty else { return "No list selected" }
        return selectedCalendars.count == 1 ? selectedCalendars[0].title : "\(selectedCalendars.count) lists"
    }

    var sourceName: String {
        Set(selectedCalendars.compactMap { $0.source?.title }).sorted().joined(separator: ", ")
    }

    enum PanelStatus {
        case awaitingAccess, denied, unselected, unavailable, loading, failed, empty, ready

        var title: String {
            switch self {
            case .awaitingAccess: return "Waiting for Reminders access"
            case .denied: return "Reminders access required"
            case .unselected: return "Choose a list to track"
            case .unavailable: return "Tracked list unavailable"
            case .loading: return "Loading reminders…"
            case .failed: return "Unable to load reminders"
            case .empty: return "No tasks for today"
            case .ready: return "Completed / Today’s tasks"
            }
        }

        var symbol: String {
            switch self {
            case .awaitingAccess, .loading: return "ellipsis"
            case .denied: return "lock.fill"
            case .unselected: return "list.bullet"
            case .unavailable, .failed: return "exclamationmark.triangle"
            case .empty: return "minus"
            case .ready: return "checkmark"
            }
        }
    }

    var selectedCalendars: [EKCalendar] { calendars.filter { selectedCalendarIDs.contains($0.calendarIdentifier) } }

    private var hasSelectedCalendar: Bool { !selectedCalendars.isEmpty }

    var canOpenTrackedList: Bool {
        access == .granted && hasSelectedCalendar
    }

    var hasStatistics: Bool {
        (!isDemo || demoStatus == nil) && access == .granted && hasSelectedCalendar && loaded && appliedDay == today
    }

    var panelStatus: PanelStatus {
        if isDemo, let demoStatus { return demoStatus }
        switch access {
        case .unknown: return .awaitingAccess
        case .denied: return .denied
        case .granted: break
        }
        guard !selectedCalendarIDs.isEmpty else { return .unselected }
        guard hasSelectedCalendar else { return .unavailable }
        if lastError != nil { return .failed }
        guard loaded, appliedDay == today else { return .loading }
        return todayStat.isEmpty ? .empty : .ready
    }

    // MARK: - 展开态视图模式

    func setExpandedMode(_ mode: String) {
        let nextMode = mode == "week" ? "today" : mode
        guard nextMode == "today" || nextMode == "month", nextMode != expandedMode else { return }
        expandedMode = nextMode
        DebugLog.write("expandedMode -> \(expandedMode) rows=\(expandedRows)")
        onUpdate?()
    }

    // MARK: - 清单选择

    func selectCalendar(_ id: String?, extendingSelection: Bool = false) {
        var ids = extendingSelection ? selectedCalendarIDs : []
        if let id {
            if extendingSelection && ids.contains(id) { ids.remove(id) }
            else { ids.insert(id) }
        }
        selectCalendars(ids)
    }

    func selectCalendars(_ ids: Set<String>) {
        guard ids != selectedCalendarIDs else { return }
        resetTaskInteraction()
        loadID = UUID()
        pendingApply = nil
        appliedDay = nil
        loaded = false
        selectedCalendarIDs = ids
        defaults.set(ids.sorted(), forKey: Keys.calendarIDs)
        lastError = nil
        demoStatus = nil
        statsByDay = [:]
        todayTasks = []
        sourceTasks = []
        if isDemo {
            if !ids.isEmpty { apply(demoTasks.filter { $0.calendarID.map(ids.contains) ?? false }) }
        } else {
            reload()
        }
        onUpdate?()
    }

    // MARK: - 生命周期

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    func start() {
        observeStoreChanges()
        startTimer()
    }

    func requestAccessAndLoad() async {
        guard !isDemo else { return }
        let status = authorizationStatus
        if status == .fullAccess {
            access = .granted
            refreshCalendars()
            reload()
            return
        }
        if status == .denied || status == .restricted {
            access = .denied
            onUpdate?()
            return
        }

        do {
            let granted = try await ek.requestFullAccessToReminders()
            access = granted ? .granted : .denied
        } catch {
            access = .denied
            lastError = error.localizedDescription
        }
        DebugLog.write("request access granted=\(access == .granted) status=\(authorizationStatus.rawValue)")
        if access == .granted {
            refreshCalendars()
            reload()
        } else {
            onUpdate?()
        }
    }

    func forceRequestAccess() async {
        guard !isDemo else { return }
        let status = authorizationStatus
        if status == .denied || status == .restricted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        do {
            let granted = try await ek.requestFullAccessToReminders()
            access = granted ? .granted : .denied
            DebugLog.write("force request granted=\(granted)")
            if granted {
                refreshCalendars()
                reload()
            } else {
                onUpdate?()
            }
        } catch {
            DebugLog.write("force request error=\(error.localizedDescription)")
            access = .denied
            onUpdate?()
        }
    }

    func refreshCalendars() {
        guard !isDemo, authorizationStatus == .fullAccess else { return }
        calendars = ek.calendars(for: .reminder)
        for cal in calendars {
            DebugLog.write("calendar \(cal.title) | \(cal.source?.title ?? "-") | \(cal.calendarIdentifier)")
        }
        calendars.sort { ($0.source?.title ?? "") + $0.title < ($1.source?.title ?? "") + $1.title }
    }

    func reload(preservingContent: Bool = false) {
        guard !isDemo else { return }
        if isMutating { reloadAfterMutation = true; return }
        loadID = UUID()
        loadTimeoutTask?.cancel()
        isRefreshing = false
        guard access == .granted else {
            statsByDay = [:]
            todayTasks = []
            loaded = false
            onUpdate?()
            return
        }
        let cal = calendar
        let requestDay = cal.startOfDay(for: Date())
        let needsPresentationUpdate = !preservingContent || lastError != nil || today != requestDay
        if !preservingContent { loaded = false }
        if !loaded { lastError = nil }
        if today != requestDay { today = requestDay }

        let ids = selectedCalendarIDs
        let targets = selectedCalendars
        guard !targets.isEmpty else {
            statsByDay = [:]
            todayTasks = []
            sourceTasks = []
            appliedDay = nil
            loaded = false
            onUpdate?()
            return
        }

        let requestID = loadID
        isRefreshing = true
        loadTimeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard let self, self.loadID == requestID, self.isRefreshing else { return }
            self.finishLoad(nil, requestID: requestID, calendarIDs: ids, day: requestDay)
            // Ignore a late response after the user has been offered a retry.
            if self.loadID == requestID { self.loadID = UUID() }
        }
        if needsPresentationUpdate { onUpdate?() }
        let predicate = ek.predicateForReminders(in: targets)
        ek.fetchReminders(matching: predicate) { [weak self] reminders in
            guard let self else { return }
            let tasks = reminders?.map { TrackedTask(reminder: $0, calendar: cal) }
            DispatchQueue.main.async {
                guard self.authorizationStatus == .fullAccess else {
                    self.syncAccess()
                    return
                }
                self.finishLoad(tasks, requestID: requestID, calendarIDs: ids, day: requestDay)
            }
        }
    }

    private func finishLoad(_ tasks: [TrackedTask]?, requestID: UUID, calendarIDs: Set<String>, day: Date) {
        guard requestID == loadID, selectedCalendarIDs == calendarIDs,
              access == .granted, hasSelectedCalendar else { return }
        guard calendar.startOfDay(for: Date()) == day else {
            reload()
            return
        }
        isRefreshing = false
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        guard let tasks else {
            lastError = "Unable to read reminders. Please try again."
            onUpdate?()
            return
        }
        let availableIDs = Set(selectedCalendars.map(\.calendarIdentifier))
        apply(tasks.filter { task in
            task.calendarID.map(availableIDs.contains) ?? (calendarIDs.count == 1)
        })
    }

    /// A task belongs to its due day, then each overdue day through its completion day.
    /// Early completion stays credited to the due day; future work is not pulled forward.
    private func belongs(_ task: TrackedTask, to day: Date) -> Bool {
        guard let due = task.dueDay, due <= day else { return false }
        if due == day || !task.isCompleted { return true }
        guard let completed = task.completedDay else { return false }
        return completed >= day
    }

    private func completed(_ task: TrackedTask, by day: Date) -> Bool {
        guard task.isCompleted else { return false }
        // A missing completion date cannot establish a past day's completion.
        guard let completed = task.completedDay else { return day == today }
        return completed <= day
    }

    func setPresentationDeferred(_ deferred: Bool) {
        presentationDeferred = deferred
        if !deferred {
            let waiter = presentationWaiter
            presentationWaiter = nil
            waiter?.resume()
        }
        guard !deferred, let pending = pendingApply else { return }
        pendingApply = nil
        guard pending.request == loadID, pending.calendarIDs == selectedCalendarIDs, pending.day == today else { return }
        apply(pending.tasks)
    }

    private func apply(_ tasks: [TrackedTask]) {
        if presentationDeferred {
            pendingApply = (tasks, loadID, selectedCalendarIDs, today)
            return
        }
        var tasks = tasks
        if isDemo {
            let fallbackID = selectedCalendars.first?.calendarIdentifier
            tasks = tasks.map { task in
                var task = task
                if task.calendarID == nil { task.calendarID = fallbackID }
                return task
            }
            demoTasks = demoTasks.filter { !selectedCalendarIDs.contains($0.calendarID ?? "") } + tasks
        }
        let canonical = tasks.sorted { $0.id < $1.id }
        guard !loaded || lastError != nil || taskError != nil || sourceTasks != canonical || appliedDay != today else { return }
        sourceTasks = canonical
        appliedDay = today
        var stats: [Date: DayStat] = [:]
        let first = calendar.dateInterval(of: .month, for: today)!.start
        var day = first
        while day <= today {
            let workload = tasks.filter { belongs($0, to: day) }
            stats[day] = DayStat(day: day, due: workload.count,
                                 done: workload.filter { completed($0, by: day) }.count)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        statsByDay = stats
        todayTasks = tasks.filter { belongs($0, to: today) }.sorted(by: TrackedTask.precedes)

        lastError = nil
        taskError = nil
        failedTaskID = nil
        needsReconciliation = false
        loaded = true
        DebugLog.write("reminders loaded")
        onUpdate?()
    }

    // MARK: - Completion editing

    private func resetTaskInteraction() {
        activeMutationID = nil
        isMutating = false
        savingTaskID = nil
        taskError = nil
        rowIdentityBridge = nil
        reloadAfterMutation = false
        goldenMoment = 0
        completionAnchor = nil
        movingTaskID = nil
        failedTaskID = nil
        needsReconciliation = false
        isRefreshing = false
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        let waiter = presentationWaiter
        presentationWaiter = nil
        waiter?.resume()
    }

    func completeTask(_ id: String) async {
        guard !isMutating, canCompleteTasks,
              let task = todayTasks.first(where: { $0.id == id }), !task.isCompleted,
              isDemo || canOpenTrackedList else { return }
        let token = UUID()
        let selection = selectedCalendarIDs
        guard let listID = task.calendarID ?? (selection.count == 1 ? selection.first : nil),
              selectedCalendars.contains(where: { $0.calendarIdentifier == listID }) else { return }
        let day = today
        let wasGolden = todayStat.isFull
        let originalIndex = presentationTasks.firstIndex(where: { $0.id == id }) ?? 0
        activeMutationID = token
        isMutating = true
        savingTaskID = id
        taskError = nil
        rowIdentityBridge = nil
        loadID = UUID() // Ignore any read that started before this explicit edit.
        isRefreshing = false
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        pendingApply = nil
        debounceTask?.cancel()
        onUpdate?()
        defer {
            if activeMutationID == token {
                isMutating = false
                savingTaskID = nil
                rowIdentityBridge = nil
                completionAnchor = nil
                movingTaskID = nil
                activeMutationID = nil
                onUpdate?()
                if reloadAfterMutation {
                    reloadAfterMutation = false
                    reload(preservingContent: true)
                }
            }
        }
        do {
            let result: ReminderMutationResult
            if isDemo {
                try await Task.sleep(nanoseconds: demoWriteBehavior == .slow ? 900_000_000 : 100_000_000)
                if demoWriteBehavior == .failed { throw NSError(domain: "Glitter.Demo", code: 1) }
                result = demoMutation(task)
                if demoWriteBehavior == .unconfirmed {
                    demoRecoveryTasks = result.tasks
                    throw ReminderMutationError.refreshAfterSave
                }
            } else {
                result = try await (mutationService ?? EventKitReminderMutation()).setCompleted(
                    true, task: task, calendarID: listID, calendar: calendar)
            }
            guard activeMutationID == token, selectedCalendarIDs == selection,
                  today == day, access == .granted else { return }
            while presentationDeferred && activeMutationID == token {
                await withCheckedContinuation { presentationWaiter = $0 }
            }
            guard activeMutationID == token, selectedCalendarIDs == selection,
                  today == day, access == .granted else { return }
            savingTaskID = nil
            // A short-lived animation identity only; row order comes solely from native fields.
            if let newID = result.completedOccurrenceID,
               !result.tasks.contains(where: { $0.id == id && belongs($0, to: today) }) {
                rowIdentityBridge = (old: id, new: newID)
            }
            let completedID = result.completedOccurrenceID ?? id
            if result.tasks.contains(where: { $0.id == completedID && $0.isCompleted && belongs($0, to: today) }) {
                completionAnchor = (id: completedID, index: originalIndex)
            }
            let retained = isDemo ? [] : sourceTasks.filter { $0.calendarID != nil && $0.calendarID != listID }
            apply(retained + result.tasks)
            if !wasGolden && todayStat.isFull { goldenMoment += 1 }
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if let anchor = completionAnchor {
                if !reduceMotion {
                    try? await Task.sleep(nanoseconds: CompletionTiming.acknowledge)
                }
                guard activeMutationID == token, selectedCalendarIDs == selection, today == day else { return }
                if !reduceMotion {
                    movingTaskID = anchor.id
                    onUpdate?()
                    try? await Task.sleep(nanoseconds: CompletionTiming.fadeOut)
                    guard activeMutationID == token, selectedCalendarIDs == selection, today == day else { return }
                }
                completionAnchor = nil
                onUpdate?()
            }
            if !reduceMotion {
                try? await Task.sleep(nanoseconds: UInt64(CompletionTiming.movement * 1_000_000_000))
                guard activeMutationID == token, selectedCalendarIDs == selection, today == day else { return }
            }
            movingTaskID = nil
            onUpdate?()
        } catch {
            guard activeMutationID == token, selectedCalendarIDs == selection, today == day else { return }
            savingTaskID = nil
            failedTaskID = id
            let reason = error as? ReminderMutationError
            needsReconciliation = reason == .refreshAfterSave || reason == .changed || reason == .unavailable || reason == .access
            taskErrorAction = needsReconciliation ? .refresh : .retryCompletion
            taskError = reason?.errorDescription ?? "Your reminder is still here. Try again when you're ready."
            onUpdate?()
        }
        // Protect the new position until its fade-in has settled.
        try? await Task.sleep(nanoseconds: Self.interactionProtection)
    }

    private func demoMutation(_ task: TrackedTask) -> ReminderMutationResult {
        let clock = calendar.dateComponents([.hour, .minute, .second], from: Date())
        let now = calendar.date(bySettingHour: clock.hour ?? 12, minute: clock.minute ?? 0,
                                second: clock.second ?? 0, of: today)!
        let newID = task.isRecurring ? UUID().uuidString : task.id
        let changed = TrackedTask(id: newID, title: task.title, dueDay: task.dueDay,
                                  completedDay: today,
                                  isCompleted: true, priority: task.priority,
                                  dueDate: task.dueDate, completionDate: now, calendarID: task.calendarID)
        var tasks = sourceTasks.filter { $0.id != task.id }
        tasks.append(changed)
        if task.isRecurring {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
            tasks.append(TrackedTask(id: task.id, title: task.title, dueDay: tomorrow,
                                     completedDay: nil, isCompleted: false, priority: task.priority,
                                     isRecurring: true, calendarID: task.calendarID))
        }
        return ReminderMutationResult(tasks: tasks,
                                      completedOccurrenceID: newID == task.id ? nil : newID)
    }

    func loadSaveFailureDemoData(taskCount: Int = 5) {
        loadDemoData(taskCount: taskCount, completedCount: 2)
        demoWriteBehavior = .failed
    }

    func loadSlowSaveDemoData() {
        loadDemoData(taskCount: 1, completedCount: 0)
        demoWriteBehavior = .slow
    }

    func loadUnconfirmedSaveDemoData() {
        loadDemoData(taskCount: 1, completedCount: 0)
        demoWriteBehavior = .unconfirmed
    }

    func loadStatusDemoData(_ status: PanelStatus) {
        loadDemoData()
        if status == .unselected { selectedCalendarIDs = [] }
        if status == .unavailable { selectedCalendarIDs = ["demo-unavailable"] }
        demoStatus = status
        onUpdate?()
    }

    func loadStaleDemoData() {
        loadDemoData()
        lastError = "Demo refresh failure"
        onUpdate?()
    }

    func loadUndatedDemoData() {
        loadDemoData(taskCount: 0, completedCount: 0)
        apply(sourceTasks + [TrackedTask(id: "demo-undated", title: "A reminder without a date",
                                        dueDay: nil, completedDay: nil, isCompleted: false)])
    }

    func loadFutureDemoData() {
        loadDemoData(taskCount: 0, completedCount: 0)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        apply(sourceTasks + [TrackedTask(id: "demo-future", title: "Read tomorrow",
                                        dueDay: tomorrow, completedDay: nil, isCompleted: false)])
    }

    func loadEmptyListDemoData() {
        loadDemoData()
        apply([])
    }

    func loadLongTitleDemoData() {
        loadDemoData(taskCount: 0, completedCount: 0)
        let title = "Read the chapter and make a short note about each idea:\n\nWhat surprised you?\nWhat would you like to try?\nWhat will you remember tomorrow?\n\nTake your time. A long reminder should remain readable, even when it continues below the preview."
        apply(sourceTasks + [TrackedTask(id: "demo-long-title", title: title, dueDay: today,
                                        completedDay: nil, isCompleted: false)])
    }

    // MARK: - 监听

    private func observeStoreChanges() {
        guard storeObserver == nil else { return }
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: ek,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleReload() }
        }
    }

    private func scheduleReload() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            refreshCalendars()
            reload(preservingContent: hasStatistics)
        }
    }

    private func startTimer() {
        startAccessWatch()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func startAccessWatch() {
        guard accessTimer == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncAccess() }
        }
        t.tolerance = 0.6
        RunLoop.main.add(t, forMode: .common)
        accessTimer = t
    }

    private func syncAccess() {
        guard !isDemo else { return }
        switch authorizationStatus {
        case .fullAccess:
            if access != .granted {
                access = .granted
                refreshCalendars()
                reload()
            }
        case .denied, .restricted:
            if access != .denied {
                access = .denied
                loadID = UUID()
                resetTaskInteraction()
                sourceTasks = []
                loaded = false
                calendars = []
                statsByDay = [:]
                todayTasks = []
                onUpdate?()
            }
        default:
            if access != .unknown {
                access = .unknown
                loadID = UUID()
                resetTaskInteraction()
                sourceTasks = []
                loaded = false
                calendars = []
                statsByDay = [:]
                todayTasks = []
                onUpdate?()
            }
        }
    }

    // MARK: - 打开提醒事项

    var trackedListURL: URL? {
        guard selectedCalendars.count == 1 else { return nil }
        return trackedListURL(for: selectedCalendars[0].calendarIdentifier)
    }

    func trackedListURL(for id: String) -> URL? {
        guard canOpenTrackedList, selectedCalendars.contains(where: { $0.calendarIdentifier == id }) else { return nil }
        var components = URLComponents()
        components.scheme = "x-apple-reminderkit"
        components.host = "REMCDList"
        components.path = "/\(id)"
        return components.url
    }

    /// 点击面板后激活提醒事项并定位到当前跟踪清单。
    func openTrackedList(_ calendarID: String? = nil) {
        guard !isDemo else { return }
        let url = calendarID.flatMap { trackedListURL(for: $0) } ?? trackedListURL
        if let url, workspace.open(url) {
            return
        }
        if let app = workspace.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            workspace.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - 调试

    /// 假数据覆盖零任务、零完成、全部八阶金色与未来日期，今天默认 2/5
    func loadDemoData(taskCount: Int = 5, completedCount: Int = 2) {
        resetTaskInteraction()
        loadID = UUID()
        pendingApply = nil
        loaded = false
        demoStatus = nil
        demoWriteBehavior = .normal
        demoRecoveryTasks = nil
        isDemo = true
        access = .granted
        if calendars.count != 3 || !calendars.allSatisfy({ $0.title.hasPrefix("Demo · ") }) {
            calendars = ["Daily Habits", "Learning", "Personal"].map { title in
                let list = EKCalendar(for: .reminder, eventStore: ek)
                list.title = "Demo · " + title
                return list
            }
        }
        selectedCalendarIDs = [calendars[0].calendarIdentifier]
        let cal = calendar
        if let start = cal.dateInterval(of: .month, for: today)?.start,
           let fake = cal.date(byAdding: .day, value: 25, to: start) {
            today = cal.startOfDay(for: fake)
        }
        demoTasks = [
            TrackedTask(id: "demo-learning", title: "Practice a new skill", dueDay: today,
                        completedDay: nil, isCompleted: false, calendarID: calendars[1].calendarIdentifier),
            TrackedTask(id: "demo-personal", title: "Take a walk", dueDay: today,
                        completedDay: nil, isCompleted: false, calendarID: calendars[2].calendarIdentifier)
        ]

        var tasks: [TrackedTask] = []
        var seq = 0
        for day in 1...26 {
            guard let d = date(inMonth: day) else { continue }
            let sample = [2, 5, 8, 11, 14, 17, 20, 23].firstIndex(of: day)
            let due = day == 26 ? taskCount : sample != nil ? 10 : day == 24 ? 1 : 0
            let done = day == 26 ? min(max(0, completedCount), due) : sample.map { [1, 2, 4, 5, 7, 8, 9, 10][$0] } ?? 0
            for i in 0..<due {
                seq += 1
                // Close historical backlog on the next day, leaving subsequent samples independent.
                let completion = i < done ? d : day < 26 ? cal.date(byAdding: .day, value: 1, to: d) : nil
                tasks.append(TrackedTask(
                    id: "demo-\(seq)",
                    title: day == 26
                        ? ["Read the next chapter", "Review lecture notes", "Finish the exercise", "Organize study materials", "Study for the midterm"][i % 5]
                        : "Demo \(seq)",
                    dueDay: d, completedDay: completion, isCompleted: completion != nil,
                    priority: day == 26 ? [1, 5, 9, 0, 1][i % 5] : 0))
            }
        }
        apply(tasks)
    }

    func loadOverdueDemoData(completed: Bool = false) {
        loadDemoData()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let tasks = (0..<3).map { index in
            TrackedTask(id: "overdue-demo-\(index)",
                        title: ["Yesterday’s recurring reminder", "Read the next chapter", "Review lecture notes"][index],
                        dueDay: index == 0 ? yesterday : today,
                        completedDay: completed ? today : nil, isCompleted: completed,
                        isRecurring: index == 0 && !completed)
        }
        apply(tasks)
    }

    private func tick() {
        guard !isDemo else { return }
        let now = calendar.startOfDay(for: Date())
        guard now != today else { return }
        today = now
        reload()
    }
}
