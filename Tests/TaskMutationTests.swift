import Foundation
import XCTest
@testable import Glitter

@MainActor
final class FakeReminderMutation: ReminderMutationService {
    var result = ReminderMutationResult(tasks: [])
    var error: Error?
    var delay: UInt64 = 0
    var calls: [(id: String, completed: Bool, calendarID: String, completedSince: Date)] = []

    func setCompleted(_ completed: Bool, task: TrackedTask, calendarID: String,
                      calendar: Calendar, completedSince: Date) async throws -> ReminderMutationResult {
        calls.append((task.id, completed, calendarID, completedSince))
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if let error { throw error }
        return result
    }
}

@MainActor
final class TaskMutationTests: XCTestCase {
    func testTaskEditingOrderingRecurrenceAndProtection() async {
        let writer = FakeReminderMutation()
        let (store, _) = TaskStore.todayFixture(mutationService: writer)
        let today = store.today
        let yesterday = store.calendar.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = store.calendar.date(byAdding: .day, value: 1, to: today)!

        func task(_ id: String, _ priority: Int = 0, _ due: Date? = nil,
                  completed: Date? = nil, recurring: Bool = false, title: String? = nil) -> TrackedTask {
            let due = due ?? today
            return TrackedTask(
                id: id,
                title: title ?? id,
                dueDay: store.calendar.startOfDay(for: due),
                completedDay: completed.map { store.calendar.startOfDay(for: $0) },
                isCompleted: completed != nil,
                priority: priority,
                dueDate: due,
                completionDate: completed,
                isRecurring: recurring
            )
        }

        let ordering = [
            task("none", 0, yesterday), task("low", 9, yesterday),
            task("medium", 5, yesterday), task("high-new", 1),
            task("high-old", 4, yesterday), task("high-later", 1, today.addingTimeInterval(3600)),
            task("done-older", 1, completed: today.addingTimeInterval(20)),
            task("done-newer", 0, completed: today.addingTimeInterval(40))
        ]
        store.apply(ordering.reversed())
        XCTAssertEqual(
            store.todayTasks.map(\.id),
            ["high-old", "high-new", "high-later", "medium", "low", "none", "done-newer", "done-older"],
            "Native fields sort status, priority groups, full due time and full completion time"
        )
        XCTAssertTrue([1, 2, 3, 4].allSatisfy { task("a", $0).priorityRank == 0 })
        XCTAssertTrue([6, 7, 8, 9].allSatisfy { task("a", $0).priorityRank == 2 })
        XCTAssertEqual(task("a").priorityRank, 3)

        let tied = [task("b", title: "Same"), task("a", title: "Same"), task("z", title: "Earlier")]
        store.apply(tied)
        XCTAssertEqual(store.todayTasks.map(\.id), ["z", "a", "b"], "Title then ID provide deterministic ties")

        let pending = task("pending", 1, yesterday, recurring: true)
        let neighbor = task("neighbor", 5)
        store.apply([pending, neighbor])
        let completed = task("materialized", 1, yesterday, completed: today.addingTimeInterval(100))
        let next = task("pending", 1, tomorrow, recurring: true)
        writer.result = ReminderMutationResult(tasks: [neighbor, completed, next], completedOccurrenceID: completed.id)
        writer.delay = 50_000_000

        let mutation = Task { await store.completeTask(pending.id) }
        await Task.yield()
        XCTAssertTrue(store.isMutating && store.savingTaskID == pending.id, "Saving locks every row before the native write")
        await store.completeTask(neighbor.id)
        XCTAssertEqual(writer.calls.count, 1, "A rapid second click cannot complete the neighboring task")
        try? await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertTrue(store.isMutating)
        XCTAssertEqual(store.todayStat.done, 1)
        XCTAssertEqual(store.todayStat.due, 2)
        XCTAssertEqual(store.todayTasks.map(\.id), [neighbor.id, completed.id])
        XCTAssertEqual(store.rowAnimationID(for: completed), pending.id)
        await mutation.value
        XCTAssertFalse(store.isMutating)
        XCTAssertNil(store.rowIdentityBridge)
        XCTAssertFalse(store.stat(for: yesterday).isFull)
        XCTAssertEqual(writer.calls.first?.calendarID, store.selectedCalendarIDs.first)
        XCTAssertEqual(writer.calls.first?.completed, true)
        XCTAssertEqual(writer.calls.first?.completedSince, TaskStatistics.completedHistoryStart(for: today, calendar: store.calendar))

        let callsBeforeCompletedClick = writer.calls.count
        let beforeCompletedClick = store.todayTasks
        await store.completeTask(completed.id)
        XCTAssertEqual(writer.calls.count, callsBeforeCompletedClick)
        XCTAssertEqual(store.todayTasks, beforeCompletedClick)
        XCTAssertTrue(store.sourceTasks.contains(next))

        let restored = task("materialized", 1, yesterday)
        store.apply([neighbor, restored, next])
        XCTAssertEqual(store.todayStat.done, 0)
        XCTAssertTrue(store.pendingTasks.contains(restored))

        writer.error = ReminderMutationError.changed
        let before = store.todayTasks
        await store.completeTask(restored.id)
        XCTAssertEqual(store.todayTasks, before)
        XCTAssertNotNil(store.taskError)
        XCTAssertFalse(store.isMutating)

        writer.error = nil
        writer.result = ReminderMutationResult(tasks: [neighbor, completed, next], completedOccurrenceID: completed.id)
        store.apply([neighbor, restored, next])
        await store.completeTask(restored.id)
        XCTAssertNil(store.taskError)
        XCTAssertEqual(store.todayStat.done, 1)

        let priorCalls = writer.calls.count
        await store.completeTask("deleted-id")
        XCTAssertEqual(writer.calls.count, priorCalls)

        store.apply([pending, neighbor])
        writer.delay = 100_000_000
        let interrupted = Task { await store.completeTask(pending.id) }
        await Task.yield()
        store.selectCalendar(nil)
        await interrupted.value
        XCTAssertTrue(store.todayTasks.isEmpty && !store.isMutating)

        let (demo, _) = TaskStore.todayFixture(mutationService: writer)
        demo.loadOverdueDemoData()
        let oldID = demo.pendingTasks.first(where: \.isRecurring)!.id
        let callsBeforeDemo = writer.calls.count
        await demo.completeTask(oldID)
        let finishedID = demo.completedTasks[0].id
        XCTAssertNotEqual(finishedID, oldID)
        XCTAssertEqual(demo.todayStat.done, 1)
        XCTAssertEqual(demo.todayStat.due, 3)
        XCTAssertTrue(demo.sourceTasks.contains { $0.id == oldID && $0.dueDay! > demo.today })
        await demo.completeTask(finishedID)
        XCTAssertEqual(demo.todayStat.done, 1)
        XCTAssertEqual(demo.pendingTasks.count, 2)
        XCTAssertEqual(writer.calls.count, callsBeforeDemo)

        demo.loadSaveFailureDemoData()
        let unchanged = demo.todayTasks
        await demo.completeTask(demo.pendingTasks[0].id)
        XCTAssertEqual(demo.todayTasks, unchanged)
        XCTAssertNotNil(demo.taskError)

        demo.loadDemoData(taskCount: 1, completedCount: 0)
        XCTAssertEqual(demo.goldenMoment, 0)
        XCTAssertNil(demo.todaySummary)
        let lastID = demo.pendingTasks[0].id
        await demo.completeTask(lastID)
        XCTAssertEqual(demo.goldenMoment, 1)
        XCTAssertEqual(demo.todaySummary, "All done for today.")
        await demo.completeTask(lastID)
        XCTAssertEqual(demo.goldenMoment, 1)
        demo.apply(demo.sourceTasks)
        XCTAssertEqual(demo.goldenMoment, 1)
        demo.loadDemoData(taskCount: 0, completedCount: 0)
        XCTAssertEqual(demo.goldenMoment, 0)
        XCTAssertEqual(demo.todaySummary, "Nothing scheduled today.")
    }
}
