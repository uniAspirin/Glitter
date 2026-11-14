import AppKit
import EventKit
import Foundation

// Standalone, explicitly invoked probe. Never fetches reminders outside its own new calendar.
@MainActor
final class RecurrenceProbe: NSObject, NSApplicationDelegate {
    let store = EKEventStore()
    let token = UUID().uuidString
    let output = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "ProbeOutputPath") as! String)
    var report: [String: Any] = [:]
    var window: NSWindow!
    var label: NSTextField!
    var calendarID: String?
    var calendarName: String?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    var zoneCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 230),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Glitter API Test"
        window.isReleasedWhenClosed = false
        label = NSTextField(wrappingLabelWithString: "Preparing isolated Reminders API test…")
        label.frame = NSRect(x: 24, y: 25, width: 512, height: 175)
        label.font = .systemFont(ofSize: 14)
        window.contentView!.addSubview(label)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await run() }
    }

    func persist() {
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output, options: .atomic)
        }
    }

    func status(_ text: String) { label.stringValue = text; persist() }

    func snapshot(_ r: EKReminder) -> [String: Any] {
        let date: (DateComponents?) -> String = { components in
            guard let components, let d = self.zoneCalendar.date(from: components) else { return "nil" }
            return ISO8601DateFormatter().string(from: d)
        }
        return ["id": r.calendarItemIdentifier, "title": r.title ?? "", "completed": r.isCompleted,
                "due": date(r.dueDateComponents), "start": date(r.startDateComponents),
                "completionDate": r.completionDate.map { ISO8601DateFormatter().string(from: $0) } ?? "nil",
                "rules": (r.recurrenceRules ?? []).map { ["frequency": $0.frequency.rawValue, "interval": $0.interval] }]
    }

    func fetchOwnCalendar() async throws -> [EKReminder] {
        guard let calendarID, let own = store.calendar(withIdentifier: calendarID), own.title == calendarName else {
            throw NSError(domain: "Probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Owned test calendar is missing; stopped safely."])
        }
        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: store.predicateForReminders(in: [own])) { reminders in
                if let reminders { continuation.resume(returning: reminders) }
                else { continuation.resume(throwing: NSError(domain: "Probe", code: 2)) }
            }
        }
    }

    func settle(_ scenarioToken: String) async throws -> [[String: Any]] {
        var observations: [[String: Any]] = []
        for delay in [0.3, 1.0, 3.0] {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            store.reset()
            let items = try await fetchOwnCalendar().filter { $0.notes == scenarioToken || $0.title == "API test only — \(scenarioToken.split(separator: ":").last!)" }
            observations.append(["delaySeconds": delay, "items": items.map(snapshot)])
        }
        return observations
    }

    func runScenario(_ name: String, overdue: Bool, recurring: Bool) async throws -> [String: Any] {
        guard let own = store.calendar(withIdentifier: calendarID!) else { throw NSError(domain: "Probe", code: 3) }
        let today = zoneCalendar.startOfDay(for: Date())
        let due = zoneCalendar.date(byAdding: .day, value: overdue ? -1 : 0, to: today)!
        let scenarioToken = "\(token):\(name)"
        let r = EKReminder(eventStore: store)
        r.calendar = own
        r.title = "API test only — \(name)"
        r.notes = scenarioToken
        let components = zoneCalendar.dateComponents([.year, .month, .day], from: due)
        r.startDateComponents = components
        r.dueDateComponents = components
        if recurring { r.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)) }
        try store.save(r, commit: true)
        let originalID = r.calendarItemIdentifier
        var result: [String: Any] = ["name": name, "initial": snapshot(r)]
        r.isCompleted = true
        try store.save(r, commit: true)
        result["originalImmediatelyAfterComplete"] = snapshot(r)
        result["afterComplete"] = try await settle(scenarioToken)

        let current = try await fetchOwnCalendar().filter { $0.notes == scenarioToken || $0.title == "API test only — \(name)" }
        // A generated next occurrence must never be mistaken for the completed original.
        let candidates = current.filter { $0.isCompleted && ($0.calendarItemIdentifier == originalID || $0.dueDateComponents.flatMap { zoneCalendar.date(from: $0) }.map { zoneCalendar.isDate($0, inSameDayAs: due) } == true) }
        guard candidates.count == 1 else {
            result["uncompleteSkipped"] = "Could not uniquely identify the completed original. Did not change the next occurrence."
            return result
        }
        let original = candidates[0]
        result["originalBeforeUncomplete"] = snapshot(original)
        original.isCompleted = false
        try store.save(original, commit: true)
        result["originalImmediatelyAfterUncomplete"] = snapshot(original)
        result["afterUncomplete"] = try await settle(scenarioToken)
        return result
    }

    func cleanup() async {
        guard let calendarID else { return }
        do {
            let items = try await fetchOwnCalendar()
            guard items.allSatisfy({ $0.notes?.hasPrefix(token + ":") == true }),
                  let own = store.calendar(withIdentifier: calendarID), own.title == calendarName else {
                report["cleanup"] = "Skipped: the calendar contains an unrecognized item."
                return
            }
            try store.removeCalendar(own, commit: true)
            store.reset()
            report["cleanup"] = store.calendar(withIdentifier: calendarID) == nil ? "Test calendar removed" : "Calendar removal not yet reflected"
        } catch { report["cleanup"] = "Failed: \(error.localizedDescription)" }
    }

    func runProductionWriter(_ name: String, overdue: Bool, recurring: Bool) async throws -> [String: Any] {
        guard let own = store.calendar(withIdentifier: calendarID!) else { throw NSError(domain: "Probe", code: 3) }
        let today = zoneCalendar.startOfDay(for: Date())
        let due = zoneCalendar.date(byAdding: .day, value: overdue ? -1 : 0, to: today)!
        let r = EKReminder(eventStore: store)
        r.calendar = own
        r.title = "Writer test only — \(name)"
        r.notes = "\(token):\(name)"
        r.priority = 1
        let components = zoneCalendar.dateComponents([.year, .month, .day], from: due)
        r.startDateComponents = components
        r.dueDateComponents = components
        if recurring { r.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)) }
        try store.save(r, commit: true)
        let initial = TrackedTask(reminder: r, calendar: zoneCalendar)
        let writer = EventKitReminderMutation()
        func items(_ result: ReminderMutationResult) -> [[String: Any]] {
            result.tasks.filter { $0.title == initial.title }.map {
                ["id": $0.id, "completed": $0.isCompleted, "priority": $0.priority,
                 "due": $0.dueDate.map { ISO8601DateFormatter().string(from: $0) } ?? "nil",
                 "recurring": $0.isRecurring]
            }
        }
        var result: [String: Any] = ["name": name, "initialID": initial.id]
        let completed = try await writer.setCompleted(true, task: initial, calendarID: calendarID!, calendar: zoneCalendar)
        result["afterComplete"] = items(completed)
        let finishedID = completed.completedOccurrenceID ?? initial.id
        guard let finished = completed.tasks.first(where: { $0.id == finishedID && $0.isCompleted }) else {
            throw NSError(domain: "Probe", code: 10, userInfo: [NSLocalizedDescriptionKey: "Production writer did not identify the completed occurrence."])
        }
        if recurring {
            guard completed.completedOccurrenceID != nil, finishedID != initial.id,
                  completed.tasks.contains(where: { $0.id == initial.id && $0.isRecurring && !$0.isCompleted && $0.dueDay! > today }) else {
                throw NSError(domain: "Probe", code: 11)
            }
            do {
                _ = try await writer.setCompleted(true, task: initial, calendarID: calendarID!, calendar: zoneCalendar)
                throw NSError(domain: "Probe", code: 12, userInfo: [NSLocalizedDescriptionKey: "Stale recurring ID was not rejected."])
            } catch ReminderMutationError.changed {
                result["staleOccurrenceRejected"] = true
            }
        }
        let undone = try await writer.setCompleted(false, task: finished, calendarID: calendarID!, calendar: zoneCalendar)
        result["afterUncomplete"] = items(undone)
        guard let restored = undone.tasks.first(where: { $0.id == finishedID && !$0.isCompleted && $0.dueDay == due }) else {
            throw NSError(domain: "Probe", code: 13)
        }
        let repeated = try await writer.setCompleted(true, task: restored, calendarID: calendarID!, calendar: zoneCalendar)
        result["afterCompleteAgain"] = items(repeated)
        let ownItems = repeated.tasks.filter { $0.title == initial.title }
        guard ownItems.count == (recurring ? 2 : 1), ownItems.filter(\.isCompleted).count == 1 else {
            throw NSError(domain: "Probe", code: 14)
        }
        result["verified"] = true
        return result
    }

    func run() async {
        report = ["started": ISO8601DateFormatter().string(from: Date()),
                  "os": ProcessInfo.processInfo.operatingSystemVersionString, "timezone": "Asia/Shanghai",
                  "scope": "Only a newly created test calendar; no existing reminder items fetched or modified.",
                  "status": "awaiting-access"]
        status("This test needs Reminders access.\n\nPlease allow the macOS prompt to continue. Only a new temporary test list with fake tasks will be accessed.")
        do {
            let granted = try await store.requestFullAccessToReminders()
            guard granted else { throw NSError(domain: "Probe", code: 4, userInfo: [NSLocalizedDescriptionKey: "Reminders access was not granted. No test list was created."]) }
            guard let source = store.defaultCalendarForNewReminders()?.source else {
                throw NSError(domain: "Probe", code: 5, userInfo: [NSLocalizedDescriptionKey: "No default Reminders source is available."])
            }
            let own = EKCalendar(for: .reminder, eventStore: store)
            own.title = "Glitter API Test \(token.prefix(8))"
            own.source = source
            try store.saveCalendar(own, commit: true)
            calendarID = own.calendarIdentifier
            calendarName = own.title
            report["testCalendar"] = own.title
            report["status"] = "running"
            persist()
            var scenarios: [[String: Any]] = []
            for scenario in [("ordinary-overdue", true, false), ("daily-today", false, true), ("daily-overdue", true, true)] {
                status("Testing \(scenario.0)…\n\nOnly temporary fake tasks are being modified. Results will be saved locally.")
                if Bundle.main.object(forInfoDictionaryKey: "ProductionWriterProbe") as? Bool == true {
                    scenarios.append(try await runProductionWriter(scenario.0, overdue: scenario.1, recurring: scenario.2))
                } else {
                    scenarios.append(try await runScenario(scenario.0, overdue: scenario.1, recurring: scenario.2))
                }
                report["scenarios"] = scenarios
                persist()
            }
            report["status"] = "complete"
        } catch {
            report["status"] = "error"
            report["error"] = error.localizedDescription
        }
        await cleanup()
        report["finished"] = ISO8601DateFormatter().string(from: Date())
        status("API test \(report["status"] as? String ?? "finished").\n\n\(report["cleanup"] as? String ?? report["error"] as? String ?? "")\n\nResults: \(output.path)")
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = RecurrenceProbe()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
