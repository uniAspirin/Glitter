@MainActor
final class FakeReminderMutation: ReminderMutationService {
    var result = ReminderMutationResult(tasks: [])
    var error: Error?
    var delay: UInt64 = 0
    var calls: [(id: String, completed: Bool, calendarID: String)] = []
    func setCompleted(_ completed: Bool, task: TrackedTask, calendarID: String,
                      calendar: Calendar) async throws -> ReminderMutationResult {
        calls.append((task.id, completed, calendarID))
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if let error { throw error }
        return result
    }
}

extension TaskStore {
    static func checkTaskEditing() async {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); count += 1
        }
        let writer = FakeReminderMutation()
        let (store, _) = todayFixture(mutationService: writer)
        let today = store.today
        let yesterday = store.calendar.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = store.calendar.date(byAdding: .day, value: 1, to: today)!
        func task(_ id: String, _ priority: Int = 0, _ due: Date? = nil,
                  completed: Date? = nil, recurring: Bool = false, title: String? = nil) -> TrackedTask {
            let due = due ?? today
            return TrackedTask(id: id, title: title ?? id,
                               dueDay: store.calendar.startOfDay(for: due),
                               completedDay: completed.map { store.calendar.startOfDay(for: $0) },
                               isCompleted: completed != nil, priority: priority, dueDate: due,
                               completionDate: completed, isRecurring: recurring)
        }
        let ordering = [task("none", 0, yesterday), task("low", 9, yesterday),
                        task("medium", 5, yesterday), task("high-new", 1),
                        task("high-old", 4, yesterday), task("high-later", 1, today.addingTimeInterval(3600)),
                        task("done-older", 1, completed: today.addingTimeInterval(20)),
                        task("done-newer", 0, completed: today.addingTimeInterval(40))]
        store.apply(ordering.reversed())
        check(store.todayTasks.map(\.id) == ["high-old", "high-new", "high-later", "medium", "low", "none", "done-newer", "done-older"],
              "Native fields sort status, priority groups, full due time and full completion time")
        check([1, 2, 3, 4].allSatisfy { task("a", $0).priorityRank == 0 }, "RFC high priority values share one rank")
        check([6, 7, 8, 9].allSatisfy { task("a", $0).priorityRank == 2 }, "RFC low priority values share one rank")
        check(task("a").priorityRank == 3, "Unspecified priority follows Low")
        let tied = [task("b", title: "Same"), task("a", title: "Same"), task("z", title: "Earlier")]
        store.apply(tied)
        check(store.todayTasks.map(\.id) == ["z", "a", "b"], "Title then ID provide deterministic ties")

        let pending = task("pending", 1, yesterday, recurring: true)
        let neighbor = task("neighbor", 5)
        store.apply([pending, neighbor])
        let completed = task("materialized", 1, yesterday, completed: today.addingTimeInterval(100))
        let next = task("pending", 1, tomorrow, recurring: true)
        writer.result = ReminderMutationResult(tasks: [neighbor, completed, next], completedOccurrenceID: completed.id)
        writer.delay = 50_000_000
        let mutation = Task { await store.completeTask(pending.id) }
        await Task.yield()
        check(store.isMutating && store.savingTaskID == pending.id, "Saving locks every row before the native write")
        await store.completeTask(neighbor.id)
        check(writer.calls.count == 1, "A rapid second click cannot complete the neighboring task")
        try? await Task.sleep(nanoseconds: 90_000_000)
        check(store.isMutating && store.todayStat.done == 1 && store.todayStat.due == 2, "Position protection remains active after save and reordering")
        check(store.todayTasks.map(\.id) == [neighbor.id, completed.id], "Next recurrence remains outside Today")
        check(store.rowAnimationID(for: completed) == pending.id, "New occurrence receives only a temporary animation identity")
        await mutation.value
        check(!store.isMutating && store.rowIdentityBridge == nil, "Animation identity is discarded after the click protection window")
        check(!store.stat(for: yesterday).isFull, "Completing overdue work does not make yesterday golden")
        check(writer.calls.first?.calendarID == store.selectedCalendarIDs.first && writer.calls.first?.completed == true,
              "Write is scoped to the current list and requested state")

        let callsBeforeCompletedClick = writer.calls.count
        let beforeCompletedClick = store.todayTasks
        await store.completeTask(completed.id)
        check(writer.calls.count == callsBeforeCompletedClick && store.todayTasks == beforeCompletedClick,
              "Completed records cannot trigger a write or become incomplete")
        check(store.sourceTasks.contains(next), "Next recurrence is left unchanged")
        // External changes in Reminders still appear on the next fetch.
        let restored = task("materialized", 1, yesterday)
        store.apply([neighbor, restored, next])
        check(store.todayStat.done == 0 && store.pendingTasks.contains(restored),
              "Uncompletion performed in Reminders is reflected by a fresh read")

        writer.error = ReminderMutationError.changed
        let before = store.todayTasks
        await store.completeTask(restored.id)
        check(store.todayTasks == before && store.taskError != nil && !store.isMutating,
              "Failed write preserves original state and exposes a readable error")
        writer.error = nil
        writer.result = ReminderMutationResult(tasks: [neighbor, completed, next], completedOccurrenceID: completed.id)
        store.apply([neighbor, restored, next]) // Reconcile the externally changed reminder before retrying.
        await store.completeTask(restored.id)
        check(store.taskError == nil && store.todayStat.done == 1, "A retry clears errors and applies native data")
        let priorCalls = writer.calls.count
        await store.completeTask("deleted-id")
        check(writer.calls.count == priorCalls, "Missing rows cannot trigger a write")

        store.apply([pending, neighbor])
        writer.delay = 100_000_000
        let interrupted = Task { await store.completeTask(pending.id) }
        await Task.yield()
        store.selectCalendar(nil)
        await interrupted.value
        check(store.todayTasks.isEmpty && !store.isMutating, "A result for a previous list cannot overwrite the new selection")

        let (demo, _) = todayFixture(mutationService: writer)
        demo.loadOverdueDemoData()
        let oldID = demo.pendingTasks.first(where: \.isRecurring)!.id
        let callsBeforeDemo = writer.calls.count
        await demo.completeTask(oldID)
        let finishedID = demo.completedTasks[0].id
        check(finishedID != oldID && demo.todayStat.done == 1 && demo.todayStat.due == 3, "Demo models EventKit's changed occurrence ID")
        check(demo.sourceTasks.contains { $0.id == oldID && $0.dueDay! > demo.today }, "Demo retains the generated tomorrow occurrence")
        await demo.completeTask(finishedID)
        check(demo.todayStat.done == 1 && demo.pendingTasks.count == 2, "Completed Demo tasks remain read-only")
        check(writer.calls.count == callsBeforeDemo, "Demo editing never invokes the native writer")
        demo.loadSaveFailureDemoData()
        let unchanged = demo.todayTasks
        await demo.completeTask(demo.pendingTasks[0].id)
        check(demo.todayTasks == unchanged && demo.taskError != nil, "Save Error demo leaves all data intact")
        demo.loadDemoData(taskCount: 1, completedCount: 0)
        check(demo.goldenMoment == 0 && demo.todaySummary == nil, "New unfinished demo day has no celebration")
        let lastID = demo.pendingTasks[0].id
        await demo.completeTask(lastID)
        check(demo.goldenMoment == 1 && demo.todaySummary == "All done for today.", "Finishing the last task triggers exactly one golden moment")
        await demo.completeTask(lastID)
        check(demo.goldenMoment == 1, "Completed rows cannot retrigger celebration")
        demo.apply(demo.sourceTasks)
        check(demo.goldenMoment == 1, "A refresh cannot replay the celebration")
        demo.loadDemoData(taskCount: 0, completedCount: 0)
        check(demo.goldenMoment == 0 && demo.todaySummary == "Nothing scheduled today.", "Resetting to an empty day clears the pulse token")
        print("PASS \(count) native-field ordering, editing, recurrence and click-protection checks")
    }
}
