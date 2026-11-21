import AppKit
import EventKit
import XCTest
@testable import Glitter

@MainActor
final class TaskStoreTests: XCTestCase {
    func testTodayModelHistoryAndPalette() {
        let (store, workspace) = TaskStore.todayFixture()
        XCTAssertEqual(store.expandedMode, "today", "Legacy saved month starts in Today")
        XCTAssertEqual(store.todayTasks.count, 5)
        XCTAssertEqual(store.todayStat.due, 5)
        XCTAssertEqual(store.todayStat.done, 2, "Detail list matches 2/5")
        XCTAssertEqual(store.pendingTasks.count, 3)
        XCTAssertEqual(store.completedTasks.count, 2, "Groups match reminder status")

        let today = store.today
        let yesterday = store.calendar.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = store.calendar.date(byAdding: .day, value: 1, to: today)!
        let tasks = [
            TrackedTask(id: "early", title: "提前完成", dueDay: today, completedDay: yesterday, isCompleted: true),
            TrackedTask(id: "pending", title: "Pending", dueDay: today, completedDay: nil, isCompleted: false),
            TrackedTask(id: "late", title: "Late", dueDay: yesterday, completedDay: today, isCompleted: true),
            TrackedTask(id: "future", title: "Future", dueDay: tomorrow, completedDay: today, isCompleted: true),
            TrackedTask(id: "undated", title: "Undated", dueDay: nil, completedDay: nil, isCompleted: false)
        ]
        store.apply(tasks)
        XCTAssertEqual(store.todayStat.due, 3)
        XCTAssertEqual(store.todayStat.done, 2)
        XCTAssertEqual(store.todayTasks.count, 3, "Today includes overdue completion but excludes future and undated reminders")
        XCTAssertTrue(store.completedTasks.contains { $0.title == "提前完成" }, "Original reminder title preserved")
        XCTAssertEqual(store.stat(for: yesterday).done, 0, "Late completion does not light history")
        XCTAssertEqual(store.monthFullDays, 0, "Future early completion excluded from golden days")

        let id = store.selectedCalendarIDs.first!
        let request = store.loadID
        let before = store.todayTasks.map(\.id)
        store.finishLoad([], requestID: UUID(), calendarIDs: [id], day: today)
        XCTAssertEqual(store.todayTasks.map(\.id), before, "Stale request cannot replace task detail")
        store.finishLoad(nil, requestID: request, calendarIDs: [id], day: today)
        XCTAssertEqual(store.todayTasks.map(\.id), before)
        XCTAssertEqual(store.panelStatus, .failed)
        XCTAssertTrue(store.hasStatistics)
        XCTAssertFalse(store.canCompleteTasks, "Failed refresh retains the last snapshot and makes it read-only")
        store.finishLoad(tasks, requestID: request, calendarIDs: [id], day: today)
        XCTAssertEqual(store.todayTasks.count, 3)
        XCTAssertNil(store.lastError, "Successful retry restores detail")

        store.openTrackedList()
        XCTAssertEqual(workspace.openedURLs.last?.path, "/" + id, "Today score opens tracked list")
        store.selectCalendar(nil)
        XCTAssertTrue(store.todayTasks.isEmpty && !store.hasStatistics, "Switching list clears old details")
        store.setExpandedMode("month")
        let relaunched = TaskStore(defaults: store.defaults)
        XCTAssertEqual(relaunched.expandedMode, "today", "Relaunch resets Month regardless of the previous session")
        store.setExpandedMode("week")
        XCTAssertEqual(store.expandedMode, "today", "Old week requests migrate to Today")
        store.setExpandedMode("invalid")
        XCTAssertEqual(store.expandedMode, "today", "Invalid modes ignored")

        XCTAssertEqual(Theme.paletteHex, [0x352B01, 0x4F4000, 0x6A5504, 0x866A03, 0x9F7F00, 0xBA9602, 0xD3AA04, 0xEEBF05])
        for percent in 0...100 {
            let level = Theme.level(for: Double(percent) / 100)
            if percent == 0 { XCTAssertEqual(level, 0) }
            else if percent == 100 { XCTAssertEqual(level, 7) }
            else { XCTAssertTrue((0...6).contains(level), "Gold reserved for 100%") }
        }
        XCTAssertEqual(Theme.level(for: 0.99999), 6)
        XCTAssertEqual(Theme.level(for: .nan), 0)
        let gray = NSColor(Theme.idle).usingColorSpace(.sRGB)!
        XCTAssertEqual(gray.redComponent, 20.0 / 255, accuracy: 0.001, "Neutral gray is exact #141414")
        for level in 0..<7 {
            XCTAssertEqual(Theme.level(for: (Double(level) + 0.5) / 7), level, "Every partial gold band is reachable")
        }
        XCTAssertEqual(DayState(stat: DayStat(day: today, due: 0, done: 0)), .idle)
        XCTAssertEqual(DayState(stat: DayStat(day: today, due: 5, done: 0)), .idle)
        XCTAssertEqual(DayState(stat: DayStat(day: today, due: 5, done: 5), isFuture: true), .future)

        store.loadDemoData()
        let positiveLevels = Set(store.monthStats.filter { $0.day <= store.today && $0.done > 0 }.map { Theme.level(for: $0.ratio) })
        XCTAssertEqual(positiveLevels, Set(0...7), "Demo covers all eight gold bands")
        XCTAssertTrue(store.monthStats.contains { $0.day < store.today && $0.due == 0 }, "Demo includes a no-task day")
        XCTAssertTrue(store.monthStats.contains { $0.day < store.today && $0.due > 0 && $0.done == 0 }, "Demo includes a zero-completion day")

        let (unchanged, _) = TaskStore.todayFixture()
        let originalTasks = unchanged.sourceTasks
        var updates = 0
        var publications = 0
        unchanged.onUpdate = { updates += 1 }
        let subscription = unchanged.objectWillChange.sink { publications += 1 }
        unchanged.apply(Array(originalTasks.reversed()))
        XCTAssertEqual(updates, 0)
        XCTAssertEqual(publications, 0, "Identical API data in a different order produces no state or cache invalidation")
        unchanged.lastError = "Read failed"
        unchanged.apply(originalTasks)
        XCTAssertNil(unchanged.lastError)
        XCTAssertEqual(updates, 1, "Identical data still recovers a previous load failure")
        let oldDay = unchanged.today
        unchanged.today = unchanged.calendar.date(byAdding: .day, value: 1, to: oldDay)!
        unchanged.apply(originalTasks)
        XCTAssertEqual(unchanged.todayStat.done, 0)
        XCTAssertEqual(unchanged.todayStat.due, 3)
        XCTAssertEqual(updates, 2, "Identical source recomputes overdue work after day rollover")
        subscription.cancel()
    }

    func testOverdueAndHistoricalReconstruction() {
        let (store, _) = TaskStore.todayFixture()
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
        XCTAssertEqual(store.todayStat.due, 3)
        XCTAssertEqual(store.todayStat.done, 0)
        XCTAssertEqual(store.stat(for: yesterday).due, 1)
        XCTAssertFalse(store.stat(for: yesterday).isFull)

        let completedOld = task("recurring-old", due: yesterday, done: today)
        store.apply([completedOld] + newTasks)
        XCTAssertEqual(store.todayStat.due, 3)
        XCTAssertEqual(store.todayStat.done, 1)
        XCTAssertEqual(store.completedTasks.map(\.id), ["recurring-old"])
        XCTAssertEqual(store.stat(for: yesterday).done, 0)

        let completedNew = newTasks.map { task($0.id, due: today, done: today) }
        let nextOccurrence = task("recurring-next", due: tomorrow)
        store.apply([completedOld, nextOccurrence] + completedNew)
        XCTAssertTrue(store.todayStat.isFull)
        XCTAssertEqual(store.todayStat.due, 3)
        XCTAssertFalse(store.stat(for: yesterday).isFull)
        XCTAssertFalse(store.todayTasks.contains { $0.id == "recurring-next" })
        XCTAssertTrue(store.stat(for: tomorrow).isEmpty)

        store.today = tomorrow
        store.apply([completedOld, nextOccurrence] + completedNew)
        XCTAssertEqual(store.todayTasks.map(\.id), ["recurring-next"])
        XCTAssertEqual(store.todayStat.done, 0)
        XCTAssertTrue(store.stat(for: today).isFull)
        XCTAssertFalse(store.stat(for: yesterday).isFull)

        store.today = today
        let backlog = task("older", due: lastMonth)
        store.apply([backlog])
        XCTAssertEqual(store.todayStat.due, 1)
        XCTAssertEqual(store.stat(for: yesterday).due, 1)
        store.apply([task("older", due: lastMonth, done: today)])
        XCTAssertTrue(store.todayStat.isFull)
        XCTAssertFalse(store.stat(for: yesterday).isFull)

        store.apply([task("early", due: today, done: yesterday)])
        XCTAssertTrue(store.todayStat.isFull)
        XCTAssertTrue(store.stat(for: yesterday).isEmpty)

        store.apply([task("unknown", due: yesterday, complete: true)])
        XCTAssertTrue(store.todayStat.isEmpty)
        XCTAssertEqual(store.stat(for: yesterday).done, 0)

        store.apply([task("unknown", due: today, complete: true)])
        XCTAssertTrue(store.todayStat.isFull)

        store.apply([completedOld])
        store.apply([])
        XCTAssertTrue(store.todayStat.isEmpty)
        XCTAssertTrue(store.stat(for: yesterday).isEmpty)

        store.apply([task("rescheduled", due: tomorrow)])
        XCTAssertTrue(store.todayStat.isEmpty)

        store.apply([recurring])
        XCTAssertFalse(store.todayStat.isFull)
        XCTAssertFalse(store.stat(for: yesterday).isFull)

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
        XCTAssertEqual(fresh.stat(for: yesterday).due, 1)
        XCTAssertEqual(fresh.stat(for: yesterday).done, 0)
        XCTAssertTrue(defaults.dataReads.isEmpty)
        XCTAssertEqual(defaults.values.count, 2)
        XCTAssertEqual(defaults.data(forKey: "SandNotch.dayLog.v2"), legacy)

        store.today = cal.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        store.apply([task("year-boundary", due: cal.date(from: DateComponents(year: 2026, month: 12, day: 31)))])
        XCTAssertEqual(store.todayStat.due, 1)
        XCTAssertEqual(store.todayStat.done, 0)
    }

    func testHabitFeedbackSummaries() {
        let (store, _) = TaskStore.todayFixture()
        store.today = store.calendar.date(from: DateComponents(year: 2026, month: 11, day: 26))!
        store.fixtureTasks(count: 5, completed: 2)
        let detail = store.monthDetail(for: store.today)
        XCTAssertTrue(detail.contains("Today · Thursday, November 26, 2026"))
        XCTAssertTrue(detail.contains("2/5 completed · 40%"))
        XCTAssertNil(store.todaySummary)

        let tomorrow = store.calendar.date(byAdding: .day, value: 1, to: store.today)!
        XCTAssertTrue(store.monthDetail(for: tomorrow).contains("Upcoming"))
        XCTAssertFalse(store.monthDetail(for: tomorrow).contains("completed"))

        let yesterday = store.calendar.date(byAdding: .day, value: -1, to: store.today)!
        XCTAssertTrue(store.monthDetail(for: yesterday).contains("Nothing scheduled"))

        store.fixtureTasks(count: 5, completed: 0)
        XCTAssertTrue(store.monthDetail(for: store.today).contains("0/5 completed · 0%"))

        store.fixtureTasks(count: 5, completed: 5)
        XCTAssertEqual(store.todaySummary, "All done for today.")
        XCTAssertEqual(store.goldenMoment, 0)
        let g = NotchGeometry.make(for: nil, rows: 5, offset: 0)
        XCTAssertGreaterThan(g.todayHeight(tasks: store.todayTasks, summary: store.todaySummary),
                             g.todayHeight(tasks: store.todayTasks))

        store.fixtureTasks(count: 0, completed: 0)
        XCTAssertEqual(store.todaySummary, "Nothing scheduled today.")
        XCTAssertFalse(store.todayStat.isFull)
        XCTAssertFalse(store.monthDetail(for: store.today).contains("0/0 completed"))
    }

    func testTaskStatisticsAndHistoryWindowBoundaries() {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        cal.timeZone = .current

        let nov = cal.date(from: DateComponents(year: 2026, month: 11, day: 26))!
        let novStart = TaskStatistics.completedHistoryStart(for: nov, calendar: cal)
        XCTAssertEqual(novStart, cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!)

        let jan = cal.date(from: DateComponents(year: 2027, month: 1, day: 5))!
        let janStart = TaskStatistics.completedHistoryStart(for: jan, calendar: cal)
        XCTAssertEqual(janStart, cal.date(from: DateComponents(year: 2026, month: 12, day: 1))!)

        let janDue = cal.date(from: DateComponents(year: 2027, month: 1, day: 3))!
        let decCompleted = cal.date(from: DateComponents(year: 2026, month: 12, day: 28))!
        let earlyTask = TrackedTask(id: "early-jan", title: "Early", dueDay: janDue, completedDay: decCompleted, isCompleted: true)
        XCTAssertTrue(decCompleted >= janStart, "Scoped completion window retains prior-month early completions")
        let stats = TaskStatistics.monthStats(for: [earlyTask], today: jan, calendar: cal)
        XCTAssertEqual(stats[janDue]?.due, 1)
        XCTAssertEqual(stats[janDue]?.done, 1)
        XCTAssertEqual(TaskStatistics.monthRows(for: nov, calendar: cal).count, 6)
    }

    func testOnDemandAccessWatchAndDayRollover() {
        let store = TaskStore(defaults: MemoryDefaults(), language: LanguageManager(defaults: MemoryDefaults(), preferredLanguages: { ["en"] }))
        store.access = .unknown
        store.updateAccessWatch()
        XCTAssertNotNil(store.accessTimer, "Access watch runs while waiting for permission")
        store.access = .granted
        store.updateAccessWatch()
        XCTAssertNil(store.accessTimer, "Access watch stops once permission is granted")

        let yesterday = store.calendar.date(byAdding: .day, value: -1, to: store.calendar.startOfDay(for: Date()))!
        store.today = yesterday
        store.tick()
        XCTAssertEqual(store.today, store.calendar.startOfDay(for: Date()), "Day rollover immediately updates today")
    }
}
