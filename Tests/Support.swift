import AppKit

final class MemoryDefaults: UserDefaults {
    var values: [String: Any] = [:]
    var dataReads: [String] = []
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { dataReads.append(key); return values[key] as? Data }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    override func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

final class TestScreen: NSScreen {
    let testFrame: NSRect
    let testID: UInt32
    let cameraWidth: CGFloat
    let refreshRate: Int
    init(id: UInt32, frame: NSRect, notch: CGFloat = 0, refreshRate: Int = 120) {
        testFrame = frame
        testID = id
        cameraWidth = notch
        self.refreshRate = refreshRate
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("unused") }
    override var backingScaleFactor: CGFloat { 2 }
    override var maximumFramesPerSecond: Int { refreshRate }
    override var frame: NSRect { testFrame }
    override var visibleFrame: NSRect { testFrame }
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets(top: cameraWidth > 0 ? 32 : 0, left: 0, bottom: 0, right: 0) }
    override var deviceDescription: [NSDeviceDescriptionKey: Any] { [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: testID)] }
    override var localizedName: String { "Test Display \(testID)" }
}

final class RecordingWorkspace: NSWorkspace {
    var openedURLs: [URL] = []
    override func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
    }
}

// NSScreen 的刘海区域为不可覆写的 Swift 扩展属性，测试构建使用等价的假屏幕数据。
extension NSScreen {
    var fixtureTopLeftArea: NSRect? {
        guard let screen = self as? TestScreen else { return auxiliaryTopLeftArea }
        guard screen.cameraWidth > 0 else { return nil }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - 32,
                      width: (screen.frame.width - screen.cameraWidth) / 2, height: 32)
    }
    var fixtureTopRightArea: NSRect? {
        guard let screen = self as? TestScreen else { return auxiliaryTopRightArea }
        guard screen.cameraWidth > 0 else { return nil }
        return NSRect(x: screen.frame.midX + screen.cameraWidth / 2, y: screen.frame.maxY - 32,
                      width: (screen.frame.width - screen.cameraWidth) / 2, height: 32)
    }
}
