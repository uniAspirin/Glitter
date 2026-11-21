import AppKit
import Combine
import EventKit
import Foundation

/// Reminders is the sole source; completion writes are explicit user actions.
@MainActor
final class TaskStore: ObservableObject {
    enum Access {
        case unknown
        case granted
        case denied
    }

    @Published var access: Access = .unknown
    @Published var today: Date = Calendar.current.startOfDay(for: Date())
    @Published var calendars: [EKCalendar] = []
    @Published var selectedCalendarIDs: Set<String>
    @Published private(set) var statsByDay: [Date: DayStat] = [:]
    @Published private(set) var todayTasks: [TrackedTask] = []
    @Published var lastError: String?
    @Published var loaded = false
    @Published private(set) var isRefreshing = false
    /// Today / Month disclosure is retained only in this process.
    /// The controller publishes page geometry without invalidating task-data observers.
    private(set) var expandedMode: String

    @Published private(set) var isMutating = false
    @Published private(set) var savingTaskID: String?
    @Published private(set) var taskError: String?
    @Published private(set) var rowIdentityBridge: (old: String, new: String)?
    @Published private(set) var goldenMoment = 0
    /// Presentation only. Native fields remain the sole ordering source.
    @Published private(set) var completionAnchor: (id: String, index: Int)?
    @Published private(set) var movingTaskID: String?

    let language: LanguageManager
    var l10n: L10n { language.strings }

    var onUpdate: (() -> Void)?
    private lazy var monthNameFormatter = makeCalendarFormatter(l10n.monthNameDateFormat)
    private lazy var dayDetailFormatter = makeCalendarFormatter(l10n.dayDetailDateFormat)
    private lazy var nextDueFormatter = makeCalendarFormatter(l10n.nextDueDateFormat)

    private func makeCalendarFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = l10n.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }

    private func configuredFormatter(_ formatter: DateFormatter, format: String) -> DateFormatter {
        let targetLocale = l10n.locale
        let cal = calendar
        if formatter.locale != targetLocale { formatter.locale = targetLocale }
        if formatter.calendar != cal { formatter.calendar = cal }
        if formatter.timeZone != cal.timeZone { formatter.timeZone = cal.timeZone }
        if formatter.dateFormat != format { formatter.dateFormat = format }
        return formatter
    }

    private let mutationService: (any ReminderMutationService)?
    private lazy var defaultMutationService: any ReminderMutationService = EventKitReminderMutation()
    private(set) var sourceTasks: [TrackedTask] = []
    private var appliedDay: Date?
    private var presentationDeferred = false
    var pendingApply: (tasks: [TrackedTask], request: UUID, calendarIDs: Set<String>, day: Date)?
    private var activeMutationID: UUID?
    private var reloadAfterMutation = false
    private var failedTaskID: String?
    private var taskErrorAction: PanelAction = .retryCompletion
    private var needsReconciliation = false
    private var presentationWaiter: CheckedContinuation<Void, Never>?
    static let interactionProtection = CompletionTiming.protection

    #if DEBUG || DEMO
    enum DemoWriteBehavior { case normal, slow, failed, unconfirmed }
    var demoWriteBehavior: DemoWriteBehavior = .normal
    var demoRecoveryTasks: [TrackedTask]?
    var demoTasks: [TrackedTask] = []
    var demoStatus: PanelStatus?
    var isDemo = false
    #else
    let isDemo = false
    #endif

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
            return PanelMessage(
                title: needsReconciliation ? l10n.noticeRefreshToContinue : l10n.noticeCouldNotComplete,
                detail: error,
                action: taskErrorAction,
                actionTitle: taskErrorAction == .refresh ? l10n.refreshAction : l10n.tryAgainAction
            )
        }
        if lastError != nil && hasStatistics {
            return PanelMessage(
                title: l10n.noticeCouldNotRefreshTitle,
                detail: l10n.noticeCouldNotRefreshDetail,
                action: .refresh,
                actionTitle: isRefreshing ? l10n.refreshingAction : l10n.tryAgainAction
            )
        }
        if hasStatistics && selectedCalendars.count < selectedCalendarIDs.count {
            return PanelMessage(
                title: l10n.noticeSomeListsUnavailableTitle,
                detail: l10n.noticeSomeListsUnavailableDetail,
                action: .settings,
                actionTitle: l10n.openSettingsAction
            )
        }
        return nil
    }

    var panelMessage: PanelMessage {
        switch panelStatus {
        case .awaitingAccess:
            return PanelMessage(title: l10n.msgAwaitingTitle, detail: l10n.msgAwaitingDetail,
                                action: .settings, actionTitle: l10n.openSettingsAction)
        case .denied:
            return PanelMessage(title: l10n.msgDeniedTitle, detail: l10n.msgDeniedDetail,
                                action: .settings, actionTitle: l10n.openSettingsAction)
        case .unselected:
            return PanelMessage(title: l10n.msgUnselectedTitle, detail: l10n.msgUnselectedDetail,
                                action: .settings, actionTitle: l10n.chooseListAction)
        case .unavailable:
            return PanelMessage(title: l10n.msgUnavailableTitle, detail: l10n.msgUnavailableDetail,
                                action: .settings, actionTitle: l10n.chooseListAction)
        case .loading:
            return PanelMessage(title: l10n.msgLoadingTitle, detail: l10n.msgLoadingDetail)
        case .failed:
            return PanelMessage(title: l10n.msgFailedTitle, detail: l10n.msgFailedDetail,
                                action: .refresh, actionTitle: l10n.tryAgainAction)
        case .empty, .ready:
            if sourceTasks.isEmpty {
                return PanelMessage(
                    title: l10n.msgEmptyListsTitle(multiple: selectedCalendarIDs.count > 1),
                    detail: l10n.msgEmptyListsDetail,
                    action: .openList,
                    actionTitle: l10n.openRemindersAction
                )
            }
            if sourceTasks.contains(where: { !$0.isCompleted && $0.dueDay == nil }) {
                return PanelMessage(
                    title: l10n.msgUndatedTitle,
                    detail: l10n.msgUndatedDetail,
                    action: .openList,
                    actionTitle: l10n.openRemindersAction
                )
            }
            if let next = sourceTasks.filter({ !$0.isCompleted && ($0.dueDay ?? .distantPast) > today })
                .compactMap(\.dueDay).min() {
                let formatter = configuredFormatter(nextDueFormatter, format: l10n.nextDueDateFormat)
                let isTomorrow = calendar.date(byAdding: .day, value: 1, to: today)
                    .map { calendar.isDate(next, inSameDayAs: $0) } ?? false
                let date = isTomorrow ? l10n.tomorrowWord : formatter.string(from: next)
                return PanelMessage(title: l10n.msgFutureTitle, detail: l10n.msgFutureDetail(date))
            }
            return PanelMessage(title: l10n.msgNothingScheduledTitle, detail: l10n.msgNothingScheduledDetail)
        }
    }

    func setLanguage(_ selection: AppLanguage) {
        language.setLanguage(selection)
    }

    private func handleLanguageChange() {
        objectWillChange.send()
        onUpdate?()
    }

    func retryLoad() {
        guard !isRefreshing, !isMutating else { return }
        #if DEBUG || DEMO
        if isDemo {
            performDemoRetryLoad()
            return
        }
        #endif
        refreshCalendars()
        reload(preservingContent: hasStatistics)
    }

    func retryCompletion() async {
        guard let id = failedTaskID, taskErrorAction == .retryCompletion else { return }
        #if DEBUG || DEMO
        if isDemo { demoWriteBehavior = .normal }
        #endif
        await completeTask(id)
    }

    func rowAnimationID(for task: TrackedTask) -> String {
        rowIdentityBridge?.new == task.id ? rowIdentityBridge!.old : task.id
    }

    let ek = EKEventStore()
    let defaults: UserDefaults
    private let workspace: NSWorkspace
    var loadID = UUID()
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    var accessTimer: Timer?
    private var debounceTask: Task<Void, Never>?
    private var loadTimeoutTask: Task<Void, Never>?
    private var activeFetchCancel: (@Sendable () -> Void)?

    enum Keys {
        static let calendarID = "SandNotch.trackedCalendar"
        static let calendarIDs = "SandNotch.trackedCalendars"
    }

    init(defaults: UserDefaults = .standard, workspace: NSWorkspace = .shared,
         mutationService: (any ReminderMutationService)? = nil,
         language: LanguageManager? = nil) {
        self.defaults = defaults
        self.workspace = workspace
        self.mutationService = mutationService
        self.language = language ?? LanguageManager(defaults: defaults)
        if let ids = defaults.object(forKey: Keys.calendarIDs) as? [String] {
            selectedCalendarIDs = Set(ids.filter { !$0.isEmpty })
        } else {
            selectedCalendarIDs = Set([defaults.string(forKey: Keys.calendarID)].compactMap { $0 })
        }
        expandedMode = "today"
        self.language.onChange = { [weak self] in self?.handleLanguageChange() }
    }

    deinit {
        accessTimer?.invalidate()
        debounceTask?.cancel()
        loadTimeoutTask?.cancel()
        activeFetchCancel?()
        for entry in observers {
            entry.center.removeObserver(entry.token)
        }
    }

    // MARK: - 日历

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.timeZone = .current
        return c
    }

    var monthDayCount: Int {
        TaskStatistics.monthDayCount(for: today, calendar: calendar)
    }

    /// 本月 7 列网格（周一开头，空位 nil）
    var monthRows: [[Int?]] {
        TaskStatistics.monthRows(for: today, calendar: calendar)
    }

    func date(inMonth day: Int) -> Date? {
        TaskStatistics.date(inMonth: day, today: today, calendar: calendar)
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
        if todayStat.isEmpty { return l10n.summaryEmptyToday }
        return todayStat.isFull ? l10n.summaryAllDoneToday : nil
    }

    func monthDetail(for date: Date) -> String {
        let day = calendar.startOfDay(for: date)
        let formatter = configuredFormatter(dayDetailFormatter, format: l10n.dayDetailDateFormat)
        let stat = stat(for: day)
        return l10n.monthDetail(
            formattedDate: formatter.string(from: day),
            isToday: day == today,
            isFuture: day > today,
            due: stat.due,
            done: stat.done,
            ratio: stat.ratio
        )
    }

    var monthStats: [DayStat] { (0..<monthDayCount).compactMap { date(inMonth: $0 + 1) }.map { stat(for: $0) } }

    /// 几何层需要的日历行数。
    var expandedRows: Int { monthRows.count }
    var pendingTasks: [TrackedTask] { todayTasks.filter { !$0.isCompleted } }
    var completedTasks: [TrackedTask] { todayTasks.filter { $0.isCompleted } }

    var monthTitle: String {
        let formatter = configuredFormatter(monthNameFormatter, format: l10n.monthNameDateFormat)
        return formatter.string(from: today)
    }
    var monthFullDays: Int { monthStats.filter { $0.day <= today && $0.isFull }.count }

    var selectedCalendarName: String {
        guard !selectedCalendars.isEmpty else { return l10n.noListSelected }
        return selectedCalendars.count == 1 ? selectedCalendars[0].title : l10n.multipleListsName(selectedCalendars.count)
    }

    var sourceName: String {
        Set(selectedCalendars.compactMap { $0.source?.title }).sorted().joined(separator: ", ")
    }

    enum PanelStatus {
        case awaitingAccess, denied, unselected, unavailable, loading, failed, empty, ready

        func title(with l10n: L10n) -> String {
            l10n.panelStatusTitle(for: self)
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
        #if DEBUG || DEMO
        if isDemo && demoStatus != nil { return false }
        #endif
        return access == .granted && hasSelectedCalendar && loaded && appliedDay == today
    }

    var panelStatus: PanelStatus {
        #if DEBUG || DEMO
        if isDemo, let demoStatus { return demoStatus }
        #endif
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
        #if DEBUG || DEMO
        demoStatus = nil
        #endif
        statsByDay = [:]
        todayTasks = []
        sourceTasks = []
        #if DEBUG || DEMO
        if isDemo {
            if !ids.isEmpty { apply(demoTasks.filter { $0.calendarID.map(ids.contains) ?? false }) }
            onUpdate?()
            return
        }
        #endif
        reload()
        onUpdate?()
    }

    // MARK: - 生命周期

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    func start() {
        observeSystemEvents()
        updateAccessWatch()
    }

    func requestAccessAndLoad() async {
        guard !isDemo else { return }
        let status = authorizationStatus
        if status == .fullAccess {
            access = .granted
            updateAccessWatch()
            refreshCalendars()
            reload()
            return
        }
        if status == .denied || status == .restricted {
            access = .denied
            updateAccessWatch()
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
        updateAccessWatch()
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
                workspace.open(url)
            }
            return
        }
        do {
            let granted = try await ek.requestFullAccessToReminders()
            access = granted ? .granted : .denied
            updateAccessWatch()
            if granted {
                refreshCalendars()
                reload()
            } else {
                onUpdate?()
            }
        } catch {
            access = .denied
            updateAccessWatch()
            onUpdate?()
        }
    }

    func refreshCalendars() {
        guard !isDemo, authorizationStatus == .fullAccess else { return }
        calendars = ek.calendars(for: .reminder)
        calendars.sort { ($0.source?.title ?? "") + $0.title < ($1.source?.title ?? "") + $1.title }
    }

    func reload(preservingContent: Bool = false) {
        guard !isDemo else { return }
        if isMutating { reloadAfterMutation = true; return }
        loadID = UUID()
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        activeFetchCancel?()
        activeFetchCancel = nil
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
            self.activeFetchCancel?()
            self.activeFetchCancel = nil
            self.finishLoad(nil, requestID: requestID, calendarIDs: ids, day: requestDay)
            // Ignore a late response after the user has been offered a retry.
            if self.loadID == requestID { self.loadID = UUID() }
        }
        if needsPresentationUpdate { onUpdate?() }
        let completedSince = TaskStatistics.completedHistoryStart(for: requestDay, calendar: cal)
        activeFetchCancel = ScopedReminderFetch.start(
            store: ek,
            calendars: targets,
            completedSince: completedSince
        ) { [weak self] reminders in
            let tasks = reminders?.map { TrackedTask(reminder: $0, calendar: cal) }
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.authorizationStatus == .fullAccess else {
                    self.syncAccess()
                    return
                }
                self.finishLoad(tasks, requestID: requestID, calendarIDs: ids, day: requestDay)
            }
        }
    }

    func finishLoad(_ tasks: [TrackedTask]?, requestID: UUID, calendarIDs: Set<String>, day: Date) {
        guard requestID == loadID, selectedCalendarIDs == calendarIDs,
              access == .granted, hasSelectedCalendar else { return }
        guard calendar.startOfDay(for: Date()) == day else {
            reload()
            return
        }
        isRefreshing = false
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        activeFetchCancel = nil
        guard let tasks else {
            lastError = l10n.readRemindersFailed
            onUpdate?()
            return
        }
        let availableIDs = Set(selectedCalendars.map(\.calendarIdentifier))
        apply(tasks.filter { task in
            task.calendarID.map(availableIDs.contains) ?? (calendarIDs.count == 1)
        })
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

    func apply(_ tasks: [TrackedTask]) {
        if presentationDeferred {
            pendingApply = (tasks, loadID, selectedCalendarIDs, today)
            return
        }
        var tasks = tasks
        #if DEBUG || DEMO
        if isDemo {
            let fallbackID = selectedCalendars.first?.calendarIdentifier
            tasks = tasks.map { task in
                var task = task
                if task.calendarID == nil { task.calendarID = fallbackID }
                return task
            }
            demoTasks = demoTasks.filter { !selectedCalendarIDs.contains($0.calendarID ?? "") } + tasks
        }
        #endif
        let canonical = tasks.sorted { $0.id < $1.id }
        guard !loaded || lastError != nil || taskError != nil || sourceTasks != canonical || appliedDay != today else { return }
        sourceTasks = canonical
        appliedDay = today
        let cal = calendar
        statsByDay = TaskStatistics.monthStats(for: tasks, today: today, calendar: cal)
        todayTasks = TaskStatistics.todayTasks(for: tasks, today: today)

        lastError = nil
        taskError = nil
        failedTaskID = nil
        needsReconciliation = false
        loaded = true
        onUpdate?()
    }

    // MARK: - Completion editing

    func resetTaskInteraction() {
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
        activeFetchCancel?()
        activeFetchCancel = nil
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
        let cal = calendar
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
        activeFetchCancel?()
        activeFetchCancel = nil
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
            #if DEBUG || DEMO
            if isDemo {
                result = try await performDemoMutation(task)
            } else {
                let completedSince = TaskStatistics.completedHistoryStart(for: day, calendar: cal)
                result = try await (mutationService ?? defaultMutationService).setCompleted(
                    true, task: task, calendarID: listID, calendar: cal, completedSince: completedSince)
            }
            #else
            let completedSince = TaskStatistics.completedHistoryStart(for: day, calendar: cal)
            result = try await (mutationService ?? defaultMutationService).setCompleted(
                true, task: task, calendarID: listID, calendar: cal, completedSince: completedSince)
            #endif
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
               !result.tasks.contains(where: { $0.id == id && TaskStatistics.belongs($0, to: today) }) {
                rowIdentityBridge = (old: id, new: newID)
            }
            let completedID = result.completedOccurrenceID ?? id
            if result.tasks.contains(where: { $0.id == completedID && $0.isCompleted && TaskStatistics.belongs($0, to: today) }) {
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
            taskError = reason?.localizedDescription(with: l10n) ?? l10n.genericCompletionFailed
            onUpdate?()
        }
        // Protect the new position until its fade-in has settled.
        try? await Task.sleep(nanoseconds: Self.interactionProtection)
    }

    // MARK: - 监听

    private func observeSystemEvents() {
        guard observers.isEmpty else { return }
        let defaultCenter = NotificationCenter.default
        let workspaceCenter = workspace.notificationCenter

        let storeToken = defaultCenter.addObserver(forName: .EKEventStoreChanged, object: ek, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleReload() }
        }
        let dayToken = defaultCenter.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        let clockToken = defaultCenter.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick(forceReload: true) }
        }
        let zoneToken = defaultCenter.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick(forceReload: true) }
        }
        let activeToken = defaultCenter.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.syncAccess() }
        }
        let wakeToken = workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.syncAccess()
                self?.tick()
            }
        }

        observers = [
            (defaultCenter, storeToken),
            (defaultCenter, dayToken),
            (defaultCenter, clockToken),
            (defaultCenter, zoneToken),
            (defaultCenter, activeToken),
            (workspaceCenter, wakeToken)
        ]
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

    func updateAccessWatch() {
        guard !isDemo, access != .granted else {
            accessTimer?.invalidate()
            accessTimer = nil
            return
        }
        guard accessTimer == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncAccess() }
        }
        t.tolerance = 0.6
        RunLoop.main.add(t, forMode: .common)
        accessTimer = t
    }

    func syncAccess() {
        guard !isDemo else { return }
        switch authorizationStatus {
        case .fullAccess:
            if access != .granted {
                access = .granted
                updateAccessWatch()
                refreshCalendars()
                reload()
            }
        case .denied, .restricted:
            if access != .denied {
                access = .denied
                updateAccessWatch()
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
                updateAccessWatch()
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

    func tick(forceReload: Bool = false) {
        guard !isDemo else { return }
        let now = calendar.startOfDay(for: Date())
        guard forceReload || now != today else { return }
        today = now
        reload()
    }
}
