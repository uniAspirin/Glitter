import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Equatable, Sendable {
    case system = "system"
    case english = "en"
    case chinese = "zh-Hans"

    enum Resolved: String, Equatable, Sendable {
        case english = "en"
        case chinese = "zh-Hans"

        var locale: Locale {
            switch self {
            case .english: return Locale(identifier: "en_US_POSIX")
            case .chinese: return Locale(identifier: "zh_Hans_CN")
            }
        }
    }

    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> Resolved {
        switch self {
        case .english: return .english
        case .chinese: return .chinese
        case .system:
            if let first = preferredLanguages.first?.lowercased(), first.hasPrefix("zh") {
                return .chinese
            }
            return .english
        }
    }
}

@MainActor
final class LanguageManager: ObservableObject {
    static let defaultsKey = "Glitter.appLanguage"

    @Published private(set) var selection: AppLanguage
    private let defaults: UserDefaults
    private let preferredLanguages: () -> [String]
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard,
         preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        if let raw = defaults.string(forKey: Self.defaultsKey),
           let saved = AppLanguage(rawValue: raw) {
            selection = saved
        } else {
            selection = .system
        }
    }

    var resolved: AppLanguage.Resolved {
        selection.resolved(preferredLanguages: preferredLanguages())
    }

    var strings: L10n { L10n(language: resolved) }

    func setLanguage(_ language: AppLanguage) {
        guard language != selection else { return }
        selection = language
        defaults.set(language.rawValue, forKey: Self.defaultsKey)
        onChange?()
    }
}

struct L10n: Equatable, Sendable {
    let language: AppLanguage.Resolved

    private var isChinese: Bool { language == .chinese }
    var locale: Locale { language.locale }

    // MARK: - Formatting

    var monthNameDateFormat: String { isChinese ? "M月" : "MMMM" }
    var dayDetailDateFormat: String { isChinese ? "yyyy年M月d日 EEEE" : "EEEE, MMMM d, yyyy" }
    var nextDueDateFormat: String { isChinese ? "M月d日 EEEE" : "EEEE, MMM d" }
    var tomorrowWord: String { isChinese ? "明天" : "tomorrow" }

    func monthYearAccessibleLabel(monthTitle: String, year: Int, goldenDays: Int) -> String {
        if isChinese {
            return "\(year)年 \(monthTitle)，\(goldenDays) 个全完成日"
        }
        let unit = goldenDays == 1 ? "Golden Day" : "Golden Days"
        return "\(monthTitle) \(year), \(goldenDays) \(unit)"
    }

    func goldenDaysHelp(_ count: Int) -> String {
        if isChinese { return "本月 \(count) 个全完成日" }
        return "\(count) \(count == 1 ? "Golden Day" : "Golden Days") this month"
    }

    func monthDetail(formattedDate: String, isToday: Bool, isFuture: Bool, due: Int, done: Int, ratio: Double) -> String {
        let prefix = isToday ? (isChinese ? "今天 · " : "Today · ") : ""
        let title = prefix + formattedDate
        if isFuture {
            return "\(title)\n\(isChinese ? "未来日期" : "Upcoming")"
        }
        if due == 0 {
            return "\(title)\n\(isChinese ? "暂无安排" : "Nothing scheduled")"
        }
        let percent = Int((ratio * 100).rounded())
        if isChinese {
            return "\(title)\n已完成 \(done)/\(due) · \(percent)%"
        }
        return "\(title)\n\(done)/\(due) completed · \(percent)%"
    }

    var weekdaySymbols: [String] {
        isChinese ? ["一", "二", "三", "四", "五", "六", "日"] : ["M", "T", "W", "T", "F", "S", "S"]
    }

    // MARK: - Summary & List Names

    var noListSelected: String { isChinese ? "未选择列表" : "No list selected" }
    func multipleListsName(_ count: Int) -> String {
        isChinese ? "\(count) 个列表" : "\(count) lists"
    }

    var summaryEmptyToday: String { isChinese ? "今日暂无安排。" : "Nothing scheduled today." }
    var summaryAllDoneToday: String { isChinese ? "今日任务已全部完成。" : "All done for today." }

    // MARK: - Panel Status

    func panelStatusTitle(for status: TaskStore.PanelStatus) -> String {
        switch status {
        case .awaitingAccess: return isChinese ? "等待提醒事项权限" : "Waiting for Reminders access"
        case .denied: return isChinese ? "需要提醒事项权限" : "Reminders access required"
        case .unselected: return isChinese ? "请选择要跟踪的列表" : "Choose a list to track"
        case .unavailable: return isChinese ? "所选列表不可用" : "Tracked list unavailable"
        case .loading: return isChinese ? "正在加载提醒事项…" : "Loading reminders…"
        case .failed: return isChinese ? "无法加载提醒事项" : "Unable to load reminders"
        case .empty: return isChinese ? "今日暂无任务" : "No tasks for today"
        case .ready: return isChinese ? "已完成 / 今日任务" : "Completed / Today’s tasks"
        }
    }

    // MARK: - Errors & Notices

    var readRemindersFailed: String { isChinese ? "无法读取提醒事项，请重试。" : "Unable to read reminders. Please try again." }
    var genericCompletionFailed: String { isChinese ? "任务未发生变化，请稍后重试。" : "Your reminder is still here. Try again when you're ready." }

    func mutationError(_ error: ReminderMutationError) -> String {
        switch error {
        case .access: return isChinese ? "需要提醒事项访问权限。" : "Reminders access is required."
        case .changed: return isChinese ? "此提醒事项已变更，请刷新后重试。" : "This reminder changed. Refresh and try again."
        case .unavailable: return isChinese ? "此提醒事项已不可用。" : "This reminder is no longer available."
        case .readFailure: return isChinese ? "提醒事项暂无响应，请重试。" : "Reminders isn't responding. Please try again."
        case .refreshAfterSave: return isChinese ? "已在提醒事项中保存，请刷新以确认结果。" : "Saved in Reminders. Refresh to confirm the result."
        }
    }

    var refreshAction: String { isChinese ? "刷新" : "Refresh" }
    var tryAgainAction: String { isChinese ? "重试" : "Try Again" }
    var refreshingAction: String { isChinese ? "正在刷新…" : "Refreshing…" }
    var openSettingsAction: String { isChinese ? "打开设置" : "Open Settings" }
    var chooseListAction: String { isChinese ? "选择列表" : "Choose a List" }
    var openRemindersAction: String { isChinese ? "打开提醒事项" : "Open Reminders" }

    var noticeRefreshToContinue: String { isChinese ? "请刷新后继续" : "Refresh to continue" }
    var noticeCouldNotComplete: String { isChinese ? "无法完成此提醒事项" : "Couldn't complete this reminder" }
    var noticeCouldNotRefreshTitle: String { isChinese ? "刷新失败" : "Couldn't refresh" }
    var noticeCouldNotRefreshDetail: String { isChinese ? "当前显示上次更新内容，请刷新后继续。" : "Showing the last update. Refresh to continue." }
    var noticeSomeListsUnavailableTitle: String { isChinese ? "部分列表不可用" : "Some lists aren't available" }
    var noticeSomeListsUnavailableDetail: String { isChinese ? "当前仅显示可用列表，请在设置中检查选择。" : "Showing your available lists. Review your selection in Settings." }

    // MARK: - Panel Empty / Connection Messages

    var msgAwaitingTitle: String { isChinese ? "连接提醒事项" : "Connect to Reminders" }
    var msgAwaitingDetail: String { isChinese ? "允许访问权限以在此查看所选列表。" : "Allow access to see your chosen list here." }

    var msgDeniedTitle: String { isChinese ? "提醒事项权限已关闭" : "Reminders access is off" }
    var msgDeniedDetail: String { isChinese ? "请在设置中开启权限以恢复列表显示。" : "Allow access in Settings to bring your list back." }

    var msgUnselectedTitle: String { isChinese ? "选择列表" : "Choose your list" }
    var msgUnselectedDetail: String { isChinese ? "在设置中选择列表，即可在此查看今日到期和逾期任务。" : "Choose lists in Settings to see their due and overdue tasks here." }

    var msgUnavailableTitle: String { isChinese ? "所选列表不可用" : "Tracked lists aren't available" }
    var msgUnavailableDetail: String { isChinese ? "这些列表可能已被移动或删除，请在设置中重新选择。" : "They may have moved or been removed. Choose a list in Settings." }

    var msgLoadingTitle: String { isChinese ? "正在读取提醒事项…" : "Getting your reminders…" }
    var msgLoadingDetail: String { isChinese ? "准备就绪后任务将显示在这里。" : "Your tasks will appear here when they're ready." }

    var msgFailedTitle: String { isChinese ? "无法加载提醒事项" : "Couldn't load your reminders" }
    var msgFailedDetail: String { isChinese ? "你的提醒事项未被修改，请重试加载。" : "Your reminders haven't been changed. Try loading them again." }

    func msgEmptyListsTitle(multiple: Bool) -> String {
        if isChinese { return multiple ? "所选列表为空" : "当前列表为空" }
        return multiple ? "Your lists are empty" : "Your list is empty"
    }
    var msgEmptyListsDetail: String { isChinese ? "请在系统“提醒事项”中添加带有到期日的任务。" : "Add a reminder with a due date in Reminders." }

    var msgUndatedTitle: String { isChinese ? "今日无到期任务" : "Nothing due today" }
    var msgUndatedDetail: String { isChinese ? "未设置日期的提醒仅保留在“提醒事项”中，添加到期日后将在此显示。" : "Undated reminders stay in Reminders. Add a due date to see them here." }

    var msgFutureTitle: String { isChinese ? "今日任务已清空" : "You're clear for today" }
    func msgFutureDetail(_ dateText: String) -> String {
        isChinese ? "下一个提醒事项将在\(dateText)到期。" : "Your next reminder is due \(dateText)."
    }

    var msgNothingScheduledTitle: String { isChinese ? "今日暂无安排" : "Nothing scheduled today" }
    var msgNothingScheduledDetail: String { isChinese ? "留白时刻。到期与逾期提醒事项会显示在这里。" : "A little room in your day. Due and overdue reminders will appear here." }

    // MARK: - Header, Tasks & Context Menu

    var showDayHelp: String { isChinese ? "显示今日" : "Show Day" }
    func showDayAccessibility(done: Int, due: Int) -> String {
        isChinese ? "显示今日，今天已完成 \(done)/\(due)" : "Show Day, today \(done) of \(due) completed"
    }
    var showMonthHelp: String { isChinese ? "显示月历" : "Show Month" }
    func staleScoreHelp(done: Int, due: Int) -> String {
        isChinese ? "上次更新：\(done)/\(due)，请刷新后继续。" : "Last update: \(done)/\(due). Refresh to continue."
    }

    var menuSettings: String { isChinese ? "设置" : "Settings" }
    var menuKeepExpand: String { isChinese ? "保持展开" : "Keep Expand" }
    var menuOpenTrackedList: String { isChinese ? "打开跟踪列表" : "Open Tracked List" }
    var menuQuit: String { isChinese ? "退出 Glitter" : "Quit Glitter" }

    var untitledReminder: String { isChinese ? "未命名提醒" : "Untitled reminder" }
    func taskCompletedAccessibility(_ title: String) -> String {
        isChinese ? "\(title)，已完成" : "\(title), Completed"
    }
    func taskPendingAccessibility(_ title: String, saving: Bool) -> String {
        if isChinese { return "\(title)，\(saving ? "保存中" : "待办")" }
        return "\(title), \(saving ? "Saving" : "To do")"
    }
    func taskActionHint(locked: Bool) -> String {
        if isChinese { return locked ? "暂不可用" : "标记为已完成" }
        return locked ? "Temporarily unavailable" : "Mark as complete"
    }
    var demoOpenListDisabledHelp: String { isChinese ? "演示模式下不打开真实提醒事项。" : "Demo does not open real reminders." }

    // MARK: - Menu Bar

    var menuBarRemindersRequired: String { isChinese ? "需要提醒事项权限…" : "Reminders Access Required…" }
    var menuBarWaitingAccess: String { isChinese ? "等待权限授权…" : "Waiting for Access…" }
    var menuBarSettings: String { isChinese ? "设置…" : "Settings…" }
    var menuBarDisplay: String { isChinese ? "显示器" : "Display" }
    var menuBarCenterPanel: String { isChinese ? "居中面板" : "Center Panel" }
    var menuBarRefresh: String { isChinese ? "刷新" : "Refresh" }
    var menuBarOpenReminders: String { isChinese ? "打开提醒事项" : "Open Reminders" }

    // MARK: - Settings Window

    var settingsWindowTitle: String { isChinese ? "Glitter 设置" : "Glitter Settings" }
    var settingsTrackedList: String { isChinese ? "跟踪列表" : "Tracked List" }
    var settingsTrackedListSubtitle: String {
        isChinese
            ? "在“提醒事项”中创建每日习惯列表并设置重复周期，再在此选择列表。（按住 ⌘ 可多选）"
            : "Create a Daily Habit list in Reminders. Set your repeats, then choose your list here. (hold ⌘ to choose more lists)"
    }
    var settingsAccessRequired: String { isChinese ? "需要提醒事项访问权限。" : "Reminders access is required." }
    var settingsSystemSettings: String { isChinese ? "系统设置" : "System Settings" }
    var settingsAllowAccess: String { isChinese ? "允许访问" : "Allow Access" }
    var settingsNoListsFound: String { isChinese ? "未找到提醒事项列表。" : "No reminder lists found." }
    var settingsListAccessibilityHint: String {
        isChinese ? "按住 Command 键可添加或取消选择此列表。" : "Hold Command to add or remove this list from your selection."
    }

    var settingsDisplay: String { isChinese ? "显示" : "Display" }
    var settingsScreen: String { isChinese ? "屏幕" : "Screen" }
    var mainDisplay: String { isChinese ? "主显示器" : "Main Display" }
    var builtInDisplay: String { isChinese ? "内建显示器" : "Built-in Display" }
    var notchSuffix: String { isChinese ? "（刘海屏）" : "(Notch)" }
    var settingsPanelPosition: String { isChinese ? "面板位置" : "Panel Position" }
    var settingsCenter: String { isChinese ? "居中" : "Center" }
    var settingsShowMenuBarIcon: String { isChinese ? "显示菜单栏图标" : "Show Menu Bar Icon" }
    var settingsLanguage: String { isChinese ? "语言" : "Language" }
    var languageSystem: String { isChinese ? "跟随系统" : "Follow System" }
    var languageEnglish: String { "English" }
    var languageChinese: String { "简体中文" }

    func languageOptionLabel(_ language: AppLanguage) -> String {
        switch language {
        case .system: return languageSystem
        case .english: return languageEnglish
        case .chinese: return languageChinese
        }
    }

    var settingsStartup: String { isChinese ? "启动" : "Startup" }
    var settingsLaunchAtLogin: String { isChinese ? "登录时启动" : "Launch at Login" }
    var settingsStartupDemoHint: String { isChinese ? "演示模式下不可用。" : "Unavailable in Demo." }
    var settingsStartupHint: String { isChinese ? "登录 macOS 时自动启动 Glitter。" : "Start Glitter when you log in." }
    var settingsApprovalHint: String { isChinese ? "请在“系统设置”中允许 Glitter 以完成启用。" : "Allow Glitter in System Settings to finish enabling." }
    var settingsOpenLoginItems: String { isChinese ? "打开登录项设置" : "Open Login Items Settings" }

    func loginItemError(_ detail: String) -> String {
        isChinese ? "无法更新登录时启动设置。\(detail)" : "Could not update Launch at Login. \(detail)"
    }

    var settingsAnimationDemo: String { isChinese ? "动画演示" : "Animation Demo" }
    var settingsReplayPages: String { isChinese ? "重放翻页" : "Replay Pages" }
    var settingsReplayNotch: String { isChinese ? "重放刘海展开" : "Replay Notch" }
}
