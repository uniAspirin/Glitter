import AppKit

extension NSScreen {
    var displayName: String {
        if let id = displayID, CGDisplayIsBuiltin(id) != 0 { return "Built-in Display" }
        return localizedName
    }

    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

struct NotchGeometry: Equatable {
    let screenFrame: NSRect
    let hasNotch: Bool
    let notchHeight: CGFloat
    /// 用作标准展开宽度的刘海参考尺寸，外接屏也可使用内建屏的参考值。
    let notchWidth: CGFloat
    var displayScale: CGFloat = 1
    let rows: Int
    var horizontalOffset: CGFloat = 0
    var collapsedScoreWidth: CGFloat = Self.reservedScoreWidth
    var scoreScale: CGFloat = 1
    var showingMonth = false
    var todayContentHeight: CGFloat = 24
    var noticeHeight: CGFloat = 0
    var showsTaskContent = true
    var showsCalendar = true

    let padding: CGFloat = 12
    let blockSize: CGFloat = 13
    let headerPadding: CGFloat = 12
    var horizontalPadding: CGFloat { headerPadding }
    static let scoreFontSize: CGFloat = 11
    static let reservedScoreWidth: CGFloat = {
        let base = NSFont.monospacedDigitSystemFont(ofSize: scoreFontSize, weight: .semibold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: scoreFontSize) } ?? base
        return ceil(("99/99" as NSString).size(withAttributes: [.font: font]).width) + 1
    }()
    let monthHeadingHeight: CGFloat = 22
    let monthHeadingGap: CGFloat = 8
    let monthWeekdayHeight: CGFloat = 14
    static let taskFontSize: CGFloat = 13
    static let taskRowHeight: CGFloat = 18
    static let taskRowPadding: CGFloat = 2.5
    static let taskMarkerWidth: CGFloat = 10
    static let taskMarkerGap: CGFloat = 7
    var taskTextInset: CGFloat { horizontalPadding + Self.taskMarkerWidth + Self.taskMarkerGap }
    private var taskTextWidth: CGFloat { contentWidth - Self.taskMarkerWidth - Self.taskMarkerGap }
    static let messageGap: CGFloat = 5

    // Integral centers and even widths avoid NSWindow rounding a half-point origin.
    var panelWidth: CGFloat { ceil(max(270, notchWidth + 2 * (Self.reservedScoreWidth + headerPadding + 2)) / 2) * 2 }
    var expandedWidth: CGFloat { panelWidth }
    var contentWidth: CGFloat { panelWidth - 2 * horizontalPadding }
    var coversNotch: Bool { hasNotch && abs(horizontalOffset) < (panelWidth + notchWidth) / 2 }
    var collapsedWidth: CGFloat { coversNotch ? panelWidth : ceil((Self.reservedScoreWidth + blockSize + 2 * headerPadding + 16) / 2) * 2 }
    var collapsedHeight: CGFloat { hasNotch ? notchHeight : 34 }
    var topGap: CGFloat { 0 }
    var headerCornerRadius: CGFloat { 6 }
    var headerButtonWidth: CGFloat { headerButtonWidth(in: expandedWidth) }
    func headerButtonWidth(in width: CGFloat) -> CGFloat {
        let alignedWithNotch = coversNotch && abs(horizontalOffset) < 1
        return alignedWithNotch ? min((expandedWidth - notchWidth) / 2, width / 2) : width / 2
    }
    func headerInteractionRect(in frame: NSRect) -> NSRect {
        NSRect(x: frame.minX, y: frame.maxY - collapsedHeight,
               width: headerButtonWidth, height: collapsedHeight)
    }
    var gridWidth: CGFloat { 7 * cell + 6 * cellGap }
    var gridOriginX: CGFloat { horizontalPadding }
    // Keep cells on physical pixels and distribute the remainder across the gaps.
    var cell: CGFloat { floor((contentWidth - 6 * 6) / 7 * displayScale) / displayScale }
    var cellGap: CGFloat { (contentWidth - 7 * cell) / 6 }
    var gridHeight: CGFloat { CGFloat(rows) * cell + CGFloat(rows - 1) * cellGap }
    var monthContentHeight: CGFloat { monthHeadingHeight + monthHeadingGap + monthWeekdayHeight + gridHeight + 6 }
    var monthViewportHeight: CGFloat { showsCalendar ? monthContentHeight : todayContentHeight }
    var monthTop: CGFloat { collapsedHeight + padding + noticeHeight }
    var maximumExpandedHeight: CGFloat {
        max(collapsedHeight, min(screenFrame.height - 8, ceil(monthTop + monthViewportHeight + padding)))
    }
    var dayViewportHeight: CGFloat {
        max(0, min(todayContentHeight, maximumExpandedHeight - monthTop - padding))
    }
    var dayScrolls: Bool { todayContentHeight > dayViewportHeight + 0.5 }
    var expandedHeight: CGFloat {
        showingMonth ? maximumExpandedHeight : min(maximumExpandedHeight, ceil(monthTop + dayViewportHeight + padding))
    }
    func blockInteractionRect(in frame: NSRect) -> NSRect {
        NSRect(x: frame.maxX - headerButtonWidth, y: frame.maxY - collapsedHeight,
               width: headerButtonWidth, height: collapsedHeight)
    }

    mutating func measureToday(tasks: [TrackedTask], error: String?, summary: String?) {
        showsTaskContent = true
        todayContentHeight = todayHeight(tasks: tasks, error: error, summary: summary)
    }
    mutating func measureMessage(_ message: PanelMessage) {
        showsTaskContent = false
        todayContentHeight = message.height(width: contentWidth) + 4
    }
    func todayHeight(tasks: [TrackedTask], error: String? = nil, summary: String? = nil) -> CGFloat {
        var height: CGFloat = tasks.isEmpty ? 24 : 0
        height += tasks.reduce(0) { $0 + taskHeight($1) }
        if !tasks.isEmpty, summary != nil { height += Self.messageGap + 16 }
        if let error {
            let bounds = (error as NSString).boundingRect(with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 11)])
            height += Self.messageGap + ceil(bounds.height) + 1
        }
        return height
    }

    func taskHeight(_ task: TrackedTask) -> CGFloat {
        let title = task.title.isEmpty ? "Untitled reminder" : task.title
        let bounds = (title as NSString).boundingRect(with: NSSize(width: taskTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: Self.taskFontSize)])
        return max(Self.taskRowHeight, ceil(bounds.height) + 1) + 2 * Self.taskRowPadding
    }

    func taskInteractionRects(tasks: [TrackedTask], in frame: NSRect) -> [(id: String, rect: NSRect)] {
        // A scrolling list uses each native row's hover, which follows the scroll offset.
        guard !showingMonth, !dayScrolls else { return [] }
        var top = frame.maxY - monthTop
        var result: [(id: String, rect: NSRect)] = []
        for task in tasks {
            let height = taskHeight(task)
            if !task.isCompleted {
                result.append((task.id, NSRect(x: frame.minX, y: top - height,
                                              width: frame.width, height: height)))
            }
            top -= height
        }
        return result
    }

    var alignedCenterX: CGFloat { (screenFrame.midX + horizontalOffset).rounded() }

    var windowRect: NSRect {
        NSRect(x: alignedCenterX - expandedWidth / 2,
               y: screenFrame.maxY - expandedHeight, width: expandedWidth, height: expandedHeight)
    }
    var collapsedRect: NSRect {
        NSRect(x: alignedCenterX - collapsedWidth / 2,
               y: screenFrame.maxY - collapsedHeight, width: collapsedWidth, height: collapsedHeight)
    }
    var hotZone: NSRect { collapsedRect.insetBy(dx: -1, dy: -1) }
    var hitRect: NSRect { windowRect.insetBy(dx: -2, dy: -2) }
    var offsetLimit: CGFloat { max(0, (screenFrame.width - expandedWidth) / 2 - 8) }
    func rect(expanded: Bool) -> NSRect { expanded ? windowRect : collapsedRect }
    func clampedOffset(_ offset: CGFloat) -> CGFloat { min(max(offset, -offsetLimit), offsetLimit) }

    func settledOffset(_ offset: CGFloat) -> CGFloat {
        let clamped = clampedOffset(offset)
        guard hasNotch else { return clamped }
        let clearance = (panelWidth + notchWidth) / 2 + 8
        guard abs(clamped) < clearance else { return clamped }
        guard clearance <= offsetLimit, abs(clamped) >= clearance / 2 else { return 0 }
        return clamped < 0 ? -clearance : clearance
    }

    static func referenceNotchWidth(in screens: [NSScreen]) -> CGFloat? {
        guard let screen = screens.first(where: { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }),
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        return screen.frame.width - left.width - right.width
    }

    static func make(for screen: NSScreen?, rows: Int, offset: CGFloat, scoreText: String = "0/0",
                     todayHeight: CGFloat = 24, showingMonth: Bool = false, referenceNotchWidth: CGFloat? = nil) -> NotchGeometry {
        let frame = screen?.frame ?? .zero
        let safeTop = screen?.safeAreaInsets.top ?? 0
        let hasNotch = safeTop > 0 && screen?.auxiliaryTopLeftArea != nil
        var notchWidth = referenceNotchWidth ?? Self.referenceNotchWidth(in: NSScreen.screens) ?? 0
        if hasNotch, let screen, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
        }
        var geometry = NotchGeometry(screenFrame: frame, hasNotch: hasNotch,
                                     notchHeight: hasNotch ? safeTop : 0, notchWidth: notchWidth,
                                     rows: min(max(rows, 1), 6))
        geometry.displayScale = screen?.backingScaleFactor ?? 1
        geometry.todayContentHeight = todayHeight
        geometry.showingMonth = showingMonth
        let base = NSFont.monospacedDigitSystemFont(ofSize: Self.scoreFontSize, weight: .semibold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: Self.scoreFontSize) } ?? base
        let textWidth = ceil((scoreText as NSString).size(withAttributes: [.font: font]).width)
        geometry.scoreScale = min(1, Self.reservedScoreWidth / max(1, textWidth))
        geometry.horizontalOffset = geometry.settledOffset(offset)
        return geometry
    }
}
