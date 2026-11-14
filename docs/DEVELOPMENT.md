# Developing Glitter

Glitter 1.0 targets Apple Silicon Macs running macOS 14 or later. Build with a recent Xcode Command Line Tools installation. It uses Swift, SwiftUI, AppKit, EventKit and ServiceManagement, with system frameworks as its only runtime dependencies.

## Build and run

```bash
./build.sh
open build/Glitter.app
```

Allow Reminders access on first launch, then choose lists in Settings. Click a list to select it. Hold Command while clicking to add or remove lists. Tasks and progress are combined across the selection.

Use the isolated Demo when working on layout or completion behavior.

```bash
./build.sh --demo
open build/Glitter-Demo.app
```

Demo uses fictional tasks and in-memory settings. It does not access real reminders or register a login item. Its context menu contains sample data and recovery scenarios.

## Checks

```bash
./Tests/run.sh
```

The checks use fake tasks, simulated displays and a fake mutation service. Native views render to `build/review/`. Run these checks in a logged-in macOS desktop session. They cover statistics, selection migration, multi-list completion, sorting, gestures, layout, recovery and login-item behavior. They do not validate live iCloud synchronization or every EventKit recurrence rule.

The separately invoked [manual API probe](../Tests/Manual/README.md) creates temporary test reminders and requires its own Reminders permission. It is not part of the automated checks.

## Source map

| File | Responsibility |
| --- | --- |
| `Sources/TaskStore.swift` | List selection, EventKit reads, derived statistics, task sorting and completion presentation |
| `Sources/ReminderMutation.swift` | Completion writes scoped to the reminder's own list, followed by a fresh read |
| `Sources/NotchPanelController.swift` | Panel lifecycle, displays, hover, gestures and window animation |
| `Sources/PanelView.swift` | Header controls, Day, Month, task rows and recovery views |
| `Sources/Geometry.swift` | Shared dimensions, text measurement and interaction rectangles |
| `Sources/PanelRenderCache.swift` | Cached native snapshots used during window transitions |
| `Sources/Theme.swift` | Eight gold levels, neutral cells, progress text and glow |
| `Sources/SettingsView.swift` | Tracked lists, display selection and startup settings |
| `Sources/LoginItemManager.swift` | Native login-item registration and status |

## Data model

Reminders is the task source. Every fetched task carries its owning list identifier. A combined fetch reads the selected lists. A completion updates its own list and merges that list's fresh records with the other selected lists.

Day includes reminders due today and overdue reminders that remain unfinished or were completed today. Undated and future-due reminders are excluded. Incomplete reminders sort by priority, due time, title and identifier. Completed reminders appear below them, newest completion first.

Month is recalculated from current reminder records, without daily history snapshots. Completing overdue work credits today and leaves the missed day incomplete. Source edits can change historical results. Eight gold levels show positive completion, with the brightest gold and glow reserved for full completion. Zero completion, no tasks and future dates use `#141414`.

The app retains the `com.sand.notch` bundle identifier and existing preference keys for continuity with previous installations. List selections persist across launches. Day/Month selection and Day disclosure last for the current run.

Window transitions use native display-link timing and cached view snapshots. The live task views resume after the transition. Reduce Motion is respected.

## Package a DMG

```bash
./package.sh
```

This rebuilds the production app and creates `dist/Glitter-1.0.dmg` and its SHA-256 checksum. The DMG contains `Glitter.app` and an Applications shortcut. Install by dragging the app to Applications.

The default build uses ad-hoc signing. A successful local signature check does not imply Apple notarization or Gatekeeper acceptance on another Mac. Gatekeeper may block an unnotarized download.

For a notarized release, install your Developer ID Application certificate in your login keychain and configure a notarytool keychain profile using Apple's instructions. Keep certificates and credentials outside Git. Then run with your own identity and profile names.

```bash
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-notary-profile" \
./package.sh
```

The script signs the app with hardened runtime and a secure timestamp, signs the DMG, submits it to Apple, checks for acceptance, staples and validates the ticket, verifies the image and generates the checksum. Signing and notarization require network access. The output is replaced only after packaging succeeds.

## Repository contents

`Sources/`, `Resources/`, `Tests/`, documentation and build scripts belong in Git. `.signing/`, `.build/`, `build/`, `dist/` and the local React `ui-preview/` are ignored. Review a staged diff before publishing and use fictional tasks for public screenshots. Glitter's application code has no file logger. See the [privacy details](PRIVACY.md) for data storage and verification scope.

## 中文速览

运行 `./build.sh --demo` 和 `open build/Glitter-Demo.app` 可用假数据开发。`./Tests/run.sh` 检查模型、交互和原生渲染，`./package.sh` 构建正式 App 与 DMG。

正式使用需要提醒事项权限。多列表合并统计，完成操作写入任务所属列表。月历从当前提醒事项记录重算，不保存每日快照。修改原始数据可能改变历史显示。

默认构建使用 ad-hoc 签名。公开分发所需的 Developer ID 签名与 Apple 公证，使用上方的环境变量配置。签名材料、构建产物和本地 React 预览均排除出 Git。
