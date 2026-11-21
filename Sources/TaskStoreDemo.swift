#if DEBUG || DEMO
import EventKit
import Foundation

final class DemoDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
    override func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    override func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

extension TaskStore {
    func performDemoMutation(_ task: TrackedTask) async throws -> ReminderMutationResult {
        try await Task.sleep(nanoseconds: demoWriteBehavior == .slow ? 900_000_000 : 100_000_000)
        if demoWriteBehavior == .failed { throw NSError(domain: "Glitter.Demo", code: 1) }
        let result = demoMutation(task)
        if demoWriteBehavior == .unconfirmed {
            demoRecoveryTasks = result.tasks
            throw ReminderMutationError.refreshAfterSave
        }
        return result
    }

    func performDemoUndoMutation(_ task: TrackedTask) async throws -> ReminderMutationResult {
        try await Task.sleep(nanoseconds: demoWriteBehavior == .slow ? 900_000_000 : 100_000_000)
        if demoWriteBehavior == .failed { throw NSError(domain: "Glitter.Demo", code: 1) }
        let reverted = TrackedTask(
            id: task.id,
            title: task.title,
            dueDay: task.dueDay,
            completedDay: nil,
            isCompleted: false,
            priority: task.priority,
            dueDate: task.dueDate,
            completionDate: nil,
            isRecurring: false,
            calendarID: task.calendarID
        )
        let tasks = sourceTasks.filter { $0.id != task.id } + [reverted]
        let result = ReminderMutationResult(tasks: tasks)
        if demoWriteBehavior == .unconfirmed {
            demoRecoveryTasks = result.tasks
            throw ReminderMutationError.refreshAfterSave
        }
        return result
    }

    func performDemoRetryLoad() {
        if let tasks = demoRecoveryTasks {
            demoRecoveryTasks = nil
            demoWriteBehavior = .normal
            apply(tasks)
        } else {
            loadDemoData()
        }
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
}
#endif
