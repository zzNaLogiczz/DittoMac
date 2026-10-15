import AppKit

// DittoMac 入口:菜单栏常驻应用(LSUIElement,不占 Dock 图标)
PerfLog.event("START")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
