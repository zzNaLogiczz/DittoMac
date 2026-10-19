import AppKit
import DittoMacKit

/// 列表:单列虚列表,复刻原版 QListCtrl 的绘制规则(spec §2),原生语义配色
final class ClipListViewController: NSViewController {

    // 回调(面板接线)
    var onPaste: (([ClipItem]) -> Void)?
    var onPastePlainText: (([ClipItem]) -> Void)?
    var onPasteDontReorder: (([ClipItem]) -> Void)?
    var onShowProperties: ((ClipItem) -> Void)?
    var onSelectionChange: (() -> Void)?
    var onTypeAhead: ((Character) -> Void)?
    /// 悬停条目(供面板显示左侧完整内容浮窗)
    var onHoverRow: ((ClipItem?, NSRect) -> Void)?
    /// 多选图片合成粘贴(面板注入)
    var onComposeImagesPaste: (([ClipItem], Bool) -> Void)?
    /// 特殊粘贴:面板注入(需要先变换再走粘贴流程)
    var onTransformedPaste: ((ClipItem, SpecialPaste.Transform) -> Void)?
    /// 进入组(面板切换 currentParentID;原版回车/双击进组)
    var onEnterGroup: ((Int64) -> Void)?
    /// 返回父组(原版 Backspace 到上级)
    var onGoToParent: (() -> Void)?
    /// ⌃G 组树开关
    var onToggleGroupTree: (() -> Void)?
    /// 编辑条目(原版 Edit Clip;面板注入打开编辑器)
    var onEditClip: ((ClipItem) -> Void)?
    /// 对比条目(原版 Compare;恰好两条时可用)
    var onCompareClips: ((ClipItem, ClipItem) -> Void)?
    /// 窗口级命令(关窗/强关/折叠/最大化 —— 注册表绑定命中时转发给面板执行)
    var onWindowCommand: ((PanelCommand) -> Bool)?

    private(set) var currentQuery = ""
    /// 当前视图所在组(-1 = 顶层;面板导航时同步)
    var parentID: Int64 = -1
    private var items: [ClipItem] = []
    private let store: ClipStoring
    private var tableView: DittoTableView!
    private var debounceWork: DispatchWorkItem?
    private let emptyLabel = NSTextField(labelWithString: "")
    /// 图片缩略图缓存(可见行按需加载)
    private let thumbCache = NSCache<NSNumber, NSImage>()
    /// 富内容缓存(原版 Draw RTF Text:RTF/HTML 条目的 NSAttributedString,
    /// NSCache 上限 ~100 条近似 LRU;仅可见行 configure 时同步加载)
    private let richTextCache = NSCache<NSNumber, NSAttributedString>()
    /// 组间剪切/复制缓冲(原版组间 Ctrl+X/C/V:只存 id,不碰系统剪贴板;
    /// cut=粘贴时移动,copy=粘贴时复制新行)
    private var bufferIDs: [Int64] = []
    private var bufferIsCut = false

    /// 列表字体(原版 Select Font:默认 Segoe UI 13 的 macOS 等价 = 系统字体 13;
    /// 用户经字体面板选择后持久化 ditto.fontName/fontSize,失效回落系统 13)
    static var rowFont: NSFont {
        let d = DittoSettings.defaults
        if let name = d.string(forKey: DittoSettings.fontNameKey), !name.isEmpty,
           let size = d.object(forKey: DittoSettings.fontSizeKey) as? Double,
           let font = NSFont(name: name, size: CGFloat(size)) {
            return font
        }
        return NSFont.systemFont(ofSize: CGFloat(DittoSettings.defaultFontSize))
    }

    /// 选中态字体(同族加粗;取不到粗体变体时退原字体)
    static var rowFontBold: NSFont {
        if let descriptor = rowFont.fontDescriptor.withSymbolicTraits(.bold) as NSFontDescriptor?,
           let bold = NSFont(descriptor: descriptor, size: 0) {
            return bold
        }
        return rowFont
    }

    /// 行高 = 字体行高 × 每条行数(始终显示描述 +1 行)+ 4(原版
    /// QListCtrl.cpp:414-428;纯函数在 DittoSettings.rowHeight,单测覆盖)
    static var rowHeight: CGFloat {
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: rowFont))
        let lines = DittoSettings.defaults.integer(forKey: DittoSettings.linesPerRowKey) == 0
            ? DittoSettings.defaultLinesPerRow
            : DittoSettings.defaults.integer(forKey: DittoSettings.linesPerRowKey)
        let alwaysDesc = DittoSettings.defaults.object(forKey: DittoSettings.alwaysShowDescriptionKey) == nil
            ? false
            : DittoSettings.defaults.bool(forKey: DittoSettings.alwaysShowDescriptionKey)
        return CGFloat(DittoSettings.rowHeight(lineHeight: Double(lineHeight), linesPerRow: lines,
                                               alwaysShowDescription: alwaysDesc))
    }

    private static let cellIdentifier = NSUserInterfaceItemIdentifier(rawValue: "ClipCell")

    init(store: ClipStoring) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        richTextCache.countLimit = 100   // 富内容缓存上限(近似 LRU)
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    /// 搜索框/面板要聚焦的控件
    var firstResponderTarget: NSView { tableView }

    override func loadView() {
        let table = DittoTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue: "desc"))
        column.width = 2500   // 原版单列宽 2500(QPasteWnd.cpp:491)
        table.addTableColumn(column)
        // 列宽自适应可视宽度:右侧相对时间/徽标贴可视右缘(2500 只是初始值)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.sizeLastColumnToFit()
        table.headerView = nil                      // 无表头
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsMultipleSelection = true        // Ctrl+A / Shift+Home 多选(原版支持)
        table.allowsEmptySelection = true
        table.backgroundColor = DittoTheme.listBackground
        table.usesAlternatingRowBackgroundColors = true    // 原生交替行(系统色,自动深浅色)
        table.selectionHighlightStyle = .regular
        table.target = self
        table.doubleAction = #selector(pasteSelected)
        table.dataSource = self
        table.delegate = self
        table.autoresizingMask = [.width]
        table.onKeyDown = { [weak self] event in self?.handleKey(event) }
        table.menuProvider = { [weak self] row in self?.contextMenu(forRow: row) }
        table.onHoverRow = { [weak self] row, screenRect in
            guard let self, let row else {
                self?.onHoverRow?(nil, .zero)
                return
            }
            let item = (row < self.items.count) ? self.items[row] : nil
            self.onHoverRow?(item, screenRect)
        }
        tableView = table

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = DittoTheme.listBackground

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        scrollView.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.contentView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.contentView.centerYAnchor),
        ])
        view = scrollView
    }

    // MARK: - 数据

    func reload(query: String?) {
        currentQuery = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        debounceWork?.cancel()
        performReload(selectFirst: true)
    }

    func refreshKeepingSelection() {
        performReload(selectFirst: false, keepIDs: selectedIDs())
    }

    /// 外观重应用(主题/字体/行高;启动与设置变更时由面板调用):
    /// 主题化 → 关系统交替行与系统选中高亮,行背景/选中态由单元格自绘
    func applyAppearance() {
        richTextCache.removeAllObjects()   // 字体变了,富内容重排
        (view as? NSScrollView)?.backgroundColor = DittoTheme.listBackground
        tableView.backgroundColor = DittoTheme.listBackground
        if DittoTheme.isThemed {
            tableView.usesAlternatingRowBackgroundColors = false
            tableView.selectionHighlightStyle = .none
        } else {
            tableView.usesAlternatingRowBackgroundColors = true
            tableView.selectionHighlightStyle = .regular
        }
        tableView.rowHeight = Self.rowHeight
        tableView.reloadData()
    }

    private func performReload(selectFirst: Bool, keepIDs: Set<Int64> = []) {
        // 组感知查询(取代直接 recent/search):范围=当前组;includeGroupClips
        // 开时顶层含组内条目(原版 ShowClipsInMainList);搜索选项(范围/方式)
        // 来自快速选项设置(原版 Search Options)
        items = store.list(parentID: parentID,
                           includeGroupClips: DittoSettings.includeGroupClips(),
                           query: currentQuery.isEmpty ? nil : currentQuery,
                           limit: 500,
                           scope: DittoSettings.searchScope(),
                           method: DittoSettings.searchMethod())
        tableView.rowHeight = Self.rowHeight
        tableView.reloadData()
        emptyLabel.stringValue = L10n.emptyList
        emptyLabel.isHidden = !items.isEmpty

        if !keepIDs.isEmpty {
            let idx = IndexSet(items.enumerated().filter { keepIDs.contains($1.id) }.map(\.offset))
            if !idx.isEmpty { tableView.selectRowIndexes(idx, byExtendingSelection: false) }
            onSelectionChange?()
            return
        }
        if selectFirst, !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
        onSelectionChange?()
    }

    // MARK: - 选中与行定位

    /// 焦点切换会改变"激活/非激活选中"配色口径(白字只配激活底色),
    /// 可见行须重绘,否则出现选中行白字浮在浅灰非激活底上的"消失"现象
    func refreshSelectionColors() {
        tableView.enumerateAvailableRowViews { [weak self] _, row in
            guard row >= 0 else { return }
            self?.tableView.view(atColumn: 0, row: row, makeIfNecessary: false)?.needsDisplay = true
        }
    }

    func selectedItems() -> [ClipItem] {
        tableView.selectedRowIndexes.compactMap { row in
            (row >= 0 && row < items.count) ? items[row] : nil
        }
    }

    private func selectedIDs() -> Set<Int64> { Set(selectedItems().map(\.id)) }

    /// 选中的条目行(组行不参与粘贴/删除/组间复制)
    func selectedClips() -> [ClipItem] {
        selectedItems().filter { !$0.isGroup }
    }

    /// 当前视图里的条目行(组行不计入;⌘1..0 序号按此编号)
    private var clipRows: [Int] {
        items.indices.filter { !items[$0].isGroup }
    }

    func selectionCounts() -> (Int, Int) { (tableView.selectedRowIndexes.count, items.count) }

    func screenRectOfSelectedRow(in window: NSWindow) -> NSRect? {
        let row = tableView.selectedRow
        guard row >= 0 else { return nil }
        let rect = tableView.rect(ofRow: row)
        let windowRect = tableView.convert(rect, to: nil)
        return window.convertToScreen(windowRect)
    }

    /// ↑↓ 转发:移动选中(单选语义);到边界返回 false 让搜索框吃掉(如 End 后 Delete)
    @discardableResult
    func moveSelection(_ delta: Int) -> Bool {
        guard !items.isEmpty else { return false }
        let current = tableView.selectedRow
        let target = (current < 0) ? (delta > 0 ? 0 : items.count - 1) : current + delta
        guard target >= 0, target < items.count else { return false }
        tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        tableView.scrollRowToVisible(target)
        return true
    }

    func pasteSelection() {
        let selected = selectedClips()
        guard !selected.isEmpty else { return }
        onPaste?(selected)
    }

    @discardableResult
    func deleteSelection() -> Bool {
        // 组行不走 Delete/Backspace 直删(删组=子项归位,须走"删除组"菜单确认)
        let selected = selectedClips()
        guard !selected.isEmpty else { return false }
        // 原版 Prompt to Delete Clip(默认关):开启时删除前确认,多选显示数量
        if DittoSettings.promptDelete(), !Self.confirmDelete(count: selected.count) {
            return false
        }
        for item in selected { store.delete(id: item.id) }
        // 被删条目可能带热键绑定 → 重注册(与组删除刷新同一模式)
        AppDelegate.shared?.clipHotkeysChanged()
        let anchor = min(tableView.selectedRow, items.count - selected.count - 1)
        performReload(selectFirst: false)
        if anchor >= 0, anchor < items.count {
            tableView.selectRowIndexes(IndexSet(integer: anchor), byExtendingSelection: false)
        }
        return true
    }

    /// 删除确认弹窗(设置"删除条目前确认"开启时走这里;组删除另有专属确认)
    static func confirmDelete(count: Int) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.dlgDeleteConfirmTitle
        alert.informativeText = L10n.dlgDeleteConfirmBody(count)
        alert.addButton(withTitle: L10n.dlgOk)
        alert.addButton(withTitle: L10n.dlgCancel)
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Ctrl+C / 菜单:把选中条目写回剪贴板(原版 COPY_SELECTED)
    @discardableResult
    func copySelection() -> Bool {
        let selected = selectedClips()
        guard let first = selected.first, let payload = store.payload(id: first.id) else { return false }
        PasteBack.write(payload, monitor: ClipboardMonitor.shared)
        return true
    }

    private func selectedItem() -> ClipItem? {
        selectedItems().first
    }

    // MARK: - 键盘(原版 §4 ActionEnums 映射;命令注册表优先)

    private func handleKey(_ event: NSEvent) {
        // 命令注册表优先(上游 Quick Paste Keyboard 的命令重绑定机制):
        // 命中 → 走注册表执行;默认注册表值与下方硬编码分支逐一等价(零回归)。
        // 未命中的键(N/P 移动+描述、方向键扩展选择、Home/End/PgUp/PgDn、打字搜索)
        // 不在注册表内,继续走原有硬编码分支(过渡安全)
        if let command = PanelAccels.command(
            forKeyCode: event.keyCode,
            carbonModifiers: DittoSettings.carbonMask(from: event.modifierFlags)) {
            executePanelCommand(command, keyCode: event.keyCode)
            return
        }
        handleKeyLegacy(event)
    }

    /// 注册表命令执行(键码随行:deleteSelected 需要区分 Backspace 的组内语义)
    private func executePanelCommand(_ command: PanelCommand, keyCode: UInt16) {
        switch command {
        case .pasteSelected:
            // 组行回车 = 进入组(不粘贴)—— 原有上下文语义保留
            if let group = selectedItem(), group.isGroup { onEnterGroup?(group.id) }
            else { pasteSelection() }
        case .pastePlain:
            onPastePlainText?(selectedClips())
        case .properties:
            _ = showPropertiesForSelected()
        case .fullDescription:
            AppDelegate.shared?.panelToggleDescTooltip()
        case .deleteSelected:
            // 组内 Backspace = 返回上级(原有上下文语义保留);其余情况删除
            if keyCode == 51, parentID != -1 { onGoToParent?() }
            else { _ = deleteSelection() }
        case .selectAll:
            tableView.selectAll(nil)
        case .copySelection:
            _ = copySelection()
        case .refresh:
            refreshKeepingSelection()
        case .clearFilter:
            AppDelegate.shared?.panelClearFilter()
        case .toggleOrder:
            // 排序方向切换(原版 Toggle Order:最新在上 ↔ 最新在下)
            DittoSettings.defaults.set(!DittoSettings.orderLatestOnTop(),
                                      forKey: DittoSettings.orderLatestOnTopKey)
            NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
        case .toggleSearchMethod:
            // 搜索方式循环(原版 DoActionToggleSearchMethod,QPasteWnd.cpp:3642-3658:
            // 包含 → 正则 → 通配 → 包含;切换后列表/占位提示即时刷新)
            let next: SearchMethod
            switch DittoSettings.searchMethod() {
            case .contains: next = .regex
            case .regex: next = .wildcard
            case .wildcard: next = .contains
            }
            DittoSettings.defaults.set(next.rawValue, forKey: DittoSettings.searchMethodKey)
            NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
        case .toggleAlwaysOnTop:
            AppDelegate.shared?.panelTogglePersistent()
        case .showGroupTree:
            onToggleGroupTree?()
        case .newGroup:
            newGroup(fromSelection: false)
        case .newGroupFromSelection:
            newGroup(fromSelection: true)
        case .cutClips:
            _ = cutSelectionToBuffer()
        case .copyClips:
            _ = copySelectionToBuffer()
        case .pasteClips:
            _ = pasteFromBuffer()
        case .pasteDontReorder:
            onPasteDontReorder?(selectedClips())
        case .moveClipUp:
            moveSelected(.toUp)
        case .moveClipDown:
            moveSelected(.toDown)
        case .moveClipTop:
            moveSelected(.toTop)
        case .moveClipLast:
            moveSelected(.toLast)
        case .makeTopSticky:
            if let item = selectedItem() {
                store.setStickyTop(item.id)
                refreshKeepingSelection()
            }
        case .makeLastSticky:
            if let item = selectedItem() {
                store.setStickyLast(item.id)
                refreshKeepingSelection()
            }
        case .replaceTopSticky:
            if let item = selectedItem() {
                store.replaceStickyTop(item.id)
                refreshKeepingSelection()
            }
        case .removeSticky:
            if let item = selectedItem() {
                store.setSticky(item.id, false)
                refreshKeepingSelection()
            }
        case .closeWindow, .forceClose, .rollUp, .maximize:
            // 窗口级命令转发给面板(Esc 三级退出链/强关/折叠/最大化在面板实现)
            _ = onWindowCommand?(command)
        case .pastePosition1, .pastePosition2, .pastePosition3, .pastePosition4, .pastePosition5,
             .pastePosition6, .pastePosition7, .pastePosition8, .pastePosition9, .pastePosition10:
            // ⌘1..⌘9,⌘0 快选:1..9,0 = 第 1-10 条,与列表序号口径一致
            let digit: Int
            switch command {
            case .pastePosition1: digit = 1
            case .pastePosition2: digit = 2
            case .pastePosition3: digit = 3
            case .pastePosition4: digit = 4
            case .pastePosition5: digit = 5
            case .pastePosition6: digit = 6
            case .pastePosition7: digit = 7
            case .pastePosition8: digit = 8
            case .pastePosition9: digit = 9
            default: digit = 0
            }
            quickPaste(index: digit)
        }
    }

    /// 原有硬编码按键分支(注册表未覆盖的键的兜底路径;默认注册表值命中的键
    /// 不会走到这里 —— 双路径并存保证重绑定生效且无回归)
    private func handleKeyLegacy(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plainMods = mods.subtracting([.function, .numericPad, .capsLock])
        let ctrlOnly = plainMods == .command
        let altOnly = plainMods == .option
        let shiftOnly = plainMods == .shift
        let noMods = plainMods.isEmpty
        let rawCtrlOnly = plainMods == .control   // ⌃X/⌃C/⌃V 组间缓冲(区别于映射到 ⌘ 的原版 Ctrl)

        switch event.keyCode {
        case 36, 76:                                     // Enter
            if altOnly { _ = showPropertiesForSelected() }
            else if shiftOnly { onPastePlainText?(selectedClips()) }
            else if let group = selectedItem(), group.isGroup { onEnterGroup?(group.id) }   // 组行回车=进入(不粘贴)
            else { pasteSelection() }
        case 51:                                         // Backspace:组内=返回父组,顶层=删条目
            if noMods, parentID != -1 { onGoToParent?() }
            else if noMods { _ = deleteSelection() }
            else { superKey(event) }
        case 117:                                        // Forward Delete
            if noMods { _ = deleteSelection() } else { superKey(event) }
        case 98:                                         // F7 组(原版 New Group 系列)
            if plainMods.isEmpty { newGroup(fromSelection: true) }
            else if rawCtrlOnly { newGroup(fromSelection: false) }
            else { superKey(event) }
        case 5:                                          // G:⌃G 组树开关
            if rawCtrlOnly { onToggleGroupTree?() } else { forwardChar(event) }
        case 7:                                          // X:⌃X 组间剪切
            if rawCtrlOnly { cutSelectionToBuffer() } else { forwardChar(event) }
        case 8:                                          // C:⌘C 复制到剪贴板 / ⌥C 清过滤 / ⌃C 组间复制
            if ctrlOnly { _ = copySelection() }
            else if altOnly { AppDelegate.shared?.panelClearFilter() }
            else if rawCtrlOnly { copySelectionToBuffer() }
            else { forwardChar(event) }
        case 9:                                          // V:⌃V 粘贴到当前组(组间缓冲)
            if rawCtrlOnly { pasteFromBuffer() } else { forwardChar(event) }
        case 115:                                        // Home
            if shiftOnly { extendSelection(to: 0) }
            else { selectOnly(0) }
        case 119:                                        // End
            if shiftOnly { extendSelection(to: items.count - 1) }
            else { selectOnly(items.count - 1) }
        case 116: movePage(-1)                           // PgUp
        case 121: movePage(+1)                           // PgDn
        case 125:                                        // ↓
            if shiftOnly, let anchor = anchorRow() { extendFrom(anchor, to: (tableView.selectedRow)+1) }
            else { moveSelection(+1) }
        case 126:                                        // ↑
            moveSelection(-1)
        case 99:                                         // F3 查看完整描述
            AppDelegate.shared?.panelToggleDescTooltip()
        case 96:                                         // F5 刷新
            refreshKeepingSelection()
        case 49:                                         // Ctrl+Space 常驻置顶(⌘Space 被 Spotlight 占用,用 ⌃Space)
            if plainMods == .control { AppDelegate.shared?.panelTogglePersistent() } else { forwardChar(event) }
        case 1:                                          // Ctrl+A 全选
            if ctrlOnly { tableView.selectAll(nil) } else { forwardChar(event) }
        case 45:                                         // N 下一个完整描述(F3 浮窗)
            if noMods { moveSelection(+1); AppDelegate.shared?.panelToggleDescTooltip() } else { forwardChar(event) }
        case 35:                                         // P:上一个完整描述(原版 Accels)
            if noMods { moveSelection(-1); AppDelegate.shared?.panelToggleDescTooltip() } else { forwardChar(event) }
        case 18, 19, 20, 21, 23, 22, 25, 28, 26, 29:     // Ctrl+1..0 粘贴第 1-10 条
            if ctrlOnly {
                let digit = Self.ctrlDigitIndex[event.keyCode]
                quickPaste(index: digit)
            } else {
                forwardChar(event)
            }
        default:
            if noMods, let chars = event.characters, let ch = chars.first, ch.isPrintable {
                onTypeAhead?(ch)                          // 列表打字直接进搜索框(含空格,原版)
            } else {
                superKey(event)
            }
        }
    }

    private func superKey(_ event: NSEvent) {
        tableView.superKeyDown(event)
    }

    private static let ctrlDigitIndex: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
        22: 6, 26: 7, 28: 8, 25: 9, 29: 0,   // 26='7'键、25='9'键(ANSI 键码非常规排序,历史版本曾对调)
    ]

    private func quickPaste(index: Int?) {
        // 1..9,0 = 第 1-10 条(与列表序号口径一致);序号只数条目行、跳过组行
        guard let index else { return }
        let ordinal = index == 0 ? 9 : index - 1
        let rows = clipRows
        guard ordinal >= 0, ordinal < rows.count else { return }
        onPaste?([items[rows[ordinal]]])
    }

    private func anchorRow() -> Int? {
        tableView.selectedRowIndexes.first
    }

    private func extendSelection(to row: Int) {
        guard !items.isEmpty else { return }
        let clamped = min(max(row, 0), items.count - 1)
        let from = tableView.selectedRowIndexes.first ?? 0
        extendFrom(from, to: clamped)
    }

    private func extendFrom(_ from: Int, to: Int) {
        let lo = min(from, to), hi = max(from, to)
        guard hi < items.count else { return }
        tableView.selectRowIndexes(IndexSet(integersIn: lo...hi), byExtendingSelection: false)
        tableView.scrollRowToVisible(to)
    }

    private func selectOnly(_ row: Int) {
        guard row >= 0, row < items.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func movePage(_ delta: Int) {
        let visible = max(1, Int(tableView.bounds.height / max(tableView.rowHeight, 1)) - 1)
        let current = tableView.selectedRow < 0 ? 0 : tableView.selectedRow
        selectOnly(current + delta * visible)
    }

    private func showPropertiesForSelected() -> Bool {
        guard let item = selectedItem() else { return false }
        onShowProperties?(item)
        return true
    }

    private func forwardChar(_ event: NSEvent) {
        if let chars = event.characters, let ch = chars.first, ch.isPrintable {
            onTypeAhead?(ch)
        }
    }

    // MARK: - 组操作(原版 Groups)

    /// 新建组:fromSelection=把选中条目移入(F7);否则空组(⌃F7)。
    /// 名称按"新建组时提示输入名称"设置决定询问或自动命名(原版 NewGroup,
    /// QPasteWnd.cpp:1156-1181:PromptForNewGroupName 开 → CGroupName 对话框)
    func newGroup(fromSelection: Bool) {
        let clips = selectedClips()
        if fromSelection, clips.isEmpty { return }

        let fallback = fromSelection
            ? (clips.first?.text.map { String($0.prefix(20)).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "")
            : ""
        let name: String
        if DittoSettings.promptForGroupName() {
            guard let entered = Self.promptGroupName(default: fallback.isEmpty ? nil : fallback) else { return }
            name = entered
        } else {
            name = L10n.groupDefaultName
        }

        guard let group = store.createGroup(name: name, parentID: parentID) else { return }
        if fromSelection {
            _ = store.moveClips(ids: clips.map(\.id), toParent: group.id)
        }
        // 原版从选中建组后进入新组(EnterGroupID),空组则聚焦新组行
        if fromSelection {
            onEnterGroup?(group.id)
        } else {
            performReload(selectFirst: false, keepIDs: [group.id])
        }
    }

    /// 输入组名弹窗(原版 CGroupName 对话框等价):取消返回 nil;空名落回默认名
    static func promptGroupName(default defaultValue: String?) -> String? {
        NSApp.activate(ignoringOtherApps: true)   // 无边框浮动面板默认不激活应用,弹窗需要
        let alert = NSAlert()
        alert.messageText = L10n.groupPromptTitle
        alert.informativeText = L10n.groupPromptBody
        alert.addButton(withTitle: L10n.dlgOk)
        alert.addButton(withTitle: L10n.dlgCancel)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultValue ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.groupDefaultName : trimmed
    }

    /// 重命名组弹窗
    func renameGroup(_ group: ClipItem) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.groupRenameTitle
        alert.addButton(withTitle: L10n.dlgOk)
        alert.addButton(withTitle: L10n.dlgCancel)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = group.text ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            _ = store.renameGroup(id: group.id, name: trimmed)
            performReload(selectFirst: false, keepIDs: selectedIDs())
        }
    }

    /// 删除组:确认后子项归位(保守删除,见 ClipStore.deleteGroup)
    func deleteGroupWithConfirm(_ group: ClipItem) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.groupDeleteTitle
        alert.informativeText = L10n.groupDeleteBody
        alert.addButton(withTitle: L10n.dlgOk)
        alert.addButton(withTitle: L10n.dlgCancel)
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // 正在删的组里 → 退到其父组(先记父 id,删后查不到该行了)
        let deletedParent = group.parentID
        _ = store.deleteGroup(id: group.id)
        if parentID == group.id {
            if deletedParent == -1 {
                onGoToParent?()
            } else {
                onEnterGroup?(deletedParent)
            }
        } else {
            performReload(selectFirst: false, keepIDs: selectedIDs())
        }
        AppDelegate.shared?.groupHotkeysChanged()
    }

    // MARK: 组间剪切/复制/粘贴(原版组间 Ctrl+X/C/V:仅内部 id 缓冲,不碰系统剪贴板)

    /// ⌃X:剪切选中条目 id(粘贴时移动)
    @discardableResult
    func cutSelectionToBuffer() -> Bool {
        let ids = selectedClips().map(\.id)
        guard !ids.isEmpty else { return false }
        bufferIDs = ids
        bufferIsCut = true
        return true
    }

    /// ⌃C:复制选中条目 id(粘贴时以新 id 复制;缓冲保留可多次粘贴)
    @discardableResult
    func copySelectionToBuffer() -> Bool {
        let ids = selectedClips().map(\.id)
        guard !ids.isEmpty else { return false }
        bufferIDs = ids
        bufferIsCut = false
        return true
    }

    /// ⌃V:把缓冲落到当前组(cut=移动并清空缓冲;copy=复制、缓冲保留)
    @discardableResult
    func pasteFromBuffer() -> Bool {
        guard !bufferIDs.isEmpty else { return false }
        let ok: Bool
        if bufferIsCut {
            ok = store.moveClips(ids: bufferIDs, toParent: parentID)
            if ok { bufferIDs = [] }
        } else {
            ok = store.duplicateClips(ids: bufferIDs, toParent: parentID)
        }
        performReload(selectFirst: false, keepIDs: Set(bufferIDs))
        return ok
    }

    /// 移动选中条目/组到目标组(右键"移动到组";成环被拒时提示)
    func moveSelectionToGroup(_ target: Int64) {
        let ids = selectedItems().map(\.id)
        guard !ids.isEmpty else { return }
        if !store.moveClips(ids: ids, toParent: target) {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L10n.groupMoveCycleAlert
            alert.addButton(withTitle: L10n.dlgOk)
            alert.runModal()
            return
        }
        performReload(selectFirst: false, keepIDs: selectedIDs())
    }

    // MARK: - 右键菜单(原版 IDR_QUICK_PASTE 的 macOS 映射,保持顺序与分隔线)

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard row >= 0, row < items.count else { return nil }
        if tableView.selectedRowIndexes.count <= 1 {
            selectOnly(row)
        }
        let item = selectedItem()
        // 组行菜单(原版组节点右键):打开/重命名/删除组/属性
        if item?.isGroup == true {
            return groupMenu(for: item!)
        }
        let menu = NSMenu()
        menu.autoenablesItems = false

        func add(_ title: String, _ action: Selector?, key: String = "") {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
            mi.target = self
            mi.isEnabled = action != nil
            menu.addItem(mi)
        }

        // (Send To/Compare/Go to Entry:好友与比较系统未移植,预注册省略;
        //  Groups 区域已实现,见菜单尾部的组条目)
        add(L10n.menuViewFullDesc, #selector(menuFullDescription))
        let special = NSMenuItem(title: L10n.menuSpecialPaste, action: nil, keyEquivalent: "")
        let specialMenu = NSMenu()
        // 顺序与分隔线逐位对齐 upstream IDR_QUICK_PASTE(CP_Main.rc:483-512)
        specialMenu.addItem(withTitle: L10n.menuPastePlain, action: #selector(menuPastePlain), target: self)
        specialMenu.addItem(.separator())
        specialMenu.addItem(withTitle: "UPPER CASE", action: #selector(menuUpper), target: self)
        specialMenu.addItem(withTitle: "lower case", action: #selector(menuLower), target: self)
        specialMenu.addItem(withTitle: "Capitalize Case", action: #selector(menuCapitalize), target: self)
        specialMenu.addItem(withTitle: "Sentence case", action: #selector(menuSentence), target: self)
        specialMenu.addItem(withTitle: "Invert Case", action: #selector(menuInvert), target: self)
        specialMenu.addItem(withTitle: "Trim White Space", action: #selector(menuTrim), target: self)
        specialMenu.addItem(withTitle: "Posixify/Paths", action: #selector(menuPosixify), target: self)
        specialMenu.addItem(withTitle: "CamelCase", action: #selector(menuCamelCase), target: self)
        specialMenu.addItem(withTitle: "Ascii Text Only", action: #selector(menuAscii), target: self)
        specialMenu.addItem(.separator())
        specialMenu.addItem(withTitle: "Remove Line Feeds", action: #selector(menuRemoveLF), target: self)
        specialMenu.addItem(withTitle: "Paste + One Line Feed", action: #selector(menuPlusLF1), target: self)
        specialMenu.addItem(withTitle: "Paste + Two Line Feeds", action: #selector(menuPlusLF2), target: self)
        specialMenu.addItem(withTitle: "Paste + Current Time", action: #selector(menuPlusTime), target: self)
        specialMenu.addItem(.separator())
        let multiH = NSMenuItem(title: "Multiple Images Horizontally", action: #selector(menuImagesH), keyEquivalent: "")
        multiH.target = self
        multiH.isEnabled = selectedItems().count >= 2
        specialMenu.addItem(multiH)
        let multiV = NSMenuItem(title: "Multiple Images Vertically", action: #selector(menuImagesV), keyEquivalent: "")
        multiV.target = self
        multiV.isEnabled = selectedItems().count >= 2
        specialMenu.addItem(multiV)
        specialMenu.addItem(.separator())
        specialMenu.addItem(withTitle: L10n.menuPasteNoReorder, action: #selector(menuPasteNoReorder), target: self)
        specialMenu.addItem(.separator())
        specialMenu.addItem(withTitle: "Typoglycemia", action: #selector(menuTypoglycemia), target: self)
        specialMenu.addItem(withTitle: "Slugify", action: #selector(menuSlugify), target: self)
        specialMenu.addItem(withTitle: "Paste new Guid", action: #selector(menuNewGuid), target: self)
        specialMenu.addItem(.separator())
        specialMenu.addItem(withTitle: "Paste as Image", action: #selector(menuPasteAsImage), target: self)
        special.submenu = specialMenu
        menu.addItem(special)

        add(L10n.menuFilterOnClip, #selector(menuFilterOnClip))
        menu.addItem(.separator())
        add(L10n.menuDeleteEntry, #selector(menuDelete))
        menu.addItem(.separator())
        add(L10n.menuEditClip, #selector(menuEditClip))
        // 对比条目(原版 Compare):恰好选中两条时可用
        let compareItem = NSMenuItem(title: L10n.menuCompareClips,
                                     action: #selector(menuCompare), keyEquivalent: "")
        compareItem.target = self
        compareItem.isEnabled = selectedClips().count == 2
        menu.addItem(compareItem)
        menu.addItem(.separator())
        add(L10n.menuProperties, #selector(menuProperties))
        let quick = NSMenuItem(title: L10n.menuQuickProps, action: nil, keyEquivalent: "")
        let quickMenu = NSMenu()
        let noDeleteTitle = (item?.noDelete == true) ? L10n.menuAutoDelete : L10n.menuNeverDelete
        quickMenu.addItem(withTitle: noDeleteTitle, action: #selector(menuToggleNoDelete), target: self)
        // 移除热键(原版 Quick Properties:Remove Hot Key;无绑定时置灰)
        let removeKey = NSMenuItem(title: L10n.menuRemoveHotKey, action: #selector(menuRemoveHotKey), keyEquivalent: "")
        removeKey.target = self
        removeKey.isEnabled = (item != nil) && (store.clipHotkey(id: item!.id) != nil)
        quickMenu.addItem(removeKey)
        let noQuickPaste = NSMenuItem(title: L10n.menuRemoveQuickPaste, action: nil, keyEquivalent: "")
        noQuickPaste.isEnabled = false   // 快速粘贴文本未移植(预注册豁免)
        quickMenu.addItem(noQuickPaste)
        quick.submenu = quickMenu
        menu.addItem(quick)

        let order = NSMenuItem(title: L10n.menuClipOrder, action: nil, keyEquivalent: "")
        let orderMenu = NSMenu()
        orderMenu.addItem(withTitle: "Move To Top", action: #selector(menuMoveTop), target: self)
        orderMenu.addItem(withTitle: "Move Up", action: #selector(menuMoveUp), target: self)
        orderMenu.addItem(withTitle: "Move Down", action: #selector(menuMoveDown), target: self)
        orderMenu.addItem(withTitle: "Move To Last", action: #selector(menuMoveLast), target: self)
        orderMenu.addItem(.separator())
        // 置顶(Sticky)子菜单(原版 Sticky Clips:首位/末位/替换首位/取消)
        let sticky = NSMenuItem(title: L10n.menuStickySubmenu, action: nil, keyEquivalent: "")
        let stickyMenu = NSMenu()
        stickyMenu.addItem(withTitle: L10n.menuStickySetTop, action: #selector(menuStickyTop), target: self)
        stickyMenu.addItem(withTitle: L10n.menuStickySetLast, action: #selector(menuStickyLast), target: self)
        stickyMenu.addItem(withTitle: L10n.menuStickyReplaceTop, action: #selector(menuStickyReplaceTop), target: self)
        stickyMenu.addItem(withTitle: L10n.menuStickyRemove, action: #selector(menuUnpin), target: self)
        sticky.submenu = stickyMenu
        orderMenu.addItem(sticky)
        order.submenu = orderMenu
        menu.addItem(order)

        menu.addItem(.separator())
        let ex = NSMenuItem(title: L10n.menuImportExport, action: nil, keyEquivalent: "")
        let exMenu = NSMenu()
        // 顺序对齐 upstream CP_Main.rc:548-557(Import → Export 包 → 分隔 →
        // QRCode → 文本 → 图片 → Google 翻译);包导入是任务口径新增,紧邻文本导入
        exMenu.addItem(withTitle: L10n.menuImportFromFiles, action: #selector(menuImportClips), target: self)
        let importPkg = NSMenuItem(title: L10n.menuImportClipPackage, action: #selector(menuImportClipPackage), keyEquivalent: "")
        importPkg.target = self
        exMenu.addItem(importPkg)
        let exportPkg = NSMenuItem(title: L10n.menuExportClipPackage, action: #selector(menuExportClipPackage), keyEquivalent: "")
        exportPkg.target = self
        exportPkg.isEnabled = !selectedClips().isEmpty
        exMenu.addItem(exportPkg)
        exMenu.addItem(.separator())
        // 查看二维码(原版 View as QRCode):仅对有文本的条目可用(取首个选中)
        let qrItem = NSMenuItem(title: L10n.menuViewAsQRCode, action: #selector(menuViewAsQRCode), keyEquivalent: "")
        qrItem.target = self
        qrItem.isEnabled = firstSelectedClipText() != nil
        exMenu.addItem(qrItem)
        exMenu.addItem(withTitle: L10n.menuExportText, action: #selector(menuExportText), target: self)
        let exportImg = NSMenuItem(title: "Export to Image File(s)", action: #selector(menuExportImage), keyEquivalent: "")
        exportImg.target = self
        exportImg.isEnabled = selectedItem()?.kind == .image
        exMenu.addItem(exportImg)
        // 导出到 Google 翻译(原版 Export to Google Translate):文本条目可用
        let translate = NSMenuItem(title: L10n.menuExportToTranslate, action: #selector(menuExportToTranslate), keyEquivalent: "")
        translate.target = self
        translate.isEnabled = firstSelectedClipText() != nil
        exMenu.addItem(translate)
        ex.submenu = exMenu
        menu.addItem(ex)

        // 发送到好友(原版 "Send To",QPasteWnd.cpp:1802;好友表在设置→网络同步):
        // 发送全部选中条目(单连接逐帧发完即关)。无好友时置灰引导去设置
        menu.addItem(.separator())
        let send = NSMenuItem(title: L10n.menuSendTo, action: nil, keyEquivalent: "")
        let sendMenu = NSMenu()
        let friends = DittoSettings.loadNetFriends()
        for (index, friend) in friends.enumerated() {
            let mi = NSMenuItem(title: "\(friend.name) (\(friend.host):\(friend.port))",
                                action: #selector(menuSendToFriend(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = index
            sendMenu.addItem(mi)
        }
        if friends.isEmpty {
            send.isEnabled = false
        }
        send.submenu = sendMenu
        menu.addItem(send)

        // Groups(原版右键组区:New Group / New Group(Selection) / Move to Group;
        // 组间 Cut/Copy/Paste = 内部缓冲,不碰系统剪贴板)
        menu.addItem(.separator())
        add(L10n.menuNewGroup, #selector(menuNewGroup), key: "F7")
        add(L10n.menuNewGroupFromSelection, #selector(menuNewGroupFromSelection))
        let move = NSMenuItem(title: L10n.menuMoveToGroup, action: nil, keyEquivalent: "")
        move.submenu = buildMoveToGroupMenu()
        menu.addItem(move)
        let cut = NSMenuItem(title: L10n.menuCutToBuffer, action: #selector(menuCutBuffer), keyEquivalent: "x")
        cut.keyEquivalentModifierMask = .control
        cut.target = self
        cut.isEnabled = !selectedClips().isEmpty
        menu.addItem(cut)
        let copyItem = NSMenuItem(title: L10n.menuCopyToBuffer, action: #selector(menuCopyBuffer), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = .control
        copyItem.target = self
        copyItem.isEnabled = !selectedClips().isEmpty
        menu.addItem(copyItem)
        let pasteItem = NSMenuItem(title: L10n.menuPasteIntoGroup, action: #selector(menuPasteBuffer), keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = .control
        pasteItem.target = self
        pasteItem.isEnabled = !bufferIDs.isEmpty
        menu.addItem(pasteItem)
        return menu
    }

    /// 组行右键菜单:打开/重命名/删除组/属性
    private func groupMenu(for group: ClipItem) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: L10n.menuOpenGroup, action: #selector(menuOpenGroup), target: self)
        menu.addItem(withTitle: L10n.menuRenameGroup, action: #selector(menuRenameGroup), target: self)
        menu.addItem(withTitle: L10n.menuDeleteGroup, action: #selector(menuDeleteGroup), target: self)
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.menuProperties, action: #selector(menuProperties), target: self)
        return menu
    }

    /// "移动到组"子菜单:顶层 + 组树缩进展示 + 底部"新建组…"(选中含组时该组及其
    /// 后代不可作为目标 —— 成环由 moveClips 拒绝,菜单里直接隐藏更直观)
    private func buildMoveToGroupMenu() -> NSMenu {
        let menu = NSMenu()
        let selectedGroups = Set(selectedItems().filter(\.isGroup).map(\.id))
        // 被移动组的后代集合(从每个选中组向下收)
        var blocked = selectedGroups
        var frontier = Array(blocked)
        while let gid = frontier.popLast() {
            for child in store.childGroups(of: gid) where !blocked.contains(child.id) {
                blocked.insert(child.id)
                frontier.append(child.id)
            }
        }
        // 顶层(仅在组内视图时有意义;组内提供"移回主列表"出口)
        if parentID != -1 {
            let top = NSMenuItem(title: L10n.menuTopLevel, action: #selector(menuMoveToGroup(_:)), keyEquivalent: "")
            top.target = self
            top.representedObject = Int64(-1)
            menu.addItem(top)
            menu.addItem(.separator())
        }
        func addTree(_ parent: Int64, depth: Int) {
            for group in store.childGroups(of: parent) {
                guard !blocked.contains(group.id) else { continue }
                let indent = String(repeating: "    ", count: depth)
                let mi = NSMenuItem(title: indent + (group.text ?? ""),
                                    action: #selector(menuMoveToGroup(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = group.id
                menu.addItem(mi)
                addTree(group.id, depth: depth + 1)
            }
        }
        addTree(-1, depth: 0)
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.menuNewGroupEllipsis, action: #selector(menuMoveToNewGroup), target: self)
        return menu
    }

    // MARK: 菜单动作

    @objc private func menuFullDescription() { AppDelegate.shared?.panelToggleDescTooltip() }
    @objc private func menuPastePlain() { onPastePlainText?(selectedItems()) }
    @objc private func menuPasteNoReorder() { onPasteDontReorder?(selectedItems()) }

    /// 发送到好友(原版 Send To friend):representedObject = 好友在列表中的下标;
    /// 全部选中条目经一次连接发出(结果弹窗见 AppDelegate.sendClips)
    @objc private func menuSendToFriend(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        let friends = DittoSettings.loadNetFriends()
        guard index >= 0, index < friends.count else { return }
        let ids = selectedClips().map(\.id)
        guard !ids.isEmpty else { return }
        AppDelegate.shared?.sendClips(ids: ids, to: friends[index])
    }

    private func pasteTransformed(_ t: SpecialPaste.Transform) {
        let selected = selectedItems()
        guard let first = selected.first else { return }
        onTransformedPaste?(first, t)
    }

    @objc private func menuUpper() { pasteTransformed(.upperCase) }
    @objc private func menuLower() { pasteTransformed(.lowerCase) }
    @objc private func menuCapitalize() { pasteTransformed(.capitalizeCase) }
    @objc private func menuSentence() { pasteTransformed(.sentenceCase) }
    @objc private func menuInvert() { pasteTransformed(.invertCase) }
    @objc private func menuTrim() { pasteTransformed(.trimWhitespace) }
    @objc private func menuRemoveLF() { pasteTransformed(.removeLineFeeds) }
    @objc private func menuPlusLF1() { pasteTransformed(.appendOneLineFeed) }
    @objc private func menuPlusLF2() { pasteTransformed(.appendTwoLineFeeds) }
    @objc private func menuPlusTime() { pasteTransformed(.appendCurrentTime) }
    @objc private func menuPosixify() { pasteTransformed(.posixifyPaths) }
    @objc private func menuCamelCase() { pasteTransformed(.camelCase) }
    @objc private func menuAscii() { pasteTransformed(.asciiTextOnly) }
    @objc private func menuPasteAsImage() { pasteTransformed(.pasteAsImage) }
    @objc private func menuTypoglycemia() { pasteTransformed(.typoglycemia) }
    @objc private func menuSlugify() { pasteTransformed(.slugify) }
    @objc private func menuNewGuid() { pasteTransformed(.newGuid) }
    @objc private func menuImagesH() { onComposeImagesPaste?(selectedItems(), true) }
    @objc private func menuImagesV() { onComposeImagesPaste?(selectedItems(), false) }

    @objc private func menuFilterOnClip() {
        guard let text = selectedItem()?.text, !text.isEmpty else { return }
        let q = String(text.prefix(24)).trimmingCharacters(in: .whitespacesAndNewlines)
        AppDelegate.shared?.panelSetFilter(q)
    }

    @objc private func menuDelete() { _ = deleteSelection() }
    @objc private func menuProperties() { _ = showPropertiesForSelected() }
    /// 编辑条目(原版 Edit Clip,2.7.8;组行无此菜单项)
    @objc private func menuEditClip() {
        guard let item = selectedItem(), !item.isGroup else { return }
        onEditClip?(item)
    }
    /// 对比条目(原版 Compare,2.7.14):恰好两条 → 打开对比窗口
    @objc private func menuCompare() {
        let clips = selectedClips()
        guard clips.count == 2 else { return }
        onCompareClips?(clips[0], clips[1])
    }
    /// 移除热键(原版 Quick Properties:Remove Hot Key)
    @objc private func menuRemoveHotKey() {
        guard let item = selectedItem(), !item.isGroup else { return }
        store.setClipHotkey(id: item.id, hotkey: nil)
        AppDelegate.shared?.clipHotkeysChanged()
    }

    // MARK: 组菜单动作

    @objc private func menuNewGroup() { newGroup(fromSelection: false) }
    @objc private func menuNewGroupFromSelection() { newGroup(fromSelection: true) }
    @objc private func menuOpenGroup() {
        guard let group = selectedItem(), group.isGroup else { return }
        onEnterGroup?(group.id)
    }
    @objc private func menuRenameGroup() {
        guard let group = selectedItem(), group.isGroup else { return }
        renameGroup(group)
    }
    @objc private func menuDeleteGroup() {
        guard let group = selectedItem(), group.isGroup else { return }
        deleteGroupWithConfirm(group)
    }
    @objc private func menuMoveToGroup(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? Int64 else { return }
        moveSelectionToGroup(target)
    }
    @objc private func menuCutBuffer() { _ = cutSelectionToBuffer() }
    @objc private func menuCopyBuffer() { _ = copySelectionToBuffer() }
    @objc private func menuPasteBuffer() { _ = pasteFromBuffer() }
    /// 移动到"新建组…":先建组(询问名称),再把选中移入
    @objc private func menuMoveToNewGroup() {
        guard let name = Self.promptGroupName(default: nil) else { return }
        guard let group = store.createGroup(name: name, parentID: -1) else { return }
        moveSelectionToGroup(group.id)
    }

    private func moveSelected(_ direction: ClipStore.ClipMove) {
        guard let item = selectedItem() else { return }
        store.moveClip(item.id, direction)
        refreshKeepingSelection()
    }

    @objc private func menuMoveTop() { moveSelected(.toTop) }
    @objc private func menuMoveUp() { moveSelected(.toUp) }
    @objc private func menuMoveDown() { moveSelected(.toDown) }
    @objc private func menuMoveLast() { moveSelected(.toLast) }

    @objc private func menuToggleNoDelete() {
        guard let item = selectedItem() else { return }
        store.setNoDelete(item.id, !item.noDelete)
        refreshKeepingSelection()
    }

    // 置顶(Sticky)子菜单动作(原版 Sticky Clips)
    @objc private func menuPinTop() {
        guard let item = selectedItem() else { return }
        store.setSticky(item.id, true)
        refreshKeepingSelection()
    }

    @objc private func menuUnpin() {
        guard let item = selectedItem() else { return }
        store.setSticky(item.id, false)
        refreshKeepingSelection()
    }

    @objc private func menuStickyTop() {
        guard let item = selectedItem() else { return }
        store.setStickyTop(item.id)
        refreshKeepingSelection()
    }

    @objc private func menuStickyLast() {
        guard let item = selectedItem() else { return }
        store.setStickyLast(item.id)
        refreshKeepingSelection()
    }

    @objc private func menuStickyReplaceTop() {
        guard let item = selectedItem() else { return }
        store.replaceStickyTop(item.id)
        refreshKeepingSelection()
    }

    @objc private func menuExportText() {
        guard let item = selectedItem() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clip-\(item.id).txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let text = self.store.payload(id: item.id)?.text ?? (item.text ?? "")
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @objc private func menuExportImage() {
        guard let item = selectedItem(), item.kind == .image,
              let data = store.payload(id: item.id)?.imageData else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "clip-\(item.id).png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    @objc private func menuImportClips() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    _ = self.store.insert(RawClip(text: text, appName: L10n.importedAppName), maxDataBytes: 20 << 20)
                }
            }
            self.refreshKeepingSelection()
        }
    }

    @objc private func pasteSelected() {
        pasteSelection()
    }

    // MARK: - 二维码 / Google 翻译 / 打包条目(原版 View as QRCode、Export to
    // Google Translate、Export Clip(s) 包格式)

    /// 首个选中条目的全文(空文本/无选中 → nil;二维码与翻译的可用性判定共用)
    private func firstSelectedClipText() -> String? {
        guard let item = selectedItem(), !item.isGroup else { return nil }
        guard let text = store.payload(id: item.id)?.text ?? item.text else { return nil }
        return text.isEmpty ? nil : text
    }

    /// 查看二维码(原版 ID_MENU_VIEWASQRCODE):>2000 字符弹"文本过长"提示不开窗
    @objc private func menuViewAsQRCode() {
        guard let text = firstSelectedClipText() else { return }
        if text.count > QRCodeExport.maxTextLength {
            Self.alertTooLong(limit: QRCodeExport.maxTextLength, actual: text.count)
            return
        }
        QRCodeWindowController.focusOrCreate(text: text).present()
        PerfLog.event("QR_VIEWED", "chars=\(text.count)")
    }

    /// 导出到 Google 翻译(原版 DoExportToGoogleTranslate):目标语言 = 当前
    /// 界面语言;超 ~1200 字符先弹截断提示再打开
    @objc private func menuExportToTranslate() {
        guard let text = firstSelectedClipText() else { return }
        let (url, truncated) = TranslateExport.urlForExport(text, isChinese: L10n.isChinese)
        guard let url, let target = URL(string: url) else { return }
        if truncated {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L10n.translateTruncatedTitle
            alert.informativeText = L10n.translateTruncatedBody(TranslateExport.maxTextLength)
            alert.addButton(withTitle: L10n.dlgOk)
            alert.addButton(withTitle: L10n.dlgCancel)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        NSWorkspace.shared.open(target)
        PerfLog.event("TRANSLATE_OPENED", "chars=\(text.count) truncated=\(truncated)")
    }

    /// 导出条目包(.dto;原版 Export Clip(s) 的打包 sqlite)
    @objc private func menuExportClipPackage() {
        let clips = selectedClips()
        guard !clips.isEmpty else { return }
        _ = ClipPackageUI.runExportPanel(store: store, items: clips)
    }

    /// 导入条目包:落到当前所在组(去重照常生效)
    @objc private func menuImportClipPackage() {
        ClipPackageUI.runImportPanel(store: store, parentID: parentID) { [weak self] imported in
            guard imported > 0 else { return }
            self?.refreshKeepingSelection()
        }
    }

    /// 文本过长提示(二维码):不截断,直接告知无法生成(原版无对应文案,新拟)
    static func alertTooLong(limit: Int, actual: Int) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.qrTooLongTitle
        alert.informativeText = L10n.qrTooLongBody(limit, actual)
        alert.addButton(withTitle: L10n.dlgOk)
        alert.runModal()
    }
}

// MARK: - DataSource / Delegate

extension ClipListViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
}

extension ClipListViewController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < items.count else { return nil }
        let cell: ClipCellView
        if let reused = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: nil) as? ClipCellView {
            cell = reused
        } else {
            cell = ClipCellView()
            cell.identifier = Self.cellIdentifier
        }
        // 序号只数条目行(组行不占号);组行传 nil
        let clipOrdinal: Int? = items[row].isGroup ? nil : items[..<row].filter { !$0.isGroup }.count
        cell.configure(item: items[row],
                       clipOrdinal: clipOrdinal,
                       query: currentQuery,
                       rowIndex: row,
                       store: store,
                       thumbCache: thumbCache,
                       richTextCache: richTextCache)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
    }
}

// MARK: - 表格(键处理 + 右键 + 悬停跟踪)

final class DittoTableView: NSTableView {
    var onKeyDown: ((NSEvent) -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?
    /// 悬停行变化:行索引(或 nil=移出)+ 该行的屏幕坐标(供左侧浮窗定位)
    var onHoverRow: ((Int?, NSRect) -> Void)?

    func superKeyDown(_ event: NSEvent) {
        super.keyDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // A configured panel command wins over the native app menu while the list has focus.
        // Otherwise a user binding such as Cmd-Q would quit before reaching keyDown.
        if event.type == .keyDown, window?.firstResponder === self,
           PanelAccels.command(forKeyCode: event.keyCode,
                               carbonModifiers: DittoSettings.carbonMask(from: event.modifierFlags)) != nil,
           let onKeyDown {
            onKeyDown(event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func layout() {
        super.layout()
        sizeLastColumnToFit()   // 列宽跟随可视宽度(时间/徽标贴右缘的关键)
        if trackingAreas.isEmpty {
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseMoved, .mouseEnteredAndExited,
                                                .activeInKeyWindow, .inVisibleRect],
                                      owner: self)
            addTrackingArea(area)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0, row < numberOfRows, let window else {
            onHoverRow?(nil, .zero)
            return
        }
        let rect = rect(ofRow: row)
        let windowRect = convert(rect, to: nil)
        onHoverRow?(row, window.convertToScreen(windowRect))
    }

    override func mouseExited(with event: NSEvent) {
        onHoverRow?(nil, .zero)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        return menuProvider?(row)
    }
}

extension NSMenu {
    func addItem(withTitle title: String, action: Selector, target: AnyObject?) {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = target
        mi.isEnabled = true
        addItem(mi)
    }
}

// MARK: - 单元绘制(原版绘制规则:序号/竖线/绿条/图钉/黄星/缩略图/色块/高亮)

final class ClipCellView: NSView {
    private var item: ClipItem?
    /// 条目行在条目中的序号(前 10 条显示;组行传 nil)
    private var clipOrdinal: Int?
    /// 行号(主题化时奇偶行配色用)
    private var rowIndex = 0
    private var query = ""
    private var thumbnail: NSImage?
    /// 富内容(原版 Draw RTF Text:RTF/HTML 条目的属性字符串;nil = 按描述绘制)
    private var richText: NSAttributedString?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    func configure(item: ClipItem, clipOrdinal: Int?, query: String, rowIndex: Int,
                   store: ClipStoring, thumbCache: NSCache<NSNumber, NSImage>,
                   richTextCache: NSCache<NSNumber, NSAttributedString>) {
        self.item = item
        self.clipOrdinal = clipOrdinal
        self.rowIndex = rowIndex
        self.query = query
        self.thumbnail = thumbCache.object(forKey: NSNumber(value: item.id))
        // 富内容绘制(原版 Draw RTF Text,默认关):RTF/HTML 条目画属性内容,
        // 解析失败/关闭 → nil 走描述路径。同步加载 + 缓存(configure 只发生在
        // 可见行,开销有界)
        if DittoSettings.defaults.bool(forKey: DittoSettings.drawRtfTextKey),
           item.kind == .rtf || item.kind == .html {
            richText = Self.richAttributed(for: item, store: store, cache: richTextCache)
        } else {
            richText = nil
        }
        needsDisplay = true
        guard !item.isGroup, item.kind == .image, thumbnail == nil else { return }
        // 缩略图按需加载(可见行),完成后刷新该行
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let data = store.payload(id: item.id)?.imageData,
                  let image = NSImage(data: data) else { return }
            thumbCache.setObject(image, forKey: NSNumber(value: item.id))
            DispatchQueue.main.async {
                guard self?.item?.id == item.id else { return }
                self?.thumbnail = image
                self?.needsDisplay = true
            }
        }
    }

    /// RTF/HTML → 属性字符串(缓存命中或同步解析;失败返回 nil → 回落描述)
    static func richAttributed(for item: ClipItem, store: ClipStoring,
                                cache: NSCache<NSNumber, NSAttributedString>) -> NSAttributedString? {
        let key = NSNumber(value: item.id)
        if let hit = cache.object(forKey: key) { return hit }
        guard let payload = store.payload(id: item.id) else { return nil }
        var attr: NSAttributedString?
        if item.kind == .rtf, let data = payload.rtfData {
            attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil)
        } else if item.kind == .html, let data = payload.htmlData {
            attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil)
        }
        if let attr { cache.setObject(attr, forKey: key) }
        return attr
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        DittoTheme.adjusted()
        let selected = (enclosingTableRowView?.isSelected == true)
        let windowIsKey = window?.isKeyWindow ?? false

        // ---- 主题化:行背景与文字色全部自绘(奇/偶行 + 有/无焦点选中)----
        if DittoTheme.isThemed {
            let bg: NSColor
            if selected {
                bg = windowIsKey ? DittoTheme.selectedBackground : DittoTheme.selectedNoFocusBackground
            } else {
                bg = (rowIndex % 2 == 1) ? DittoTheme.listBackgroundEven : DittoTheme.listBackground
            }
            bg.setFill()
            bounds.fill()
        }
        let foreground: NSColor
        if DittoTheme.isThemed {
            if selected {
                foreground = windowIsKey ? DittoTheme.selectedText : DittoTheme.selectedNoFocusText
            } else {
                foreground = (rowIndex % 2 == 1) ? DittoTheme.textColorEven : DittoTheme.textColor
            }
        } else {
            // 白色选中文字只配系统"激活选中"底色;面板失焦后系统画的是浅灰非激活底,
            // 白字会"消失"(Shift 多选后点窗口外空白的首行白字 bug)→ 非焦点退回正常色
            foreground = (selected && windowIsKey)
                ? NSColor.alternateSelectedControlTextColor
                : DittoTheme.textColor
        }

        // 组行:folder.fill + 组名,无序号/图钉/缩略图/时间(与条目行的视觉区分)
        if item.isGroup {
            drawGroupRow(item: item, selected: selected, foreground: foreground)
            return
        }

        var textX: CGFloat = 5

        // 已粘贴绿条:行首 2px(原版 lastPasteDate≠lDate)
        if item.wasPasted {
            DittoTheme.pastedBar.setFill()
            NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
        }

        // 前 10 条:浅灰小序号(10 作 0)+ x=8 竖线,文字右移 12px
        if let ordinal = clipOrdinal, ordinal < 10 {
            let number = ordinal == 9 ? "0" : "\(ordinal + 1)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .light),
                .foregroundColor: DittoTheme.topTenNumber,
            ]
            let s = NSAttributedString(string: number, attributes: attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: 1, y: max(1, bounds.height - size.height - 1)))
            DittoTheme.topTenNumber.setFill()
            NSRect(x: 8, y: 0, width: 1, height: bounds.height).fill()
            textX = max(textX, 13)
        }

        // 图钉(置顶)/ 黄星(永不删除)—— 原版 sticky 图钉 + noautodelete 黄星
        var iconX = textX
        let iconSize: CGFloat = 12
        if item.pinned {
            drawSymbol("pin.fill", at: iconX, size: iconSize, color: foreground)
            iconX += iconSize + 2
        }
        if item.noDelete {
            drawSymbol("star.fill", at: iconX, size: iconSize, color: .systemYellow)
            iconX += iconSize + 2
        }
        textX = iconX

        // 图片条目:行高缩略图(原版 thumbnails 默认开),文本右移
        if item.kind == .image, let thumb = thumbnail {
            let h = bounds.height - 4
            let ratio = thumb.size.width > 0 ? h / thumb.size.height : 1
            let w = min(max(8, thumb.size.width * ratio), 160)
            let rect = NSRect(x: textX, y: 2, width: w, height: h)
            NSGraphicsContext.current?.imageInterpolation = .high
            thumb.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            textX += w + 3
        }

        // 描述:优先用户自定义标题(原版 Item Title 覆盖派生描述),否则按内容派生
        let desc = ClipDescription.build(text: item.title ?? item.text)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: selected ? ClipListViewController.rowFontBold : ClipListViewController.rowFont,
            .foregroundColor: foreground,
        ]

        // 颜色值自动色块(#hex / rgb() / 色名)
        if let color = ClipDescription.colorValue(in: desc) {
            let side = bounds.height - 6
            color.setFill()
            NSRect(x: textX, y: 3, width: side, height: side).fill()
            textX += side + 4
        }

        // 右侧:相对时间(注册映射)+ rtf/html 类型徽标(注册映射)
        let timeStr = Fmt.relativeTime(item.createdAt)
        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: selected ? NSColor.alternateSelectedControlTextColor : DittoTheme.timeText,
        ]
        let timeSize = (timeStr as NSString).size(withAttributes: timeAttrs)
        var badgeWidth: CGFloat = 0
        if item.kind == .rtf || item.kind == .html {
            let badgeName = item.kind == .rtf ? "doc.richtext" : "safari"
            let badgeRect = NSRect(x: bounds.width - timeSize.width - 20, y: (bounds.height - 11) / 2,
                                   width: 11, height: 11)
            drawSymbol(badgeName, at: badgeRect.minX, size: 11,
                       color: selected ? NSColor.alternateSelectedControlTextColor : DittoTheme.timeText)
            badgeWidth = 15
        }
        (timeStr as NSString).draw(at: NSPoint(x: bounds.width - timeSize.width - 6,
                                               y: (bounds.height - timeSize.height) / 2),
                                   withAttributes: timeAttrs)

        // 始终显示描述(原版 Always Show Description):底部追加一行完整派生描述
        // (次要色,截断到行宽);主描述在剩余区域垂直居中
        let alwaysDesc = DittoSettings.defaults.bool(forKey: DittoSettings.alwaysShowDescriptionKey)
        let descLineHeight = ceil(NSLayoutManager().defaultLineHeight(for: ClipListViewController.rowFont))
        let mainAreaHeight = alwaysDesc ? max(bounds.height - descLineHeight - 2, descLineHeight)
                                        : bounds.height

        // 主文本:富内容(开启且可解析)优先,否则描述(+ 搜索高亮)
        let maxTextWidth = bounds.width - textX - timeSize.width - badgeWidth - 12
        if let rich = richText {
            drawVerticallyCentered(rich, at: textX, maxWidth: maxTextWidth, height: mainAreaHeight)
        } else if !query.isEmpty {
            let attributed = NSMutableAttributedString(string: desc, attributes: attrs)
            ClipDescription.highlight(attributed, matchesOf: query, color: DittoTheme.searchHighlight)
            drawVerticallyCentered(attributed, at: textX, maxWidth: maxTextWidth, height: mainAreaHeight)
        } else {
            let attributed = NSAttributedString(string: desc, attributes: attrs)
            drawVerticallyCentered(attributed, at: textX, maxWidth: maxTextWidth, height: mainAreaHeight)
        }

        // 第二行:完整派生描述(次要色)
        if alwaysDesc {
            let second = NSAttributedString(string: desc, attributes: [
                .font: ClipListViewController.rowFont,
                .foregroundColor: selected
                    ? (DittoTheme.isThemed ? foreground.withAlphaComponent(0.7) : NSColor.alternateSelectedControlTextColor)
                    : DittoTheme.timeText,
            ])
            let secondWidth = bounds.width - textX - 4
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: textX, y: 1, width: max(0, secondWidth), height: descLineHeight)).addClip()
            second.draw(at: NSPoint(x: textX, y: 2))
            NSGraphicsContext.current?.restoreGraphicsState()
        }
    }

    /// 组行绘制:folder.fill 图标 + 组名(可半粗),右侧子项计数
    private func drawGroupRow(item: ClipItem, selected: Bool, foreground: NSColor) {
        var x: CGFloat = 5
        drawSymbol("folder.fill", at: x, size: 14,
                   color: selected ? foreground : NSColor.controlAccentColor)
        x += 18

        let name = ClipDescription.build(text: item.text)
        // 组名半粗(原版组行视觉;自定义字体同样升到 medium 权重)
        let mediumDescriptor = ClipListViewController.rowFont.fontDescriptor
            .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.medium.rawValue]])
        let mediumFont = NSFont(descriptor: mediumDescriptor, size: 0)
            ?? ClipListViewController.rowFont
        let attrs: [NSAttributedString.Key: Any] = [
            .font: selected ? ClipListViewController.rowFontBold : mediumFont,
            .foregroundColor: foreground,
        ]
        let attributed: NSAttributedString
        if !query.isEmpty {
            let mutable = NSMutableAttributedString(string: name, attributes: attrs)
            ClipDescription.highlight(mutable, matchesOf: query, color: DittoTheme.searchHighlight)
            attributed = mutable
        } else {
            attributed = NSAttributedString(string: name, attributes: attrs)
        }
        drawVerticallyCentered(attributed, at: x, maxWidth: bounds.width - x - 4)
    }

    private func drawVerticallyCentered(_ text: NSAttributedString, at x: CGFloat,
                                        maxWidth: CGFloat? = nil, height: CGFloat? = nil) {
        let size = text.size()
        let viewHeight = height ?? bounds.height
        let y = max(0, (viewHeight - size.height) / 2)
        let right = maxWidth ?? (bounds.width - x - 4)
        let clip = NSRect(x: x, y: 0, width: max(0, right), height: bounds.height)
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: clip).addClip()
        text.draw(at: NSPoint(x: x, y: y))
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func drawSymbol(_ name: String, at x: CGFloat, size: CGFloat, color: NSColor) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size - 2, weight: .regular)) else { return }
        let rect = NSRect(x: x, y: (bounds.height - size) / 2, width: size, height: size)
        let tinted = NSImage(size: rect.size, flipped: true) { _ in
            img.draw(in: NSRect(origin: .zero, size: rect.size),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            color.set()
            NSRect(origin: .zero, size: rect.size).fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private var enclosingTableRowView: NSTableRowView? {
        var v = superview
        while let current = v, !(current is NSTableRowView) { v = current.superview }
        return v as? NSTableRowView
    }
}

extension Character {
    var isPrintable: Bool {
        !isWhitespace || self == " "
    }
}
