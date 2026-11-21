import AppKit
import SwiftUI
import XCTest
@testable import Glitter

@MainActor
final class LocalizationTests: XCTestCase {
    func testSystemLanguageResolutionAndManualPersistence() {
        let zhSystem = LanguageManager(defaults: MemoryDefaults(), preferredLanguages: { ["zh-Hans-CN", "en-US"] })
        XCTAssertEqual(zhSystem.selection, .system)
        XCTAssertEqual(zhSystem.resolved, .chinese)

        let enSystem = LanguageManager(defaults: MemoryDefaults(), preferredLanguages: { ["en-US", "zh-Hans-CN"] })
        XCTAssertEqual(enSystem.selection, .system)
        XCTAssertEqual(enSystem.resolved, .english)

        let defaults = MemoryDefaults()
        let manager = LanguageManager(defaults: defaults, preferredLanguages: { ["en-US"] })
        XCTAssertEqual(manager.resolved, .english)
        manager.setLanguage(.chinese)
        XCTAssertEqual(manager.selection, .chinese)
        XCTAssertEqual(manager.resolved, .chinese)
        XCTAssertEqual(defaults.string(forKey: LanguageManager.defaultsKey), "zh-Hans")

        let relaunched = LanguageManager(defaults: defaults, preferredLanguages: { ["en-US"] })
        XCTAssertEqual(relaunched.selection, .chinese)
        XCTAssertEqual(relaunched.resolved, .chinese)

        relaunched.setLanguage(.system)
        XCTAssertEqual(relaunched.resolved, .english)
        XCTAssertEqual(defaults.string(forKey: LanguageManager.defaultsKey), "system")

        let demoDefaults = DemoDefaults()
        let demoLang = LanguageManager(defaults: demoDefaults, preferredLanguages: { ["en-US"] })
        demoLang.setLanguage(.chinese)
        XCTAssertEqual(demoDefaults.string(forKey: LanguageManager.defaultsKey), "zh-Hans")
        XCTAssertEqual(LanguageManager(defaults: DemoDefaults(), preferredLanguages: { ["en-US"] }).selection, .system)
    }

    func testLiveLanguageSwitchingUpdatesStringsCacheAndViews() async {
        let defaults = MemoryDefaults()
        let language = LanguageManager(defaults: defaults, preferredLanguages: { ["en-US"] })
        let (store, _) = TaskStore.todayFixture(language: language)
        store.today = store.calendar.date(from: DateComponents(year: 2026, month: 11, day: 26))!
        store.fixtureTasks(count: 5, completed: 5)

        let c = NotchPanelController(store: store, defaults: defaults)
        c.screensChanged([DisplayMetrics.fixture(id: 1001, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), notch: 185, isBuiltin: true)])
        defer { c.panel.orderOut(nil) }

        XCTAssertEqual(store.todaySummary, "All done for today.")
        XCTAssertEqual(store.monthTitle, "November")
        XCTAssertEqual(store.l10n.weekdaySymbols, ["M", "T", "W", "T", "F", "S", "S"])
        XCTAssertTrue(store.monthDetail(for: store.today).contains("Today · Thursday, November 26, 2026"))

        let englishDay = c.renderCache.snapshot(page: .day, store: store, state: c.state)
        let englishMonth = c.renderCache.snapshot(page: .month, store: store, state: c.state)
        XCTAssertNotNil(englishDay)
        XCTAssertNotNil(englishMonth)

        var controllerNotifications = 0
        c.onDataChanged = { controllerNotifications += 1 }

        store.setLanguage(.chinese)

        XCTAssertEqual(store.l10n.language, .chinese)
        XCTAssertEqual(store.todaySummary, "今日任务已全部完成。")
        XCTAssertEqual(store.monthTitle, "11月")
        XCTAssertEqual(store.l10n.weekdaySymbols, ["一", "二", "三", "四", "五", "六", "日"])
        XCTAssertTrue(store.monthDetail(for: store.today).contains("今天 · 2026年11月26日 星期四"))
        XCTAssertTrue(store.monthDetail(for: store.today).contains("已完成 5/5 · 100%"))
        XCTAssertEqual(controllerNotifications, 1, "Language change propagates to controller and menus")

        let chineseDay = c.renderCache.snapshot(page: .day, store: store, state: c.state)
        let chineseMonth = c.renderCache.snapshot(page: .month, store: store, state: c.state)
        XCTAssertNotNil(chineseDay)
        XCTAssertNotNil(chineseMonth)
        XCTAssertTrue(chineseDay?.body !== englishDay?.body, "Language switch invalidates cached Day snapshot")
        XCTAssertTrue(chineseMonth?.body !== englishMonth?.body, "Language switch invalidates cached Month snapshot")

        // Render Chinese Today, Month and Settings views for visual review.
        store.loadDemoData(taskCount: 5, completedCount: 2)
        c.state.pinned = true
        c.expand()
        finishAnimation(on: c)
        try? await Task.sleep(nanoseconds: 120_000_000)
        ReviewArtifacts.captureView(c.surfaceView, filename: "zh-day.png")

        c.state.onSelectMonth?()
        finishAnimation(on: c)
        try? await Task.sleep(nanoseconds: 120_000_000)
        ReviewArtifacts.captureView(c.surfaceView, filename: "zh-month.png")

        let loginItems = LoginItemManager(isDemo: true)
        let settingsHost = NSHostingView(rootView: SettingsView(store: store, controller: c, loginItems: loginItems, onRequestAccess: {}))
        settingsHost.frame = NSRect(x: 0, y: 0, width: 380, height: 820)
        ReviewArtifacts.captureView(settingsHost, filename: "zh-settings-demo.png")
    }
}
