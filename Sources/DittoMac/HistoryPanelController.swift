import AppKit
import Carbon.HIToolbox
import DittoMacKit

// MARK: - 主题色(macOS 原生语义色,自动适配深浅色)

enum DittoTheme {
    static var borderColor = NSColor.separatorColor
    static var listBackground = NSColor.windowBackgroundColor
    static var captionBackground = NSColor.windowBackgroundColor
    static var captionText = NSColor.secondaryLabelColor
    static var textColor = NSColor.labelColor
    static var pastedBar = NSColor.controlAccentColor      // 已粘贴指示(原版可随系统强调色)
    static var searchHighlight = NSColor.systemRed
    static var topTenNumber = NSColor.tertiaryLabelColor
    static var timeText = NSColor.secondaryLabelColor

    /// 语义色本身随外观动态解析,无需按明暗切换(保留入口以兼容调用点)
    static func adjusted() {}
}

// MARK: - 右侧竖排标题栏(原版 caption 在右侧、25px、竖排文字 + 四按钮)

final class CaptionView: NSView {
    var onClose: (() -> Void)?
    var onRoll: (() -> Void)?
    var onMaximize: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    /// 标题动态后缀(原版 §7:"ditto-mac [置顶] ... - 选中/总数")
    var titleText = "ditto-mac" { didSet { needsDisplay = true } }
    /// 剪贴板断开(=暂停记录)时标题区变黄(原版 Disconnected 态)
    var disconnected = false { didSet { needsDisplay = true } }

    private let captionWidth: CGFloat = 25
    private let buttonSize: CGFloat = 16
    private var rollUp = false
    /// 按钮区总高(4 钮:4/28/60/92,16px)——标题文字锚在其下
    private static let buttonAreaHeight: CGFloat = 112

    override var isFlipped: Bool { true }   // 全视图统一"自顶向下"坐标系,绘制与命中共用

    func setRolled(_ rolled: Bool) {
        rollUp = rolled
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        _ = DittoTheme.adjusted()
        (disconnected ? NSColor(red: 1, green: 1, blue: 0, alpha: 0.9) : DittoTheme.captionBackground).setFill()
        bounds.fill()
        // 与主区之间的发丝分隔线(原生观感)
        DittoTheme.borderColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()

        // 四枚 16px 按钮:顶部向下 关闭/折叠/最大化/最小化(间距 24/32/32,原版 DittoWindow.cpp:269-318)
        drawButton(kind: .close, topOffset: 4)
        drawButton(kind: .roll, topOffset: 28)
        drawButton(kind: .max, topOffset: 60)
        drawButton(kind: .min, topOffset: 92)

        // 竖排标题:锚在按钮区之下,向下排(原版 CAPTION_RIGHT 分支 textRect 在按钮区下)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let text = NSAttributedString(string: titleText, attributes: [
            .font: NSFont.systemFont(ofSize: 19),
            .foregroundColor: DittoTheme.captionText,
        ])
        let size = text.size()
        ctx.saveGState()
        ctx.translateBy(x: bounds.width - captionWidth / 2, y: Self.buttonAreaHeight + 10)
        ctx.rotate(by: .pi / 2)
        text.draw(at: NSPoint(x: 0, y: -size.height / 2 + 4))
        ctx.restoreGState()
    }

    private enum CaptionButton { case close, roll, max, min }

    private func drawButton(kind: CaptionButton, topOffset: CGFloat) {
        let rect = NSRect(x: (captionWidth - buttonSize) / 2, y: topOffset, width: buttonSize, height: buttonSize)
        let p = NSBezierPath()
        p.lineWidth = 1.2
        DittoTheme.captionText.setStroke()
        switch kind {
        case .close:
            p.move(to: NSPoint(x: rect.minX + 4, y: rect.minY + 4))
            p.line(to: NSPoint(x: rect.maxX - 4, y: rect.maxY - 4))
            p.move(to: NSPoint(x: rect.maxX - 4, y: rect.minY + 4))
            p.line(to: NSPoint(x: rect.minX + 4, y: rect.maxY - 4))
        case .roll:
            let midX = rect.midX
            if rollUp {
                p.move(to: NSPoint(x: midX - 5, y: rect.midY + 2))
                p.line(to: NSPoint(x: midX, y: rect.midY - 3))
                p.line(to: NSPoint(x: midX + 5, y: rect.midY + 2))
            } else {
                p.move(to: NSPoint(x: midX - 5, y: rect.midY - 2))
                p.line(to: NSPoint(x: midX, y: rect.midY + 3))
                p.line(to: NSPoint(x: midX + 5, y: rect.midY - 2))
            }
        case .max:
            p.append(NSBezierPath(rect: rect.insetBy(dx: 4, dy: 4)))
        case .min:
            p.move(to: NSPoint(x: rect.minX + 4, y: rect.midY))
            p.line(to: NSPoint(x: rect.maxX - 4, y: rect.midY))
        }
        p.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x >= bounds.width - captionWidth else { return }
        if rollUp {
            // 折叠态:整条 caption 点击=展开(必须有 UI 出口,原版点击标题条恢复)
            if event.clickCount == 2 || point.y <= 24 { onRoll?() }
            return
        }
        switch point.y {
        case ..<24: onClose?()
        case ..<48: onRoll?()
        case ..<80: onMaximize?()
        case ..<112: onMinimize?()
        default:
            if event.clickCount == 2 { onDoubleClick?() }   // 双击空白标题区=折叠
        }
    }

    override func mouseDragged(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - 面板(无边框、方形发丝边框,原版 WS_POPUP + Draw3dRect)

final class DittoPanel: NSPanel {
    /// 窗口级按键拦截(Esc);返回 true 表示已消费
    var escapeHandler: (() -> Void)?
    var forceHideHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        escapeHandler?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53 {
            let shift = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
            if shift {
                forceHideHandler?()   // Shift+Esc 强制关窗(原版)
            } else {
                escapeHandler?()
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 主区背景(列表底色),避免透出边框灰
final class PanelMainAreaView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        DittoTheme.listBackground.setFill()
        bounds.fill()
    }
}

/// 面板根视图:画 1px 边框 + 布局 主区/右侧标题栏 + 边缘拖拽缩放(无边框窗需自实现)
final class PanelRootView: NSView {
    let caption = CaptionView()
    let mainArea = PanelMainAreaView()
    private static let edge: CGFloat = 5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        caption.translatesAutoresizingMaskIntoConstraints = false
        mainArea.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainArea)
        addSubview(caption)
        NSLayoutConstraint.activate([
            mainArea.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            mainArea.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            mainArea.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            mainArea.trailingAnchor.constraint(equalTo: caption.leadingAnchor),
            caption.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            caption.widthAnchor.constraint(equalToConstant: 25),
        ])
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    override func draw(_ dirtyRect: NSRect) {
        DittoTheme.borderColor.setFill()
        bounds.fill()
    }

    // MARK: 边缘缩放(原版无边框窗四周可拖)

    private enum Zone { case none, l, r, t, b, tl, tr, bl, br }

    private func zone(at point: NSPoint) -> Zone {
        let e = Self.edge
        let left = point.x <= e, right = point.x >= bounds.width - e
        let top = point.y >= bounds.height - e, bottom = point.y <= e
        switch (left, right, top, bottom) {
        case (true, false, false, false): return .l
        case (false, true, false, false): return .r
        case (false, false, true, false): return .t
        case (false, false, false, true): return .b
        case (true, false, true, false): return .tl
        case (false, true, true, false): return .tr
        case (true, false, false, true): return .bl
        case (false, true, false, true): return .br
        default: return .none
        }
    }

    override func resetCursorRects() {
        switch zone(at: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)) {
        case .l, .r: addCursorRect(bounds, cursor: .resizeLeftRight)
        case .t, .b: addCursorRect(bounds, cursor: .resizeUpDown)
        default: break
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        let z = zone(at: point)
        guard z != .none else { super.mouseDown(with: event); return }
        let startFrame = window.frame
        let start = NSEvent.mouseLocation
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            guard e.type == .leftMouseDragged else { break }
            let now = NSEvent.mouseLocation
            var f = startFrame
            let dx = now.x - start.x, dy = now.y - start.y
            if z == .l || z == .tl || z == .bl {
                f.origin.x = startFrame.minX + dx
                f.size.width = startFrame.width - dx
            }
            if z == .r || z == .tr || z == .br {
                f.size.width = startFrame.width + dx
            }
            if z == .b || z == .bl || z == .br {
                f.origin.y = startFrame.minY + dy
                f.size.height = startFrame.height - dy
            }
            if z == .t || z == .tl || z == .tr {
                f.size.height = startFrame.height + dy
            }
            if f.width >= window.minSize.width {
                window.setFrame(f, display: true)
            } else {
                var fixed = f
                fixed.size.width = window.minSize.width
                window.setFrame(fixed, display: true)
            }
        }
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
    }
}

// MARK: - 面板控制器

final class HistoryPanelController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {

    private static let frameKey = "panelFrame"

    let store: ClipStoring
    let listViewController: ClipListViewController
    private let rootView = PanelRootView()
    private let searchField = PanelSearchField()
    private var rolledFrame: NSRect?
    private var normalFrame: NSRect?
    private var isRolled = false
    private var isPersistent = false   // 常驻置顶(原版 ShowPersistent / Ctrl+Space)
    private var pendingAutoHide: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    /// 描述浮窗(F3 / 查看完整描述,原版 tooltip 等价)
    private var descTooltip: NSPanel?
    /// 临时关闭失焦隐藏(选菜单/拖窗口期间)
    private var suspendAutoHide = false

    var isOnScreen: Bool { window?.isVisible == true }
    var isPersistentMode: Bool { isPersistent }

    init(store: ClipStoring) {
        self.store = store
        let list = ClipListViewController(store: store)
        self.listViewController = list

        let panel = DittoPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),   // 原版默认 300×300
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false)
        super.init(window: panel)

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = NSSize(width: 160, height: 120)
        panel.delegate = self

        buildContent(in: rootView)
        panel.contentView = rootView
        panel.escapeHandler = { [weak self] in self?.escapePressed() }
        panel.forceHideHandler = { [weak self] in self?.hide() }
        rootView.caption.onClose = { [weak self] in self?.hide() }
        rootView.caption.onMinimize = { [weak self] in self?.hide() }
        rootView.caption.onRoll = { [weak self] in self?.toggleRollUp() }
        rootView.caption.onMaximize = { [weak self] in self?.toggleMaximize() }
        rootView.caption.onDoubleClick = { [weak self] in self?.toggleRollUp() }

        restoreFrame()

        // 列表 → 粘贴流程
        list.onPaste = { [weak self] items in self?.paste(items: items, mode: .normal) }
        list.onPastePlainText = { [weak self] items in self?.paste(items: items, mode: .plainText) }
        list.onPasteDontReorder = { [weak self] items in self?.paste(items: items, mode: .dontReorder) }
        list.onTransformedPaste = { [weak self] item, t in self?.paste(items: [item], mode: .transform(t)) }
        list.onComposeImagesPaste = { [weak self] items, horizontal in
            guard let self else { return }
            let payloads = items.compactMap { self.store.payload(id: $0.id) }
            if let composed = SpecialPaste.composeImages(payloads, horizontal: horizontal) {
                self.hide()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    if Permissions.isAccessibilityGranted {
                        _ = PasteBack.paste(composed, monitor: ClipboardMonitor.shared)
                    } else {
                        PasteBack.write(composed, monitor: ClipboardMonitor.shared)
                        AppDelegate.shared?.promptAccessibilityForPaste()
                    }
                }
            }
        }
        list.onShowProperties = { [weak self] item in self?.showProperties(item: item) }
        list.onSelectionChange = { [weak self] in self?.updateCaptionSuffix() }
        list.onTypeAhead = { [weak self] ch in self?.typeAhead(char: ch) }
        list.onHoverRow = { [weak self] item, rowScreenRect in
            self?.handleHover(item: item, rowScreenRect: rowScreenRect)
        }

        // 应用失活 → 延迟复核隐藏(原版 OnActivate WA_INACTIVE)
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleAutoHideCheck()
        })
        // 暂停记录(原版"断开剪贴板")→ 标题区变黄
        observers.append(NotificationCenter.default.addObserver(
            forName: .dittoPausedChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.rootView.caption.disconnected = UserDefaults.standard.bool(forKey: DittoSettings.pausedKey)
        })
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - 布局(原版 §1:列表 + 底部 33px 工具行)

    private func buildContent(in root: PanelRootView) {
        let placeholder = NSAttributedString(string: L10n.searchPlaceholder, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor(srgbRed: 127 / 255, green: 127 / 255, blue: 127 / 255, alpha: 1),
            .obliqueness: 0.25,   // 灰斜体
        ])
        searchField.placeholderAttributedString = placeholder
        searchField.delegate = self

        // 底部工具行:左 = 搜索历史按钮(原版文件夹钮位置,映射 ⌘↓ 历史),
        // 中 = 搜索框 @(34, 高 25),右 = 系统菜单钮 @(cx-30)
        let historyButton = NSButton(image: NSImage(systemSymbolName: "clock",
                                                     accessibilityDescription: "搜索历史")!,
                                     target: self, action: #selector(showSearchHistory))
        historyButton.bezelStyle = .regularSquare
        historyButton.isBordered = false
        let systemButton = NSButton(image: NSImage(systemSymbolName: "line.3.horizontal",
                                                   accessibilityDescription: "系统菜单")!,
                                    target: self, action: #selector(showSystemMenu))
        systemButton.bezelStyle = .regularSquare
        systemButton.isBordered = false

        let listView = listViewController.view
        for v in [listView, searchField, historyButton, systemButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.mainArea.addSubview(v)
        }
        rootView.caption.disconnected = UserDefaults.standard.bool(forKey: DittoSettings.pausedKey)

        NSLayoutConstraint.activate([
            listView.topAnchor.constraint(equalTo: root.mainArea.topAnchor),
            listView.leadingAnchor.constraint(equalTo: root.mainArea.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: root.mainArea.trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: root.mainArea.bottomAnchor, constant: -33),

            searchField.centerYAnchor.constraint(equalTo: historyButton.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: root.mainArea.leadingAnchor, constant: 34),
            searchField.trailingAnchor.constraint(equalTo: root.mainArea.trailingAnchor, constant: -36),
            searchField.heightAnchor.constraint(equalToConstant: 25),

            historyButton.leadingAnchor.constraint(equalTo: root.mainArea.leadingAnchor, constant: 4),
            historyButton.bottomAnchor.constraint(equalTo: root.mainArea.bottomAnchor, constant: -4),
            historyButton.widthAnchor.constraint(equalToConstant: 24),
            historyButton.heightAnchor.constraint(equalToConstant: 24),

            systemButton.trailingAnchor.constraint(equalTo: root.mainArea.trailingAnchor, constant: -6),
            systemButton.centerYAnchor.constraint(equalTo: historyButton.centerYAnchor),
            systemButton.widthAnchor.constraint(equalToConstant: 24),
            systemButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        // 搜索框行为接线(原版 CSymbolEdit)
        searchField.onArrow = { [weak self] down in
            guard let self else { return false }
            if down { self.listViewController.moveSelection(+1); return true }
            return self.listViewController.moveSelection(-1)
        }
        searchField.onSubmit = { [weak self] in
            guard let self else { return }
            self.recordSearchHistory(self.searchField.stringValue)
            self.listViewController.pasteSelection()
        }
        searchField.onDeleteAtEnd = { [weak self] in
            self?.listViewController.deleteSelection() ?? false
        }
        searchField.onCopyItem = { [weak self] in
            self?.listViewController.copySelection() ?? false
        }
        searchField.onHistory = { [weak self] in self?.showSearchHistory() }
    }

    // MARK: - NSSearchFieldDelegate:FindAsYouType 250ms 防抖(原版默认)

    private var searchDebounce: DispatchWorkItem?

    func controlTextDidChange(_ obj: Notification) {
        searchDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.listViewController.reload(query: self?.searchField.stringValue ?? "")
        }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: - 显示 / 隐藏(原版 ShowQPasteWindow / HideQPasteWindow)

    func show() {
        guard let panel = window else { return }
        cancelPendingAutoHide()
        listViewController.reload(query: searchField.stringValue)
        positionWindow(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(listViewController.firstResponderTarget)
        updateCaptionSuffix()
    }

    /// 原版三种出现位置;macOS 等价:光标处(默认)/ 上次位置(出屏夹取)
    private func positionWindow(_ panel: NSWindow) {
        let mode = UserDefaults.standard.string(forKey: DittoSettings.positionModeKey)
            ?? DittoSettings.defaultPositionMode
        guard mode != "atPrevious", let screen = NSScreen.main else { return }
        var origin = NSEvent.mouseLocation
        origin.x += 2; origin.y -= 2   // At Cursor +2px 偏移
        var frame = panel.frame
        frame.origin = origin
        let visible = screen.visibleFrame
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        panel.setFrameOrigin(frame.origin)
    }

    func toggle() {
        if isOnScreen { hide() } else { show() }
    }

    func hide() {
        cancelPendingAutoHide()
        saveFrame()
        closeDescTooltip()
        closeHoverTip()
        // 原版隐藏时清空搜索文本(QPasteWnd.cpp:923-929)
        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            listViewController.reload(query: "")
        }
        window?.orderOut(nil)
        onHidden?()
    }

    var onHidden: (() -> Void)?

    func refreshList() {
        listViewController.refreshKeepingSelection()
    }

    /// Alt+C / 菜单:清空过滤
    func clearFilter() {
        searchField.stringValue = ""
        listViewController.reload(query: "")
    }

    /// 菜单"以此条过滤列表":把搜索词设为该条描述
    func setFilter(_ q: String) {
        searchField.stringValue = q
        listViewController.reload(query: q)
    }

    // MARK: - 折叠 / 最大化 / 常驻(原版 Roll-up / Maximize / ShowPersistent)

    private func toggleRollUp() {
        guard let panel = window else { return }
        if isRolled {
            if let f = rolledFrame { panel.setFrame(f, display: true, animate: false) }
            isRolled = false
        } else {
            rolledFrame = panel.frame
            var f = panel.frame
            f.size.height = 29   // 2px 边框 ×2 + 标题内容
            panel.setFrame(f, display: true, animate: false)
            isRolled = true
        }
        rootView.caption.setRolled(isRolled)
    }

    private func toggleMaximize() {
        guard let panel = window, let screen = NSScreen.main else { return }
        if let normal = normalFrame {
            panel.setFrame(normal, display: true, animate: false)
            normalFrame = nil
        } else {
            normalFrame = panel.frame
            var f = screen.visibleFrame
            f = f.insetBy(dx: 40, dy: 40)
            panel.setFrame(f, display: true, animate: false)
        }
    }

    /// Ctrl+Space / 系统菜单:常驻置顶(不因失焦隐藏)
    func togglePersistent() {
        isPersistent.toggle()
        window?.level = isPersistent ? .statusBar : .floating
        updateCaptionSuffix()
    }

    private func updateCaptionSuffix() {
        guard isOnScreen else { return }
        var title = "ditto-mac"
        if isPersistent { title += " [\(L10n.tagPinned)]" }
        if UserDefaults.standard.bool(forKey: DittoSettings.pausedKey) { title += " [\(L10n.tagDisconnected)]" }
        let (sel, total) = listViewController.selectionCounts()
        if total > 0 { title += " - \(sel)/\(total)" }
        rootView.caption.titleText = title
    }

    // MARK: - 搜索历史(原版:10 条,Ctrl+↓ 弹出,含 Clear List)

    private static let historyKey = "ditto.searchHistory"

    private var searchHistory: [String] {
        UserDefaults.standard.stringArray(forKey: Self.historyKey) ?? []
    }

    private func recordSearchHistory(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var h = searchHistory.filter { $0 != trimmed }
        h.insert(trimmed, at: 0)
        if h.count > 10 { h = Array(h.prefix(10)) }
        UserDefaults.standard.set(h, forKey: Self.historyKey)
    }

    @objc private func showSearchHistory() {
        let menu = NSMenu()
        for q in searchHistory {
            let item = NSMenuItem(title: q, action: #selector(historyPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = q
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear List", action: #selector(clearSearchHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        let btn = searchField.superview
        let popRect = btn.map { $0.convert(searchField.frame, from: searchField.superview) } ?? NSRect.zero
        menu.popUp(positioning: nil, at: NSPoint(x: popRect.minX + 34, y: popRect.minY), in: btn)
    }

    @objc private func historyPicked(_ sender: NSMenuItem) {
        searchField.stringValue = sender.representedObject as? String ?? ""
        listViewController.reload(query: searchField.stringValue)
    }

    @objc private func clearSearchHistory() {
        UserDefaults.standard.removeObject(forKey: Self.historyKey)
    }

    // MARK: - 系统菜单(原版 IDR_QUICK_PASTE_SYSTEM_MENU 的 macOS 映射)

    @objc private func showSystemMenu() {
        let menu = AppDelegate.shared?.buildSystemMenu() ?? NSMenu()
        let origin = NSPoint(x: rootView.mainArea.frame.width - 30, y: 8)
        menu.popUp(positioning: nil, at: origin, in: rootView.mainArea)
    }

    // MARK: - Esc 三级退出(原版:关 tooltip → 清过滤 → 隐藏窗)

    private func escapePressed() {
        if descTooltip != nil {
            closeDescTooltip()
        } else if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            listViewController.reload(query: "")
        } else {
            hide()
        }
    }

    // MARK: - 列表打字转发 / 焦点(原版:列表打字直接进搜索框)

    private func typeAhead(char: Character) {
        window?.makeFirstResponder(searchField)
        searchField.stringValue.append(char)
        listViewController.reload(query: searchField.stringValue)
    }

    // MARK: - 粘贴流程(原版 DoPaste:写板 → 激活目标 → 隐藏;标记 lastPasteDate)

    private enum PasteMode: Equatable {
        case normal
        case plainText
        case dontReorder
        case transform(SpecialPaste.Transform)
    }

    private func paste(items: [ClipItem], mode: PasteMode) {
        guard !items.isEmpty else { return }
        hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            let payloads = items.compactMap { self.store.payload(id: $0.id) }
            guard !payloads.isEmpty else { return }
            var payload = payloads[0]
            if payloads.count > 1 {
                // 多选:全部为文本时按顺序拼接(原版多选聚合粘贴,分隔 \r\n)
                if payloads.allSatisfy({ $0.imageData == nil && ($0.filePaths ?? []).isEmpty }) {
                    let joined = payloads.compactMap(\.text).joined(separator: "\r\n")
                    payload = RawClip(text: joined)
                }
            }
            switch mode {
            case .normal: break
            case .plainText:
                payload = SpecialPaste.apply(.plainTextOnly, to: payload)
            case .transform(let t):
                payload = SpecialPaste.apply(t, to: payload)
            case .dontReorder: break
            }
            if !Permissions.isAccessibilityGranted {
                // 未授权:内容仍在剪贴板可手动 ⌘V,同时明确引导授权(不再静默)
                PasteBack.write(payload, monitor: ClipboardMonitor.shared)
                AppDelegate.shared?.promptAccessibilityForPaste()
            } else {
                _ = PasteBack.paste(payload, monitor: ClipboardMonitor.shared)
            }
            if mode != .dontReorder {
                let now = Date()
                for item in items { self.store.markPasted(id: item.id, at: now) }
            }
        }
    }

    // MARK: - 属性(原版 Alt+Enter / Properties 菜单)

    private func showProperties(item: ClipItem) {
        suspendAutoHide = true
        let payload = store.payload(id: item.id)
        let controller = PropertiesWindowController(item: item, payload: payload)
        controller.noteSelfWrite = { ClipboardMonitor.shared.noteExternalWrite() }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: controller.window, queue: .main) { [weak self] _ in
            self?.suspendAutoHide = false
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.center()
    }

    // MARK: - 悬停浮窗(鼠标移到条目上时,在面板左侧展示完整内容;对齐原版 tooltip)

    private var hoverTip: NSPanel?
    private var hoverDebounce: DispatchWorkItem?
    private var hoverItemID: Int64?

    private func handleHover(item: ClipItem?, rowScreenRect: NSRect) {
        hoverDebounce?.cancel()
        guard let item else {
            closeHoverTip()
            return
        }
        if hoverItemID == item.id, hoverTip?.isVisible == true { return }
        let work = DispatchWorkItem { [weak self] in
            self?.showHoverTip(item: item, rowScreenRect: rowScreenRect)
        }
        hoverDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func showHoverTip(item: ClipItem, rowScreenRect: NSRect) {
        guard isOnScreen, let panel = window else { return }
        let payload = store.payload(id: item.id)

        // ---- 单文本流内容:元数据 + 图片附件 + 全文,精确测量高度,永不裁切 ----
        let tipWidth: CGFloat = 380
        let hPadding: CGFloat = 12, vPadding: CGFloat = 10
        let contentWidth = tipWidth - hPadding * 2

        let ts = NSMutableAttributedString()
        let meta = ClipDescription.metaLine(item: item,
                                            lastUsedAt: item.lastPasteAt,
                                            neverAutoDelete: item.noDelete)
        ts.append(NSAttributedString(string: meta + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        if let imageData = payload?.imageData, let image = NSImage(data: imageData) {
            let attach = NSTextAttachment()
            let maxW = contentWidth, maxH: CGFloat = 180
            let ratio = min(maxW / max(image.size.width, 1), maxH / max(image.size.height, 1), 1)
            attach.image = image
            attach.bounds = CGRect(x: 0, y: 0,
                                   width: image.size.width * ratio,
                                   height: image.size.height * ratio)
            ts.append(NSAttributedString(attachment: attach))
            ts.append(NSAttributedString(string: "\n"))
        }
        var fullText = payload?.text ?? item.text ?? "(无文本内容)"
        if fullText.isEmpty { fullText = "(空白内容)" }
        if fullText.utf8.count > 64 * 1024 {
            fullText = String(fullText.prefix(64 * 1024)) + "\n…(已截断)"
        }
        ts.append(NSAttributedString(string: fullText, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ]))

        // 测量:按 contentWidth 排版后的实际高度
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 0))
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        text.textStorage?.setAttributedString(ts)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let usedHeight = text.layoutManager!.usedRect(for: text.textContainer!).height

        let viewHeight = min(max(usedHeight + vPadding * 2, 48), 400)

        // ---- 容器:圆角窗口背景 + 滚动视图(超高时内部滚动,不再裁切)----
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: hPadding, height: vPadding)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.frame = NSRect(x: 0, y: 0, width: contentWidth, height: usedHeight + vPadding * 2)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: tipWidth, height: viewHeight))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay

        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        wrap.layer?.cornerRadius = 8
        wrap.layer?.borderColor = NSColor.separatorColor.cgColor
        wrap.layer?.borderWidth = 1
        wrap.layer?.masksToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: wrap.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            wrap.widthAnchor.constraint(equalToConstant: tipWidth),
            wrap.heightAnchor.constraint(equalToConstant: viewHeight),
        ])

        if hoverTip == nil {
            let tip = NSPanel(contentRect: NSRect(x: 0, y: 0, width: tipWidth, height: viewHeight),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
            tip.isOpaque = false
            tip.backgroundColor = .clear
            tip.hasShadow = true
            tip.hidesOnDeactivate = false
            tip.level = .floating + 1
            tip.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            hoverTip = tip
        }
        guard let tip = hoverTip else { return }
        tip.contentView = wrap

        // 定位:面板左侧,与悬停行垂直居中;左侧放不下换右侧;上下夹取到屏内
        let vf = panel.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: panel.frame.minX - tipWidth - 8,
                             y: rowScreenRect.midY - viewHeight / 2)
        if origin.x < vf.minX + 8 {
            origin.x = panel.frame.maxX + 8
        }
        origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - viewHeight - 8)
        tip.setFrameOrigin(origin)
        tip.orderFront(nil)
        hoverItemID = item.id
    }

    private func closeHoverTip() {
        hoverDebounce?.cancel()
        hoverTip?.orderOut(nil)
        hoverTip = nil
        hoverItemID = nil
    }

    func hoverTipForTesting() -> NSPanel? { hoverTip }

    /// 自测钩子:程序化显示第一条(或 DITTO_HOVER_LONG_TEXT=1 时临时插入的长文本)的悬停浮窗
    var hoverTestCleanup: (() -> Void)?

    func showHoverTipForTesting() {
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { PerfLog.event("HOVER_DBG", "self nil"); return }
            let longTextMode = ProcessInfo.processInfo.environment["DITTO_HOVER_LONG_TEXT"] == "1"
            if longTextMode {
                let body = (1...24).map { "第\($0)行:悬停浮窗长文本裁切验证 Hello world \($0) clipboard 测试内容行,中文与 English 混排。" }
                    .joined(separator: "\n")
                if let item = self.store.insert(RawClip(text: body, appName: "hover-test"),
                                                maxDataBytes: 20 << 20) {
                    self.hoverTestCleanup = { [weak self] in self?.store.delete(id: item.id) }
                    self.listViewController.reload(query: "")   // 刷新列表使新行排在首位并被选中
                }
            }
            guard let item = self.listViewController.selectedItems().first else {
                PerfLog.event("HOVER_DBG", "no selected item")
                return
            }
            guard let window = self.window else { PerfLog.event("HOVER_DBG", "no window"); return }
            let rect = self.listViewController.screenRectOfSelectedRow(in: window) ?? .zero
            PerfLog.event("HOVER_DBG", "show item=\(item.id)")
            self.showHoverTip(item: item, rowScreenRect: rect)
            PerfLog.event("HOVER_DBG", "tip=\(self.hoverTip != nil)")
        }
    }

    // MARK: - 描述浮窗(F3,原版 View Full Description tooltip 等价)

    func toggleDescTooltip() {
        if descTooltip != nil {
            closeDescTooltip()
            return
        }
        guard let item = listViewController.selectedItems().first,
              let window = window else { return }
        let full = store.payload(id: item.id)?.text ?? item.text ?? L10n.noTextPlaceholder
        let meta = ClipDescription.metaLine(item: item, lastUsedAt: item.lastPasteAt, neverAutoDelete: item.noDelete)
        let text = NSAttributedString(string: "\(meta)\n\n\(full)", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ])
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        tv.isEditable = false
        tv.drawsBackground = true
        tv.backgroundColor = .windowBackgroundColor
        tv.textStorage?.setAttributedString(text)
        let sv = NSScrollView(frame: tv.frame)
        sv.documentView = tv
        sv.hasVerticalScroller = true
        let tip = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        tip.title = L10n.descWindowTitle
        tip.contentView = sv
        tip.setFrameAutosaveName("descTooltip")
        // 出现在选中行附近
        if let rowRect = listViewController.screenRectOfSelectedRow(in: window) {
            var origin = NSPoint(x: rowRect.minX + 20, y: rowRect.minY - 20)
            origin.x = min(origin.x, window.screen?.visibleFrame.maxX ?? 1600) - 500
            origin.y = max(origin.y, (window.screen?.visibleFrame.minY ?? 0))
            tip.setFrameOrigin(origin)
        } else {
            tip.center()
        }
        tip.orderFront(nil)
        descTooltip = tip
    }

    private func closeDescTooltip() {
        descTooltip?.orderOut(nil)
        descTooltip = nil
    }

    // MARK: - 失焦自动隐藏(原版 OnActivate WA_INACTIVE;常驻模式不隐藏)

    private func cancelPendingAutoHide() {
        pendingAutoHide?.cancel()
        pendingAutoHide = nil
    }

    private func scheduleAutoHideCheck() {
        guard !isPersistent, !suspendAutoHide else { return }
        pendingAutoHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.window else { return }
            if panel.isVisible, NSApp.keyWindow !== panel, !NSApp.isActive {
                self.hide()
            }
        }
        pendingAutoHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: - 位置记忆

    /// 按主屏分辨率分键(原版按分辨率记忆)
    private var frameKeyForScreen: String {
        if let screen = window?.screen ?? NSScreen.main {
            let w = Int(screen.frame.width), h = Int(screen.frame.height)
            if "\(w)x\(h)" != "0x0" { return "\(Self.frameKey)-\(w)x\(h)" }
        }
        return Self.frameKey
    }

    private func restoreFrame() {
        guard let panel = window else { return }
        if let saved = UserDefaults.standard.string(forKey: frameKeyForScreen) {
            let frame = NSRectFromString(saved)
            let visible = NSScreen.screens.contains { $0.frame.intersects(frame) }
            if frame.width >= panel.minSize.width, frame.height >= panel.minSize.height, visible {
                panel.setFrame(frame, display: false)
                return
            }
        }
        panel.center()
    }

    private func saveFrame() {
        guard let panel = window, panel.isVisible, !isRolled else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: frameKeyForScreen)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        scheduleAutoHideCheck()
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveFrame()
    }
}

// MARK: - 搜索框(原版 CSymbolEdit 行为)

final class PanelSearchField: NSSearchField {
    var onArrow: ((Bool /*down*/) -> Bool)?          // ↑↓/PgUp/PgDn/End 转发列表
    var onSubmit: (() -> Void)?                       // 回车 = 粘贴选中(FindAsYouType)
    var onDeleteAtEnd: (() -> Bool)?                  // 光标在末尾按 Delete → 删条目
    var onCopyItem: (() -> Bool)?                     // Ctrl+C 无字段选中 → 复制条目
    var onHistory: (() -> Void)?                      // ⌘↓ 历史

    override init(frame: NSRect) {
        super.init(frame: frame)
        target = self
        action = #selector(submit)
        sendsWholeSearchString = true
        (cell as? NSSearchFieldCell)?.searchButtonCell = nil
        centersPlaceholder = false
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    private func cursorAtEnd() -> Bool {
        guard let editor = currentEditor as? NSTextView? else { return false }
        let len = (editor?.string as NSString?)?.length ?? 0
        let sel = editor?.selectedRange ?? NSRange(location: 0, length: 0)
        return sel.location + sel.length >= len
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command), event.keyCode == 125 { onHistory?(); return }   // ⌘↓ 历史(先于 ↓ 判断)
        switch event.keyCode {
        case 125: if onArrow?(true) == true { return }          // ↓
        case 126: if onArrow?(false) == true { return }         // ↑
        case 36, 76: onSubmit?(); return                        // 回车 = 粘贴选中
        case 117:                                               // Forward Delete @末尾 → 删条目
            if cursorAtEnd(), onDeleteAtEnd?() == true { return }
        case 115, 119, 116, 121:                                // Home/End/PgUp/PgDn 转发列表
            if onArrow?(event.keyCode == 119 || event.keyCode == 121) == true { return }
        default: break
        }
        if mods.contains(.command), event.charactersIgnoringModifiers == "c",
           (currentEditor as? NSTextView?)??.selectedRange.length == 0, onCopyItem?() == true { return }
        super.keyDown(with: event)
    }

    @objc private func submit() { onSubmit?() }
}
