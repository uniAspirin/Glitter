# Glitter

**_Turn your days into gold._**

<a href="#en">English</a> · <a href="#cn">简体中文</a>

<img src="docs/images/today.gif" width="1200" alt="Today's tasks in Glitter">

<a id="en"></a>

## English

Glitter is a small macOS app that keeps Apple Reminders tasks beside your notch and shows your daily progress in a monthly calendar. It grew out of SAND, an earlier project about time and grains of sand.

- **Local and private.** Glitter makes no direct network requests and includes no analytics or app logs. It saves only your list selection and interface preferences.
- **Works Seamlessly with Apple Reminders.** Reads and updates your reminders through Apple’s on-device API. Task data always stays in Reminders, and Apple handles iCloud syncing across your devices.
- **Track your lists.** Choose a list in Settings, or hold ⌘ while clicking to select several. Their tasks and daily progress are combined.
- **Keeps today visible.** Shows today’s tasks and unfinished overdue reminders at the top of your screen. Click to mark them complete. Create and edit tasks in Apple Reminders.
- **Shows your progress.** Eight shades of gold represent daily completion. Days with all tasks completed glow gold.
- **Today on hover.** Every hover expansion starts with Today. Click the top-right cube to view Month.
- **Choose your controls.** Show or hide the menu bar icon in Settings. Right-click the panel for Settings, Open Tracked List and Quit Glitter.

Read the [privacy details and verification notes](docs/PRIVACY.md).

### Download

Download [Glitter 1.1.1](https://github.com/uniAspirin/Glitter/releases/download/v1.1.1/Glitter-1.1.1.dmg). Requires macOS 14 or later and Apple Silicon.

Open the DMG and drag Glitter to Applications.

On first launch, allow Reminders access and choose your lists in Settings. The app is ad-hoc signed and has not been notarized by Apple.

MacOS may require approval under System Settings → Privacy & Security → Open Anyway.

<a id="cn"></a>

## 简体中文

Glitter 是一个小型 macOS 应用，将 Apple Reminders 中的任务放在刘海旁，并用月历展示每天的完成情况。它来自之前的项目 SAND，延续了用金色沙粒记录时间的想法。

- **本地处理，保护隐私。** Glitter 不需联网，没有统计追踪或应用日志。所有操作均通过苹果 EventKit API。任务数据保留在提醒事项中，设备间的 iCloud 同步由苹果负责。
- **选择要跟踪的列表。** 在设置中选择一个列表，按住 ⌘ 点击可多选。所选列表的任务与每日进度会合并显示。
- **让今天的任务保持可见。** 在屏幕顶部显示今日任务和未完成的逾期事项。悬停查看，点击完成。创建和编辑仍在提醒事项中进行。
- **看见每天的积累。** 八级金色表示每天的完成比例，全部完成的日子会亮起金色光晕。
- **查看今天。** 每次悬停展开都显示 Today，点击右上角方块进入 Month。
- **选择操作入口。** 在设置中选择是否显示菜单栏图标。刘海右键菜单提供设置、打开跟踪列表和退出三项操作。

查看[隐私说明与检查记录](docs/PRIVACY.md)。

### 软件理念

_Out of sight, out of mind._

TodoList 软件成功地解决了任务管理问题，但当用户切出软件，面对密集的网页与弹窗时，任务早就被遗忘了。

我们需要一个位于用户和 TodoList 软件之间的工具，能把注意力抢回任务本身。核心理念如下：

1. 足够明显：以至于注意力自然地被吸引。
2. 足够克制：**透明地**传递信息，防止注意力被**工具的信息**二次抢夺；使用方式唯一且闭环，防止注意力被**工具的配置**二次抢夺。
3. 符合直觉：降低认知成本，看一眼就懂，让行动更简单。

目的是做到：
**吸引注意力 => 保护注意力 => 直接行动**

### 下载

下载 [Glitter 1.1.1](https://github.com/uniAspirin/Glitter/releases/download/v1.1.1/Glitter-1.1.1.dmg)。支持 macOS 14 及以上版本，需要 Apple Silicon 芯片。

打开 DMG，将 Glitter 拖入 Applications。

首次启动需允许提醒事项访问，再在设置中选择列表。macOS 如阻止首次启动，可在系统设置 → 隐私与安全性中选择“仍要打开”。

[Development / 开发说明](docs/DEVELOPMENT.md) · [Release notes / 版本说明](docs/RELEASE_NOTES.md) · [MIT License](LICENSE)
