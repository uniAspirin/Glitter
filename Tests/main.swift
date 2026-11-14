import AppKit
import SwiftUI
MainActor.assumeIsolated { TaskStore.checkTodayModel(); NotchPanelController.checkTodayInteraction() }

Task { @MainActor in
    NotchPanelController.checkMenuBarVisibility()
    NotchPanelController.checkHoverEntry()
    await TaskStore.checkTaskEditing()
    await TaskStore.checkMultipleLists()
    await TaskStore.checkCraftStates()
    await NotchPanelController.checkCraftPresentation()
    await checkLoginItems()
    print("PASS all checks completed")
    exit(0)
}
RunLoop.main.run()
