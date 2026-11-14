import AppKit
import SwiftUI
MainActor.assumeIsolated { TaskStore.checkTodayModel(); NotchPanelController.checkTodayInteraction() }

Task { @MainActor in
    await TaskStore.checkTaskEditing()
    await TaskStore.checkMultipleLists()
    await TaskStore.checkCraftStates()
    await NotchPanelController.checkCraftPresentation()
    await checkLoginItems()
    exit(0)
}
RunLoop.main.run()
