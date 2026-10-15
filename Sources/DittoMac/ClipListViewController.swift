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

    private(set) var currentQuery = ""
    private var items: [ClipItem] = []
    private let store: ClipStoring
    private var tableView: DittoTableView!
    private var debounceWork: DispatchWorkItem?
    private let emptyLabel = NSTextField(labelWithString: "")
    /// 图片缩略图缓存(可见行按需加载)
    private let thumbCache = NSCache<NSNumber, NSImage>()

    /// 列表字体(原版默认 Segoe UI 13;macOS 等价系统字体 13)
    static let rowFont = NSFont.systemFont(ofSize: 13)
    /// 行高 = 字体行高 × 每条行数 + 4(原版 QListCtrl.cpp:414-428)
    static var rowHeight: CGFloat {
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: rowFont))
        let lines = CGFloat(UserDefaults.standard.integer(forKey: DittoSettings.linesPerRowKey) == 0
            ? DittoSettings.defaultLinesPerRow
            : UserDefaults.standard.integer(forKey: DittoSettings.linesPerRowKey))
        return lineHeight * lines + 4
    }

    private static let cellIdentifier = NSUserInterfaceItemIdentifier(rawValue: "ClipCell")

    init(store: ClipStoring) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
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

    private func performReload(selectFirst: Bool, keepIDs: Set<Int64> = []) {
        items = currentQuery.isEmpty
            ? store.recent(limit: 500)
            : store.search(currentQuery, limit: 500)
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

    func selectedItems() -> [ClipItem] {
        tableView.selectedRowIndexes.compactMap { row in
            (row >= 0 && row < items.count) ? items[row] : nil
        }
    }

    private func selectedIDs() -> Set<Int64> { Set(selectedItems().map(\.id)) }

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
        let selected = selectedItems()
        guard !selected.isEmpty else { return }
        onPaste?(selected)
    }

    @discardableResult
    func deleteSelection() -> Bool {
        let selected = selectedItems()
        guard !selected.isEmpty else { return false }
        for item in selected { store.delete(id: item.id) }
        let anchor = min(tableView.selectedRow, items.count - selected.count - 1)
        performReload(selectFirst: false)
        if anchor >= 0, anchor < items.count {
            tableView.selectRowIndexes(IndexSet(integer: anchor), byExtendingSelection: false)
        }
        return true
    }

    /// Ctrl+C / 菜单:把选中条目写回剪贴板(原版 COPY_SELECTED)
    @discardableResult
    func copySelection() -> Bool {
        let selected = selectedItems()
        guard let first = selected.first, let payload = store.payload(id: first.id) else { return false }
        PasteBack.write(payload, monitor: ClipboardMonitor.shared)
        return true
    }

    private func selectedItem() -> ClipItem? {
        selectedItems().first
    }

    // MARK: - 键盘(原版 §4 ActionEnums 映射)

    private func handleKey(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plainMods = mods.subtracting([.function, .numericPad, .capsLock])
        let ctrlOnly = plainMods == .command
        let altOnly = plainMods == .option
        let shiftOnly = plainMods == .shift
        let noMods = plainMods.isEmpty

        switch event.keyCode {
        case 36, 76:                                     // Enter
            if altOnly { _ = showPropertiesForSelected() }
            else if shiftOnly { onPastePlainText?(selectedItems()) }
            else { pasteSelection() }
        case 51, 117:                                    // Backspace / Delete
            if noMods { _ = deleteSelection() } else { superKey(event) }
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
        case 8:                                          // C:Ctrl+C 复制 / Alt+C 清过滤
            if ctrlOnly { _ = copySelection() }
            else if altOnly { AppDelegate.shared?.panelClearFilter() }
            else { forwardChar(event) }
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
        22: 6, 25: 7, 28: 8, 26: 9, 29: 0,
    ]

    private func quickPaste(index: Int?) {
        // 1..10 条(10 = 0);从当前过滤视图取
        guard let index, index >= 0, index < items.count else { return }
        onPaste?([items[index]])
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

    // MARK: - 右键菜单(原版 IDR_QUICK_PASTE 的 macOS 映射,保持顺序与分隔线)

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard row >= 0, row < items.count else { return nil }
        if tableView.selectedRowIndexes.count <= 1 {
            selectOnly(row)
        }
        let item = selectedItem()
        let menu = NSMenu()
        menu.autoenablesItems = false

        func add(_ title: String, _ action: Selector?, key: String = "") {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
            mi.target = self
            mi.isEnabled = action != nil
            menu.addItem(mi)
        }

        // (Groups/Send To/Compare/Go to Entry:分组与好友系统未移植,预注册省略)
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
        add(L10n.menuProperties, #selector(menuProperties))
        let quick = NSMenuItem(title: L10n.menuQuickProps, action: nil, keyEquivalent: "")
        let quickMenu = NSMenu()
        let noDeleteTitle = (item?.noDelete == true) ? L10n.menuAutoDelete : L10n.menuNeverDelete
        quickMenu.addItem(withTitle: noDeleteTitle, action: #selector(menuToggleNoDelete), target: self)
        for disabled in ["Remove Hot Key", "Remove Quick Paste"] {   // 条目热键/快速粘贴文本未移植(预注册豁免)
            let mi = NSMenuItem(title: disabled, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            quickMenu.addItem(mi)
        }
        quick.submenu = quickMenu
        menu.addItem(quick)

        let order = NSMenuItem(title: L10n.menuClipOrder, action: nil, keyEquivalent: "")
        let orderMenu = NSMenu()
        orderMenu.addItem(withTitle: "Move To Top", action: #selector(menuMoveTop), target: self)
        orderMenu.addItem(withTitle: "Move Up", action: #selector(menuMoveUp), target: self)
        orderMenu.addItem(withTitle: "Move Down", action: #selector(menuMoveDown), target: self)
        orderMenu.addItem(withTitle: "Move To Last", action: #selector(menuMoveLast), target: self)
        orderMenu.addItem(.separator())
        orderMenu.addItem(withTitle: L10n.menuSticky, action: #selector(menuPinTop), target: self)
        orderMenu.addItem(withTitle: L10n.menuUnsticky, action: #selector(menuUnpin), target: self)
        order.submenu = orderMenu
        menu.addItem(order)

        menu.addItem(.separator())
        let ex = NSMenuItem(title: L10n.menuImportExport, action: nil, keyEquivalent: "")
        let exMenu = NSMenu()
        exMenu.addItem(withTitle: L10n.menuImportFromFiles, action: #selector(menuImportClips), target: self)
        exMenu.addItem(withTitle: L10n.menuExportText, action: #selector(menuExportText), target: self)
        let exportImg = NSMenuItem(title: "Export to Image File(s)", action: #selector(menuExportImage), keyEquivalent: "")
        exportImg.target = self
        exportImg.isEnabled = selectedItem()?.kind == .image
        exMenu.addItem(exportImg)
        ex.submenu = exMenu
        menu.addItem(ex)
        return menu
    }

    // MARK: 菜单动作

    @objc private func menuFullDescription() { AppDelegate.shared?.panelToggleDescTooltip() }
    @objc private func menuPastePlain() { onPastePlainText?(selectedItems()) }
    @objc private func menuPasteNoReorder() { onPasteDontReorder?(selectedItems()) }

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

    @objc private func menuPinTop() {
        guard let item = selectedItem() else { return }
        store.setPinned(item.id, true)
        refreshKeepingSelection()
    }

    @objc private func menuUnpin() {
        guard let item = selectedItem() else { return }
        store.setPinned(item.id, false)
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
        cell.configure(item: items[row],
                       row: row,
                       query: currentQuery,
                       store: store,
                       thumbCache: thumbCache)
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
    private var rowIndex = 0
    private var query = ""
    private var thumbnail: NSImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    func configure(item: ClipItem, row: Int, query: String,
                   store: ClipStoring, thumbCache: NSCache<NSNumber, NSImage>) {
        self.item = item
        self.rowIndex = row
        self.query = query
        self.thumbnail = thumbCache.object(forKey: NSNumber(value: item.id))
        needsDisplay = true
        guard item.kind == .image, thumbnail == nil else { return }
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

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        DittoTheme.adjusted()
        let selected = (enclosingTableRowView?.isSelected == true)
        let foreground = selected ? NSColor.alternateSelectedControlTextColor : DittoTheme.textColor

        var textX: CGFloat = 5

        // 已粘贴绿条:行首 2px(原版 lastPasteDate≠lDate)
        if item.wasPasted {
            DittoTheme.pastedBar.setFill()
            NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
        }

        // 前 10 条:浅灰小序号(10 作 0)+ x=8 竖线,文字右移 12px
        if rowIndex < 10 {
            let number = rowIndex == 9 ? "0" : "\(rowIndex + 1)"
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

        // 描述:tab→2 空格、剥缩进加 »、首行、500 截断(ClipDescription 规则)
        let desc = ClipDescription.build(text: item.text)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: selected ? NSFont.systemFont(ofSize: 13, weight: .semibold) : ClipListViewController.rowFont,
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

        // 搜索命中红色高亮(右侧为时间/徽标让位)
        let maxTextWidth = bounds.width - textX - timeSize.width - badgeWidth - 12
        if !query.isEmpty {
            let attributed = NSMutableAttributedString(string: desc, attributes: attrs)
            ClipDescription.highlight(attributed, matchesOf: query, color: DittoTheme.searchHighlight)
            drawVerticallyCentered(attributed, at: textX, maxWidth: maxTextWidth)
        } else {
            let attributed = NSAttributedString(string: desc, attributes: attrs)
            drawVerticallyCentered(attributed, at: textX, maxWidth: maxTextWidth)
        }
    }

    private func drawVerticallyCentered(_ text: NSAttributedString, at x: CGFloat, maxWidth: CGFloat? = nil) {
        let size = text.size()
        let y = (bounds.height - size.height) / 2
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
