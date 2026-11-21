import Foundation

struct TrackedTask: Identifiable, Equatable, Sendable {
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

    func isOverdue(on today: Date) -> Bool {
        guard !isCompleted, let dueDay else { return false }
        return dueDay < today
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

struct DayStat: Equatable, Sendable {
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

enum TaskStatistics {
    /// Captures current-month completions and early completions made in the prior month.
    static func completedHistoryStart(for today: Date, calendar: Calendar) -> Date {
        let monthStart = calendar.dateInterval(of: .month, for: today)?.start ?? calendar.startOfDay(for: today)
        return calendar.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
    }

    /// A task belongs to its due day, then each overdue day through its completion day.
    /// Early completion stays credited to the due day; future work is not pulled forward.
    static func belongs(_ task: TrackedTask, to day: Date) -> Bool {
        guard let due = task.dueDay, due <= day else { return false }
        if due == day || !task.isCompleted { return true }
        guard let completed = task.completedDay else { return false }
        return completed >= day
    }

    static func completed(_ task: TrackedTask, by day: Date, today: Date) -> Bool {
        guard task.isCompleted else { return false }
        // A missing completion date cannot establish a past day's completion.
        guard let completed = task.completedDay else { return day == today }
        return completed <= day
    }

    static func monthStats(for tasks: [TrackedTask], today: Date, calendar: Calendar) -> [Date: DayStat] {
        var stats: [Date: DayStat] = [:]
        guard let first = calendar.dateInterval(of: .month, for: today)?.start else { return stats }
        var day = first
        while day <= today {
            let workload = tasks.filter { belongs($0, to: day) }
            stats[day] = DayStat(day: day, due: workload.count,
                                 done: workload.filter { completed($0, by: day, today: today) }.count)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return stats
    }

    static func todayTasks(for tasks: [TrackedTask], today: Date) -> [TrackedTask] {
        tasks.filter { belongs($0, to: today) }.sorted(by: TrackedTask.precedes)
    }

    static func monthDayCount(for today: Date, calendar: Calendar) -> Int {
        calendar.range(of: .day, in: .month, for: today)?.count ?? 30
    }

    /// 本月 7 列网格（周一开头，空位 nil）
    static func monthRows(for today: Date, calendar: Calendar) -> [[Int?]] {
        guard let first = calendar.dateInterval(of: .month, for: today)?.start else { return [] }
        let weekday = calendar.component(.weekday, from: first)
        let offset = (weekday + 5) % 7
        var cells: [Int?] = Array(repeating: nil, count: offset)
        cells.append(contentsOf: (1...monthDayCount(for: today, calendar: calendar)).map { Optional($0) })
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map {
            Array(cells[$0 ..< min($0 + 7, cells.count)])
        }
    }

    static func date(inMonth day: Int, today: Date, calendar: Calendar) -> Date? {
        guard let start = calendar.dateInterval(of: .month, for: today)?.start else { return nil }
        return calendar.date(byAdding: .day, value: day - 1, to: start)
    }
}
