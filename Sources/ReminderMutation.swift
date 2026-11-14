import EventKit
import Foundation

struct ReminderMutationResult {
    let tasks: [TrackedTask]
    /// Used only to animate a newly materialized completed occurrence, never to order rows.
    var completedOccurrenceID: String? = nil
}

enum ReminderMutationError: LocalizedError, Equatable {
    case access, changed, unavailable, readFailure, refreshAfterSave
    var errorDescription: String? {
        switch self {
        case .access: return "Reminders access is required."
        case .changed: return "This reminder changed. Refresh and try again."
        case .unavailable: return "This reminder is no longer available."
        case .readFailure: return "Reminders isn't responding. Please try again."
        case .refreshAfterSave: return "Saved in Reminders. Refresh to confirm the result."
        }
    }
}

/// EventKit callbacks can arrive after a timeout. Resolve and cancel exactly once.
@MainActor
final class ReminderFetchRequest {
    private var completion: ((Result<[EKReminder], Error>) -> Void)?
    private var timeout: Timer?
    private var cancel: (() -> Void)?

    init(timeout seconds: TimeInterval = 10, completion: @escaping (Result<[EKReminder], Error>) -> Void) {
        self.completion = completion
        let timer = Timer(timeInterval: seconds, repeats: false) { [self] _ in
            MainActor.assumeIsolated { finish(.failure(ReminderMutationError.readFailure), cancelRequest: true) }
        }
        timeout = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func attachCancellation(_ cancel: @escaping () -> Void) { self.cancel = cancel }

    func finish(_ result: Result<[EKReminder], Error>, cancelRequest: Bool = false) {
        guard let completion else { return }
        self.completion = nil
        timeout?.invalidate()
        timeout = nil
        if cancelRequest { cancel?() }
        cancel = nil
        completion(result)
    }
}

@MainActor
protocol ReminderMutationService {
    func setCompleted(_ completed: Bool, task: TrackedTask, calendarID: String,
                      calendar: Calendar) async throws -> ReminderMutationResult
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

/// A separate store isolates writes from the regular read/refresh pipeline.
@MainActor
final class EventKitReminderMutation: ReminderMutationService {
    private let store = EKEventStore()

    private func fetch(calendarID: String) async throws -> [EKReminder] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw ReminderMutationError.access
        }
        guard let list = store.calendar(withIdentifier: calendarID) else { throw ReminderMutationError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            let request = ReminderFetchRequest { continuation.resume(with: $0) }
            let identifier = store.fetchReminders(matching: store.predicateForReminders(in: [list])) { [weak request] reminders in
                DispatchQueue.main.async {
                    request?.finish(reminders.map { .success($0) } ?? .failure(ReminderMutationError.readFailure))
                }
            }
            request.attachCancellation { [store] in store.cancelFetchRequest(identifier) }
        }
    }

    func setCompleted(_ completed: Bool, task: TrackedTask, calendarID: String,
                      calendar: Calendar) async throws -> ReminderMutationResult {
        store.reset()
        let before = try await fetch(calendarID: calendarID)
        guard let original = before.first(where: { $0.calendarItemIdentifier == task.id }),
              original.calendar.calendarIdentifier == calendarID else { throw ReminderMutationError.unavailable }
        guard original.isCompleted == task.isCompleted else { throw ReminderMutationError.changed }
        let old = TrackedTask(reminder: original, calendar: calendar)
        // An ID can now refer to the advanced next occurrence after an external edit.
        guard old.dueDate == task.dueDate else { throw ReminderMutationError.changed }
        let previousIDs = Set(before.map(\.calendarItemIdentifier))
        let started = Date()
        original.isCompleted = completed
        try store.save(original, commit: true)

        // Saving a recurring reminder may advance this very ID to the next due date.
        // Refetch; never synthesize or delete the next occurrence and never change it back.
        for delay: UInt64 in [0, 80_000_000, 200_000_000, 400_000_000, 800_000_000] {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            store.reset()
            guard let reminders = try? await fetch(calendarID: calendarID) else { throw ReminderMutationError.refreshAfterSave }
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
                    return ReminderMutationResult(tasks: tasks,
                        completedOccurrenceID: candidates.count == 1 ? candidates[0].id : nil)
                }
            }
        }
        throw ReminderMutationError.refreshAfterSave
    }
}
