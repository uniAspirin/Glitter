import AppKit
import EventKit
import XCTest
@testable import Glitter

final class MemoryDefaults: UserDefaults {
    var values: [String: Any] = [:]
    var dataReads: [String] = []

    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { dataReads.append(key); return values[key] as? Data }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
    override func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    override func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

final class RecordingWorkspace: NSWorkspace {
    var openedURLs: [URL] = []

    override func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
    }
}

extension DisplayMetrics {
    static func fixture(
        id: CGDirectDisplayID,
        frame: NSRect,
        notch: CGFloat = 0,
        refreshRate: Int = 120,
        scale: CGFloat = 2,
        name: String? = nil,
        isBuiltin: Bool = false
    ) -> DisplayMetrics {
        DisplayMetrics(
            id: id,
            frame: frame,
            safeAreaTop: notch > 0 ? 32 : 0,
            notchWidth: notch,
            backingScaleFactor: scale,
            maximumFramesPerSecond: refreshRate,
            name: name ?? "Test Display \(id)",
            isBuiltin: isBuiltin
        )
    }
}

enum ReviewArtifacts {
    static func outputURL(filename: String) -> URL? {
        guard let dir = ProcessInfo.processInfo.environment["GLITTER_REVIEW_OUTPUT"],
              !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: dir).appendingPathComponent(filename)
    }

    @MainActor
    @discardableResult
    static func captureView(_ view: NSView, filename: String? = nil) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let scale = max(1, view.window?.backingScaleFactor ?? 2)
        let width = max(1, Int(round(view.bounds.width * scale)))
        let height = max(1, Int(round(view.bounds.height * scale)))
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )?.retagging(with: .sRGB) ?? view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let filename, let url = outputURL(filename: filename),
           let data = bitmap.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
        return bitmap
    }

    @MainActor
    static func captureLayer(_ layer: CALayer, size: CGSize, scale: CGFloat = 2, filename: String) {
        guard let url = outputURL(filename: filename) else { return }
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let cgImage = context.makeImage() else { return }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    static func samplePixel(_ bitmap: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> [Int] {
        let scaleX = CGFloat(bitmap.pixelsWide) / max(1, bitmap.size.width)
        let scaleY = CGFloat(bitmap.pixelsHigh) / max(1, bitmap.size.height)
        let px = min(max(0, Int((x * scaleX).rounded(.down))), max(0, bitmap.pixelsWide - 1))
        let py = min(max(0, Int((y * scaleY).rounded(.down))), max(0, bitmap.pixelsHigh - 1))
        var pixel = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        bitmap.getPixel(&pixel, atX: px, y: py)
        return pixel
    }
}

@MainActor
func finishAnimation(on controller: NotchPanelController) {
    for _ in 0..<10 {
        guard let motion = controller.motion else { break }
        controller.advanceAnimation(at: motion.started + motion.duration + 0.01)
    }
}

extension TaskStore {
    static func todayFixture(
        mutationService: (any ReminderMutationService)? = nil,
        language: LanguageManager? = nil
    ) -> (TaskStore, RecordingWorkspace) {
        let workspace = RecordingWorkspace()
        let defaults = MemoryDefaults()
        defaults.set("month", forKey: "SandNotch.expandedMode")
        let lang = language ?? LanguageManager(defaults: defaults, preferredLanguages: { ["en"] })
        let store = TaskStore(defaults: defaults, workspace: workspace, mutationService: mutationService, language: lang)
        let list = EKCalendar(for: .reminder, eventStore: store.ek)
        list.title = "学习"
        store.calendars = [list]
        store.selectedCalendarIDs = [list.calendarIdentifier]
        store.access = .granted
        store.fixtureTasks(count: 5, completed: 2)
        return (store, workspace)
    }

    func fixtureTasks(count: Int, completed: Int, longTitles: Bool = false) {
        let names = ["Read the next chapter", "Review lecture notes", "Study for the midterm", "Finish the exercise", "Organize study materials"]
        let tasks = (0..<count).map { i in
            TrackedTask(
                id: "fixture-\(i)",
                title: longTitles
                    ? "Task \(i + 1): A longer reminder title that should wrap cleanly and stay inside the scrolling list"
                    : names[i % names.count],
                dueDay: today,
                completedDay: i < completed ? today : nil,
                isCompleted: i < completed
            )
        }
        apply(tasks)
    }

    func loadDemoMonthFixture(month: Int) {
        today = calendar.date(from: DateComponents(year: 2021, month: month, day: 26))!
        loadDemoData()
    }
}
