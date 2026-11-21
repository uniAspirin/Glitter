import EventKit
import Foundation

struct ReminderMutationResult: Sendable {
    let tasks: [TrackedTask]
    /// Used only to animate a newly materialized completed occurrence, never to order rows.
    var completedOccurrenceID: String? = nil
}

enum ReminderMutationError: LocalizedError, Equatable, Sendable {
    case access, changed, unavailable, readFailure, refreshAfterSave

    var errorDescription: String? {
        L10n(language: AppLanguage.system.resolved()).mutationError(self)
    }

    func localizedDescription(with l10n: L10n) -> String {
        l10n.mutationError(self)
    }
}

/// EventKit callbacks can arrive after a timeout. Resolve and cancel exactly once.
final class ReminderFetchRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Result<[EKReminder], Error>) -> Void)?
    private var timeoutWork: DispatchWorkItem?
    private var cancel: (@Sendable () -> Void)?
    private var cancelledBeforeAttach = false

    init(timeout seconds: TimeInterval = 10,
         completion: @escaping @Sendable (Result<[EKReminder], Error>) -> Void) {
        self.completion = completion
        let item = DispatchWorkItem {
            self.finish(.failure(ReminderMutationError.readFailure), cancelRequest: true)
        }
        timeoutWork = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func attachCancellation(_ cancel: @escaping @Sendable () -> Void) {
        var runImmediately = false
        lock.lock()
        if cancelledBeforeAttach {
            runImmediately = true
            cancelledBeforeAttach = false
        } else if completion != nil {
            self.cancel = cancel
        }
        lock.unlock()
        if runImmediately { cancel() }
    }

    func finish(_ result: Result<[EKReminder], Error>, cancelRequest: Bool = false) {
        lock.lock()
        guard let completion else {
            lock.unlock()
            return
        }
        self.completion = nil
        let timeoutWork = self.timeoutWork
        self.timeoutWork = nil
        let cancel = self.cancel
        self.cancel = nil
        if cancelRequest && cancel == nil {
            cancelledBeforeAttach = true
        }
        lock.unlock()

        timeoutWork?.cancel()
        if cancelRequest { cancel?() }
        completion(result)
    }
}

enum ScopedReminderFetch {
    private final class Box<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var remaining = 2
        var failed = false
        var finished = false
        var cancelled = false
        var collected: [[EKReminder]] = []
        var tokens: [Any] = []
    }

    static func merge(_ lists: [[EKReminder]]) -> [EKReminder] {
        var byID: [String: EKReminder] = [:]
        for reminder in lists.joined() {
            let id = reminder.calendarItemIdentifier
            if let existing = byID[id] {
                let newModified = reminder.lastModifiedDate ?? .distantPast
                let oldModified = existing.lastModifiedDate ?? .distantPast
                if newModified > oldModified
                    || (newModified == oldModified && reminder.isCompleted && !existing.isCompleted) {
                    byID[id] = reminder
                }
            } else {
                byID[id] = reminder
            }
        }
        return Array(byID.values)
    }

    @discardableResult
    static func start(
        store: EKEventStore,
        calendars: [EKCalendar],
        completedSince: Date,
        completion: @escaping @Sendable ([EKReminder]?) -> Void
    ) -> @Sendable () -> Void {
        let state = State()
        let storeBox = Box(store)
        let incomplete = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        let completed = store.predicateForCompletedReminders(withCompletionDateStarting: completedSince, ending: nil, calendars: calendars)

        @Sendable func handle(_ reminders: [EKReminder]?) {
            var resolved: [EKReminder]?
            var shouldComplete = false
            state.lock.lock()
            if !state.finished {
                if let reminders {
                    state.collected.append(reminders)
                } else {
                    state.failed = true
                }
                state.remaining -= 1
                if state.remaining == 0 {
                    state.finished = true
                    shouldComplete = true
                    resolved = state.failed ? nil : merge(state.collected)
                    state.collected.removeAll()
                }
            }
            state.lock.unlock()
            if shouldComplete {
                completion(resolved)
            }
        }

        let tokenA = store.fetchReminders(matching: incomplete) { reminders in
            handle(reminders)
        }
        let tokenB = store.fetchReminders(matching: completed) { reminders in
            handle(reminders)
        }

        state.lock.lock()
        let shouldCancel = state.cancelled
        if !state.finished && !state.cancelled {
            state.tokens = [tokenA, tokenB]
        }
        state.lock.unlock()

        if shouldCancel {
            store.cancelFetchRequest(tokenA)
            store.cancelFetchRequest(tokenB)
        }

        return {
            state.lock.lock()
            let tokens = state.finished ? [] : state.tokens
            state.cancelled = true
            state.finished = true
            state.tokens.removeAll()
            state.collected.removeAll()
            state.lock.unlock()
            for token in tokens {
                storeBox.value.cancelFetchRequest(token)
            }
        }
    }
}

protocol ReminderMutationService: Sendable {
    func setCompleted(_ completed: Bool, task: TrackedTask, calendarID: String,
                      calendar: Calendar, completedSince: Date) async throws -> ReminderMutationResult
}

extension TrackedTask {
    init(reminder: EKReminder, calendar: Calendar) {
        let due = reminder.dueDateComponents.flatMap { calendar.date(from: $0) }
        self.init(id: reminder.calendarItemIdentifier, title: reminder.title ?? "",
                  dueDay: due.map { calendar.startOfDay(for: $0) },
                  completedDay: reminder.completionDate.map { calendar.startOfDay(for: $0) },
                  isCompleted: reminder.isCompleted, priority: reminder.priority,
                  dueDate: due, completionDate: reminder.completionDate,
                  isRecurring: !(reminder.recurrenceRules ?? []).isEmpty,
                  calendarID: reminder.calendar.calendarIdentifier)
    }
}

/// A separate actor + store isolates writes off the main actor and regular read/refresh pipeline.
actor EventKitReminderMutation: ReminderMutationService {
    private let store = EKEventStore()

    private func fetch(calendarID: String, completedSince: Date) async throws -> [EKReminder] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw ReminderMutationError.access
        }
        guard let list = store.calendar(withIdentifier: calendarID) else {
            throw ReminderMutationError.unavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            let request = ReminderFetchRequest { continuation.resume(with: $0) }
            let cancel = ScopedReminderFetch.start(
                store: store,
                calendars: [list],
                completedSince: completedSince
            ) { reminders in
                request.finish(reminders.map { .success($0) } ?? .failure(ReminderMutationError.readFailure))
            }
            request.attachCancellation(cancel)
        }
    }

    func setCompleted(_ completed: Bool, task: TrackedTask, calendarID: String,
                      calendar: Calendar, completedSince: Date) async throws -> ReminderMutationResult {
        store.reset()
        let before = try await fetch(calendarID: calendarID, completedSince: completedSince)
        guard let original = before.first(where: { $0.calendarItemIdentifier == task.id }),
              original.calendar.calendarIdentifier == calendarID else {
            throw ReminderMutationError.unavailable
        }
        guard original.isCompleted == task.isCompleted else {
            throw ReminderMutationError.changed
        }
        let old = TrackedTask(reminder: original, calendar: calendar)
        if !completed && old.isRecurring {
            throw ReminderMutationError.changed
        }
        // An ID can now refer to the advanced next occurrence after an external edit.
        guard old.dueDate == task.dueDate else {
            throw ReminderMutationError.changed
        }
        let previousIDs = Set(before.map(\.calendarItemIdentifier))
        let started = Date()
        original.isCompleted = completed
        if !completed { original.completionDate = nil }
        try store.save(original, commit: true)

        // Saving a recurring reminder may advance this very ID to the next due date.
        // Refetch; never synthesize or delete the next occurrence and never change it back.
        for delay: UInt64 in [0, 80_000_000, 200_000_000, 400_000_000, 800_000_000] {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            store.reset()
            guard let reminders = try? await fetch(calendarID: calendarID, completedSince: completedSince) else {
                throw ReminderMutationError.refreshAfterSave
            }
            let tasks = reminders.map { TrackedTask(reminder: $0, calendar: calendar) }
            if tasks.contains(where: { $0.id == task.id && $0.isCompleted == completed }) {
                return ReminderMutationResult(tasks: tasks)
            }
            if completed && old.isRecurring {
                // Only newly returned records can be the materialized completed occurrence.
                // An ambiguous match is not used for UI identity, and never drives another write.
                let candidates = tasks.filter {
                    !previousIDs.contains($0.id) && $0.isCompleted && $0.title == old.title
                        && $0.dueDate == old.dueDate && $0.priority == old.priority
                        && ($0.completionDate ?? .distantPast) >= started.addingTimeInterval(-2)
                }
                if !candidates.isEmpty {
                    return ReminderMutationResult(
                        tasks: tasks,
                        completedOccurrenceID: candidates.count == 1 ? candidates[0].id : nil
                    )
                }
            }
        }
        throw ReminderMutationError.refreshAfterSave
    }
}
