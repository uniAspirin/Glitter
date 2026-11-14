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
    var dayExpanded = false
    var previewTaskCount = 0
    var previewContentHeight: CGFloat = 24
    var todayContentHeight: CGFloat = 24
    var taskContentHeight: CGFloat = 0
    var previewOverflowOffset: CGFloat = 0
    var noticeHeight: CGFloat = 0
    var showsTaskContent = true
    var showsCalendar = true

    let padding: CGFloat = 12
    let blockSize: CGFloat = 13
    let footerGap: CGFloat = 6
    let footerHeight: CGFloat = 26
    let headerPadding: CGFloat = 8
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
    var panelWidth: CGFloat { ceil(max(262, notchWidth + 2 * (Self.reservedScoreWidth + headerPadding + 2)) / 2) * 2 }
    var expandedWidth: CGFloat { panelWidth }
    var contentWidth: CGFloat { panelWidth - 2 * horizontalPadding }
    var coversNotch: Bool { hasNotch && abs(horizontalOffset) < (panelWidth + notchWidth) / 2 }
    var collapsedWidth: CGFloat { coversNotch ? panelWidth : ceil((Self.reservedScoreWidth + blockSize + headerPadding * 4) / 2) * 2 }
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
    var dayPreviewLimit: CGFloat { 6 * (Self.taskRowHeight + 2 * Self.taskRowPadding) }
    var dayPreviewHeight: CGFloat { dayOverflows ? dayPreviewLimit : todayContentHeight }
    var dayOverflows: Bool { showsTaskContent && taskContentHeight > dayPreviewLimit }
    var overflowStartIndex: Int { max(0, previewTaskCount - (previewOverflowOffset > 0 ? 1 : 0)) }
    var dayBaseHeight: CGFloat { dayPreviewHeight + (dayOverflows ? footerHeight + footerGap : 0) }
    var toggleTop: CGFloat { monthTop + dayPreviewHeight + footerGap }
    var monthTop: CGFloat { collapsedHeight + padding + noticeHeight }
    var overflowHeight: CGFloat { max(0, todayContentHeight - previewContentHeight) }
    var expandedHeight: CGFloat {
        let bodyHeight = showingMonth ? monthViewportHeight : dayBaseHeight
        let extra = !showingMonth && dayExpanded && dayOverflows ? overflowHeight + padding : 0
        let bottomPadding = showingMonth || !dayOverflows || dayExpanded ? padding : 0
        return min(screenFrame.height - 8, ceil(monthTop + bodyHeight + bottomPadding + extra))
    }
    var overflowViewportHeight: CGFloat {
        max(0, expandedHeight - toggleTop - footerHeight - 2 * padding)
    }
    func toggleInteractionRect(in frame: NSRect) -> NSRect {
        NSRect(x: frame.minX, y: frame.maxY - toggleTop - footerHeight,
               width: frame.width, height: footerHeight)
    }
    func blockInteractionRect(in frame: NSRect) -> NSRect {
        NSRect(x: frame.maxX - headerButtonWidth, y: frame.maxY - collapsedHeight,
               width: headerButtonWidth, height: collapsedHeight)
    }

    mutating func measureToday(tasks: [TrackedTask], error: String?, summary: String?) {
        showsTaskContent = true
        taskContentHeight = tasks.reduce(0) { $0 + taskHeight($1) }
        previewOverflowOffset = 0
        todayContentHeight = todayHeight(tasks: tasks, error: error, summary: summary)
        previewTaskCount = tasks.count
        previewContentHeight = todayContentHeight
        guard dayOverflows else { return }
        previewTaskCount = 0
        previewContentHeight = 0
        for task in tasks {
            let remaining = dayPreviewHeight - previewContentHeight
            guard remaining > 0 else { break }
            let height = taskHeight(task)
            previewTaskCount += 1
            if height > remaining {
                previewOverflowOffset = textBoundary(in: task, within: remaining)
                if previewOverflowOffset == 0 { previewTaskCount -= 1 }
                previewContentHeight += previewOverflowOffset
                break
            }
            previewContentHeight += height
        }
    }
    mutating func measureMessage(_ message: PanelMessage) {
        showsTaskContent = false
        taskContentHeight = 0
        previewOverflowOffset = 0
        todayContentHeight = message.height(width: contentWidth) + 4
        previewContentHeight = todayContentHeight
        previewTaskCount = 0
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

    /// Split a very tall reminder between complete text lines, never through glyphs.
    private func textBoundary(in task: TrackedTask, within available: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: task.title, attributes: [.font: NSFont.systemFont(ofSize: Self.taskFontSize)])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: taskTextWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var boundary: CGFloat = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { rect, _, _, _, stop in
            let bottom = ceil(rect.maxY) + Self.taskRowPadding
            if bottom <= available { boundary = bottom } else { stop.pointee = true }
        }
        // If the remaining space cannot fit even one line, leave this entire row below the arrow.
        return boundary
    }

    func taskInteractionRects(tasks: [TrackedTask], in frame: NSRect) -> [(id: String, rect: NSRect)] {
        guard !showingMonth else { return [] }
        var previewTop = frame.maxY - monthTop
        var overflowTop = frame.maxY - toggleTop - footerHeight - padding
        var result: [(id: String, rect: NSRect)] = []
        for (index, task) in tasks.enumerated() {
            let height = taskHeight(task)
            if !dayOverflows || index < previewTaskCount {
                let visibleBottom = dayOverflows ? frame.maxY - monthTop - previewContentHeight : frame.minY + padding
                let visibleHeight = max(0, min(height, previewTop - visibleBottom))
                if !task.isCompleted && visibleHeight > 0 {
                    result.append((task.id, NSRect(x: frame.minX, y: previewTop - visibleHeight, width: frame.width, height: visibleHeight)))
                }
                previewTop -= height
            }
            // Scrolling overflow rows use native hover events instead of sampled coordinates.
            if dayOverflows && dayExpanded && index >= overflowStartIndex && overflowHeight <= overflowViewportHeight + 0.5 {
                let visibleHeight = height - (index == overflowStartIndex ? previewOverflowOffset : 0)
                if !task.isCompleted && overflowTop - visibleHeight >= frame.minY + padding {
                    result.append((task.id, NSRect(x: frame.minX, y: overflowTop - visibleHeight, width: frame.width, height: visibleHeight)))
                }
                overflowTop -= visibleHeight
            }
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
