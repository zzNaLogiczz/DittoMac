import AppKit
import Carbon.HIToolbox
import ServiceManagement
import DittoMacKit

extension Notification.Name {
    /// 设置变更(热键 / 清空历史等)。
    /// 设置窗口 post;AppDelegate 监听后重注册热键并刷新在屏面板。
    static let dittoSettingsChanged = Notification.Name("ditto.settingsChanged")

    /// 热键录入状态变更(userInfo["recording"]: Bool)。
    /// 录入期间 AppDelegate 临时注销全局热键,结束(提交/取消/失焦)后恢复。
    static let dittoHotKeyRecording = Notification.Name("ditto.hotKeyRecording")

    /// 暂停记录(原版 Connect To Clipboard)状态变化;面板据此把标题区变黄
    static let dittoPausedChanged = Notification.Name("ditto.pausedChanged")
}

/// 快捷键录入控件:点击进入监听,用户按下的下一个组合键即被捕获提交
/// (对齐原版 Ditto Options 热键页的"按下新快捷键"捕获框)
final class HotKeyRecorderView: NSView {

    var onCommit: ((UInt32, UInt) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var isRecording = false
    private var currentText = ""

    /// 修饰键自身的键码:监听时按下这些不算完成,继续等实际按键
    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    /// 允许不带修饰键直接使用的功能键(F1-F12)
    private static let functionKeyCodes: Set<UInt16> = [
        96, 97, 98, 99, 100, 101, 103, 109, 111, 118, 120, 122,
    ]

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 170, height: 26))
        wantsLayer = true
        layer?.cornerRadius = 5
        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            widthAnchor.constraint(equalToConstant: 170),
            heightAnchor.constraint(equalToConstant: 26),
        ])
        refreshUI()
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    /// 展示当前生效的热键
    func display(code: UInt32, mods: UInt) {
        currentText = Fmt.hotKeyString(code: code, mods: mods)
        refreshUI()
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        setRecording(!isRecording)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {                       // Esc = 取消录入
            setRecording(false)
            return
        }
        if Self.modifierKeyCodes.contains(event.keyCode) { return }   // 只按了修饰键,继续等

        // 剥离无关标志后换算 Carbon 修饰掩码
        let mods = DittoSettings.carbonMask(from: event.modifierFlags)
        if mods == 0 && !Self.functionKeyCodes.contains(event.keyCode) {
            label.textColor = .systemRed
            label.stringValue = L10n.recNeedModifier
            return
        }
        setRecording(false)
        onCommit?(UInt32(event.keyCode), mods)
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { setRecording(false) }         // 失焦 = 放弃录入
        return true
    }

    private func setRecording(_ on: Bool) {
        isRecording = on
        refreshUI()
        NotificationCenter.default.post(name: .dittoHotKeyRecording, object: nil,
                                        userInfo: ["recording": on])
    }

    private func refreshUI() {
        if isRecording {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = 1.5
            label.textColor = NSColor.controlAccentColor
            label.stringValue = L10n.recPressKeys
        } else {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 1
            label.textColor = .labelColor
            label.stringValue = currentText.isEmpty ? L10n.recClickToSet : currentText
        }
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    var onClose: (() -> Void)?
    private let viewController: SettingsViewController

    init(store: ClipStoring) {
        let content = SettingsViewController(store: store)
        self.viewController = content

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = L10n.settingsTitle
        window.contentViewController = content
        window.isReleasedWhenClosed = false // 由 AppDelegate 持有并在关闭后释放
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

private final class SettingsViewController: NSViewController {

    private let store: ClipStoring
    private var accessibilityStatusField: NSTextField!
    private var launchButton: NSButton!
    private var hotKeyRecorder: HotKeyRecorderView!
    private var observers: [NSObjectProtocol] = []

    init(store: ClipStoring) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildContent()
        // 权限/自启状态随应用激活刷新(用户去系统设置授权后回来能看到)
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshDynamicStates()
        })
        // 语言切换 → 即时重建整个设置界面(全量文案 + 语言行选中态)
        observers.append(NotificationCenter.default.addObserver(
            forName: L10n.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.view.subviews.forEach { $0.removeFromSuperview() }
            self.buildContent()
        })
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - UI 构建

    private func buildContent() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            // 固定内容宽度 + 最小高度:contentViewController 会按 fitting size 重定窗口,
            // 不约束就会缩成 ~220pt(原版 Options 是规整的固定宽度对话框)
            view.widthAnchor.constraint(equalToConstant: 360),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])

        stack.addArrangedSubview(sectionHeader(L10n.setSectionRecording))
        stack.addArrangedSubview(makeRow(L10n.setKeepCount, makePopup(
            titles: ["100", "500", "1000", "5000"],
            values: [100, 500, 1000, 5000],
            current: intSetting(DittoSettings.maxItemsKey, default: DittoSettings.defaultMaxItems),
            action: #selector(maxItemsChanged(_:)))))

        stack.addArrangedSubview(makeRow(L10n.setKeepDays, makePopup(
            titles: ["7 \(L10n.setDaysUnit)", "30 \(L10n.setDaysUnit)", "90 \(L10n.setDaysUnit)", "365 \(L10n.setDaysUnit)"],
            values: [7, 30, 90, 365],
            current: intSetting(DittoSettings.maxAgeDaysKey, default: DittoSettings.defaultMaxAgeDays),
            action: #selector(maxAgeDaysChanged(_:)))))

        stack.addArrangedSubview(makeRow(L10n.setSizeLimit, makePopup(
            titles: ["5 MB", "20 MB", "50 MB"],
            values: [5, 20, 50].map { $0 * 1024 * 1024 },
            current: intSetting(DittoSettings.maxDataBytesKey, default: DittoSettings.defaultMaxDataBytes),
            action: #selector(maxDataBytesChanged(_:)),
            customTitle: { "\($0 / 1024 / 1024) MB" })))

        stack.addArrangedSubview(sectionHeader(L10n.setSectionShortcuts))
        stack.addArrangedSubview(makeRow(L10n.setGlobalHotkey, makeHotKeyRow()))
        addSeparator(to: stack)

        stack.addArrangedSubview(sectionHeader(L10n.setSectionBehavior))
        stack.addArrangedSubview(makeRow(L10n.setLinesPerRow, makePopup(
            titles: ["1 \(L10n.setLinesUnit)", "2 \(L10n.setLinesUnit)", "3 \(L10n.setLinesUnit)", "4 \(L10n.setLinesUnit)", "5 \(L10n.setLinesUnit)"],
            values: [1, 2, 3, 4, 5],
            current: intSetting(DittoSettings.linesPerRowKey, default: DittoSettings.defaultLinesPerRow),
            action: #selector(linesPerRowChanged(_:)))))
        stack.addArrangedSubview(makeRow(L10n.setPosition, makePositionPopup()))
        stack.addArrangedSubview(makeRow(L10n.setLanguage, makeLanguagePopup()))
        addSeparator(to: stack)

        stack.addArrangedSubview(sectionHeader(L10n.setSectionPrivacy))
        let launch = NSButton(checkboxWithTitle: L10n.setLaunchAtLogin, target: self, action: #selector(launchToggleChanged(_:)))
        launchButton = launch
        stack.addArrangedSubview(launch)

        let statusField = NSTextField(labelWithString: "")
        accessibilityStatusField = statusField
        let permButton = NSButton(title: L10n.btnOpenSettings + "…", target: self, action: #selector(openAccessibilitySettings))
        permButton.bezelStyle = .rounded
        let permStack = NSStackView(views: [statusField, permButton])
        permStack.orientation = .vertical
        permStack.alignment = .leading
        permStack.spacing = 6
        stack.addArrangedSubview(makeRow(L10n.setAccessibility, permStack))

        stack.addArrangedSubview(makeSeparator(in: stack))

        let clearButton = NSButton(title: L10n.menuClearClipData, target: self, action: #selector(clearHistory))
        clearButton.bezelStyle = .rounded
        clearButton.attributedTitle = NSAttributedString(
            string: L10n.menuClearClipData,
            attributes: [.foregroundColor: NSColor.systemRed])
        stack.addArrangedSubview(clearButton)

        refreshDynamicStates()
    }

    private func sectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeRow(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    private func addSeparator(to stack: NSStackView) {
        let box = NSBox()
        box.boxType = .separator
        // 必须先加入堆栈层级再激活跨视图约束:无共同祖先时 activate 会抛
        // NSGenericException(设置窗口一开就崩的根因)
        stack.addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func makeSeparator(in stack: NSStackView) -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func makePopup(titles: [String],
                           values: [Int],
                           current: Int,
                           action: Selector,
                           customTitle: ((Int) -> String)? = nil) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = action
        for (title, value) in zip(titles, values) {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = value
        }
        if let index = values.firstIndex(of: current) {
            popup.selectItem(at: index)
        } else {
            popup.insertItem(withTitle: customTitle?(current) ?? "自定义", at: 0)
            popup.selectItem(at: 0)
        }
        popup.setContentHuggingPriority(.required, for: .horizontal)
        return popup
    }

    /// 热键行:录入控件 + 恢复默认按钮
    private func makeHotKeyRow() -> NSView {
        let recorder = HotKeyRecorderView()
        let d = UserDefaults.standard
        let code = (d.object(forKey: DittoSettings.hotKeyCodeKey) as? NSNumber)?.uint32Value
            ?? DittoSettings.defaultHotKeyCode
        let mods = (d.object(forKey: DittoSettings.hotKeyModsKey) as? NSNumber)?.uintValue
            ?? DittoSettings.defaultHotKeyMods
        recorder.display(code: code, mods: mods)
        recorder.onCommit = { [weak self, weak recorder] code, mods in
            guard let self else { return }
            UserDefaults.standard.set(code, forKey: DittoSettings.hotKeyCodeKey)
            UserDefaults.standard.set(mods, forKey: DittoSettings.hotKeyModsKey)
            recorder?.display(code: code, mods: mods)
            self.notifyChanged()
        }
        hotKeyRecorder = recorder

        let reset = NSButton(title: L10n.setResetHotkey, target: self, action: #selector(resetHotKey(_:)))
        reset.bezelStyle = .rounded
        reset.controlSize = .small

        let row = NSStackView(views: [recorder, reset])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    /// 语言:跟随系统 / 中文 / English(切换即时生效,广播 L10n.changedNotification)
    private func makeLanguagePopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(languageChanged(_:))
        for lang in L10n.Lang.allCases {
            popup.addItem(withTitle: lang.displayName)
            popup.lastItem?.representedObject = lang.rawValue
        }
        popup.selectItem(at: L10n.Lang.allCases.firstIndex(of: L10n.lang) ?? 0)
        return popup
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let lang = L10n.Lang(rawValue: raw) else { return }
        L10n.lang = lang   // setter 写 UserDefaults 并广播 → 设置界面即时重建
    }

    /// 出现位置(原版 Positioning At Caret/At Cursor/At Previous;macOS 等价映射)
    private func makePositionPopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(positionModeChanged(_:))
        let options = [("atCursor", L10n.menuAtCursor), ("atPrevious", L10n.menuAtPrevious)]
        for (value, title) in options {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = value
        }
        let mode = UserDefaults.standard.string(forKey: DittoSettings.positionModeKey)
            ?? DittoSettings.defaultPositionMode
        popup.selectItem(at: options.firstIndex(where: { $0.0 == mode }) ?? 0)
        return popup
    }

    // MARK: - 动作

    @objc private func maxItemsChanged(_ sender: NSPopUpButton) {
        if let value = sender.selectedItem?.representedObject as? Int {
            UserDefaults.standard.set(value, forKey: DittoSettings.maxItemsKey)
            notifyChanged()
        }
    }

    @objc private func maxAgeDaysChanged(_ sender: NSPopUpButton) {
        if let value = sender.selectedItem?.representedObject as? Int {
            UserDefaults.standard.set(value, forKey: DittoSettings.maxAgeDaysKey)
            notifyChanged()
        }
    }

    @objc private func maxDataBytesChanged(_ sender: NSPopUpButton) {
        if let value = sender.selectedItem?.representedObject as? Int {
            UserDefaults.standard.set(value, forKey: DittoSettings.maxDataBytesKey)
            notifyChanged()
        }
    }

    @objc private func linesPerRowChanged(_ sender: NSPopUpButton) {
        if let value = sender.selectedItem?.representedObject as? Int {
            UserDefaults.standard.set(value, forKey: DittoSettings.linesPerRowKey)
            notifyChanged()
        }
    }

    @objc private func positionModeChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String else { return }
        UserDefaults.standard.set(value, forKey: DittoSettings.positionModeKey)
    }

    @objc private func resetHotKey(_ sender: NSButton) {
        UserDefaults.standard.set(DittoSettings.defaultHotKeyCode, forKey: DittoSettings.hotKeyCodeKey)
        UserDefaults.standard.set(DittoSettings.defaultHotKeyMods, forKey: DittoSettings.hotKeyModsKey)
        hotKeyRecorder?.display(code: DittoSettings.defaultHotKeyCode,
                                mods: DittoSettings.defaultHotKeyMods)
        notifyChanged()
    }

    @objc private func launchToggleChanged(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // 注册失败(未打包/受限环境):静默回退为实际状态
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    @objc private func openAccessibilitySettings() {
        Permissions.openAccessibilitySettings()
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
        notifyChanged()
    }

    // MARK: - 状态

    private func refreshDynamicStates() {
        let granted = Permissions.isAccessibilityGranted
        accessibilityStatusField.stringValue = granted ? L10n.setGranted : L10n.setNotGranted
        accessibilityStatusField.textColor = granted ? .secondaryLabelColor : .systemRed
        launchButton.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
    }

    private func intSetting(_ key: String, default defaultValue: Int) -> Int {
        (UserDefaults.standard.object(forKey: key) as? NSNumber)?.intValue ?? defaultValue
    }
}
