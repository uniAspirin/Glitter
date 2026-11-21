import Foundation
import XCTest
@testable import Glitter

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@MainActor
final class CraftTests: XCTestCase {
    func testCraftStatesCompletionRhythmRecoveryAndFetchTimeouts() async {
        let completionDuration = Double(CompletionTiming.acknowledge + CompletionTiming.fadeOut) / 1_000_000_000
            + CompletionTiming.movement
        XCTAssertEqual(completionDuration, 0.265, accuracy: 0.000001)
        XCTAssertEqual(CompletionTiming.fadeIn, 0.08)
        XCTAssertEqual(CompletionTiming.protection, 120_000_000)

        let (store, _) = TaskStore.todayFixture()
        let listID = store.selectedCalendarIDs.first!
        store.loaded = false
        store.finishLoad(nil, requestID: store.loadID, calendarIDs: [listID], day: store.today)
        XCTAssertFalse(store.hasStatistics)
        XCTAssertEqual(store.panelStatus, .failed)
        XCTAssertEqual(store.panelMessage.action, .refresh)

        store.fixtureTasks(count: 5, completed: 2)
        let old = store.todayTasks
        store.finishLoad(nil, requestID: store.loadID, calendarIDs: [listID], day: store.today)
        XCTAssertEqual(store.todayTasks, old)
        XCTAssertEqual(store.todayStat.done, 2)
        XCTAssertEqual(store.panelNotice?.action, .refresh)
        XCTAssertFalse(store.canCompleteTasks)

        store.apply(store.sourceTasks)
        XCTAssertTrue(store.canCompleteTasks)
        XCTAssertNil(store.panelNotice)

        let source = store.sourceTasks
        let calendars = store.calendars
        store.calendars = []
        store.reload(preservingContent: true)
        XCTAssertFalse(store.hasStatistics)
        XCTAssertFalse(store.loaded)
        XCTAssertEqual(store.panelStatus, .unavailable)
        store.calendars = calendars
        store.apply(source)
        XCTAssertEqual(store.todayTasks, old)
        XCTAssertEqual(store.todayStat.done, 2)

        store.loadEmptyListDemoData()
        XCTAssertEqual(store.panelMessage.title, "Your list is empty")
        XCTAssertEqual(store.panelMessage.action, .openList)
        store.loadUndatedDemoData()
        XCTAssertTrue(store.todayTasks.isEmpty)
        XCTAssertTrue(store.panelMessage.detail.contains("Undated"))
        store.loadFutureDemoData()
        XCTAssertTrue(store.panelMessage.detail.contains("tomorrow"))
        XCTAssertEqual(store.todayStat.due, 0)
        store.loadDemoData(taskCount: 0, completedCount: 0)
        XCTAssertEqual(store.panelMessage.title, "Nothing scheduled today")
        XCTAssertFalse(store.todayStat.isFull)

        for status: TaskStore.PanelStatus in [.awaitingAccess, .denied, .unselected, .unavailable, .loading, .failed] {
            store.loadStatusDemoData(status)
            XCTAssertFalse(store.hasStatistics)
            XCTAssertFalse(store.canCompleteTasks)
            XCTAssertEqual(store.panelStatus, status)
            XCTAssertFalse(store.panelMessage.detail.isEmpty)
            if status != .loading { XCTAssertNotNil(store.panelMessage.action) }
        }
        store.retryLoad()
        XCTAssertTrue(store.hasStatistics)
        XCTAssertEqual(store.todayStat.due, 5)

        store.loadSaveFailureDemoData()
        let failedID = store.pendingTasks[0].id
        let beforeFailure = store.todayTasks
        await store.completeTask(failedID)
        XCTAssertEqual(store.todayTasks, beforeFailure)
        XCTAssertEqual(store.panelNotice?.action, .retryCompletion)
        await store.retryCompletion()
        XCTAssertNil(store.taskError)
        XCTAssertTrue(store.completedTasks.contains(where: { $0.id == failedID }))

        store.loadUnconfirmedSaveDemoData()
        let unconfirmedID = store.pendingTasks[0].id
        await store.completeTask(unconfirmedID)
        XCTAssertFalse(store.canCompleteTasks)
        XCTAssertEqual(store.panelNotice?.action, .refresh)
        XCTAssertEqual(store.goldenMoment, 0)
        await store.completeTask(unconfirmedID)
        XCTAssertEqual(store.todayStat.done, 0)
        store.retryLoad()
        XCTAssertTrue(store.todayStat.isFull)
        XCTAssertTrue(store.canCompleteTasks)
        XCTAssertNil(store.panelNotice)
        XCTAssertEqual(store.goldenMoment, 0)

        store.loadOverdueDemoData()
        let oldIDs = store.presentationTasks.map(\.id)
        let id = store.pendingTasks.first(where: \.isRecurring)!.id
        let edit = Task { await store.completeTask(id) }
        await Task.yield()
        XCTAssertEqual(store.savingTaskID, id)
        XCTAssertEqual(store.todayStat.done, 0)
        for _ in 0..<500 {
            if store.completionAnchor != nil { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(store.todayStat.done, 1)
        XCTAssertNotNil(store.completionAnchor)
        XCTAssertEqual(store.presentationTasks.map { store.rowAnimationID(for: $0) }, oldIDs)
        XCTAssertEqual(store.todayTasks, store.todayTasks.sorted(by: TrackedTask.precedes))
        let anchored = store.presentationTasks.first(where: { store.rowAnimationID(for: $0) == id })!
        XCTAssertTrue(anchored.isCompleted)
        await edit.value
        XCTAssertNil(store.completionAnchor)
        XCTAssertEqual(store.presentationTasks, store.todayTasks)
        XCTAssertFalse(store.isMutating)

        store.loadDemoData(taskCount: 1, completedCount: 0)
        store.setPresentationDeferred(true)
        let deferredID = store.pendingTasks[0].id
        let deferred = Task { await store.completeTask(deferredID) }
        try? await Task.sleep(nanoseconds: 160_000_000)
        XCTAssertEqual(store.todayStat.done, 0)
        XCTAssertEqual(store.goldenMoment, 0)
        store.setPresentationDeferred(false)
        await deferred.value
        XCTAssertTrue(store.todayStat.isFull)
        XCTAssertEqual(store.goldenMoment, 1)

        store.loadDemoData(taskCount: 1, completedCount: 0)
        store.setPresentationDeferred(true)
        let obsolete = Task { await store.completeTask(store.pendingTasks[0].id) }
        try? await Task.sleep(nanoseconds: 160_000_000)
        store.loadEmptyListDemoData()
        store.setPresentationDeferred(false)
        await obsolete.value
        XCTAssertTrue(store.todayTasks.isEmpty)
        XCTAssertEqual(store.goldenMoment, 0)
        XCTAssertFalse(store.isMutating)

        let resolutions = LockedCounter()
        let cancellations = LockedCounter()
        let request = ReminderFetchRequest(timeout: 0.02) { _ in resolutions.increment() }
        request.attachCancellation { cancellations.increment() }
        try? await Task.sleep(nanoseconds: 80_000_000)
        request.finish(.success([]))
        XCTAssertEqual(resolutions.value, 1)
        XCTAssertEqual(cancellations.value, 1)

        let success = ReminderFetchRequest(timeout: 0.02) { _ in resolutions.increment() }
        success.attachCancellation { cancellations.increment() }
        success.finish(.success([]))
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(resolutions.value, 2)
        XCTAssertEqual(cancellations.value, 1)
    }
}
