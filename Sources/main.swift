import AppKit

// main.swift 的顶层代码在 Swift 5 模式下不自动继承 MainActor，
// 这里显式断言：进程启动时就在主线程。
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
