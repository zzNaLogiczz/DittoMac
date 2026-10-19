import AppKit

enum SettingsSection: String, CaseIterable {
    case general, clipboard, appearance, shortcuts, filters, automation, network, advanced

    var title: String {
        switch self {
        case .general: return L10n.t("常规", "General")
        case .clipboard: return L10n.t("剪贴板", "Clipboard")
        case .appearance: return L10n.t("外观", "Appearance")
        case .shortcuts: return L10n.t("快捷键", "Shortcuts")
        case .filters: return L10n.t("过滤规则", "Filters")
        case .automation: return L10n.t("自动化", "Automation")
        case .network: return L10n.t("网络同步", "Network Sync")
        case .advanced: return L10n.t("高级", "Advanced")
        }
    }

    var subtitle: String {
        switch self {
        case .general: return L10n.t("让 DittoMac 按你的习惯工作。", "Make DittoMac work the way you do.")
        case .clipboard: return L10n.t("选择记录的内容，以及保留多久。", "Choose what to capture and how long to keep it.")
        case .appearance: return L10n.t("调整快速粘贴窗口的显示方式。", "Personalize the Quick Paste window.")
        case .shortcuts: return L10n.t("使用键盘快速呼出、浏览和粘贴。", "Open, browse and paste using your keyboard.")
        case .filters: return L10n.t("决定哪些应用和内容不进入历史。", "Choose which apps and content stay out of your history.")
        case .automation: return L10n.t("配置复制缓冲和应用专属按键。", "Configure copy buffers and app-specific keystrokes.")
        case .network: return L10n.t("与局域网中的其他 Mac 共享剪贴内容。", "Share clips with other Macs on your local network.")
        case .advanced: return L10n.t("查看使用统计、诊断问题和管理数据。", "View usage, diagnose issues and manage your data.")
        }
    }

    /// Filled glyph shown white on the category tile.
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .appearance: return "paintpalette.fill"
        case .shortcuts: return "command"
        case .filters: return "line.3.horizontal.decrease"
        case .automation: return "bolt.fill"
        case .network: return "network"
        case .advanced: return "wrench.and.screwdriver.fill"
        }
    }

    /// Tile color; system colors keep the hue tuned for light, dark and Increase Contrast.
    var tint: NSColor {
        switch self {
        case .general: return .systemGray
        case .clipboard: return .systemBlue
        case .appearance: return .systemPurple
        case .shortcuts: return .systemIndigo
        case .filters: return .systemOrange
        case .automation: return .systemPink
        case .network: return .systemGreen
        case .advanced: return NSColor(name: nil) { appearance in
            appearance.isDarkMode ? NSColor(srgbRed: 0.42, green: 0.44, blue: 0.48, alpha: 1)
                                  : NSColor(srgbRed: 0.36, green: 0.38, blue: 0.42, alpha: 1)
        }
        }
    }

    func tile(size: CGFloat, elevated: Bool = false) -> SettingsIconTile {
        SettingsIconTile(symbol: symbol, fallback: "gearshape", tint: tint, size: size, elevated: elevated)
    }

    var searchTerms: String {
        switch self {
        case .general: return "语言 language 登录 启动 login 权限 辅助 accessibility 删除 确认"
        case .clipboard: return "历史 history 保留 数量 天数 大小 格式 types rtf html 图片 文本"
        case .appearance: return "主题 theme 字体 font 透明 transparency 位置 position 行数 排序 分组 描述 rich text"
        case .shortcuts: return "键盘 keyboard 快捷键 hotkey 全局 global 复制 粘贴 paste"
        case .filters: return "应用 排除 include exclude 正则 regex 过滤 privacy 隐私"
        case .automation: return "缓冲 buffer 声音 sound 按键串 keys 复制 剪切 cut"
        case .network: return "同步 sync 接收 receive 密码 password 端口 port 好友 friends"
        case .advanced: return "日志 log 统计 statistics 清理 删除 数据 data"
        }
    }
}


/// Sidebar content hosted by a native split-view sidebar item, which supplies the material,
/// full-height layout under the toolbar and (on newer systems) the floating glass treatment.
/// Table selection keeps keyboard navigation, focus and VoiceOver native; rows draw their own
/// accent pill so the highlight stays crisp over any material.
final class SettingsSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((SettingsSection) -> Void)?
    var searchIndex: [SettingsSection: String] = [:]
    private let table = SettingsSidebarTable()
    private let search = NSSearchField()
    private let empty = NSStackView()
    private var sections = SettingsSection.allCases
    private var selection: SettingsSection
    private var updatingSelection = false

    init(selected: SettingsSection) {
        selection = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        search.placeholderString = L10n.t("搜索", "Search")
        search.setAccessibilityLabel(L10n.t("搜索设置", "Search Settings"))
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(filterSections)
        search.translatesAutoresizingMaskIntoConstraints = false
        addSubview(search)

        table.addTableColumn(NSTableColumn(identifier: .init("section")))
        table.headerView = nil
        table.style = .plain
        table.rowSizeStyle = .custom
        table.rowHeight = 32
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = false
        table.setAccessibilityLabel(L10n.t("设置分类", "Settings categories"))
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let footer = makeFooter()
        addSubview(footer)

        let emptyIcon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        emptyIcon.symbolConfiguration = .init(pointSize: 20, weight: .light)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        let emptyLabel = NSTextField(labelWithString: L10n.t("未找到设置", "No settings found"))
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        empty.setViews([emptyIcon, emptyLabel], in: .center)
        empty.orientation = .vertical
        empty.spacing = 6
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.isHidden = true
        addSubview(empty)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            search.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 6),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 28),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        select(selected)
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    /// App identity at the foot of the sidebar; doubles as the "no Save button" explanation.
    private func makeFooter() -> NSView {
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let name = NSTextField(labelWithString: "DittoMac")
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        let note = NSTextField(labelWithString: L10n.t("更改会自动保存", "Changes save automatically"))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [name, note])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let footer = NSStackView(views: [icon, text])
        footer.spacing = 8
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false
        return footer
    }

    func select(_ section: SettingsSection) {
        selection = section
        if let row = sections.firstIndex(of: section) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    func focusSelection() -> Bool { window?.makeFirstResponder(table) ?? true }

    @objc private func filterSections() {
        updatingSelection = true
        defer { updatingSelection = false }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = sections
        let new = SettingsSection.allCases.filter {
            query.isEmpty || "\($0.title) \($0.subtitle) \($0.searchTerms) \(searchIndex[$0] ?? "")".localizedCaseInsensitiveContains(query)
        }
        guard new != old else { return }
        // Both lists keep the canonical order, so removals then insertions transform old into new.
        let removed = IndexSet(old.indices.filter { !new.contains(old[$0]) })
        let inserted = IndexSet(new.indices.filter { !old.contains(new[$0]) })
        let motion: NSTableView.AnimationOptions = SettingsMotion.isReduced ? [] : [.effectFade]
        sections = new
        table.beginUpdates()
        table.removeRows(at: removed, withAnimation: motion)
        table.insertRows(at: inserted, withAnimation: motion)
        table.endUpdates()
        empty.isHidden = !sections.isEmpty
        // Searching does not change the current page until the user selects a result.
        table.allowsEmptySelection = true
        table.deselectAll(nil)
        if let row = sections.firstIndex(of: selection) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sections.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SettingsSidebarRow()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let section = sections[row]
        let cell = SettingsSidebarCell()
        let tile = section.tile(size: 22)
        let label = NSTextField(labelWithString: section.title)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = label
        cell.addSubview(tile)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 15),
            tile.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -14),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection, sections.indices.contains(table.selectedRow) else { return }
        selection = sections[table.selectedRow]
        onSelect?(selection)
    }
}

/// Rounded selection pill inset from the sidebar edges: accent while the list has focus,
/// neutral otherwise (the same emphasis rule as Finder and System Settings).
private final class SettingsSidebarRow: NSTableRowView {
    override var allowsVibrancy: Bool { false }
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isEmphasized ? .emphasized : .normal
    }
    override func drawSelection(in dirtyRect: NSRect) {
        let color: NSColor = isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 9, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
}

private final class SettingsSidebarCell: NSTableCellView {
    override var allowsVibrancy: Bool { false }
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            textField?.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        }
    }
}

private final class SettingsSidebarTable: NSTableView {
    override var allowsVibrancy: Bool { false }
}
