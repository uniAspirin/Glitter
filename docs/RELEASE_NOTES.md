# Glitter 1.2

## English

- Every hover expansion opens Today, including re-entry while the panel is closing.
- Click the top-right cube for Month and the score to return to Today.
- Simplified Settings and menu bar options. View navigation uses the header buttons.
- Day fits its task content up to the Month height and scrolls for longer lists, with aligned text and overlay scrollbars.
- Page transitions take 100 ms and preserve the Day scroll position. Cached pages and paused display callbacks reduce repeated work.

Validated with 669 automated checks using fictional tasks.

Requires macOS 14 or later and Apple Silicon. The app uses ad-hoc signing and has not been notarized by Apple.

## 简体中文

- 每次悬停展开都进入 Today，收起过程中重新移入也会回到 Today。
- 点击右上角方块进入 Month，点击分数返回 Today。
- 精简设置和菜单栏选项，视图通过顶部按钮切换。
- Day 高度随任务内容变化，上限与 Month 一致。较长列表直接滚动，文字保持对齐，滚动条覆盖显示。
- 页面切换动画为 100 ms，并保留 Day 的滚动位置。复用页面缓存，空闲时暂停刷新回调。

通过 669 项假数据自动检查。

支持 macOS 14 及以上版本和 Apple Silicon。应用使用 ad-hoc 签名，尚未经过 Apple 公证。

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
