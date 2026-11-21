import EventKit
import XCTest
@testable import Glitter

@MainActor
final class MultilistTests: XCTestCase {
    func testMultipleListsSelectionMigrationAggregationAndCompletion() async {
        let defaults = MemoryDefaults()
        defaults.set("old-list", forKey: TaskStore.Keys.calendarID)
        let migrated = TaskStore(defaults: defaults)
        XCTAssertEqual(migrated.selectedCalendarIDs, ["old-list"])
        migrated.selectCalendar("second", extendingSelection: true)
        XCTAssertEqual(migrated.selectedCalendarIDs, ["old-list", "second"])
        XCTAssertEqual(TaskStore(defaults: defaults).selectedCalendarIDs, migrated.selectedCalendarIDs)
        migrated.selectCalendar("old-list", extendingSelection: true)
        XCTAssertEqual(migrated.selectedCalendarIDs, ["second"])
        migrated.selectCalendar("third")
        XCTAssertEqual(migrated.selectedCalendarIDs, ["third"])
        let request = migrated.loadID
        migrated.selectCalendar("third")
        XCTAssertEqual(migrated.loadID, request)
        migrated.selectCalendar("third", extendingSelection: true)
        XCTAssertTrue(migrated.selectedCalendarIDs.isEmpty)
        XCTAssertTrue(TaskStore(defaults: defaults).selectedCalendarIDs.isEmpty)
        XCTAssertEqual(defaults.string(forKey: TaskStore.Keys.calendarID), "old-list")

        let writer = FakeReminderMutation()
        let (store, workspace) = TaskStore.todayFixture(mutationService: writer)
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
        XCTAssertEqual(store.todayStat.due, 2)
        XCTAssertEqual(store.todayStat.done, 0)
        XCTAssertEqual(store.todayTasks.map(\.id), ["second", "first"])
        XCTAssertEqual(store.stat(for: yesterday).due, 1)
        XCTAssertFalse(store.stat(for: yesterday).isFull)
        XCTAssertNil(store.trackedListURL)
        store.openTrackedList(secondID)
        XCTAssertEqual(workspace.openedURLs.last?.path, "/" + secondID)
        XCTAssertNil(store.trackedListURL(for: "untracked"))

        store.finishLoad([], requestID: store.loadID, calendarIDs: [firstID], day: today)
        XCTAssertEqual(store.todayTasks.count, 2)
        store.finishLoad(nil, requestID: store.loadID, calendarIDs: [firstID, secondID], day: today)
        XCTAssertEqual(store.todayTasks.count, 2)
        XCTAssertFalse(store.canCompleteTasks)
        store.finishLoad([firstTask, secondTask], requestID: store.loadID, calendarIDs: [firstID, secondID], day: today)
        XCTAssertTrue(store.canCompleteTasks)
        XCTAssertEqual(store.todayStat.due, 2)

        let secondDone = task("second-completed", list: secondID, due: yesterday, completed: true)
        let next = task("second", list: secondID, due: tomorrow)
        writer.result = ReminderMutationResult(tasks: [secondDone, next], completedOccurrenceID: secondDone.id)
        await store.completeTask(secondTask.id)
        XCTAssertEqual(writer.calls.last?.calendarID, secondID)
        XCTAssertEqual(store.pendingTasks.map(\.id), [firstTask.id])
        XCTAssertEqual(store.completedTasks.map(\.id), [secondDone.id])
        XCTAssertEqual(store.todayStat.due, 2)
        XCTAssertEqual(store.todayStat.done, 1)
        XCTAssertFalse(store.stat(for: yesterday).isFull)
        XCTAssertTrue(store.sourceTasks.contains(next))
        XCTAssertFalse(store.todayTasks.contains(next))

        let firstDone = task("first", list: firstID, due: today, completed: true)
        writer.result = ReminderMutationResult(tasks: [firstDone])
        await store.completeTask(firstTask.id)
        XCTAssertTrue(store.todayStat.isFull)
        XCTAssertEqual(store.todayStat.due, 2)
        XCTAssertEqual(store.completedTasks.count, 2)
        XCTAssertEqual(store.goldenMoment, 1)
        XCTAssertTrue(store.sourceTasks.contains(next))

        store.apply([firstTask, secondTask])
        writer.delay = 80_000_000
        writer.result = ReminderMutationResult(tasks: [secondDone, next])
        let pending = Task { await store.completeTask(secondTask.id) }
        await Task.yield()
        store.selectCalendars([])
        await pending.value
        XCTAssertTrue(store.todayTasks.isEmpty && !store.isMutating)

        store.selectedCalendarIDs = [firstID, secondID]
        store.calendars = [first]
        store.finishLoad([firstTask, secondTask], requestID: store.loadID, calendarIDs: [firstID, secondID], day: today)
        XCTAssertTrue(store.hasStatistics)
        XCTAssertEqual(store.todayStat.due, 1)
        XCTAssertEqual(store.panelNotice?.action, .settings)
        store.calendars = []
        XCTAssertFalse(store.hasStatistics)
        XCTAssertEqual(store.panelStatus, .unavailable)

        let native = EKReminder(eventStore: store.ek)
        native.calendar = first
        native.title = "Native task"
        XCTAssertEqual(TrackedTask(reminder: native, calendar: store.calendar).calendarID, firstID)

        let demo = TaskStore(defaults: MemoryDefaults(), mutationService: writer,
                             language: LanguageManager(defaults: MemoryDefaults(), preferredLanguages: { ["en"] }))
        demo.loadDemoData()
        let demoFirst = demo.calendars[0].calendarIdentifier
        let demoSecond = demo.calendars[1].calendarIdentifier
        XCTAssertEqual(demo.calendars.count, 3)
        XCTAssertEqual(demo.todayStat.due, 5)
        demo.selectCalendar(demoSecond, extendingSelection: true)
        XCTAssertEqual(demo.todayStat.due, 6)
        XCTAssertEqual(demo.selectedCalendarIDs.count, 2)
        demo.selectCalendar(demoFirst, extendingSelection: true)
        XCTAssertEqual(demo.todayTasks.map(\.id), ["demo-learning"])
        let calls = writer.calls.count
        await demo.completeTask("demo-learning")
        XCTAssertTrue(demo.todayStat.isFull)
        XCTAssertEqual(writer.calls.count, calls)
        demo.selectCalendar(demoSecond, extendingSelection: true)
        XCTAssertEqual(demo.panelStatus, .unselected)
        XCTAssertFalse(demo.hasStatistics)
        demo.selectCalendar(demoSecond)
        XCTAssertTrue(demo.todayStat.isFull)
        demo.loadStatusDemoData(.unselected)
        XCTAssertTrue(demo.selectedCalendarIDs.isEmpty)
        demo.selectCalendar(demoFirst)
        XCTAssertTrue(demo.hasStatistics)
    }
}
