# Glitter 1.4.1

## English

- Refined panel typography: switched numeric labels to SF Mono with subtle month heading and letter-spacing adjustments.
- Unified internal panel typography definitions.

Requires macOS 14 or later and Apple Silicon. The app uses ad-hoc signing and has not been notarized by Apple. macOS may require approval under System Settings → Privacy & Security → Open Anyway.

## 简体中文

- 优化面板字体与样式，数字改用 SF Mono，并微调月份标题与字距。
- 更新面板内部字体规范。

支持 macOS 14 及以上版本和 Apple Silicon。应用使用 ad-hoc 签名，尚未经过 Apple 公证。macOS 如阻止首次启动，可在系统设置 → 隐私与安全性中选择“仍要打开”。

# Glitter 1.4

## English

- Highlighted overdue pending reminders (`dueDay < today`) with a `#FF453A` leading dot while keeping titles crisp white and restoring completed rows to the standard neutral checkmark and strikethrough.
- Added a subtle 5-second inline Undo icon button on the right side of the just-completed non-recurring reminder: dimmed at rest (`white 35%`) without a background box, brightens (`white 92%`) with press feedback while hovering that completed row, resets to a full 5 seconds when the pointer leaves, preserves its active 5-second window across temporary panel collapse, fades in and out smoothly, and disappears when completing another reminder. Clicking it writes `isCompleted = false` back to Reminders before moving the task back to pending. Recurring reminders remain silent and read-only upon completion.
- Unified Month view heading typography (`September 2026` / `九月 2026`), aligned task row leading dots/checkmarks/spinners to a shared visual center, refined Settings alignment, and fixed an EventKit completion write hang caused by premature fetch-request deallocation.

Validated with 22 XCTest cases across 11 test suites using fictional tasks.

Requires macOS 14 or later and Apple Silicon. The app uses ad-hoc signing and has not been notarized by Apple. macOS may require approval under System Settings → Privacy & Security → Open Anyway.

## 简体中文

- 为自然日已逾期且未完成的提醒事项（`dueDay < today`）增加 `#FF453A` 左侧状态圆点提示，标题仍保持纯白；完成后立即恢复为标准灰色勾与删除线。
- 完成非重复提醒事项后，在该已完成事项最右侧提供轻量的 5 秒行内撤销图标按钮：无底框设计、静置时呈暗白色（35%）不打扰注意力；仅当鼠标悬停在该已完成事项整行区域时图标提亮（92%）并保持常亮（移出后重新计算 5 秒），暂离刘海收起期间依然保留 5 秒有效窗口，超时或完成下一条任务时以渐入渐出效果消失；点击后对称写回提醒事项并将任务平滑恢复到未完成列表与原分数。重复任务完成保持静默与只读。
- 统一月历视图中英文标题排版为左对齐“重左轻右”样式（如 `September 2026` / `九月 2026`），将任务行前圆点、对号与加载指示器统一为视觉中心对齐，微调设置页排版对齐，并修复因查询请求对象过早释放导致的完成写入无限转圈问题。

通过全部 11 个测试套件共 22 项 XCTest 假数据自动化测试。

支持 macOS 14 及以上版本和 Apple Silicon。应用使用 ad-hoc 签名，尚未经过 Apple 公证。macOS 如阻止首次启动，可在系统设置 → 隐私与安全性中选择“仍要打开”。

# Glitter 1.3

## English

- Scoped EventKit reads to incomplete reminders and recent completions (`month start - 1 month`) instead of loading unbounded historical records, and moved EventKit completion writes and recurrence reconciliation onto a dedicated background actor.
- Replaced idle background polling with event-driven lifecycle updates: day-rollover, clock/timezone, wake, and app-activation notifications replace the 30-second day timer, while the permission and hover timers run strictly on demand.
- Added full Simplified Chinese and English localization (including system Reminders permission prompts) and an in-app Language picker in Settings (`Follow System` / `English` / `简体中文`) with live UI, date formatter, menu, and render-cache updates.
- Modernized architecture and engineering quality: introduced pure value-type `DisplayMetrics`, extracted pure `TaskStatistics`, isolated Demo fixtures under `DEBUG`/`DEMO` so Release builds exclude them, unified version metadata in `Config/Version.xcconfig`, reused a persistent offscreen render-cache window, fixed `DateFormatter` reuse and `DemoDefaults.bool(forKey:)` isolation, added the standard `GlitterTests` XCTest target in Xcode, and added GitHub Actions CI.

Validated with 18 XCTest cases across 10 test suites using fictional tasks.

Requires macOS 14 or later and Apple Silicon. The app uses ad-hoc signing and has not been notarized by Apple. macOS may require approval under System Settings → Privacy & Security → Open Anyway.

## 简体中文

- 优化 EventKit 查询与写入性能：将提醒事项读取收敛为“全部未完成 + 近两月内已完成”，并将完成写入与重复任务校验移出主线程，由独立后台 `actor` 执行。
- 用系统事件替代常驻轮询：通过日期变更、系统时钟/时区、睡眠唤醒和应用激活通知取代 30 秒跨日定时器，权限监听与悬停兜底定时器改为按需启停，折叠空闲期零定时唤醒。
- 新增完整的中英双语本地化（含系统提醒事项权限弹窗文案），支持在设置中实时切换应用语言（跟随系统 / English / 简体中文），同步更新面板、月历、菜单、窗口标题与渲染缓存。
- 架构与工程现代化：引入纯值类型 `DisplayMetrics`、拆分纯统计模块 `TaskStatistics`、在 Release 构建中移除 Demo 夹具代码、统一 `Config/Version.xcconfig` 单一版本源、复用常驻离屏渲染窗口、修复 `DateFormatter` 复用与 `DemoDefaults.bool(forKey:)` 隔离缺陷，并配置标准 Xcode `GlitterTests` 单元测试目标与 GitHub Actions CI。

通过全部 10 个测试套件共 18 项 XCTest 假数据自动化测试。

支持 macOS 14 及以上版本和 Apple Silicon。应用使用 ad-hoc 签名，尚未经过 Apple 公证。macOS 如阻止首次启动，可在系统设置 → 隐私与安全性中选择“仍要打开”。

# Glitter 1.2

## English

- Hovering always opens Today, including when re-entering a closing panel. Click the top-right square for Month and the score to return to Today.
- Fixed alternating button highlights as the compact panel expands away from the notch or on a display without one. The header stays quiet while opening. Moving into a button after opening subtly highlights its symbol, and clicks give brief feedback.
- The panel opens and closes with a spring and waits 300 ms after the pointer leaves. The 160 ms page slide preserves the Today scroll position and reuses cached views.
- The collapsed panel matches the physical notch height. Expanded content uses 12 pt insets, and single-line task rows are 26 pt tall. Longer lists scroll within the Month height.
- Completing a task animates faster while retaining protection against accidental clicks. Keep Expand is available in the development Demo.

Validated with 1,596 automated checks using fictional tasks.

Requires macOS 14 or later and Apple Silicon. The app uses ad-hoc signing and has not been notarized by Apple. macOS may require approval under System Settings → Privacy & Security → Open Anyway.

When upgrading from 1.1.1 or earlier, quit Glitter before replacing it. The new bundle identifier requires granting Reminders access and choosing your tracked lists again. Set your other Glitter preferences again as needed. Your reminders stay in Apple Reminders.

## 简体中文

- 每次悬停展开都进入 Today，收起过程中重新移入也会回到 Today。点击右上角方块进入 Month，点击分数返回 Today。
- 修复非刘海位置或无刘海屏幕上，药丸展开时顶部按钮交替闪烁的问题。展开时顶部保持安静，展开后移入按钮才轻微提亮图标或文字，点击时有短暂反馈。
- 展开和收起采用弹簧动画，鼠标移出后等待 300 ms。页面滑动为 160 ms，保留 Today 的滚动位置并复用页面缓存。
- 折叠高度贴合真实刘海。展开内容留白为 12 pt，单行任务高度为 26 pt。较长列表在 Month 的高度范围内滚动。
- 加快任务完成动画，保留误点保护。Keep Expand 可在开发 Demo 中使用。

通过 1,596 项假数据自动检查。

支持 macOS 14 及以上版本和 Apple Silicon。应用使用 ad-hoc 签名，尚未经过 Apple 公证。macOS 如阻止首次启动，可在系统设置 → 隐私与安全性中选择“仍要打开”。

从 1.1.1 或更早版本升级时，请先退出旧版再替换。应用标识已更新，需要重新授权提醒事项、选择跟踪列表，并按需重新配置其他偏好。提醒事项数据仍保存在 Apple 提醒事项中。

# Glitter 1.1.1

## English

- Hover expansion and collapse both take 120 ms. A separate 140 ms grace period before collapse helps prevent accidental closing near the edge.
- Day and Month views, animation snapshots and layers stay in memory for reuse. Task and display changes refresh the cached content.
- Selecting a page reuses measured layout and avoids unnecessary task-data notifications and menu updates.
- Monthly labels and date tooltips reuse date formatters.

Validated with 681 automated checks using fictional tasks, plus native Demo checks for Day/Month switching and task completion.

Requires macOS 14 or later and Apple Silicon. Open the DMG and drag Glitter to Applications.

The app uses ad-hoc signing and has not been notarized by Apple. macOS may require approval under System Settings → Privacy & Security → Open Anyway.

## 简体中文

- 鼠标移入展开、移出收起的动画统一为 120 ms。收起前保留独立的 140 ms 缓冲，减少鼠标短暂越过边缘时的误收起。
- Day、Month 视图及动画图片、图层常驻内存复用。任务和显示器变化时刷新缓存。
- 切换页面复用已有布局，减少不必要的任务数据通知和菜单更新。
- 月份标题和日期悬浮说明复用日期格式化器。

通过 681 项假数据自动检查，并在原生 Demo 中验证 Day/Month 切换及任务完成后的更新。

支持 macOS 14 及以上版本和 Apple Silicon。打开 DMG，将 Glitter 拖入 Applications。

应用使用 ad-hoc 签名，尚未经过 Apple 公证。macOS 如阻止首次启动，可在系统设置 → 隐私与安全性中选择“仍要打开”。

# Glitter 1.1

## English

- Hover into the left half to open Today, or the right half to open Month. The view is selected once on entry.
- Always Show Today on Hover is available as a switch in Settings and a checked item in the menu bar menu. It defaults to off and is remembered across launches.
- Settings uses a centered window title and consistent rows with labels on the left and switches on the right.
- Choose whether to show the menu bar icon in Settings. The icon is shown by default, and your choice is remembered across launches.
- The panel context menu now contains Settings, Keep Expand, Open Tracked List and Quit Glitter. Settings remains available when the menu bar icon is hidden.
- Keep Expand displays a checkmark when enabled. Turning it off resumes hover behavior.
- When tracking several lists, Open Tracked List offers a submenu with each list.

Requires macOS 14 or later and Apple Silicon. Open the DMG and drag Glitter to Applications.

The app uses ad-hoc signing and has not been notarized by Apple. macOS may require approval under System Settings → Privacy & Security → Open Anyway.

## 简体中文

- 从折叠态左半边进入显示 Today，右半边进入显示 Month，仅在进入时判断一次。
- 设置中新增 Always Show Today on Hover 开关，菜单栏菜单中也可勾选，开启后每次悬停展开都进入 Today。默认关闭，重新启动后保留选择。
- 设置窗口标题居中，各设置项独占一行，文字在左、开关在右。
- 设置中新增 Show Menu Bar Icon 开关。图标默认显示，选择会在重新启动后保留。
- 刘海右键菜单精简为 Settings、Keep Expand、Open Tracked List 和 Quit Glitter。隐藏菜单栏图标后，仍可从刘海右键打开设置。
- Keep Expand 启用时显示勾选，关闭后恢复悬停展开与离开收起。
- 跟踪多个列表时，Open Tracked List 提供对应列表的子菜单。

支持 macOS 14 及以上版本和 Apple Silicon。打开 DMG，将 Glitter 拖入 Applications。

应用使用 ad-hoc 签名，尚未经过 Apple 公证。macOS 如阻止首次启动，可在系统设置 → 隐私与安全性中选择“仍要打开”。
