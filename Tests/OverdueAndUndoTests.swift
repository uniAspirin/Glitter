import AppKit
import EventKit
import XCTest
@testable import Glitter

@MainActor
final class OverdueAndUndoTests: XCTestCase {
    func testOverdueDetectionAndVisualDotColor() async throws {
        let writer = FakeReminderMutation()
        let (store, _) = TaskStore.todayFixture(mutationService: writer)
        let today = store.today
        let yesterday = store.calendar.date(byAdding: .day, value: -1, to: today)!
        let tomorrow = store.calendar.date(byAdding: .day, value: 1, to: today)!

        let overdue = TrackedTask(id: "overdue", title: "Overdue reminder", dueDay: yesterday,
                                  completedDay: nil, isCompleted: false, calendarID: store.selectedCalendarIDs.first)
        let dueToday = TrackedTask(id: "today", title: "Today reminder", dueDay: today,
                                   completedDay: nil, isCompleted: false, calendarID: store.selectedCalendarIDs.first)
        let future = TrackedTask(id: "future", title: "Future reminder", dueDay: tomorrow,
                                 completedDay: nil, isCompleted: false, calendarID: store.selectedCalendarIDs.first)
        let undated = TrackedTask(id: "undated", title: "Undated reminder", dueDay: nil,
                                  completedDay: nil, isCompleted: false, calendarID: store.selectedCalendarIDs.first)
        let completedOverdue = TrackedTask(id: "overdue", title: "Overdue reminder", dueDay: yesterday,
                                           completedDay: today, isCompleted: true, calendarID: store.selectedCalendarIDs.first)

        XCTAssertTrue(overdue.isOverdue(on: today))
        XCTAssertFalse(dueToday.isOverdue(on: today))
        XCTAssertFalse(future.isOverdue(on: today))
        XCTAssertFalse(undated.isOverdue(on: today))
        XCTAssertFalse(completedOverdue.isOverdue(on: today))

        let enL10n = L10n(language: .english)
        let zhL10n = L10n(language: .chinese)
        XCTAssertTrue(enL10n.taskPendingAccessibility("Task", saving: false, overdue: true).contains("Overdue"))
        XCTAssertTrue(zhL10n.taskPendingAccessibility("任务", saving: false, overdue: true).contains("已逾期"))

        store.apply([overdue, dueToday])
        let c = NotchPanelController(store: store, defaults: MemoryDefaults())
        c.screensChanged([DisplayMetrics.fixture(id: 1001, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: 185)])
        c.state.pinned = true
        c.expand()
        c.hoverTimer?.invalidate()
        finishAnimation(on: c)
        defer { c.panel.orderOut(nil) }

        let before = ReviewArtifacts.captureView(c.surfaceView, filename: "overdue-day.png")
        let g = c.state.geometry

        func hasRedOverdueDot(in bitmap: NSBitmapImageRep, rowIndex: Int) -> Bool {
            let yStart = g.monthTop + CGFloat(rowIndex) * 26 + 4
            let yEnd = yStart + 18
            var y = yStart
            while y <= yEnd {
                var x = g.horizontalPadding
                while x <= g.horizontalPadding + NotchGeometry.taskMarkerWidth {
                    let px = ReviewArtifacts.samplePixel(bitmap, x: x, y: y)
                    if px[0] > 170 && px[0] > px[1] + 80 && px[0] > px[2] + 80 {
                        return true
                    }
                    x += 0.5
                }
                y += 0.5
            }
            return false
        }

        XCTAssertTrue(hasRedOverdueDot(in: before, rowIndex: 0), "Overdue task renders #FF453A leading dot")
        XCTAssertFalse(hasRedOverdueDot(in: before, rowIndex: 1), "Today task keeps neutral dot")

        func markerCentroid(in bitmap: NSBitmapImageRep, rowIndex: Int) -> CGPoint? {
            let rowTop = g.monthTop + CGFloat(rowIndex) * 26
            var sumX = 0.0
            var sumDY = 0.0
            var totalWeight = 0.0
            var dy: CGFloat = 0
            while dy < 26 {
                var x = g.horizontalPadding
                while x <= g.horizontalPadding + NotchGeometry.taskMarkerWidth {
                    let px = ReviewArtifacts.samplePixel(bitmap, x: x, y: rowTop + dy)
                    let lum = Double(max(px[0], px[1], px[2]))
                    if lum > 20 {
                        sumX += Double(x) * lum
                        sumDY += Double(dy) * lum
                        totalWeight += lum
                    }
                    x += 0.5
                }
                dy += 0.5
            }
            guard totalWeight > 0 else { return nil }
            return CGPoint(x: sumX / totalWeight, y: sumDY / totalWeight)
        }

        writer.result = ReminderMutationResult(tasks: [dueToday, completedOverdue])
        await store.completeTask(overdue.id)
        finishAnimation(on: c)
        let after = ReviewArtifacts.captureView(c.surfaceView, filename: "overdue-completed.png")
        XCTAssertFalse(hasRedOverdueDot(in: after, rowIndex: 0))
        XCTAssertFalse(hasRedOverdueDot(in: after, rowIndex: 1), "Completed overdue task loses overdue color immediately")

        let dotCenter = try XCTUnwrap(markerCentroid(in: before, rowIndex: 0))
        let checkCenter = try XCTUnwrap(markerCentroid(in: after, rowIndex: 1))
        XCTAssertLessThanOrEqual(abs(dotCenter.x - checkCenter.x), 1.0,
                                 "Dot (\(dotCenter)) and checkmark (\(checkCenter)) should share horizontal visual center")
        XCTAssertLessThanOrEqual(abs(dotCenter.y - checkCenter.y), 1.0,
                                 "Dot (\(dotCenter)) and checkmark (\(checkCenter)) should share vertical visual center")
    }

    func testNonRecurringUndoFlowAndRecurringSilence() async {
        let writer = FakeReminderMutation()
        let (store, _) = TaskStore.todayFixture(mutationService: writer)
        let listID = store.selectedCalendarIDs.first!
        let today = store.today
        let tomorrow = store.calendar.date(byAdding: .day, value: 1, to: today)!

        let taskA = TrackedTask(id: "a", title: "First task", dueDay: today, completedDay: nil, isCompleted: false, priority: 1, calendarID: listID)
        let taskB = TrackedTask(id: "b", title: "Second task", dueDay: today, completedDay: nil, isCompleted: false, priority: 5, calendarID: listID)
        let recurring = TrackedTask(id: "rec", title: "Recurring habit", dueDay: today, completedDay: nil, isCompleted: false, priority: 9, isRecurring: true, calendarID: listID)
        store.apply([taskA, taskB, recurring])

        let c = NotchPanelController(store: store, defaults: MemoryDefaults())
        c.screensChanged([DisplayMetrics.fixture(id: 1001, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: 185)])
        c.state.pinned = true
        c.expand()
        c.hoverTimer?.invalidate()
        finishAnimation(on: c)
        defer { c.panel.orderOut(nil) }

        let baselineHeight = c.panel.frame.height
        let baselineMonthTop = c.state.geometry.monthTop

        // Recurring completion must remain completely silent.
        let recDone = TrackedTask(id: "rec-done", title: "Recurring habit", dueDay: today, completedDay: today, isCompleted: true, priority: 9, calendarID: listID)
        let recNext = TrackedTask(id: "rec", title: "Recurring habit", dueDay: tomorrow, completedDay: nil, isCompleted: false, priority: 9, isRecurring: true, calendarID: listID)
        writer.result = ReminderMutationResult(tasks: [taskA, taskB, recDone, recNext], completedOccurrenceID: recDone.id)
        await store.completeTask(recurring.id)
        finishAnimation(on: c)
        XCTAssertNil(store.undoCandidate)
        XCTAssertEqual(c.panel.frame.height, baselineHeight)

        // First non-recurring completion activates inline Undo and keeps panel height unchanged.
        let doneA = TrackedTask(id: "a", title: "First task", dueDay: today, completedDay: today, isCompleted: true, priority: 1, completionDate: today.addingTimeInterval(10), calendarID: listID)
        writer.result = ReminderMutationResult(tasks: [doneA, taskB, recDone, recNext])
        await store.completeTask(taskA.id)
        finishAnimation(on: c)
        XCTAssertEqual(store.undoCandidate?.taskID, taskA.id)
        XCTAssertNotNil(store.presentationUndo)
        XCTAssertEqual(c.state.geometry.monthTop, baselineMonthTop)
        XCTAssertEqual(c.panel.frame.height, baselineHeight)

        // Second non-recurring completion replaces previous undo candidate (single-step).
        let doneB = TrackedTask(id: "b", title: "Second task", dueDay: today, completedDay: today, isCompleted: true, priority: 5, completionDate: today.addingTimeInterval(20), calendarID: listID)
        writer.result = ReminderMutationResult(tasks: [doneA, doneB, recDone, recNext])
        await store.completeTask(taskB.id)
        finishAnimation(on: c)
        XCTAssertEqual(store.undoCandidate?.taskID, taskB.id)
        XCTAssertTrue(store.todayStat.isFull)
        let goldenBeforeUndo = store.goldenMoment
        XCTAssertEqual(goldenBeforeUndo, 1)

        // Undo B via symmetrical EventKit write-back.
        writer.result = ReminderMutationResult(tasks: [doneA, taskB, recDone, recNext])
        await store.undoLastCompletion()
        finishAnimation(on: c)
        XCTAssertEqual(writer.calls.last?.id, taskB.id)
        XCTAssertEqual(writer.calls.last?.completed, false)
        XCTAssertEqual(writer.calls.last?.calendarID, listID)
        XCTAssertNil(store.undoCandidate)
        XCTAssertEqual(c.panel.frame.height, baselineHeight)
        XCTAssertEqual(store.todayStat.done, 2)
        XCTAssertEqual(store.todayStat.due, 3)
        XCTAssertFalse(store.todayStat.isFull)
        XCTAssertTrue(store.pendingTasks.contains(taskB))
        XCTAssertEqual(store.goldenMoment, goldenBeforeUndo)

        // Completing B again reaches 100% and triggers a new golden moment.
        writer.result = ReminderMutationResult(tasks: [doneA, doneB, recDone, recNext])
        await store.completeTask(taskB.id)
        finishAnimation(on: c)
        XCTAssertEqual(store.goldenMoment, goldenBeforeUndo + 1)
    }

    func testUndoCountdownHoverPauseAndCollapseDismissal() async {
        let writer = FakeReminderMutation()
        let (store, _) = TaskStore.todayFixture(mutationService: writer)
        store.undoDuration = 0.14
        let listID = store.selectedCalendarIDs.first!
        let today = store.today
        let taskA = TrackedTask(id: "a", title: "Timed undo", dueDay: today, completedDay: nil, isCompleted: false, calendarID: listID)
        let taskB = TrackedTask(id: "b", title: "Second task", dueDay: today, completedDay: nil, isCompleted: false, calendarID: listID)
        store.apply([taskA, taskB])

        let c = NotchPanelController(store: store, defaults: MemoryDefaults())
        c.screensChanged([DisplayMetrics.fixture(id: 1001, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: 185)])
        c.state.pinned = true
        c.expand()
        c.hoverTimer?.invalidate()
        finishAnimation(on: c)
        defer { c.panel.orderOut(nil) }

        let doneA = TrackedTask(id: "a", title: "Timed undo", dueDay: today, completedDay: today, isCompleted: true, calendarID: listID)
        writer.result = ReminderMutationResult(tasks: [doneA, taskB])
        await store.completeTask(taskA.id)
        finishAnimation(on: c)
        XCTAssertNotNil(store.undoCandidate)

        // Single-row hover tracking bounds must clip strictly to one row, not the entire list.
        func hoverTrackers(in view: NSView) -> [NSView] {
            var found: [NSView] = []
            if String(describing: type(of: view)).contains("HoverTrackingView") {
                found.append(view)
            }
            for subview in view.subviews {
                found.append(contentsOf: hoverTrackers(in: subview))
            }
            return found
        }
        let trackers = hoverTrackers(in: c.surfaceView)
        XCTAssertEqual(trackers.count, 1)
        if let tracker = trackers.first {
            XCTAssertTrue(tracker.clipsToBounds)
            let clipped = tracker.bounds.intersection(tracker.visibleRect)
            XCTAssertGreaterThan(clipped.height, 0)
            XCTAssertLessThanOrEqual(clipped.height, 26.5)
        }

        // Hover holds countdown indefinitely; leaving resets to a fresh full window.
        try? await Task.sleep(nanoseconds: 70_000_000)
        store.setUndoHoverPaused(true)
        try? await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertNotNil(store.undoCandidate, "Hovering the completed row holds its Undo countdown")

        store.setUndoHoverPaused(false)
        try? await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertNotNil(store.undoCandidate, "Leaving resets the full countdown instead of resuming remaining time")
        try? await Task.sleep(nanoseconds: 90_000_000)
        finishAnimation(on: c)
        XCTAssertNil(store.undoCandidate, "Reset countdown expires automatically after full duration")

        // Collapsing within the Undo window preserves Undo so re-expanding still displays it.
        store.undoDuration = 0.40
        let doneB = TrackedTask(id: "b", title: "Second task", dueDay: today, completedDay: today, isCompleted: true, calendarID: listID)
        writer.result = ReminderMutationResult(tasks: [doneA, doneB])
        await store.completeTask(taskB.id)
        finishAnimation(on: c)
        XCTAssertEqual(store.undoCandidate?.taskID, taskB.id)

        c.state.pinned = false
        c.collapse()
        finishAnimation(on: c)
        XCTAssertEqual(c.panel.frame.height, c.state.geometry.collapsedHeight)
        XCTAssertEqual(store.undoCandidate?.taskID, taskB.id, "Temporary collapse preserves active Undo countdown")

        c.state.pinned = true
        c.expand()
        c.hoverTimer?.invalidate()
        finishAnimation(on: c)
        XCTAssertEqual(store.undoCandidate?.taskID, taskB.id)
        XCTAssertEqual(store.presentationUndo?.taskID, taskB.id)

        try? await Task.sleep(nanoseconds: 450_000_000)
        finishAnimation(on: c)
        XCTAssertNil(store.undoCandidate, "Preserved Undo expires after its duration elapses")

        // Collapsing while hover-paused releases hover hold so the countdown still finishes.
        store.apply([taskA, taskB])
        finishAnimation(on: c)
        writer.result = ReminderMutationResult(tasks: [doneA, taskB])
        await store.completeTask(taskA.id)
        finishAnimation(on: c)
        store.setUndoHoverPaused(true)
        c.state.pinned = false
        c.collapse()
        finishAnimation(on: c)
        XCTAssertEqual(store.undoCandidate?.taskID, taskA.id)
        try? await Task.sleep(nanoseconds: 450_000_000)
        finishAnimation(on: c)
        XCTAssertNil(store.undoCandidate, "Collapse releases hover hold so Undo clears cleanly after timeout")
    }

    func testUndoLongScrollingLayoutFailureAndLocalization() async {
        let writer = FakeReminderMutation()
        let defaults = MemoryDefaults()
        let language = LanguageManager(defaults: defaults, preferredLanguages: { ["en"] })
        let (store, _) = TaskStore.todayFixture(mutationService: writer, language: language)
        let listID = store.selectedCalendarIDs.first!
        let today = store.today
        let yesterday = store.calendar.date(byAdding: .day, value: -1, to: today)!

        // Short day screenshot with overdue task + inline Undo button.
        let overdue = TrackedTask(id: "ov", title: "Submit expense report", dueDay: yesterday, completedDay: nil, isCompleted: false, priority: 1, calendarID: listID)
        let shortB = TrackedTask(id: "sb", title: "Review lecture notes", dueDay: today, completedDay: nil, isCompleted: false, priority: 5, calendarID: listID)
        let shortDone = TrackedTask(id: "sb", title: "Review lecture notes", dueDay: today, completedDay: today, isCompleted: true, priority: 5, calendarID: listID)
        store.apply([overdue, shortB])

        let c = NotchPanelController(store: store, defaults: defaults)
        c.screensChanged([DisplayMetrics.fixture(id: 1001, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: 185)])
        c.state.pinned = true
        c.expand()
        c.hoverTimer?.invalidate()
        finishAnimation(on: c)
        defer { c.panel.orderOut(nil) }

        writer.result = ReminderMutationResult(tasks: [overdue, shortDone])
        await store.completeTask(shortB.id)
        finishAnimation(on: c)
        try? await Task.sleep(nanoseconds: 280_000_000)
        ReviewArtifacts.captureView(c.surfaceView, filename: "undo-short-day.png")

        // Chinese localization with inline Undo button.
        store.setLanguage(.chinese)
        finishAnimation(on: c)
        ReviewArtifacts.captureView(c.surfaceView, filename: "undo-zh-day.png")
        store.setLanguage(.english)
        finishAnimation(on: c)

        // External uncompletion reconciles active undo away.
        store.apply([overdue, shortB])
        finishAnimation(on: c)
        XCTAssertNil(store.undoCandidate)

        // Long scrolling list retains maximumExpandedHeight and preserves dayViewportHeight with inline Undo.
        let manyTasks = (0..<15).map { i in
            let title = i == 0 ? "Review lecture notes and send weekly summary" : "Long list task \(i + 1)"
            return TrackedTask(id: "many-\(i)", title: title, dueDay: i == 0 ? yesterday : today,
                               completedDay: nil, isCompleted: false, calendarID: listID)
        }
        store.apply(manyTasks)
        finishAnimation(on: c)
        let maxWithoutUndo = c.state.geometry.dayViewportHeight
        XCTAssertTrue(c.state.geometry.dayScrolls)
        XCTAssertEqual(c.panel.frame.height, c.state.geometry.maximumExpandedHeight)

        let first = manyTasks[0]
        let firstDone = TrackedTask(id: first.id, title: first.title, dueDay: first.dueDay,
                                    completedDay: today, isCompleted: true, calendarID: listID)
        writer.result = ReminderMutationResult(tasks: [firstDone] + Array(manyTasks.dropFirst()))
        await store.completeTask(first.id)
        finishAnimation(on: c)
        XCTAssertEqual(c.panel.frame.height, c.state.geometry.maximumExpandedHeight)
        XCTAssertEqual(c.state.geometry.dayViewportHeight, maxWithoutUndo)
        try? await Task.sleep(nanoseconds: 280_000_000)
        ReviewArtifacts.captureView(c.surfaceView, filename: "undo-long-day.png")

        // Transient undo failure offers retryUndo and recovers.
        writer.error = NSError(domain: "Test", code: 2)
        await store.undoLastCompletion()
        finishAnimation(on: c)
        XCTAssertNil(store.undoCandidate)
        XCTAssertEqual(store.panelNotice?.action, .retryUndo)
        XCTAssertEqual(store.panelNotice?.title, "Couldn't undo this reminder")

        writer.error = nil
        writer.result = ReminderMutationResult(tasks: manyTasks)
        await store.retryUndo()
        finishAnimation(on: c)
        XCTAssertNil(store.taskError)
        XCTAssertNil(store.panelNotice)
        XCTAssertTrue(store.pendingTasks.contains(first))

        // Reconciliation error during undo clears undo and locks completion until refresh.
        writer.result = ReminderMutationResult(tasks: [firstDone] + Array(manyTasks.dropFirst()))
        await store.completeTask(first.id)
        finishAnimation(on: c)
        writer.error = ReminderMutationError.changed
        await store.undoLastCompletion()
        finishAnimation(on: c)
        XCTAssertNil(store.undoCandidate)
        XCTAssertEqual(store.panelNotice?.action, .refresh)
        XCTAssertFalse(store.canCompleteTasks)
    }
}
