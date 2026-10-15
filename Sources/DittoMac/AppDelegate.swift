import AppKit
import Carbon.HIToolbox
import DittoMacKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 二次启动信号:已有实例收到后弹出历史面板(对齐原版"再次运行=呼出快速粘贴窗口")
    static let secondLaunchNote = Notification.Name("local.dittomac.secondLaunch")

    /// 列表菜单/快捷键回调要触达面板与系统菜单
    static var shared: AppDelegate?

    private let hotKeyID = "togglePanel"
    private var statusItem: NSStatusItem?
    private let monitor = ClipboardMonitor.shared
    private let store = ClipStore()
    private var _panelController: HistoryPanelController?
    private var settingsController: SettingsWindowController?
    private var pruneTimer: Timer?
    private var panelReleaseWork: DispatchWorkItem?

    /// 面板控制器按需创建;隐藏 2s 后整体释放,空闲时常驻内存更轻(重新打开 ≈30ms,可接受)
    private var panelController: HistoryPanelController {
        panelReleaseWork?.cancel()
        if let c = _panelController { return c }
        let c = HistoryPanelController(store: store)
        c.onHidden = { [weak self] in self?.schedulePanelRelease() }
        _panelController = c
        return c
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // 自测钩子:DITTO_APPEARANCE=dark/light 强制外观(截图验证深浅色)
        switch ProcessInfo.processInfo.environment["DITTO_APPEARANCE"]?.lowercased() {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }

        // 单实例守卫(对齐原版 Ditto):再次启动 → 激活已有实例并让它的历史面板弹出,自己退出。
        // 裸二进制(无 bundle,如自测)不启用守卫
        if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let existing = others.first {
                if #available(macOS 14.0, *) {
                    existing.activate()
                } else {
                    existing.activate(options: .activateIgnoringOtherApps)
                }
                DistributedNotificationCenter.default().postNotificationName(
                    Self.secondLaunchNote, object: nil, deliverImmediately: true)
                PerfLog.event("SECOND_LAUNCH_QUIT", "existing pid=\(existing.processIdentifier)")
                NSApp.terminate(nil)
                return
            }
        }

        buildStatusItem()

        // 剪贴板监听:入库(超限丢弃);面板在屏则增量刷新
        monitor.onClip = { [weak self] raw in
            guard let self else { return }
            self.store.insert(raw, maxDataBytes: Self.maxDataBytesSetting())
            if self.panelController.isOnScreen {
                self.panelController.refreshList()
            }
        }
        if UserDefaults.standard.bool(forKey: DittoSettings.pausedKey) {
            monitor.setPaused(true)
        }
        refreshStatusIcon()

        let headlessRun = ProcessInfo.processInfo.environment["DITTO_STDOUT"] != nil
        if !Permissions.isAccessibilityGranted {
            PerfLog.event("AX_MISSING", "granted=false")
            if !headlessRun {
                // 启动即检测辅助功能权限:未授权时粘贴回不可用,主动引导(每次启动一次)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.showAccessibilityAlert(startup: true)
                }
            }
        } else {
            PerfLog.event("AX_OK", "granted=true")
        }

        if !headlessRun, !UserDefaults.standard.bool(forKey: "ditto.showedStartupMessage") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.showStartupMessage()
            }
        }
        monitor.start()

        refreshHotKey()

        pruneExpired()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.pruneExpired()
        }

        // 设置变更:重注册热键 + 刷新在屏面板
        NotificationCenter.default.addObserver(
            forName: .dittoSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.refreshHotKey()
            if self.panelController.isOnScreen {
                self.panelController.refreshList()
            }
        }

        // 二次启动(被新实例顶到)→ 呼出历史面板
        DistributedNotificationCenter.default().addObserver(
            forName: Self.secondLaunchNote, object: nil, queue: .main
        ) { [weak self] _ in
            self?.togglePanel()
        }

        // 热键录入期间临时注销全局热键(否则按下"当前热键"会先弹面板,录不进去)
        NotificationCenter.default.addObserver(
            forName: .dittoHotKeyRecording, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let recording = (note.userInfo?["recording"] as? Bool) ?? false
            if recording {
                HotKeyCenter.shared.unregister(id: self.hotKeyID)
            } else {
                self.refreshHotKey()
            }
        }

        // 损坏库已自动重建:明确告知用户(备份文件在哪),不静默
        if let backup = store.lastRecoveryBackupPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L10n.dlgDbRebuiltTitle
                alert.informativeText = L10n.dlgDbRebuiltBody + "\(backup)\n" + self.t_dbRebuiltTail()
                alert.addButton(withTitle: L10n.dlgOk)
                alert.runModal()
            }
        }

        PerfLog.event("READY")

        // 自动化自测:开面板→测 P2→关面板(仅 DITTO_SELFTEST=1 时)
        if ProcessInfo.processInfo.environment["DITTO_SELFTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self else { return }
                PerfLog.event("PANEL_SELF_BEGIN")
                self.togglePanel()
                PerfLog.event("PANEL_SELF_END")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.captureIfRequested(view: self.panelController.window?.contentView, tag: "panel")
                    // 悬停浮窗自测:程序化显示并截图
                    if ProcessInfo.processInfo.environment["DITTO_SELFTEST_HOVER"] != nil {
                        self.panelController.showHoverTipForTesting()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            if let tip = self.panelController.hoverTipForTesting() {
                                self.captureIfRequested(view: tip.contentView, tag: "hover-tip")
                            }
                            self.panelController.hoverTestCleanup?()
                            self.panelController.hoverTestCleanup = nil
                            self.panelController.hide()
                            PerfLog.event("SELFTEST_DONE")
                        }
                        return
                    }
                    self.panelController.hide()
                    PerfLog.event("SELFTEST_DONE")
                }
            }
        }

        // 设置窗口自测:打开设置并报告窗口可见性(仅 DITTO_SELFTEST_SETTINGS=1 时)
        if ProcessInfo.processInfo.environment["DITTO_SELFTEST_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                self.showSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if let w = self.settingsController?.window {
                        let f = w.frame
                        let onScreen = NSScreen.screens.contains { $0.frame.intersects(f) }
                        PerfLog.event("SETTINGS_STATE",
                                      "visible=\(w.isVisible) key=\(w.isKeyWindow) onScreen=\(onScreen) frame=\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.width))x\(Int(f.height))")
                        self.captureIfRequested(view: w.contentView, tag: "settings")
                    } else {
                        PerfLog.event("SETTINGS_STATE", "window=nil")
                    }
                    PerfLog.event("SETTINGS_DONE")
                }
            }
        }
    }

    /// DITTO_CAPTURE_DIR 非空时把视图离屏渲染成 PNG(截图取证,无需屏幕录制权限)
    @objc private func captureIfRequested(view: NSView?, tag: String) {
        guard let view,
              let dir = ProcessInfo.processInfo.environment["DITTO_CAPTURE_DIR"],
              !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let rect = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
        view.cacheDisplay(in: rect, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let scale = Int(view.window?.backingScaleFactor ?? 1)
        let path = "\(dir)/\(tag)-\(Int(rect.width))x\(Int(rect.height))@\(scale)x.png"
        try? png.write(to: URL(fileURLWithPath: path))
        PerfLog.event("CAPTURED", path)
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.unregisterAll()
        monitor.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - 面板释放

    private func schedulePanelRelease() {
        panelReleaseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?._panelController = nil
        }
        panelReleaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    // MARK: - 公开操作

    @objc func togglePanel() {
        PerfLog.event("PANEL_REQ")
        panelController.toggle()
        PerfLog.event("PANEL_DONE", "visible=\(panelController.isOnScreen)")
    }

    @objc func showSettings() {
        if settingsController == nil {
            let controller = SettingsWindowController(store: store)
            controller.onClose = { [weak self] in self?.settingsController = nil }
            settingsController = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.showWindow(nil)
        // 部分系统版本对 accessory 应用在显示窗口前的 activate 不生效,补一次确保置前
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 设置中的热键变更后调用:重注册并更新菜单标题
    func refreshHotKey() {
        HotKeyCenter.shared.unregister(id: hotKeyID)
        let d = UserDefaults.standard
        let code = (d.object(forKey: DittoSettings.hotKeyCodeKey) as? NSNumber)?.uint32Value
            ?? DittoSettings.defaultHotKeyCode
        let mods = (d.object(forKey: DittoSettings.hotKeyModsKey) as? NSNumber)?.uintValue
            ?? DittoSettings.defaultHotKeyMods
        let ok = HotKeyCenter.shared.register(keyCode: code, carbonModifiers: mods, id: hotKeyID) { [weak self] in
            DispatchQueue.main.async { self?.togglePanel() }
        }
        if !ok {
            PerfLog.event("HOTKEY_CONFLICT", Fmt.hotKeyString(code: code, mods: mods))
        }
    }

    /// 数据库重建弹窗的收尾句
    private func t_dbRebuiltTail() -> String {
        L10n.t("并新建了空数据库继续记录。", "An empty database was created and recording continues.")
    }

    // MARK: - 状态栏

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        refreshStatusIcon()
    }

    /// 左键:秒开面板;右键:弹出菜单(每次动态构建 → 语言切换即时生效)
    @objc private func statusItemClicked(_ sender: Any?) {
        let type = NSApp.currentEvent?.type
        if type == .rightMouseUp || type == .rightMouseDown {
            statusItem?.menu = buildStatusMenu()
            statusItem?.button?.performClick(nil) // 挂上 menu 后模拟点击 → 弹出菜单
            statusItem?.menu = nil
        } else {
            togglePanel()
        }
    }

    /// 菜单栏图标:原版 Ditto 图标(Ditto2.ico);暂停时右上角红色暂停角标(对应原版 NoCopyCb 换图标行为)
    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        let paused = monitor.isPaused
        let base = NSApp.applicationIconImage ?? NSImage(systemSymbolName: "doc.on.doc.fill",
                                                          accessibilityDescription: "DittoMac")!
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: paused ? 0.5 : 1)
            if paused {
                NSColor.systemRed.setFill()
                NSRect(x: rect.maxX - 8, y: 0, width: 8, height: 8).fill()
                NSColor.white.setFill()
                NSRect(x: rect.maxX - 6.1, y: 1.5, width: 1.3, height: 5).fill()
                NSRect(x: rect.maxX - 3.6, y: 1.5, width: 1.3, height: 5).fill()
            }
            return true
        }
        img.isTemplate = false   // 彩色原版图标
        button.image = img
        button.contentTintColor = nil
    }

    /// 托盘右键菜单(原版 IDR_MENU 的 macOS 映射,保持原顺序;文案随 L10n)
    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.items = [
            menuItem(L10n.menuShowQuickPaste, #selector(togglePanel)),
            menuItem(L10n.menuOptions, #selector(showSettings)),
            NSMenuItem.separator(),
            menuItem(L10n.menuStartupMessage, #selector(showStartupMessage)),
            menuItem(L10n.menuGlobalHotKeys, #selector(showSettings)),
            menuItem(L10n.menuClearClipData, #selector(clearHistory)),
            NSMenuItem.separator(),
            menuItem(L10n.menuBackup, #selector(backupDatabase)),
            menuItem(L10n.menuRestore, #selector(restoreDatabase)),
            NSMenuItem.separator(),
            menuItem(L10n.menuImportClips, #selector(importClips)),
            NSMenuItem.separator(),
            menuItem(L10n.menuHelp, #selector(showHelp)),
            NSMenuItem.separator(),
            buildConnectItem(),
            menuItem(L10n.menuSaveCurrentClip, #selector(saveCurrentClipboard)),
            NSMenuItem.separator(),
            menuItem(L10n.menuExit, #selector(quit)),
        ]
        return menu
    }

    /// 原版 "Connect To Clipboard":勾选态 = 已连接(未暂停)
    private func buildConnectItem() -> NSMenuItem {
        let item = menuItem(L10n.menuConnectClipboard, #selector(togglePaused))
        item.state = monitor.isPaused ? .off : .on
        return item
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// 系统菜单(原版 IDR_QUICK_PASTE_SYSTEM_MENU 的 macOS 映射;面板右下按钮用)
    func buildSystemMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(menuItem(L10n.menuOptions, #selector(showSettings)))

        let quick = NSMenuItem(title: L10n.menuQuickOptions, action: nil, keyEquivalent: "")
        let quickMenu = NSMenu()
        let lines = NSMenuItem(title: L10n.menuLinesPerClip, action: nil, keyEquivalent: "")
        let linesMenu = NSMenu()
        let current = UserDefaults.standard.integer(forKey: DittoSettings.linesPerRowKey) == 0
            ? DittoSettings.defaultLinesPerRow
            : UserDefaults.standard.integer(forKey: DittoSettings.linesPerRowKey)
        for n in 1...5 {
            let mi = menuItem("\(n)", #selector(linesPerRowPicked(_:)))
            mi.state = n == current ? .on : .off
            mi.representedObject = n
            linesMenu.addItem(mi)
        }
        lines.submenu = linesMenu
        quickMenu.addItem(lines)

        let pos = NSMenuItem(title: L10n.menuPositioning, action: nil, keyEquivalent: "")
        let posMenu = NSMenu()
        let mode = UserDefaults.standard.string(forKey: DittoSettings.positionModeKey)
            ?? DittoSettings.defaultPositionMode
        let posOptions = [("atCursor", L10n.menuAtCursor), ("atPrevious", L10n.menuAtPrevious)]
        for (value, title) in posOptions {
            let mi = menuItem(title, #selector(positionModePicked(_:)))
            mi.state = value == mode ? .on : .off
            mi.representedObject = value
            posMenu.addItem(mi)
        }
        pos.submenu = posMenu
        quickMenu.addItem(pos)

        let top = menuItem(L10n.menuAlwaysOnTop, #selector(panelTogglePersistent))
        top.state = panelController.isPersistentMode ? .on : .off
        quickMenu.addItem(top)
        quick.submenu = quickMenu
        menu.addItem(quick)

        menu.addItem(.separator())
        menu.addItem(menuItem(L10n.menuClearClipData, #selector(clearHistory)))
        menu.addItem(.separator())
        menu.addItem(menuItem(L10n.menuBackup, #selector(backupDatabase)))
        menu.addItem(.separator())
        menu.addItem(buildConnectItem())
        menu.addItem(menuItem(L10n.menuSaveCurrentClip, #selector(saveCurrentClipboard)))
        menu.addItem(.separator())
        menu.addItem(menuItem(L10n.menuExit, #selector(quit)))
        return menu
    }

    @objc private func linesPerRowPicked(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? Int else { return }
        UserDefaults.standard.set(n, forKey: DittoSettings.linesPerRowKey)
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
    }

    @objc private func positionModePicked(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        UserDefaults.standard.set(mode, forKey: DittoSettings.positionModeKey)
    }

    // MARK: - 面板辅助(列表菜单/快捷键回调入口)

    @objc func panelToggleDescTooltip() { panelController.toggleDescTooltip() }
    @objc func panelTogglePersistent() { panelController.togglePersistent() }
    func panelClearFilter() {
        panelController.clearFilter()
        if panelController.isOnScreen {
            panelController.listViewController.reload(query: "")
        }
    }
    func panelSetFilter(_ q: String) {
        panelController.setFilter(q)
        if !panelController.isOnScreen { panelController.show() }
    }

    // MARK: - 托盘动作

    /// 启动消息(原版气泡等价):首次启动或从菜单触发
    @objc private func showStartupMessage() {
        let alert = NSAlert()
        alert.messageText = L10n.dlgStartupTitle
        alert.informativeText = L10n.dlgStartupBody
        alert.runModal()
        UserDefaults.standard.set(true, forKey: "ditto.showedStartupMessage")
    }

    /// 帮助(原版 Help 菜单等价):快捷键速查
    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = L10n.dlgHelpTitle
        alert.informativeText = L10n.dlgHelpBody
        alert.runModal()
    }

    /// 原版 Import Clip(s):文本文件逐个入库
    @objc private func importClips() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            for url in panel.urls {
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    _ = self.store.insert(RawClip(text: text, appName: "导入"),
                                          maxDataBytes: Self.maxDataBytesSetting())
                }
            }
            if self.panelController.isOnScreen {
                self.panelController.refreshList()
            }
        }
    }

    /// 原版 Backup Database:checkpoint 后拷贝数据库文件
    @objc private func backupDatabase() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.data]
        panel.nameFieldStringValue = "ditto-backup-\(Int(Date().timeIntervalSince1970)).sqlite"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let ok = self?.store.backup(to: url) ?? false
            let alert = NSAlert()
            if ok {
                alert.messageText = L10n.dlgBackupDone
                alert.informativeText = url.path
            } else {
                alert.alertStyle = .critical
                alert.messageText = L10n.dlgBackupFailed
            }
            alert.runModal()
        }
    }

    /// 原版 Restore Database:替换库文件后重启应用
    @objc private func restoreDatabase() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.data]
        panel.message = L10n.dlgRestorePrompt
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let dbURL = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DittoMac/ditto.sqlite")
            let alert = NSAlert()
            do {
                _ = self.store.backup(to: URL(fileURLWithPath: dbURL.path + ".pre-restore"))
                try? FileManager.default.removeItem(at: dbURL)
                try FileManager.default.copyItem(at: url, to: dbURL)
                alert.messageText = L10n.dlgRestoredTitle
                alert.addButton(withTitle: L10n.dlgOk)
                alert.runModal()
                let bundlePath = Bundle.main.bundlePath
                if !bundlePath.isEmpty {
                    try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: [bundlePath])
                }
                NSApp.terminate(nil)
            } catch {
                alert.alertStyle = .critical
                alert.messageText = L10n.dlgRestoreFailed + " \(error.localizedDescription)"
                alert.runModal()
            }
        }
    }

    /// 原版 Save Current Clipboard:立即把当前剪贴板记一条
    @objc private func saveCurrentClipboard() {
        _ = monitor.captureNow()
        if panelController.isOnScreen {
            panelController.refreshList()
        }
    }

    /// 辅助功能权限引导(粘贴回依赖;带"不再提示")
    func showAccessibilityAlert(startup: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = startup ? L10n.axStartupTitle : L10n.axPasteTitle
        alert.informativeText = L10n.axBody
        alert.addButton(withTitle: L10n.btnOpenSettings)
        alert.addButton(withTitle: L10n.btnLater)
        let suppress = NSButton(checkboxWithTitle: L10n.axDontAsk, target: nil, action: nil)
        alert.accessoryView = suppress
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openAccessibilitySettings()
        }
        if suppress.state == .on {
            UserDefaults.standard.set(true, forKey: "ditto.suppressAXAlert")
        }
    }

    /// 粘贴回失败时调用:系统授权弹窗 + 我们的说明(受"不再提示"控制)
    func promptAccessibilityForPaste() {
        Permissions.promptAccessibility()
        if !UserDefaults.standard.bool(forKey: "ditto.suppressAXAlert") {
            showAccessibilityAlert(startup: false)
        }
    }

    @objc private func togglePaused() {
        let paused = !monitor.isPaused
        UserDefaults.standard.set(paused, forKey: DittoSettings.pausedKey)
        monitor.setPaused(paused)
        refreshStatusIcon()
        NotificationCenter.default.post(name: .dittoPausedChanged, object: nil)
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.dlgClearTitle
        alert.informativeText = L10n.dlgClearBody
        alert.addButton(withTitle: L10n.dlgClear)
        alert.addButton(withTitle: L10n.dlgCancel)
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clear(keepingPinned: true)
        if panelController.isOnScreen {
            panelController.refreshList()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 设置读取

    private func pruneExpired() {
        let d = UserDefaults.standard
        let maxItems = (d.object(forKey: DittoSettings.maxItemsKey) as? NSNumber)?.intValue
            ?? DittoSettings.defaultMaxItems
        let maxAgeDays = (d.object(forKey: DittoSettings.maxAgeDaysKey) as? NSNumber)?.intValue
            ?? DittoSettings.defaultMaxAgeDays
        // 后台清理,不占主线程(ClipStore 内部串行队列保证线程安全)
        DispatchQueue.global(qos: .utility).async { [store] in
            store.prune(maxItems: maxItems, maxAgeDays: maxAgeDays)
        }
    }

    private static func maxDataBytesSetting() -> Int {
        if let n = UserDefaults.standard.object(forKey: DittoSettings.maxDataBytesKey) as? NSNumber {
            return n.intValue
        }
        return DittoSettings.defaultMaxDataBytes
    }
}
