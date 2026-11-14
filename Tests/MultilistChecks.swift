import EventKit

extension TaskStore {
    static func checkMultipleLists() async {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            count += 1
        }

        let defaults = MemoryDefaults()
        defaults.set("old-list", forKey: Keys.calendarID)
        let migrated = TaskStore(defaults: defaults)
        check(migrated.selectedCalendarIDs == ["old-list"], "Existing single-list settings migrate without changing the original key")
        migrated.selectCalendar("second", extendingSelection: true)
        check(migrated.selectedCalendarIDs == ["old-list", "second"], "Command-click adds a list")
        check(TaskStore(defaults: defaults).selectedCalendarIDs == migrated.selectedCalendarIDs, "Multiple selections survive relaunch")
        migrated.selectCalendar("old-list", extendingSelection: true)
        check(migrated.selectedCalendarIDs == ["second"], "Command-click removes a selected list")
        migrated.selectCalendar("third")
        check(migrated.selectedCalendarIDs == ["third"], "An ordinary click replaces the selection")
        let request = migrated.loadID
        migrated.selectCalendar("third")
        check(migrated.loadID == request, "Clicking the only selected list does not restart loading")
        migrated.selectCalendar("third", extendingSelection: true)
        check(migrated.selectedCalendarIDs.isEmpty && TaskStore(defaults: defaults).selectedCalendarIDs.isEmpty,
              "An explicitly empty selection does not restore the legacy single list")
        check(defaults.string(forKey: Keys.calendarID) == "old-list", "Original settings remain available to the backup version")

        let writer = FakeReminderMutation()
        let (store, workspace) = todayFixture(mutationService: writer)
        let first = store.calendars[0]
        let second = EKCalendar(for: .reminder, eventStore: store.ek)
        second.title = "Exercise"
        let firstID = first.calendarIdentifier
        let secondID = second.calendarIdentifier
        store.calendars = [first, second]
        store.selectedCalendarIDs = [firstID, secondID]
        let today = store.today
        let yesterday = store.calendar.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = store.calendar.date(byAdding: .day, value: 1, to: today)!
        func task(_ id: String, list: String, due: Date, completed: Bool = false, priority: Int = 0) -> TrackedTask {
            TrackedTask(id: id, title: "Same title", dueDay: due, completedDay: completed ? today : nil,
                        isCompleted: completed, priority: priority, calendarID: list)
        }
        let firstTask = task("first", list: firstID, due: today)
        let secondTask = task("second", list: secondID, due: yesterday, priority: 1)
        store.apply([firstTask, secondTask])
        check(store.todayStat.due == 2 && store.todayStat.done == 0, "All selected lists contribute to today's score")
        check(store.todayTasks.map(\.id) == ["second", "first"], "Native priority sorting applies across lists and keeps identical titles distinct")
        check(store.stat(for: yesterday).due == 1 && !store.stat(for: yesterday).isFull, "Overdue history uses the combined workload")
        check(store.trackedListURL == nil, "Multiple lists never resolve silently to an arbitrary list")
        store.openTrackedList(secondID)
        check(workspace.openedURLs.last?.path == "/" + secondID, "Each tracked list has its own Reminders destination")
        check(store.trackedListURL(for: "untracked") == nil, "Untracked lists are not exposed as destinations")
        store.finishLoad([], requestID: store.loadID, calendarIDs: [firstID], day: today)
        check(store.todayTasks.count == 2, "An old single-list response cannot replace a combined selection")
        store.finishLoad(nil, requestID: store.loadID, calendarIDs: [firstID, secondID], day: today)
        check(store.todayTasks.count == 2 && !store.canCompleteTasks, "A failed combined read preserves all rows as read-only")
        store.finishLoad([firstTask, secondTask], requestID: store.loadID, calendarIDs: [firstID, secondID], day: today)
        check(store.canCompleteTasks && store.todayStat.due == 2, "A successful combined read restores interaction")

        let secondDone = task("second-completed", list: secondID, due: yesterday, completed: true)
        let next = task("second", list: secondID, due: tomorrow)
        writer.result = ReminderMutationResult(tasks: [secondDone, next], completedOccurrenceID: secondDone.id)
        await store.completeTask(secondTask.id)
        check(writer.calls.last?.calendarID == secondID, "Completion writes to the reminder's own list")
        check(store.pendingTasks.map(\.id) == [firstTask.id] && store.completedTasks.map(\.id) == [secondDone.id],
              "Completing one list preserves the other list's unfinished rows")
        check(store.todayStat.due == 2 && store.todayStat.done == 1 && !store.stat(for: yesterday).isFull,
              "Recurring completion updates the combined score without changing a missed day")
        check(store.sourceTasks.contains(next) && !store.todayTasks.contains(next), "The next occurrence stays outside today's merged list")
        let firstDone = task("first", list: firstID, due: today, completed: true)
        writer.result = ReminderMutationResult(tasks: [firstDone])
        await store.completeTask(firstTask.id)
        check(store.todayStat.isFull && store.todayStat.due == 2 && store.completedTasks.count == 2,
              "A golden day requires completion across every selected list")
        check(store.goldenMoment == 1 && store.sourceTasks.contains(next), "One combined golden pulse preserves the other list's future recurrence")

        store.apply([firstTask, secondTask])
        writer.delay = 80_000_000
        writer.result = ReminderMutationResult(tasks: [secondDone, next])
        let pending = Task { await store.completeTask(secondTask.id) }
        await Task.yield()
        store.selectCalendars([])
        await pending.value
        check(store.todayTasks.isEmpty && !store.isMutating, "An in-flight write cannot restore a previous list selection")

        store.selectedCalendarIDs = [firstID, secondID]
        store.calendars = [first]
        store.finishLoad([firstTask, secondTask], requestID: store.loadID, calendarIDs: [firstID, secondID], day: today)
        check(store.hasStatistics && store.todayStat.due == 1 && store.panelNotice?.action == .settings,
              "An unavailable list leaves remaining lists usable with a settings notice")
        store.calendars = []
        check(!store.hasStatistics && store.panelStatus == .unavailable, "Losing every selected list hides stale statistics")

        let native = EKReminder(eventStore: store.ek)
        native.calendar = first
        native.title = "Native task"
        check(TrackedTask(reminder: native, calendar: store.calendar).calendarID == firstID,
              "EventKit conversion preserves each reminder's list identifier")

        let demo = TaskStore(defaults: MemoryDefaults(), mutationService: writer)
        demo.loadDemoData()
        let demoFirst = demo.calendars[0].calendarIdentifier
        let demoSecond = demo.calendars[1].calendarIdentifier
        check(demo.calendars.count == 3 && demo.todayStat.due == 5, "Demo starts with one of three fictional lists")
        demo.selectCalendar(demoSecond, extendingSelection: true)
        check(demo.todayStat.due == 6 && demo.selectedCalendarIDs.count == 2, "Demo Command-selection adds tasks without accessing real Reminders")
        demo.selectCalendar(demoFirst, extendingSelection: true)
        check(demo.todayTasks.map(\.id) == ["demo-learning"], "Removing a Demo list removes only its contribution")
        let calls = writer.calls.count
        await demo.completeTask("demo-learning")
        check(demo.todayStat.isFull && writer.calls.count == calls, "Demo completes multi-list tasks entirely in memory")
        demo.selectCalendar(demoSecond, extendingSelection: true)
        check(demo.panelStatus == .unselected && !demo.hasStatistics, "Removing the final Demo list shows the selection state")
        demo.selectCalendar(demoSecond)
        check(demo.todayStat.isFull, "Reselecting a Demo list preserves its completed tasks")
        demo.loadStatusDemoData(.unselected)
        check(demo.selectedCalendarIDs.isEmpty, "The no-selection Demo also clears settings checkmarks")
        demo.selectCalendar(demoFirst)
        check(demo.hasStatistics, "Choosing a Demo list recovers the no-selection state")
        print("PASS \(count) multiple-list selection, migration, aggregation and completion checks")
    }
}
