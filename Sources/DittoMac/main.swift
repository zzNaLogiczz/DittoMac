import AppKit
import DittoMacKit

// DittoMac 入口:菜单栏常驻应用(LSUIElement,不占 Dock 图标)

// 便携模式引导(上游 GetIsPortableDitto,Options.cpp:200-227 的标记文件检测):
// bundle 旁存在 DittoMac.portable → 数据库/主题/日志/设置全部落 <便携根>/DittoMac/,
// 且 DittoSettings 切到便携 plist suite。必须在任何 DittoSettings 读取之前执行
// —— 以下是全文件最早的代码,后续再无第二入口。
PortableMode.bootstrap(bundleURL: Bundle.main.bundleURL)

// 调试日志落盘(上游 "Write debug to file"):按设置开关装配共享 FileLog;
// 开启后 PerfLog 事件与 DiagLog 错误都追加到 logs/ditto-YYYYMMDD.log
FileLog.setEnabled(DittoSettings.writeDebugLogFile(), directory: PortableMode.currentLogsDirectory)

PerfLog.event("START")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
