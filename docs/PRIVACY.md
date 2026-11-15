# Privacy

Glitter 1.2 processes reminders on your Mac through Apple's EventKit API. It makes no direct network requests and includes no advertising, analytics or application logging service.

## Data on your Mac

Glitter reads list names to display the selection in Settings. It fetches reminder content from the selected lists, calculates progress in memory and writes completion changes back to the reminder's own list. It keeps no additional task database, daily history snapshots or application log files.

The app stores selected list identifiers, your selected display, panel position, menu bar icon visibility in macOS preferences. Launch at Login is managed by macOS. Task content and rendered view caches live in memory for the running session.

Apple Reminders manages the underlying task records. If your list uses iCloud, Apple's services perform synchronization. Apple's data storage, synchronization and macOS diagnostic behavior follow your system settings.

## Permissions

macOS grants full Reminders access through EventKit. Glitter uses that permission to list available lists, fetch the selected lists and complete tasks you click. The selection restricts application queries. The macOS permission itself covers Reminders rather than individual lists.

The application does not request microphone, camera, screen recording, Accessibility or Full Disk Access permissions. The floating panel observes pointer position for hover behavior. Task scrolling uses the native scroll view.

## Verification

The release's source can be checked in `Sources/`. The data access and completion paths are in [TaskStore.swift](../Sources/TaskStore.swift) and [ReminderMutation.swift](../Sources/ReminderMutation.swift). The preference writes are in TaskStore and [NotchPanelController.swift](../Sources/NotchPanelController.swift).

The local review checked source access paths, file writes, network API references and the production executable's linked libraries. The executable links Apple system frameworks and runtime libraries. File logging was removed before publication.

The final 1.0 build 23 Demo was started and exercised through task completion and Day/Month switching. It created no application log file. The production DMG was mounted read-only to verify its version, local signature, executable checksum and removal of the old log filename.

A limited runtime check of the earlier 1.0 candidate used fictional Demo tasks. During Day/Month switches and task completion, 83 TCP/UDP connection samples over 45.1 seconds observed no connections for that Demo process. This was process sampling, with gaps between observations. It did not test live EventKit access, iCloud synchronization or every possible execution path.

These notes document a project self-review. They do not represent an independent security certification or Apple notarization. Releases include a SHA-256 checksum to identify the download.

## 简体中文

Glitter 通过苹果 EventKit API 在本机读取和更新提醒事项，不主动发起网络请求，不含广告、统计追踪或应用日志。

应用读取列表名称用于设置界面，从所选列表读取任务，在内存中计算完成比例，将点击完成的操作写回任务所属列表。不额外保存任务数据库、每日历史快照或日志文件。仅在 macOS 偏好设置中保存所选列表 ID、显示器、窗口位置、菜单栏图标显示设置，登录时启动由系统管理。

任务原始记录由苹果提醒事项管理。使用 iCloud 列表时，同步由苹果服务负责。苹果的数据存储、同步和系统诊断行为遵循你的系统设置。

macOS 授予的是提醒事项完整访问权限。Glitter 在代码中将任务查询限定为所选列表，这种选择并非系统提供的逐列表权限。悬停使用鼠标位置，任务列表使用系统滚动控件，应用不请求麦克风、摄像头、屏幕录制、辅助功能或完全磁盘访问权限。

本项目已检查源码中的数据访问、文件写入、网络调用和正式程序的动态依赖，并在发布前删除文件日志。最终 1.0 build 23 的 Demo 已验收启动、完成任务和视图切换，未生成应用日志。正式 DMG 已只读挂载核对版本、本地签名、程序校验和及旧日志文件名的移除。

早期 1.0 候选版曾用假数据进行 45.1 秒、83 次 TCP/UDP 连接采样，未观察到 Demo 进程的连接。采样有间隔，也未覆盖真实 EventKit 访问、iCloud 同步或所有执行路径。

这里记录的是项目自查，发布文件附带 SHA-256 校验和。当前发行版使用 ad-hoc 签名，尚未经过 Apple 公证。
