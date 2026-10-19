import AppKit
import Carbon.HIToolbox
import DittoMacKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 二次启动信号:已有实例收到后弹出历史面板(对齐原版"再次运行=呼出快速粘贴窗口")
    static let secondLaunchNote = Notification.Name("local.dittomac.secondLaunch")

    /// 命令行动词转发信号(上游 Command Line Options:第二实例把 /Verb 转发给已运行
    /// 实例执行 —— 上游用 SendMessage(WM_OPEN_CLOSE_WINDOW 等),macOS 用分布式通知)
    static let verbNote = Notification.Name("local.dittomac.verb")

    /// 列表菜单/快捷键回调要触达面板与系统菜单
    static var shared: AppDelegate?

    private let hotKeyID = "togglePanel"
    /// 组热键注册 id 前缀(组 id 拼在后;HotKeyCenter 支持任意多命名热键)
    private static let groupHotKeyPrefix = "group."
    /// 条目热键注册 id 前缀(原版 Main.lShortCut/globalShortCut;条目 id 拼在后)
    private static let clipHotKeyPrefix = "clip."
    /// 复制缓冲热键注册 id 前缀(原版 Copy Buffers;"copybuffer.<n>.<action>" 拼在后)
    private static let copyBufferHotKeyPrefix = "copybuffer."
    private var statusItem: NSStatusItem?
    private let monitor = ClipboardMonitor.shared
    private let store = ClipStore()
    /// 使用统计(原版 TotalCopy/TotalPaste 计数:累计复制 / 累计粘贴)
    private let stats = UsageStats.shared
    /// 复制缓冲 1-3 引擎(快照 → ⌘C/⌘X → 入库关联 → 恢复;见 CopyBufferController)
    private let copyBuffers: CopyBufferController
    private var _panelController: HistoryPanelController?
    private var settingsController: SettingsWindowController?
    /// 删除剪贴板数据窗口(单实例;关闭即释放)
    private var deleteDataController: DeleteClipDataWindowController?
    /// 统计窗口(单实例;关闭即释放)
    private var statsController: StatsWindowController?
    private var pruneTimer: Timer?
    /// 局域网接收服务器(原版 Server.cpp TCP 监听;默认端口 23443,接收开关默认关)
    private let netSyncServer = NetSyncServer()
    /// 当前监听配置快照(设置变更时比对,变了才重启监听器)
    private var netSyncConfig: (enabled: Bool, port: Int, password: String?)?
    /// 系统空闲秒数(原版 IdleSeconds,Misc.cpp:141-165 的 macOS 等价:
    /// CGEventSource 读任意输入事件距今秒数;注入点供单测)。
    /// kCGAnyInputEventType 不暴露给 Swift,等价值 = CGEventType(~0)
    var idleSecondsProvider: () -> Double = {
        let anyInput = CGEventType(rawValue: UInt32.max) ?? .leftMouseDown
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }
    private var panelReleaseWork: DispatchWorkItem?
    /// 组热键双击检测:上次触发的组 id 与时刻(500ms 窗口;原版 GroupDoubleClickTimeMS 默认 500,MainFrm.cpp:638-659
    /// 的 GROUP_DOUBLE_CLICK 定时器机制,此处简化为时间戳比较)
    private var lastGroupHotKey: (id: Int64, at: Date)?

    override init() {
        copyBuffers = CopyBufferController(store: store, monitor: monitor)
        super.init()
    }

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

        // 单实例守卫(对齐原版 Ditto):再次启动 → 激活已有实例,自己退出。
        // 裸二进制(无 bundle,如自测)不启用守卫。
        // 带命令行动词时(上游 Command Line Options):动词转发给已运行实例执行;
        // 无动词 → 维持原行为(呼出历史面板)
        let verb = CommandLineParser.parse(CommandLine.arguments)
        if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let existing = others.first {
                if #available(macOS 14.0, *) {
                    existing.activate()
                } else {
                    existing.activate(options: .activateIgnoringOtherApps)
                }
                if let verb {
                    // 有动词:转发后退出(上游 SendMessage(hWnd, WM_*) 后 return FALSE)
                    DistributedNotificationCenter.default().postNotificationName(
                        Self.verbNote, object: nil,
                        userInfo: Self.verbUserInfo(verb), deliverImmediately: true)
                    PerfLog.event("VERB_FORWARDED", "\(verb.rawName) pid=\(existing.processIdentifier)")
                } else {
                    DistributedNotificationCenter.default().postNotificationName(
                        Self.secondLaunchNote, object: nil, deliverImmediately: true)
                }
                PerfLog.event("SECOND_LAUNCH_QUIT", "existing pid=\(existing.processIdentifier)")
                NSApp.terminate(nil)
                return
            }
        }
        // 无已运行实例:动词本地生效(上游 Connect/Disconnect 决定启动时的记录状态,
        // 其余动词上游直接退出;偏差:此处选择继续启动,避免"带参启动即闪退")
        if let verb {
            applyStartupVerb(verb)
        }

        buildMainMenu()
        buildStatusItem()
        NotificationCenter.default.addObserver(
            self, selector: #selector(nativeMenuLanguageChanged),
            name: L10n.changedNotification, object: nil)

        // 剪贴板监听:入库(超限丢弃);面板在屏则增量刷新。
        // 组热键双击抓板时 monitor.captureParentID 被临时指到目标组(见 handleGroupHotKey)
        monitor.onClip = { [weak self] raw in
            guard let self else { return }
            // 入库成功(新插入或去重置顶)都算一次"捕获复制"(原版 TotalCopyCount)
            let parent = self.monitor.captureParentID
            let captured = parent == -1
                ? self.store.insert(raw, maxDataBytes: Self.maxDataBytesSetting())
                : self.store.captureToGroup(raw, maxDataBytes: Self.maxDataBytesSetting(), parentID: parent)
            if let captured {
                self.stats.noteCopy()
                if parent == -1 {
                    self.copyBuffers.didCapture(clipID: captured.id,
                                                changeCount: self.monitor.lastCaptureChangeCount)
                }
            }
            if self.panelController.isOnScreen {
                self.panelController.refreshList()
            }
        }
        // 捕获排除(原版 RegExFilter + 应用包含/排除列表):设置在闭包内现读,改动即时生效
        monitor.shouldDrop = { clip in
            CaptureFilter.shouldExclude(text: clip.text,
                                        appName: clip.appName,
                                        rules: DittoSettings.loadExcludeRules(),
                                        appInclude: DittoSettings.appInclude(),
                                        appExclude: DittoSettings.appExclude())
        }
        if DittoSettings.defaults.bool(forKey: DittoSettings.pausedKey) {
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

        if !headlessRun, !DittoSettings.defaults.bool(forKey: "ditto.showedStartupMessage") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.showStartupMessage()
            }
        }
        monitor.start()

        refreshHotKey()
        refreshGroupHotkeys(panelVisible: false)
        refreshClipHotkeys(panelVisible: false)
        refreshCopyBufferHotkeys()
        wireNetSync()   // 局域网接收:挂插入回调 + 按设置起/停监听(默认关)

        // 每应用自定义按键串(上游 Custom Key Strokes):粘贴/复制/剪切时前台应用
        // 命中条目 → 用该串替换默认 ⌘V/⌘C/⌘X(PasteBack.triggerKey 内消费)
        PasteBack.keyStringResolver = { kind in
            let app = NSWorkspace.shared.frontmostApplication
            return AppKeyStrings.matchedString(kind: kind,
                                               appName: app?.localizedName ?? nil,
                                               bundleID: app?.bundleIdentifier ?? nil,
                                               entries: AppKeyStrings.load())
        }

        // 组热键绑定变化(组属性窗口保存/删组)→ 重注册
        NotificationCenter.default.addObserver(
            forName: .dittoGroupHotkeysChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshGroupHotkeys(panelVisible: self?.panelController.isOnScreen ?? false)
        }

        // 条目热键绑定变化(条目属性/快速属性/编辑器)→ 重注册
        NotificationCenter.default.addObserver(
            forName: .dittoClipHotkeysChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshClipHotkeys(panelVisible: self?.panelController.isOnScreen ?? false)
        }

        pruneExpired(gatedByIdle: false)   // 启动后不久先清一次(既有行为,不走空闲门控)
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            // 周期清理在系统空闲时才执行(原版删除跑在空闲判定之后):未到阈值
            // 本轮跳过,下个 tick 重试;门控判定是纯函数(PruneGate)单测覆盖
            self?.pruneExpired(gatedByIdle: true)
        }

        // 设置变更:重注册热键(全局 + 复制缓冲)+ 刷新在屏面板
        NotificationCenter.default.addObserver(
            forName: .dittoSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.refreshHotKey()
            self.refreshCopyBufferHotkeys()
            self.refreshNetSyncListener()   // 网络同步:接收开关/端口/密码变更 → 起/停监听
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

        // 命令行动词(第二实例转发来)→ 本地执行
        // (上游各 WM_* 消息:WM_OPEN_CLOSE_WINDOW / WM_SET_CONNECTED /
        // WM_PLAIN_TEXT_PASTE / WM_PASTE_CLIP / WM_EDIT_CLIP / WM_CLOSE)
        DistributedNotificationCenter.default().addObserver(
            forName: Self.verbNote, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?["verb"] as? String,
                  let verb = DittoVerb.from(rawName: raw,
                                            clipID: (note.userInfo?["id"] as? Int).map(Int64.init))
            else { return }
            self.execute(verb)
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

    @objc private func showShortcutSettings() {
        showSettings()
        settingsController?.selectSection(.shortcuts)
    }

    /// 设置中的热键变更后调用:重注册并更新菜单标题
    func refreshHotKey() {
        HotKeyCenter.shared.unregister(id: hotKeyID)
        let d = DittoSettings.defaults
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

    // MARK: - 组热键(原版组热键:单击开组,500ms 内双击=抓板入组)

    /// 重注册全部组热键。全局的常驻;非全局的仅在面板在屏时注册
    /// (原版非全局热键只在快速粘贴窗口按键路径里派发,注册式实现等价且更直接)
    func refreshGroupHotkeys(panelVisible: Bool) {
        HotKeyCenter.shared.unregisterAll(matchingPrefix: Self.groupHotKeyPrefix)
        for (groupID, hk) in store.allGroupHotkeys() {
            guard hk.isGlobal || panelVisible else { continue }
            let ok = HotKeyCenter.shared.register(
                keyCode: hk.keyCode, carbonModifiers: hk.modifiers,
                id: "\(Self.groupHotKeyPrefix)\(groupID)") { [weak self] in
                    DispatchQueue.main.async { self?.handleGroupHotKey(groupID: groupID) }
                }
            if !ok {
                PerfLog.event("GROUP_HOTKEY_CONFLICT", "group=\(groupID)")
            }
        }
    }

    // MARK: - 条目热键(原版 Main.lShortCut/globalShortCut:按下 = 把条目粘贴进当前应用)

    /// 重注册全部条目热键。全局的常驻;非全局的仅在面板在屏时注册
    /// (与组热键同一策略,镜像原版"非全局热键只在快速粘贴窗口派发")
    func refreshClipHotkeys(panelVisible: Bool) {
        HotKeyCenter.shared.unregisterAll(matchingPrefix: Self.clipHotKeyPrefix)
        for (clipID, hk) in store.allClipHotkeys() {
            guard hk.isGlobal || panelVisible else { continue }
            let ok = HotKeyCenter.shared.register(
                keyCode: hk.keyCode, carbonModifiers: hk.modifiers,
                id: "\(Self.clipHotKeyPrefix)\(clipID)") { [weak self] in
                    DispatchQueue.main.async { self?.handleClipHotKey(clipID: clipID) }
                }
            if !ok {
                PerfLog.event("CLIP_HOTKEY_CONFLICT", "clip=\(clipID)")
            }
        }
    }

    /// 条目热键触发:完整粘贴流程(payload → PasteBack.paste 到当前应用 → 标记已粘贴),
    /// 与面板回车粘贴同一管线;条目已删 → 清理绑定
    private func handleClipHotKey(clipID: Int64) {
        guard let payload = store.payload(id: clipID) else {
            store.setClipHotkey(id: clipID, hotkey: nil)
            refreshClipHotkeys(panelVisible: panelController.isOnScreen)
            return
        }
        if !Permissions.isAccessibilityGranted {
            // 未授权:内容仍在剪贴板可手动 ⌘V,并引导授权(与面板粘贴路径一致)
            PasteBack.write(payload, monitor: monitor)
            promptAccessibilityForPaste()
        } else {
            _ = PasteBack.paste(payload, monitor: monitor)
        }
        store.markPasted(id: clipID, at: Date())
        stats.notePaste()   // 原版 TotalPasteCount:每次粘贴计数
    }

    /// 条目热键绑定变化后的刷新入口(属性窗口/列表快速属性调用)
    func clipHotkeysChanged() {
        refreshClipHotkeys(panelVisible: panelController.isOnScreen)
    }

    // MARK: - 复制缓冲热键(原版 Copy Buffers:每个缓冲 粘贴/复制/剪切 三键)

    /// 重注册全部复制缓冲热键(设置变更/启动时;全局常驻)
    func refreshCopyBufferHotkeys() {
        HotKeyCenter.shared.unregisterAll(matchingPrefix: Self.copyBufferHotKeyPrefix)
        for index in 1...DittoSettings.copyBufferCount {
            for action in CopyBufferAction.allCases {
                guard let key = DittoSettings.copyBufferKey(index: index, action: action) else {
                    continue   // 未绑定(默认无或用户解绑)
                }
                let ok = HotKeyCenter.shared.register(
                    keyCode: key.code, carbonModifiers: key.mods,
                    id: "\(Self.copyBufferHotKeyPrefix)\(index).\(action.rawValue)"
                ) { [weak self] in
                    DispatchQueue.main.async {
                        self?.copyBuffers.handleHotkey(bufferIndex: index, action: action)
                    }
                }
                if !ok {
                    PerfLog.event("COPY_BUFFER_HOTKEY_CONFLICT",
                                  "buffer=\(index) action=\(action.rawValue)")
                }
            }
        }
    }

    // MARK: - 命令行动词(上游 Command Line Options,转发后的执行端)

    /// 动词 → 分布式通知 userInfo(只放 property list 标量)
    private static func verbUserInfo(_ verb: DittoVerb) -> [String: Any] {
        var info: [String: Any] = ["verb": verb.rawName]
        if let id = verb.clipID { info["id"] = Int(id) }
        return info
    }

    /// 首次启动自带动词(无已运行实例):Connect/Disconnect 决定初始记录状态,
    /// Open 启动完成后弹面板;其余动词仅在已有实例时有意义(忽略)
    private func applyStartupVerb(_ verb: DittoVerb) {
        PerfLog.event("VERB_STARTUP", verb.rawName)
        switch verb {
        case .connect:
            DittoSettings.defaults.set(false, forKey: DittoSettings.pausedKey)
        case .disconnect:
            DittoSettings.defaults.set(true, forKey: DittoSettings.pausedKey)
        case .open:
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.panelController.show()
            }
        default:
            break
        }
    }

    /// 已运行实例执行转发来的动词(上游 WM_* 处理的一一对应)
    private func execute(_ verb: DittoVerb) {
        PerfLog.event("VERB_EXEC", verb.rawName)
        switch verb {
        case .open:
            panelController.show()
        case .close:
            panelController.hide()
        case .connect:
            setPaused(false)
        case .disconnect:
            setPaused(true)
        case .plainTextPaste:
            plainTextPaste()
        case .exitApp:
            NSApp.terminate(nil)
        case .paste(let clipID):
            // Paste:id = 该条目的完整粘贴管线(与条目热键同路径)
            guard let payload = store.payload(id: clipID) else { return }
            if Permissions.isAccessibilityGranted {
                _ = PasteBack.paste(payload, monitor: monitor)
            } else {
                PasteBack.write(payload, monitor: monitor)
                promptAccessibilityForPaste()
            }
            store.markPasted(id: clipID, at: Date())
            stats.notePaste()   // 原版 TotalPasteCount:每次粘贴计数
        case .edit(let clipID):
            guard let item = store.item(id: clipID) else { return }
            _ = showClipEditor(clip: item)
        }
    }

    /// /PlainTextPaste:取当前剪贴板文本 → 只写纯文本格式(自写豁免)→ 发粘贴键
    private func plainTextPaste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return
        }
        let pb = NSPasteboard.general
        let countBefore = pb.changeCount
        pb.clearContents()
        pb.setString(text, forType: .string)
        monitor.noteSelfWrite(countBefore: countBefore, countAfter: pb.changeCount)
        _ = PasteBack.triggerKey(.paste)
    }

    // MARK: - 编辑器 / 对比 / 删除剪贴板数据窗口

    /// 打开条目编辑器(clip=nil = 新建条目,首保存在当前组落一条;原版 2.7.8/2.7.9)
    @discardableResult
    func showClipEditor(clip: ClipItem?) -> ClipEditorWindowController {
        let parentID = clip?.parentID ?? panelController.currentParentID
        let payload = clip.flatMap { store.payload(id: $0.id) }
        let controller = ClipEditorWindowController.focusOrCreate(clip: clip, payload: payload,
                                                                  store: store, parentID: parentID)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        if controller.window?.isVisible == true { controller.window?.center() }
        return controller
    }

    /// 打开对比窗口(恰好两条;原版 Compare 2.7.14)
    @discardableResult
    func showCompareClips(_ left: ClipItem, _ right: ClipItem) -> CompareWindowController {
        let controller = CompareWindowController.focusOrCreate(left: left, right: right, store: store)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        if controller.window?.isVisible == true { controller.window?.center() }
        return controller
    }

    /// 打开"删除剪贴板数据"过滤删除窗口(替代原简单清空路径;原版 2.7.6)
    func showDeleteClipData() {
        if deleteDataController == nil {
            let controller = DeleteClipDataWindowController(store: store)
            controller.onClose = { [weak self] in self?.deleteDataController = nil }
            deleteDataController = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        deleteDataController?.showWindow(nil)
    }

    /// 托盘:修正置顶顺序(原版 Fixup Sticky Clip Order → ReOrderStickyClips)
    @objc private func fixupStickyOrder() {
        store.fixupStickyOrder()
        if panelController.isOnScreen {
            panelController.refreshList()
        }
    }

    /// 托盘/系统菜单:新建条目(打开空白编辑器,首保存入库)
    @objc private func newClip() {
        showClipEditor(clip: nil)
    }


    /// 组属性/删组后的刷新入口(列表控制器等调用)
    func groupHotkeysChanged() {
        refreshGroupHotkeys(panelVisible: panelController.isOnScreen)
    }

    /// 面板显示/隐藏时调用:切换非全局组热键与条目热键的注册
    func panelVisibilityChanged() {
        refreshGroupHotkeys(panelVisible: panelController.isOnScreen)
        refreshClipHotkeys(panelVisible: panelController.isOnScreen)
    }

    // MARK: - 网络同步(原版 LAN CLIP SYNC:Server.cpp 接收 / Client.cpp 发送)

    /// 挂接收回调并按设置起/停监听。收到的条目走既有 insert 管线:
    /// appName = "↔ <机器名>"(上游收到的条目带发送方信息);配置了接收组则落组
    private func wireNetSync() {
        netSyncServer.onClip = { [weak self] header, payload in
            guard let self, var raw = payload.toRawClip() else { return false }
            raw.appName = "↔ " + header.computerName
            // 落库与面板刷新(面板只在主线程碰)
            let parent = DittoSettings.netReceiveGroupID()
            if self.store.insert(raw, maxDataBytes: Self.maxDataBytesSetting(),
                                 parentID: parent) != nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.panelController.isOnScreen else { return }
                    self.panelController.refreshList()
                }
                return true
            }
            return false
        }
        refreshNetSyncListener()
    }

    /// 监听与设置对齐:接收开(默认关)→ 绑定端口(默认 23443)监听;关 → 关 socket。
    /// 配置快照比对,无变化不动(避免设置窗口无关改动反复重启监听)
    private func refreshNetSyncListener() {
        let enabled = DittoSettings.netReceiveEnabled()
        let port = DittoSettings.netPort()
        let password = NetSyncKeychain.loadPassword()
        if netSyncConfig?.enabled == enabled, netSyncConfig?.port == port,
           netSyncConfig?.password == password { return }
        netSyncConfig = (enabled, port, password)
        if enabled {
            if netSyncServer.start(port: UInt16(clamping: port), password: password) {
                PerfLog.event("NETSYNC_LISTENING",
                              "port=\(netSyncServer.boundPort ?? 0) encrypted=\(password != nil)")
            } else {
                netSyncConfig = nil   // 失败不记快照,下次设置变更可重试
                PerfLog.event("NETSYNC_LISTEN_FAILED", "port=\(port)")
            }
        } else {
            netSyncServer.stop()
            PerfLog.event("NETSYNC_STOPPED")
        }
    }

    /// 把若干条目发给好友(列表右键「发送到」):单连接发全部 clip 帧 + exit 帧;
    /// 发送在后台队列,结果弹窗回主线程
    func sendClips(ids: [Int64], to friend: NetSyncFriend) {
        let payloads = ids.compactMap { id -> NetSyncClipPayload? in
            guard let raw = store.payload(id: id) else { return nil }
            return NetSyncClipPayload.from(raw: raw)
        }
        guard !payloads.isEmpty else { return }
        let password = NetSyncKeychain.loadPassword()
        // 机器名(上游 m_cComputerName):本机名,取不到退 bundle 名
        let computerName = Host.current().localizedName
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "DittoMac"
        let count = payloads.count
        PerfLog.event("NETSYNC_SEND_BEGIN", "friend=\(friend.name) clips=\(count)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            NetSyncClient.send(clips: payloads, to: friend.host,
                               port: UInt16(clamping: friend.port),
                               password: password, computerName: computerName,
                               completionQueue: .main) { ok, message in
                PerfLog.event("NETSYNC_SEND_DONE", "ok=\(ok) \(message)")
                self?.showNetSendResult(ok: ok, friend: friend, count: count)
            }
        }
    }

    /// 发送结果弹窗(成功/失败;失败信息指向常见原因)
    private func showNetSendResult(ok: Bool, friend: NetSyncFriend, count: Int) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if ok {
            alert.messageText = L10n.netSendDoneTitle
            alert.informativeText = L10n.netSendDoneBody(count, friend.name)
        } else {
            alert.alertStyle = .warning
            alert.messageText = L10n.netSendFailedTitle
            alert.informativeText = L10n.netSendFailedBody(friend.host, friend.port)
        }
        alert.addButton(withTitle: L10n.dlgOk)
        alert.runModal()
    }

    /// 组热键触发:同组 500ms 内第二次按下 → 把当前剪贴板直接存入该组
    /// (原版 MainFrm.cpp:638-656 二击分支:SetActiveGroupId + SendCopy,由
    /// CopyThread.cpp:64 的 GetActiveGroupId 消费落组);否则 → 打开面板定位到该组
    private func handleGroupHotKey(groupID: Int64) {
        // 组已删/非组 → 清理绑定
        guard store.item(id: groupID)?.isGroup == true else {
            store.setGroupHotkey(id: groupID, hotkey: nil)
            refreshGroupHotkeys(panelVisible: panelController.isOnScreen)
            return
        }
        let now = Date()
        if let last = lastGroupHotKey, last.id == groupID,
           now.timeIntervalSince(last.at) < 0.5 {
            lastGroupHotKey = nil
            // 双击:抓板入组。captureParentID 临时指向目标组,captureNow 同步走
            // onClip 入库(主线程串行,轮询不会交错读到该值),完成后复位
            monitor.captureParentID = groupID
            _ = monitor.captureNow()
            monitor.captureParentID = -1
            PerfLog.event("GROUP_HOTKEY_CAPTURE", "group=\(groupID)")
        } else {
            lastGroupHotKey = (groupID, now)
            panelController.show(atGroup: groupID)
            PerfLog.event("GROUP_HOTKEY_OPEN", "group=\(groupID)")
        }
    }

    // MARK: - 状态栏

    /// A persistent main menu supplies native key equivalents even when no popup is open.
    /// Keep the accessory activation policy; editing actions resolve through the responder chain.
    private func buildMainMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem(title: "DittoMac", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "DittoMac")
        let aboutItem = NSMenuItem(title: L10n.t("关于 DittoMac", "About DittoMac"),
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: "")
        aboutItem.target = NSApp
        let hideItem = NSMenuItem(title: L10n.t("隐藏 DittoMac", "Hide DittoMac"),
                                  action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = NSApp
        hideItem.keyEquivalentModifierMask = .command
        let hideOthersItem = NSMenuItem(title: L10n.t("隐藏其他", "Hide Others"),
                                        action: #selector(NSApplication.hideOtherApplications(_:)),
                                        keyEquivalent: "h")
        hideOthersItem.target = NSApp
        hideOthersItem.keyEquivalentModifierMask = [.option, .command]
        let showAllItem = NSMenuItem(title: L10n.t("全部显示", "Show All"),
                                     action: #selector(NSApplication.unhideAllApplications(_:)),
                                     keyEquivalent: "")
        showAllItem.target = NSApp
        applicationMenu.items = [
            aboutItem,
            .separator(),
            menuItem(L10n.menuSettings, #selector(showSettings), keyEquivalent: ","),
            .separator(),
            hideItem,
            hideOthersItem,
            showAllItem,
            .separator(),
            menuItem(L10n.t("退出 DittoMac", "Quit DittoMac"), #selector(quit), keyEquivalent: "q"),
        ]
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)

        let editTitle = L10n.t("编辑", "Edit")
        let editItem = NSMenuItem(title: editTitle, action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: editTitle)
        let editActions: [(String, Selector, String)] = [
            (L10n.t("剪切", "Cut"), #selector(NSText.cut(_:)), "x"),
            (L10n.t("复制", "Copy"), #selector(NSText.copy(_:)), "c"),
            (L10n.t("粘贴", "Paste"), #selector(NSText.paste(_:)), "v"),
            (L10n.t("全选", "Select All"), #selector(NSText.selectAll(_:)), "a"),
        ]
        for (title, action, key) in editActions {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            item.target = nil
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)

        let windowTitle = L10n.t("窗口", "Window")
        let windowItem = NSMenuItem(title: windowTitle, action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: windowTitle)
        let closeItem = NSMenuItem(title: L10n.t("关闭窗口", "Close Window"),
                                   action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = .command
        closeItem.target = nil
        windowMenu.addItem(closeItem)
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func nativeMenuLanguageChanged() {
        buildMainMenu()
        refreshStatusIcon()
    }

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

    /// Template symbols follow the menu bar's appearance, contrast and selection state.
    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        let paused = monitor.isPaused
        let description = paused
            ? L10n.t("DittoMac — 已暂停记录", "DittoMac — Recording Paused")
            : L10n.t("DittoMac — 剪贴板历史", "DittoMac — Clipboard History")
        let image = NSImage(systemSymbolName: paused ? "pause.circle" : "clipboard",
                            accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = nil
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    /// Keep frequent actions at the top; maintenance stays in a shared submenu.
    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.items = [
            menuItem(L10n.menuShowQuickPaste, #selector(togglePanel)),
            menuItem(L10n.menuNewClip, #selector(newClip)),
            menuItem(L10n.menuSaveCurrentClip, #selector(saveCurrentClipboard)),
            NSMenuItem.separator(),
            buildConnectItem(),
            NSMenuItem.separator(),
            menuItem(L10n.menuSettings, #selector(showSettings), keyEquivalent: ","),
            menuItem(L10n.menuGlobalHotKeys, #selector(showShortcutSettings)),
            buildDataManagementMenu(),
            NSMenuItem.separator(),
            buildHelpMenu(),
            NSMenuItem.separator(),
            menuItem(L10n.t("退出 DittoMac", "Quit DittoMac"), #selector(quit), keyEquivalent: "q"),
        ]
        return menu
    }

    private func buildDataManagementMenu() -> NSMenuItem {
        let title = L10n.t("数据管理", "Data Management")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        menu.items = [
            menuItem(L10n.menuImportClips, #selector(importClips)),
            menuItem(L10n.menuImportClipPackage, #selector(importClipPackage)),
            .separator(),
            menuItem(L10n.menuBackup, #selector(backupDatabase)),
            menuItem(L10n.menuRestore, #selector(restoreDatabase)),
            .separator(),
            menuItem(L10n.menuFixupStickyOrder, #selector(fixupStickyOrder)),
            menuItem(L10n.menuClearClipData, #selector(openDeleteClipData)),
        ]
        item.submenu = menu
        return item
    }

    /// 菜单入口:打开"删除剪贴板数据"窗口(替代旧的直接清空路径)
    @objc private func openDeleteClipData() {
        showDeleteClipData()
    }

    /// 帮助子菜单(帮助… + 统计…;原版 Help 菜单 + Options→Statistics 的入口)
    private func buildHelpMenu() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.menuHelpRoot, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: L10n.menuHelpRoot)
        menu.autoenablesItems = false
        menu.addItem(menuItem(L10n.menuHelp, #selector(showHelp)))
        menu.addItem(menuItem(L10n.menuStartupMessage, #selector(showStartupMessage)))
        menu.addItem(.separator())
        menu.addItem(menuItem(L10n.menuStats, #selector(showStats)))
        item.submenu = menu
        return item
    }

    /// 打开统计窗口(设置「统计…」按钮与托盘 帮助→统计… 共用)
    @objc func showStats() {
        if statsController == nil {
            let controller = StatsWindowController()
            controller.onClose = { [weak self] in self?.statsController = nil }
            statsController = controller
        }
        statsController?.present()
    }

    /// 导入打包条目(.dto;原版 Import Clip(s) from .dto 的包路径):
    /// 读包 → 逐条转模型 → 落到顶层(列表内的入口走当前组,见 ClipListViewController)
    @objc func importClipPackage() {
        ClipPackageUI.runImportPanel(store: store, parentID: -1) { [weak self] imported in
            guard imported > 0 else { return }
            if self?.panelController.isOnScreen == true {
                self?.panelController.refreshList()
            }
            PerfLog.event("PACKAGE_IMPORTED_TOP", "count=\(imported)")
        }
    }

    /// Name the next action explicitly; no ambiguous "connected" checkmark.
    private func buildConnectItem() -> NSMenuItem {
        let title = monitor.isPaused
            ? L10n.t("继续记录剪贴板", "Resume Clipboard Recording")
            : L10n.t("暂停记录剪贴板", "Pause Clipboard Recording")
        let item = menuItem(title, #selector(togglePaused))
        return item
    }

    private func menuItem(_ title: String, _ action: Selector,
                          keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        if !keyEquivalent.isEmpty { item.keyEquivalentModifierMask = .command }
        item.target = self
        return item
    }

    /// 系统菜单(原版 IDR_QUICK_PASTE_SYSTEM_MENU 的 macOS 映射;面板右下按钮用)
    func buildSystemMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(menuItem(L10n.menuNewClip, #selector(newClip)))
        menu.addItem(menuItem(L10n.menuSaveCurrentClip, #selector(saveCurrentClipboard)))
        menu.addItem(.separator())
        menu.addItem(buildConnectItem())
        menu.addItem(.separator())
        menu.addItem(menuItem(L10n.menuSettings, #selector(showSettings), keyEquivalent: ","))
        menu.addItem(menuItem(L10n.menuGlobalHotKeys, #selector(showShortcutSettings)))

        let quick = NSMenuItem(title: L10n.menuQuickOptions, action: nil, keyEquivalent: "")
        let quickMenu = NSMenu()
        let lines = NSMenuItem(title: L10n.menuLinesPerClip, action: nil, keyEquivalent: "")
        let linesMenu = NSMenu()
        let current = DittoSettings.defaults.integer(forKey: DittoSettings.linesPerRowKey) == 0
            ? DittoSettings.defaultLinesPerRow
            : DittoSettings.defaults.integer(forKey: DittoSettings.linesPerRowKey)
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
        let mode = DittoSettings.defaults.string(forKey: DittoSettings.positionModeKey)
            ?? DittoSettings.defaultPositionMode
        // 三种出现位置(原版:光标处/插入符处/上次位置;At Caret 经辅助功能定位)
        let posOptions = [("atCursor", L10n.menuAtCursor),
                          ("atCaret", L10n.menuAtCaret),
                          ("atPrevious", L10n.menuAtPrevious)]
        for (value, title) in posOptions {
            let mi = menuItem(title, #selector(positionModePicked(_:)))
            mi.state = value == mode ? .on : .off
            mi.representedObject = value
            posMenu.addItem(mi)
        }
        pos.submenu = posMenu
        quickMenu.addItem(pos)

        // 排序方向(原版 2.8.1:最新在上/最新在下,影响非置顶条目的 created_at 方向)
        let sort = NSMenuItem(title: L10n.menuSortOrder, action: nil, keyEquivalent: "")
        let sortMenu = NSMenu()
        let latestOnTop = DittoSettings.orderLatestOnTop()
        let topItem = menuItem(L10n.menuSortLatestOnTop, #selector(sortDirectionPicked(_:)))
        topItem.state = latestOnTop ? .on : .off
        topItem.representedObject = true
        sortMenu.addItem(topItem)
        let bottomItem = menuItem(L10n.menuSortLatestOnBottom, #selector(sortDirectionPicked(_:)))
        bottomItem.state = latestOnTop ? .off : .on
        bottomItem.representedObject = false
        sortMenu.addItem(bottomItem)
        sort.submenu = sortMenu
        quickMenu.addItem(sort)

        let top = menuItem(L10n.menuAlwaysOnTop, #selector(panelTogglePersistent))
        top.state = panelController.isPersistentMode ? .on : .off
        quickMenu.addItem(top)
        quickMenu.addItem(.separator())

        // 组选项(原版 Quick Options 的 ShowClipsInMainList / PrompForNewGroupName,
        // QPasteWnd.cpp:2320-2323 一带两项都在快速选项里)
        let showGroupClips = menuItem(L10n.quickShowGroupClips, #selector(toggleIncludeGroupClips))
        showGroupClips.state = DittoSettings.includeGroupClips() ? .on : .off
        quickMenu.addItem(showGroupClips)
        let promptNames = menuItem(L10n.quickPromptGroupName, #selector(togglePromptForGroupName))
        promptNames.state = DittoSettings.promptForGroupName() ? .on : .off
        quickMenu.addItem(promptNames)
        // 即输即搜(原版 2.3.9 Find As You Type;关 = 搜索仅回车触发)
        let findAsYouType = menuItem(L10n.quickFindAsYouType, #selector(toggleFindAsYouType))
        findAsYouType.state = DittoSettings.findAsYouType() ? .on : .off
        quickMenu.addItem(findAsYouType)
        // 删除前确认(原版 2.7.5 Prompt to Delete Clip,默认关)
        let promptDelete = menuItem(L10n.quickPromptDelete, #selector(togglePromptDelete))
        promptDelete.state = DittoSettings.promptDelete() ? .on : .off
        quickMenu.addItem(promptDelete)
        quickMenu.addItem(.separator())
        // 透明度(原版 Quick Options→Transparency:无/5..40;面板 alpha = 1-pct/100)
        quickMenu.addItem(buildTransparencyMenu())
        // 字体(原版 Select Font;系统字体面板选择,列表/浮窗/行高即时生效)
        quickMenu.addItem(menuItem(L10n.menuFont, #selector(selectFont)))
        quickMenu.addItem(menuItem(L10n.menuResetFont, #selector(resetFont)))
        // 主题(原版 12 内置 XML + 从文件导入;跟随系统 = 原生语义色)
        quickMenu.addItem(buildThemeMenu())
        // 标题栏位置(原版 View Caption Bar On Top/Right/Bottom/Left)
        quickMenu.addItem(buildCaptionPositionMenu())
        // 失焦自动折叠(原版 Auto Roll-up:失焦 → 折叠而非隐藏;默认关)
        let autoRoll = menuItem(L10n.menuAutoRollUp, #selector(toggleAutoRollUp))
        autoRoll.state = DittoSettings.defaults.bool(forKey: DittoSettings.autoRollUpKey) ? .on : .off
        quickMenu.addItem(autoRoll)
        // 始终显示描述(原版 Always Show Description:行内第二行完整描述;默认关)
        let alwaysDesc = menuItem(L10n.menuAlwaysShowDescription, #selector(toggleAlwaysShowDescription))
        alwaysDesc.state = DittoSettings.defaults.bool(forKey: DittoSettings.alwaysShowDescriptionKey) ? .on : .off
        quickMenu.addItem(alwaysDesc)
        // 绘制富文本内容(原版 Draw RTF Text:RTF/HTML 条目画属性内容;默认关)
        let drawRtf = menuItem(L10n.menuDrawRtfText, #selector(toggleDrawRtfText))
        drawRtf.state = DittoSettings.defaults.bool(forKey: DittoSettings.drawRtfTextKey) ? .on : .off
        quickMenu.addItem(drawRtf)
        quickMenu.addItem(.separator())
        // 搜索选项(原版 Search Options:范围 = 全文/仅描述,方式 = 包含/通配/正则)
        quickMenu.addItem(buildSearchOptionsMenu())
        quick.submenu = quickMenu
        menu.addItem(quick)
        menu.addItem(buildDataManagementMenu())
        menu.addItem(.separator())
        menu.addItem(buildHelpMenu())
        menu.addItem(.separator())
        menu.addItem(menuItem(L10n.t("退出 DittoMac", "Quit DittoMac"), #selector(quit), keyEquivalent: "q"))
        return menu
    }

    @objc private func linesPerRowPicked(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? Int else { return }
        DittoSettings.defaults.set(n, forKey: DittoSettings.linesPerRowKey)
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
    }

    @objc private func positionModePicked(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        DittoSettings.defaults.set(mode, forKey: DittoSettings.positionModeKey)
    }

    /// 快速选项:主列表显示组内条目(切换后在屏面板立即重查)
    @objc private func toggleIncludeGroupClips() {
        let value = !DittoSettings.includeGroupClips()
        DittoSettings.defaults.set(value, forKey: DittoSettings.includeGroupClipsKey)
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
    }

    /// 快速选项:新建组时提示输入名称
    @objc private func togglePromptForGroupName() {
        let value = !DittoSettings.promptForGroupName()
        DittoSettings.defaults.set(value, forKey: DittoSettings.promptForGroupNameKey)
    }

    /// 快速选项:排序方向(切换后在屏面板立即重排)
    @objc private func sortDirectionPicked(_ sender: NSMenuItem) {
        guard let latestOnTop = sender.representedObject as? Bool else { return }
        DittoSettings.defaults.set(latestOnTop, forKey: DittoSettings.orderLatestOnTopKey)
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
    }

    /// 快速选项:即输即搜(关 = 搜索框仅回车触发查询)
    @objc private func toggleFindAsYouType() {
        let value = !DittoSettings.findAsYouType()
        DittoSettings.defaults.set(value, forKey: DittoSettings.findAsYouTypeKey)
    }

    /// 快速选项:删除条目前确认
    @objc private func togglePromptDelete() {
        let value = !DittoSettings.promptDelete()
        DittoSettings.defaults.set(value, forKey: DittoSettings.promptDeleteKey)
    }

    // MARK: - 快速选项新增(透明度/字体/主题/标题栏位置/折叠/描述行/富文本/搜索)

    /// 透明度子菜单(原版 Transparency 档位:无 + 5..40)
    private func buildTransparencyMenu() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.menuTransparency, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let current = DittoSettings.clampedTransparencyPercent(
            DittoSettings.defaults.integer(forKey: DittoSettings.transparencyPercentKey))
        let options: [(Int, String)] = [(0, L10n.transparencyNone)]
            + [5, 10, 15, 20, 25, 30, 40].map { ($0, "\($0)%") }
        for (value, title) in options {
            let mi = menuItem(title, #selector(transparencyPicked(_:)))
            mi.state = value == current ? .on : .off
            mi.representedObject = value
            menu.addItem(mi)
        }
        item.submenu = menu
        return item
    }

    @objc private func transparencyPicked(_ sender: NSMenuItem) {
        guard let pct = sender.representedObject as? Int else { return }
        DittoSettings.defaults.set(pct, forKey: DittoSettings.transparencyPercentKey)
        panelController.applyTransparency()   // 即时生效(窗口级 alpha,折叠态同样生效)
    }

    /// 字体…(原版 Select Font):打开系统字体面板;选择经 FontPanelManager 持久化
    @objc private func selectFont() {
        NSApp.activate(ignoringOtherApps: true)
        FontPanelManager.shared.openFontPanel()
    }

    /// 重置字体(回系统 13pt)
    @objc private func resetFont() {
        DittoSettings.defaults.removeObject(forKey: DittoSettings.fontNameKey)
        DittoSettings.defaults.removeObject(forKey: DittoSettings.fontSizeKey)
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
    }

    /// 主题子菜单(跟随系统 + 12 内置 + 导入的主题 + 从文件导入…)
    private func buildThemeMenu() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.menuTheme, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let stored = DittoSettings.defaults.string(forKey: DittoSettings.themeFileKey) ?? ""
        let system = menuItem(L10n.themeFollowSystem, #selector(themePicked(_:)))
        system.state = stored.isEmpty ? .on : .off
        system.representedObject = ""
        menu.addItem(system)
        menu.addItem(.separator())
        // 内置主题(存储值 "builtin:<名>";名字持久,包路径随构建变化)
        for name in ThemeRegistry.bundledThemeNames() {
            let mi = menuItem(name, #selector(themePicked(_:)))
            mi.state = stored == ThemeRegistry.builtinPrefix + name ? .on : .off
            mi.representedObject = ThemeRegistry.builtinPrefix + name
            menu.addItem(mi)
        }
        // 已导入的用户主题(按文件名列出,存储值 = 绝对路径)
        let userNames = ThemeRegistry.userThemeNames()
        if !userNames.isEmpty {
            menu.addItem(.separator())
            for name in userNames {
                guard let url = ThemeRegistry.userThemeURL(name: name) else { continue }
                let mi = menuItem(name, #selector(themePicked(_:)))
                mi.state = stored == url.path ? .on : .off
                mi.representedObject = url.path
                menu.addItem(mi)
            }
        }
        menu.addItem(.separator())
        menu.addItem(menuItem(L10n.themeImportFromFile, #selector(importTheme)))
        item.submenu = menu
        return item
    }

    @objc private func themePicked(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        DittoSettings.defaults.set(value, forKey: DittoSettings.themeFileKey)
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
    }

    /// 从文件导入主题:拷入 ~/Library/Application Support/DittoMac/Themes 后选中
    @objc private func importTheme() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.xml]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if let dest = ThemeRegistry.importTheme(from: url) {
                DittoSettings.defaults.set(dest.path, forKey: DittoSettings.themeFileKey)
                NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L10n.dlgThemeImportFailed
                alert.addButton(withTitle: L10n.dlgOk)
                alert.runModal()
            }
        }
    }

    /// 标题栏位置子菜单(上/右/下/左;默认右 = 既有布局)
    private func buildCaptionPositionMenu() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.menuCaptionPosition, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let current = DittoSettings.captionPosition()
        let titles: [CaptionPosition: String] = [
            .top: L10n.captionTop, .right: L10n.captionRight,
            .bottom: L10n.captionBottom, .left: L10n.captionLeft,
        ]
        for pos in CaptionPosition.allCases {
            let mi = menuItem(titles[pos] ?? pos.rawValue, #selector(captionPositionPicked(_:)))
            mi.state = pos == current ? .on : .off
            mi.representedObject = pos.rawValue
            menu.addItem(mi)
        }
        item.submenu = menu
        return item
    }

    @objc private func captionPositionPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        DittoSettings.defaults.set(raw, forKey: DittoSettings.captionPositionKey)
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
    }

    /// 快速选项:失焦自动折叠(原版 Auto Roll-up)
    @objc private func toggleAutoRollUp() {
        let value = !DittoSettings.defaults.bool(forKey: DittoSettings.autoRollUpKey)
        DittoSettings.defaults.set(value, forKey: DittoSettings.autoRollUpKey)
    }

    /// 快速选项:始终显示描述(切换后行高 = (行数+1) × 字体行高,立即重查)
    @objc private func toggleAlwaysShowDescription() {
        let value = !DittoSettings.defaults.bool(forKey: DittoSettings.alwaysShowDescriptionKey)
        DittoSettings.defaults.set(value, forKey: DittoSettings.alwaysShowDescriptionKey)
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
    }

    /// 快速选项:绘制富文本内容(原版 Draw RTF Text)
    @objc private func toggleDrawRtfText() {
        let value = !DittoSettings.defaults.bool(forKey: DittoSettings.drawRtfTextKey)
        DittoSettings.defaults.set(value, forKey: DittoSettings.drawRtfTextKey)
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
    }

    /// 搜索选项子菜单(范围:全文/仅描述 + 方式:包含/通配/正则)
    private func buildSearchOptionsMenu() -> NSMenuItem {
        let item = NSMenuItem(title: L10n.menuSearch, action: nil, keyEquivalent: "")
        let menu = NSMenu()

        let scope = NSMenuItem(title: L10n.searchScopeLabel, action: nil, keyEquivalent: "")
        let scopeMenu = NSMenu()
        let currentScope = DittoSettings.searchScope()
        for (value, title) in [(SearchScope.fullText.rawValue, L10n.searchScopeFullText),
                               (SearchScope.descriptionOnly.rawValue, L10n.searchScopeDescription)] {
            let mi = menuItem(title, #selector(searchScopePicked(_:)))
            mi.state = value == currentScope.rawValue ? .on : .off
            mi.representedObject = value
            scopeMenu.addItem(mi)
        }
        scope.submenu = scopeMenu
        menu.addItem(scope)

        let method = NSMenuItem(title: L10n.searchMethodLabel, action: nil, keyEquivalent: "")
        let methodMenu = NSMenu()
        let currentMethod = DittoSettings.searchMethod()
        for (value, title) in [(SearchMethod.contains.rawValue, L10n.searchMethodContains),
                               (SearchMethod.wildcard.rawValue, L10n.searchMethodWildcard),
                               (SearchMethod.regex.rawValue, L10n.searchMethodRegex)] {
            let mi = menuItem(title, #selector(searchMethodPicked(_:)))
            mi.state = value == currentMethod.rawValue ? .on : .off
            mi.representedObject = value
            methodMenu.addItem(mi)
        }
        method.submenu = methodMenu
        menu.addItem(method)
        item.submenu = menu
        return item
    }

    @objc private func searchScopePicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        DittoSettings.defaults.set(raw, forKey: DittoSettings.searchScopeKey)
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
    }

    @objc private func searchMethodPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        DittoSettings.defaults.set(raw, forKey: DittoSettings.searchMethodKey)
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
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
        DittoSettings.defaults.set(true, forKey: "ditto.showedStartupMessage")
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
            // 恢复目标 = 当前生效的库位置(便携模式 → 便携根下)
            let dbURL = PortableMode.databaseURL(base: PortableMode.currentBaseDirectory)
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
            DittoSettings.defaults.set(true, forKey: "ditto.suppressAXAlert")
        }
    }

    /// 粘贴回失败时调用:系统授权弹窗 + 我们的说明(受"不再提示"控制)
    func promptAccessibilityForPaste() {
        Permissions.promptAccessibility()
        if !DittoSettings.defaults.bool(forKey: "ditto.suppressAXAlert") {
            showAccessibilityAlert(startup: false)
        }
    }

    @objc private func togglePaused() {
        setPaused(!monitor.isPaused)
    }

    /// 记录暂停状态切换(托盘菜单与 /Connect //Disconnect 命令行动词共用)
    private func setPaused(_ paused: Bool) {
        DittoSettings.defaults.set(paused, forKey: DittoSettings.pausedKey)
        monitor.setPaused(paused)
        refreshStatusIcon()
        NotificationCenter.default.post(name: .dittoPausedChanged, object: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 设置读取

    /// 过期/超额清理。gatedByIdle = true 时(周期 tick)按系统空闲门控放行
    /// (原版删除在电脑空闲时执行;阈值 300s 见 PruneGate)
    private func pruneExpired(gatedByIdle: Bool) {
        if gatedByIdle, !PruneGate.shouldPrune(idleSeconds: idleSecondsProvider()) {
            PerfLog.event("PRUNE_SKIPPED_NOT_IDLE",
                          String(format: "idle=%.0fs", idleSecondsProvider()))
            return
        }
        let d = DittoSettings.defaults
        let maxItems = (d.object(forKey: DittoSettings.maxItemsKey) as? NSNumber)?.intValue
            ?? DittoSettings.defaultMaxItems
        let maxAgeDays = (d.object(forKey: DittoSettings.maxAgeDaysKey) as? NSNumber)?.intValue
            ?? DittoSettings.defaultMaxAgeDays
        // 后台清理,不占主线程(ClipStore 内部串行队列保证线程安全)
        DispatchQueue.global(qos: .utility).async { [store] in
            store.prune(maxItems: maxItems, maxAgeDays: maxAgeDays)
        }
    }

    /// 单条体积上限(设置读取;编辑器新建条目入库也用同一上限)
    static func maxDataBytesSetting() -> Int {
        if let n = DittoSettings.defaults.object(forKey: DittoSettings.maxDataBytesKey) as? NSNumber {
            return n.intValue
        }
        return DittoSettings.defaultMaxDataBytes
    }
}

// MARK: - 字体面板管理(原版 Quick Options → Select Font)
//
// NSFontPanel 的委托对象(NSFontChanging):面板内选择(实时回调)→ 持久化
// ditto.fontName/fontSize 并广播设置变更,列表/组行/描述行/悬停浮窗与行高即时刷新。

final class FontPanelManager: NSObject, NSFontChanging {
    static let shared = FontPanelManager()

    /// 打开系统字体面板(预选当前列表字体)
    func openFontPanel() {
        NSFontManager.shared.target = self
        NSFontManager.shared.setSelectedFont(ClipListViewController.rowFont, isMultiple: false)
        NSFontManager.shared.fontPanel(true)?.makeKeyAndOrderFront(nil)
    }

    func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        let converted = sender.convert(ClipListViewController.rowFont)
        // 与已持久化值一致则不重复广播(面板预选自身/同字体点击)
        if converted.fontName == DittoSettings.defaults.string(forKey: DittoSettings.fontNameKey),
           (DittoSettings.defaults.object(forKey: DittoSettings.fontSizeKey) as? Double) == Double(converted.pointSize) {
            return
        }
        DittoSettings.defaults.set(converted.fontName, forKey: DittoSettings.fontNameKey)
        DittoSettings.defaults.set(Double(converted.pointSize), forKey: DittoSettings.fontSizeKey)
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
    }

    func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask {
        [.size, .collection, .face]
    }
}
