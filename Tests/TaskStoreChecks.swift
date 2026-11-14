extension TaskStore {
    static func todayFixture(mutationService: ReminderMutationService? = nil) -> (TaskStore, RecordingWorkspace) {
        let workspace = RecordingWorkspace()
        let defaults = MemoryDefaults()
        defaults.set("month", forKey: "SandNotch.expandedMode")
        let store = TaskStore(defaults: defaults, workspace: workspace, mutationService: mutationService)
        let list = EKCalendar(for: .reminder, eventStore: store.ek)
        list.title = "学习"
        store.calendars = [list]
        store.selectedCalendarIDs = [list.calendarIdentifier]
        store.access = .granted
        store.fixtureTasks(count: 5, completed: 2)
        return (store, workspace)
    }
    func fixtureTasks(count: Int, completed: Int, longTitles: Bool = false) {
        let names = ["Read the next chapter", "Review lecture notes", "Study for the midterm", "Finish the exercise", "Organize study materials"]
        let tasks = (0..<count).map { i in
            TrackedTask(id: "fixture-\(i)", title: longTitles
                        ? "Task \(i + 1): A longer reminder title that should wrap cleanly and stay inside the scrolling list"
                        : names[i % names.count], dueDay: today,
                        completedDay: i < completed ? today : nil, isCompleted: i < completed)
        }
        apply(tasks)
    }
    static func checkTodayModel() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); count += 1 }
        let (store, workspace) = todayFixture()
        check(store.expandedMode == "today", "Legacy saved month starts in Today")
        check(store.todayTasks.count == 5 && store.todayStat.due == 5 && store.todayStat.done == 2, "Detail list matches 2/5")
        check(store.pendingTasks.count == 3 && store.completedTasks.count == 2, "Groups match reminder status")
        let today = store.today
        let yesterday = store.calendar.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = store.calendar.date(byAdding: .day, value: 1, to: today)!
        let tasks = [TrackedTask(id: "early", title: "提前完成", dueDay: today, completedDay: yesterday, isCompleted: true),
                     TrackedTask(id: "pending", title: "Pending", dueDay: today, completedDay: nil, isCompleted: false),
                     TrackedTask(id: "late", title: "Late", dueDay: yesterday, completedDay: today, isCompleted: true),
                     TrackedTask(id: "future", title: "Future", dueDay: tomorrow, completedDay: today, isCompleted: true),
                     TrackedTask(id: "undated", title: "Undated", dueDay: nil, completedDay: nil, isCompleted: false)]
        store.apply(tasks)
        check(store.todayStat.due == 3 && store.todayStat.done == 2 && store.todayTasks.count == 3, "Today includes overdue completion but excludes future and undated reminders")
        check(store.completedTasks.contains { $0.title == "提前完成" }, "Original reminder title preserved")
        check(store.stat(for: yesterday).done == 0, "Late completion does not light history")
        check(store.monthFullDays == 0, "Future early completion excluded from golden days")
        let id = store.selectedCalendarIDs.first!
        let request = store.loadID
        let before = store.todayTasks.map(\.id)
        store.finishLoad([], requestID: UUID(), calendarIDs: [id], day: today)
        check(store.todayTasks.map(\.id) == before, "Stale request cannot replace task detail")
        store.finishLoad(nil, requestID: request, calendarIDs: [id], day: today)
        check(store.todayTasks.map(\.id) == before && store.panelStatus == .failed && store.hasStatistics && !store.canCompleteTasks,
              "Failed refresh retains the last snapshot and makes it read-only")
        store.finishLoad(tasks, requestID: request, calendarIDs: [id], day: today)
        check(store.todayTasks.count == 3 && store.lastError == nil, "Successful retry restores detail")
        store.openTrackedList()
        check(workspace.openedURLs.last?.path == "/" + id, "Today score opens tracked list")
        store.selectCalendar(nil)
        check(store.todayTasks.isEmpty && !store.hasStatistics, "Switching list clears old details")
        store.setExpandedMode("month")
        let relaunched = TaskStore(defaults: store.defaults)
        check(relaunched.expandedMode == "today", "Relaunch resets Month regardless of the previous session")
        store.setExpandedMode("week")
        check(store.expandedMode == "today", "Old week requests migrate to Today")
        store.setExpandedMode("invalid")
        check(store.expandedMode == "today", "Invalid modes ignored")
        check(Theme.paletteHex == [0x352B01,0x4F4000,0x6A5504,0x866A03,0x9F7F00,0xBA9602,0xD3AA04,0xEEBF05], "Selected screenshot palette preserved")
        for percent in 0...100 {
            let level = Theme.level(for: Double(percent)/100)
            check(percent == 0 ? level == 0 : percent == 100 ? level == 7 : (0...6).contains(level), "Gold reserved for 100%")
        }
        check(Theme.level(for: 0.99999) == 6 && Theme.level(for: .nan) == 0, "Near-complete and invalid values are safe")
        let gray = NSColor(Theme.idle).usingColorSpace(.sRGB)!
        check(abs(gray.redComponent - 20.0/255) < 0.001, "Neutral gray is exact #141414")
        for level in 0..<7 {
            check(Theme.level(for: (Double(level) + 0.5) / 7) == level, "Every partial gold band is reachable")
        }
        check(DayState(stat: DayStat(day: today, due: 0, done: 0)) == .idle, "No tasks use neutral state")
        check(DayState(stat: DayStat(day: today, due: 5, done: 0)) == .idle, "Zero completion uses neutral state")
        check(DayState(stat: DayStat(day: today, due: 5, done: 5), isFuture: true) == .future, "Future dates stay neutral even if completed early")
        store.loadDemoData()
        let positiveLevels = Set(store.monthStats.filter { $0.day <= store.today && $0.done > 0 }.map { Theme.level(for: $0.ratio) })
        check(positiveLevels == Set(0...7), "Demo covers all eight gold bands")
        check(store.monthStats.contains { $0.day < store.today && $0.due == 0 }, "Demo includes a no-task day")
        check(store.monthStats.contains { $0.day < store.today && $0.due > 0 && $0.done == 0 }, "Demo includes a zero-completion day")
        let (unchanged, _) = todayFixture()
        let originalTasks = unchanged.sourceTasks
        var updates = 0
        var publications = 0
        unchanged.onUpdate = { updates += 1 }
        let subscription = unchanged.objectWillChange.sink { publications += 1 }
        unchanged.apply(Array(originalTasks.reversed()))
        check(updates == 0 && publications == 0, "Identical API data in a different order produces no state or cache invalidation")
        unchanged.lastError = "Read failed"
        unchanged.apply(originalTasks)
        check(unchanged.lastError == nil && updates == 1, "Identical data still recovers a previous load failure")
        let oldDay = unchanged.today
        unchanged.today = unchanged.calendar.date(byAdding: .day, value: 1, to: oldDay)!
        unchanged.apply(originalTasks)
        check(unchanged.todayStat.done == 0 && unchanged.todayStat.due == 3 && updates == 2,
              "Identical source recomputes overdue work after day rollover")
        subscription.cancel()
        checkHabitFeedback()
        checkOverdueModel()
        print("PASS \(count) Today model, history and palette checks")
    }
}

extension TaskStore {
    static func checkOverdueModel() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); count += 1 }
        let (store, _) = todayFixture()
        // Fixed dates make month/year transitions and repeated launches reproducible.
        let cal = store.calendar
        let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        store.today = today
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let lastMonth = cal.date(byAdding: .day, value: -2, to: today)!
        func task(_ id: String, due: Date?, done: Date? = nil, complete: Bool? = nil) -> TrackedTask {
            TrackedTask(id: id, title: id, dueDay: due, completedDay: done, isCompleted: complete ?? (done != nil))
        }
        let recurring = task("recurring-old", due: yesterday)
        let newTasks = [task("new-a", due: today), task("new-b", due: today)]
        store.apply([recurring] + newTasks)
        check(store.todayStat.due == 3 && store.todayStat.done == 0, "Overdue recurring occurrence joins today's workload")
        check(store.stat(for: yesterday).due == 1 && !store.stat(for: yesterday).isFull, "Missed due day is not golden")
        let completedOld = task("recurring-old", due: yesterday, done: today)
        store.apply([completedOld] + newTasks)
        check(store.todayStat.due == 3 && store.todayStat.done == 1, "Late completion remains in today's denominator and numerator")
        check(store.completedTasks.map(\.id) == ["recurring-old"], "Late completion remains visible in completed rows")
        check(store.stat(for: yesterday).done == 0, "Completion today does not retroactively complete yesterday")
        let completedNew = newTasks.map { task($0.id, due: today, done: today) }
        let nextOccurrence = task("recurring-next", due: tomorrow)
        store.apply([completedOld, nextOccurrence] + completedNew)
        check(store.todayStat.isFull && store.todayStat.due == 3, "Today's cleared workload is golden even with next recurrence present")
        check(!store.stat(for: yesterday).isFull, "Yesterday remains non-golden after all work is cleared")
        check(!store.todayTasks.contains { $0.id == "recurring-next" }, "Next occurrence is excluded until due")
        check(store.stat(for: tomorrow).isEmpty, "Future dates stay neutral")
        store.today = tomorrow
        store.apply([completedOld, nextOccurrence] + completedNew)
        check(store.todayTasks.map(\.id) == ["recurring-next"] && store.todayStat.done == 0, "Completed backlog leaves Today on following day")
        check(store.stat(for: today).isFull && !store.stat(for: yesterday).isFull, "Recomputed past days retain their respective outcomes")
        store.today = today
        let backlog = task("older", due: lastMonth)
        store.apply([backlog])
        check(store.todayStat.due == 1 && store.stat(for: yesterday).due == 1, "Backlog crosses month boundaries")
        store.apply([task("older", due: lastMonth, done: today)])
        check(store.todayStat.isFull && !store.stat(for: yesterday).isFull, "Cross-month late completion credits only completion day")
        store.apply([task("early", due: today, done: yesterday)])
        check(store.todayStat.isFull && store.stat(for: yesterday).isEmpty, "Early completion is credited to its due day")
        store.apply([task("unknown", due: yesterday, complete: true)])
        check(store.todayStat.isEmpty && store.stat(for: yesterday).done == 0, "Missing completion date does not invent overdue completion history")
        store.apply([task("unknown", due: today, complete: true)])
        check(store.todayStat.isFull, "Current due task respects known completed state without a completion date")
        store.apply([completedOld])
        store.apply([])
        check(store.todayStat.isEmpty && store.stat(for: yesterday).isEmpty, "Deleted source tasks disappear from reconstructed history")
        store.apply([task("rescheduled", due: tomorrow)])
        check(store.todayStat.isEmpty, "Rescheduling follows current source dates")
        store.apply([recurring])
        check(!store.todayStat.isFull && !store.stat(for: yesterday).isFull, "Uncompleting a reminder recalculates previous days")
        // Legacy history remains untouched and must never affect calculations.
        let defaults = MemoryDefaults()
        let legacyStore = EKEventStore()
        let list = EKCalendar(for: .reminder, eventStore: legacyStore)
        let legacy = try! JSONSerialization.data(withJSONObject: [list.calendarIdentifier: ["2026-11-01": ["due": 99, "done": 99]]])
        defaults.values["SandNotch.dayLog.v2"] = legacy
        defaults.values["SandNotch.trackedCalendar"] = list.calendarIdentifier
        let fresh = TaskStore(defaults: defaults)
        fresh.calendars = [list]
        fresh.access = .granted
        fresh.today = today
        fresh.apply([recurring])
        check(fresh.stat(for: yesterday).due == 1 && fresh.stat(for: yesterday).done == 0, "New instance reconstructs history without loading snapshots")
        check(defaults.dataReads.isEmpty, "No persisted history is read during startup or aggregation")
        check(defaults.values.count == 2 && defaults.data(forKey: "SandNotch.dayLog.v2") == legacy, "Legacy data is neither written nor removed")
        store.today = cal.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        store.apply([task("year-boundary", due: cal.date(from: DateComponents(year: 2026, month: 12, day: 31)))])
        check(store.todayStat.due == 1 && store.todayStat.done == 0, "Backlog crosses year boundary")
        print("PASS \(count) stateless overdue and historical reconstruction checks")
    }
}

extension TaskStore {
    static func checkHabitFeedback() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); count += 1 }
        let (store, _) = todayFixture()
        store.today = store.calendar.date(from: DateComponents(year: 2026, month: 11, day: 26))!
        store.fixtureTasks(count: 5, completed: 2)
        let detail = store.monthDetail(for: store.today)
        check(detail.contains("Today · Thursday, November 26, 2026"), "Today details include the full English date")
        check(detail.contains("2/5 completed · 40%"), "Month details include count and percentage")
        check(store.todaySummary == nil, "An unfinished day has no premature all-done message")
        let tomorrow = store.calendar.date(byAdding: .day, value: 1, to: store.today)!
        check(store.monthDetail(for: tomorrow).contains("Upcoming") && !store.monthDetail(for: tomorrow).contains("completed"), "Future dates do not report a completion percentage")
        let yesterday = store.calendar.date(byAdding: .day, value: -1, to: store.today)!
        check(store.monthDetail(for: yesterday).contains("Nothing scheduled"), "Empty historical days explain the neutral cell")
        store.fixtureTasks(count: 5, completed: 0)
        check(store.monthDetail(for: store.today).contains("0/5 completed · 0%"), "Zero completion stays distinct from an empty day in the tooltip")
        store.fixtureTasks(count: 5, completed: 5)
        check(store.todaySummary == "All done for today.", "A finished day has a quiet closing message")
        check(store.goldenMoment == 0, "Loading completed data does not trigger celebration")
        let g = NotchGeometry.make(for: nil, rows: 5, offset: 0)
        check(g.todayHeight(tasks: store.todayTasks, summary: store.todaySummary) > g.todayHeight(tasks: store.todayTasks), "The all-done message is included in the content height")
        store.fixtureTasks(count: 0, completed: 0)
        check(store.todaySummary == "Nothing scheduled today." && !store.todayStat.isFull, "An empty day is neutral, not golden")
        check(!store.monthDetail(for: store.today).contains("0/0 completed"), "Empty-day details use plain language")
        print("PASS \(count) habit summaries and calendar detail checks")
    }
}
