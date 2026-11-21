import AppKit
import XCTest
@testable import Glitter

@MainActor
final class MenuBarTests: XCTestCase {
    func testMenuBarVisibilityPersistenceAndDemoIsolation() {
        func configuredController(defaults: UserDefaults, demo: Bool = false) -> NotchPanelController {
            let (store, _) = TaskStore.todayFixture(
                language: LanguageManager(defaults: defaults, preferredLanguages: { ["en"] })
            )
            if demo { store.loadDemoData() }
            let controller = NotchPanelController(store: store, defaults: defaults)
            controller.hoverTimer?.invalidate()
            return controller
        }

        let defaults = MemoryDefaults()
        defaults.set("keep", forKey: "unrelated.setting")
        let controller = configuredController(defaults: defaults)
        defer { controller.panel.orderOut(nil) }
        var updates = 0
        controller.onDataChanged = { updates += 1 }
        XCTAssertTrue(controller.showsMenuBarIcon)
        controller.setMenuBarIconVisible(false)
        XCTAssertFalse(controller.showsMenuBarIcon)
        XCTAssertEqual(defaults.object(forKey: "Glitter.showMenuBarIcon") as? Bool, false)
        XCTAssertEqual(updates, 1)
        controller.setMenuBarIconVisible(false)
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(defaults.string(forKey: "unrelated.setting"), "keep")

        let relaunched = configuredController(defaults: defaults)
        defer { relaunched.panel.orderOut(nil) }
        XCTAssertFalse(relaunched.showsMenuBarIcon)
        relaunched.setMenuBarIconVisible(true)
        XCTAssertTrue(relaunched.showsMenuBarIcon)
        XCTAssertEqual(defaults.object(forKey: "Glitter.showMenuBarIcon") as? Bool, true)

        XCTAssertNil(controller.state.onTogglePinned)
        controller.togglePinned()
        controller.forceExpandedForDebug()
        XCTAssertFalse(controller.state.pinned || controller.state.expanded)

        let demoDefaults = DemoDefaults()
        let demo = configuredController(defaults: demoDefaults, demo: true)
        defer { demo.panel.orderOut(nil) }
        demo.state.onTogglePinned?()
        XCTAssertTrue(demo.state.pinned && demo.state.expanded)
        demo.collapse()
        XCTAssertTrue(demo.state.expanded)
        demo.state.onTogglePinned?()
        XCTAssertFalse(demo.state.pinned)
        demo.forceExpandedForDebug()
        XCTAssertTrue(demo.state.pinned && demo.state.expanded)
        demo.setMenuBarIconVisible(false)
        XCTAssertEqual(demoDefaults.object(forKey: "Glitter.showMenuBarIcon") as? Bool, false)
        XCTAssertFalse(demoDefaults.bool(forKey: "Glitter.showMenuBarIcon"))
        demoDefaults.set(true, forKey: "Glitter.demoBoolIsolation")
        XCTAssertTrue(demoDefaults.bool(forKey: "Glitter.demoBoolIsolation"))
        XCTAssertFalse(DemoDefaults().bool(forKey: "Glitter.demoBoolIsolation"))
        XCTAssertNil(DemoDefaults().object(forKey: "Glitter.showMenuBarIcon"))
    }
}
