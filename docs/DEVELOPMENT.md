# Developing Glitter

Glitter 1.2 targets Apple Silicon Macs running macOS 14 or later. Build with a recent Xcode Command Line Tools installation. It uses Swift, SwiftUI, AppKit, EventKit and ServiceManagement, with system frameworks as its only runtime dependencies.

## Xcode development / Xcode 开发

Open `Glitter.xcodeproj` directly (File → Open), rather than opening the repository as a folder. The native macOS app target shares the existing `Sources/` files and keeps the script workflow available. Requires macOS 14+ on Apple Silicon; local builds use ad-hoc signing without a developer account.

- **Glitter Demo** → **My Mac** → **⌘R**: run the full notch app with fictional tasks and in-memory preferences. This scheme uses the Demo build configuration and `Xcode/Demo-Info.plist`, including its separate `com.glitter.notch.demo` identity.
- **Glitter** → **My Mac** → **⌘R**: run with real Reminders. Grant permission and select lists when needed. Stop debugging with **⌘.**.
- Open `Sources/PreviewContent.swift`, enable **Editor → Canvas** (**⌥⌘↩**), then **Resume** (**⌥⌘P**). Select Today, Month, Collapsed, Empty List or Long Task. Live preview supports completing fake tasks and switching Today/Month with the header buttons.
- Preview fixtures use `DemoDefaults` and existing `loadDemoData` helpers. The preview process skips application-level initialization, so Canvas does not create the global notch panel or request Reminders access.
- Canvas checks SwiftUI content and layout. Use **Glitter Demo** for actual screen placement, hover expansion, native window animation and Settings.

中文：先打开原生工程，再选 **Glitter Demo / My Mac**。**⌘B** 编译，**⌘R** 运行，**⌘.** 停止。修改 SwiftUI 后可在 Canvas 查看假数据界面；涉及刘海位置和鼠标悬停时运行 Demo。预览代码仅在 Xcode 的 Debug / Demo 配置编译；原来的脚本构建不需要加载 Preview 宏插件。新增源码文件时，请同时加入 Glitter target 的 Compile Sources。

The project uses Debug / Demo / Release configurations. Release omits preview fixtures. Existing script-based checks remain available under `Tests/run.sh`; they are not configured as an Xcode test target.

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

Demo uses fictional tasks and in-memory settings. It does not access real reminders or register a login item. The checks below cover additional sample data and recovery scenarios.

Settings includes Show Menu Bar Icon, enabled by default and persisted for regular use. The controller notifies AppDelegate to update the native status item's visibility. Hiding it leaves the panel's Settings context-menu entry available. The panel context menu contains Settings, Open Tracked List and Quit Glitter. Demo also includes Keep Expand for development. Multi-list destinations appear in the Open Tracked List submenu.

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

The app uses `com.glitter.notch`; Demo uses `com.glitter.notch.demo`. The production identifier is defined in `Resources/Info.plist`, and the build script derives the Demo and signing identifiers from it. Builds using the former `com.sand.notch` identity have separate preferences, Reminders permission and login-item registration. Existing preference keys are unchanged, but settings are not automatically migrated: choose lists and interface preferences again, grant Reminders access and re-enable Launch at Login as needed when first using the new identity. Reminder data itself remains in Apple Reminders. List selections persist across launches under the new identity.

Every expansion starts with Today, regardless of entry position or the previously open page. A collapsed panel prepares Today before expansion. Re-entry during collapse retargets the animation toward Today from its current presentation frame. Click the top-right cube to enter Month and the score to return to Today. Header buttons stay quiet during expansion. At the animation endpoint the controller records the cursor position; only subsequent pointer entry highlights the score or cube itself. A cursor already inside must leave and re-enter. Accepted clicks briefly dim and shrink the symbol for 100 ms; dragging and the existing 150 ms post-drag guard suppress navigation. Day fits its full task content up to the Month height, then scrolls vertically with overlay scrollbars. View selection is handled by the header buttons. Horizontal padding and expanded content's top and bottom padding are 12 pt. On notched displays, the collapsed height matches the physical notch height.

Window transitions use native display-link timing and cached view snapshots. Hover expansion uses a spring with response 0.36 and damping ratio 0.76; collapse uses response 0.26 and damping ratio 0.96, with a separate 300 ms grace period before collapse. Smooth Slide page transitions take 160 ms independently of the container spring. The display link requests the screen's maximum refresh rate during motion and stays paused between transitions. Day and Month view trees and snapshot layers remain in memory for reuse. Selecting a page reuses measured geometry and updates presentation without publishing task-data changes or rebuilding the menu. Data and display changes refresh the cached snapshots. Scrollable Day transitions capture the retained live viewport so the same rows appear before and after the layer handoff. The live task views resume after the transition. Reduce Motion is respected. Task completion uses an 80 ms acknowledgement, 45 ms fade-out, 140 ms movement and 80 ms fade-in, retaining 120 ms of interaction protection after completion.

Single-line task rows are 26 pt tall with 4 pt of vertical padding on each side. Wrapped titles increase the row height to fit their content. Header hover is owned by the panel controller, using the current presented width for both button regions during pill expansion and collapse.

## Package a DMG

```bash
./package.sh
```

This rebuilds the production app and creates `dist/Glitter-1.2.dmg` and its SHA-256 checksum. The DMG contains `Glitter.app` and an Applications shortcut. Install by dragging the app to Applications.

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
