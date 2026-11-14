extension TaskStore {
    static func checkCraftStates() async {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); count += 1
        }
        let (store, _) = todayFixture()
        let listID = store.selectedCalendarIDs.first!
        store.loaded = false
        store.finishLoad(nil, requestID: store.loadID, calendarIDs: [listID], day: store.today)
        check(!store.hasStatistics && store.panelStatus == .failed, "An initial read failure never presents a 0/0 day or a calendar")
        check(store.panelMessage.action == .refresh, "An initial read failure has a recovery action")
        store.fixtureTasks(count: 5, completed: 2)
        let old = store.todayTasks
        store.finishLoad(nil, requestID: store.loadID, calendarIDs: [listID], day: store.today)
        check(store.todayTasks == old && store.todayStat.done == 2, "Refresh failure retains last successful counts and tasks")
        check(store.panelNotice?.action == .refresh && !store.canCompleteTasks, "Stale data is labeled and cannot be edited")
        store.apply(store.sourceTasks)
        check(store.canCompleteTasks && store.panelNotice == nil, "Identical fresh data clears the stale warning")
        let source = store.sourceTasks
        let calendars = store.calendars
        store.calendars = []
        store.reload(preservingContent: true)
        check(!store.hasStatistics && !store.loaded && store.panelStatus == .unavailable,
              "A disappeared list invalidates its derived snapshot")
        store.calendars = calendars
        store.apply(source)
        check(store.todayTasks == old && store.todayStat.done == 2,
              "A reappearing list rebuilds even when its source data is unchanged")

        store.loadEmptyListDemoData()
        check(store.panelMessage.title == "Your list is empty" && store.panelMessage.action == .openList, "An empty list explains how to add dated reminders")
        store.loadUndatedDemoData()
        check(store.todayTasks.isEmpty && store.panelMessage.detail.contains("Undated"), "Undated reminders are explained without being counted")
        store.loadFutureDemoData()
        check(store.panelMessage.detail.contains("tomorrow") && store.todayStat.due == 0, "Future work has a quiet next-due explanation")
        store.loadDemoData(taskCount: 0, completedCount: 0)
        check(store.panelMessage.title == "Nothing scheduled today" && !store.todayStat.isFull, "An unscheduled day remains neutral")
        for status: PanelStatus in [.awaitingAccess, .denied, .unselected, .unavailable, .loading, .failed] {
            store.loadStatusDemoData(status)
            check(!store.hasStatistics && !store.canCompleteTasks && store.panelStatus == status, "Demo connection states do not expose stale tasks as current data")
            check(!store.panelMessage.detail.isEmpty, "Each connection state explains what happened")
            if status != .loading { check(store.panelMessage.action != nil, "Each actionable connection state has a recovery route") }
        }
        store.retryLoad()
        check(store.hasStatistics && store.todayStat.due == 5, "Demo retry recovers without accessing EventKit")

        store.loadSaveFailureDemoData()
        let failedID = store.pendingTasks[0].id
        let beforeFailure = store.todayTasks
        await store.completeTask(failedID)
        check(store.todayTasks == beforeFailure && store.panelNotice?.action == .retryCompletion,
              "Failed writes retain original data and offer an explicit retry")
        await store.retryCompletion()
        check(store.taskError == nil && store.completedTasks.contains(where: { $0.id == failedID }), "Retry completes the same failed reminder")

        store.loadUnconfirmedSaveDemoData()
        let unconfirmedID = store.pendingTasks[0].id
        await store.completeTask(unconfirmedID)
        check(!store.canCompleteTasks && store.panelNotice?.action == .refresh && store.goldenMoment == 0,
              "Saved but unconfirmed never offers another write or celebrates prematurely")
        await store.completeTask(unconfirmedID)
        check(store.todayStat.done == 0, "An unconfirmed save blocks duplicate completion attempts")
        store.retryLoad()
        check(store.todayStat.isFull && store.canCompleteTasks && store.panelNotice == nil,
              "Refreshing an unconfirmed save reconciles the native result")
        check(store.goldenMoment == 0, "Reconciliation is not replayed as a new user completion")

        store.loadOverdueDemoData()
        let oldIDs = store.presentationTasks.map(\.id)
        let id = store.pendingTasks.first(where: \.isRecurring)!.id
        let edit = Task { await store.completeTask(id) }
        await Task.yield()
        check(store.savingTaskID == id && store.todayStat.done == 0, "Press feedback is immediate and never optimistic")
        for _ in 0..<500 {
            if store.completionAnchor != nil { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        check(store.todayStat.done == 1 && store.completionAnchor != nil, "Native confirmation updates progress before the row moves")
        check(store.presentationTasks.map { store.rowAnimationID(for: $0) } == oldIDs, "Confirmation retains the original screen positions")
        check(store.todayTasks == store.todayTasks.sorted(by: TrackedTask.precedes), "Source ordering always follows native fields")
        let anchored = store.presentationTasks.first(where: { store.rowAnimationID(for: $0) == id })!
        check(anchored.isCompleted, "The original row is visibly completed during the acknowledgement beat")
        await edit.value
        check(store.completionAnchor == nil && store.presentationTasks == store.todayTasks && !store.isMutating, "Completion settles with no retained custom sort order")

        store.loadDemoData(taskCount: 1, completedCount: 0)
        store.setPresentationDeferred(true)
        let deferredID = store.pendingTasks[0].id
        let deferred = Task { await store.completeTask(deferredID) }
        try? await Task.sleep(nanoseconds: 160_000_000)
        check(store.todayStat.done == 0 && store.goldenMoment == 0, "A save arriving during a window transition waits for its endpoint")
        store.setPresentationDeferred(false)
        await deferred.value
        check(store.todayStat.isFull && store.goldenMoment == 1, "Deferred save still produces exactly one golden moment")

        store.loadDemoData(taskCount: 1, completedCount: 0)
        store.setPresentationDeferred(true)
        let obsolete = Task { await store.completeTask(store.pendingTasks[0].id) }
        try? await Task.sleep(nanoseconds: 160_000_000)
        store.loadEmptyListDemoData()
        store.setPresentationDeferred(false)
        await obsolete.value
        check(store.todayTasks.isEmpty && store.goldenMoment == 0 && !store.isMutating, "Changing context releases a waiting edit and discards its obsolete result")

        var resolutions = 0
        var cancellations = 0
        let request = ReminderFetchRequest(timeout: 0.02) { _ in resolutions += 1 }
        request.attachCancellation { cancellations += 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        request.finish(.success([]))
        check(resolutions == 1 && cancellations == 1, "A timed-out fetch resolves once, cancels its native request and ignores late success")
        let success = ReminderFetchRequest(timeout: 0.02) { _ in resolutions += 1 }
        success.attachCancellation { cancellations += 1 }
        success.finish(.success([]))
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(resolutions == 2 && cancellations == 1, "Successful fetches release their timeout without a second callback")
        print("PASS \(count) completion rhythm, recovery, empty-state and timeout checks")
    }
}

extension TaskStore {
    func loadDemoMonthFixture(month: Int) {
        today = calendar.date(from: DateComponents(year: 2021, month: month, day: 26))!
        loadDemoData()
    }
}
