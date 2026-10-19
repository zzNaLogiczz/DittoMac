import AppKit
import DittoMacKit

/// 删除剪贴板数据窗口(原版 DeleteClipData.cpp,2.7.6):
/// 过滤器(标题包含 / 创建时间范围 / 上次使用范围 / 格式)→ 搜索 → 结果表多选 →
/// 删除所选(置顶/永不删除/组行豁免,受保护行自动跳过并提示)
final class DeleteClipDataWindowController: NSWindowController, NSWindowDelegate {

    var onClose: (() -> Void)?

    private let store: ClipStoring
    private var results: [ClipItem] = []

    // 过滤控件
    private let titleField = NSTextField()
    private let createdCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let createdStart = NSDatePicker()
    private let createdEnd = NSDatePicker()
    private let usedCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let usedStart = NSDatePicker()
    private let usedEnd = NSDatePicker()
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    // 结果表与页脚
    private let table = NSTableView()
    private let dbSizeLabel = NSTextField(labelWithString: "")
    private let selectedSizeLabel = NSTextField(labelWithString: "")
    private let selectedCountLabel = NSTextField(labelWithString: "")
    private let skippedNote = NSTextField(labelWithString: "")
    private let deleteButton = NSButton()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    init(store: ClipStoring) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L10n.deleteDataTitle
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        refreshFooter()
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // MARK: - 构建

    private func buildContent() {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8
        container.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        func addFull(_ v: NSView) {
            container.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }
        func label(_ s: String, width: CGFloat = 64) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            l.alignment = .right
            l.setContentHuggingPriority(.required, for: .horizontal)
            l.widthAnchor.constraint(greaterThanOrEqualToConstant: width).isActive = true
            return l
        }
        func picker(_ p: NSDatePicker) {
            p.datePickerStyle = .textFieldAndStepper
            p.datePickerElements = [.yearMonthDay, .hourMinute]
            p.datePickerMode = .single
            p.dateValue = Date()
        }

        // 标题包含
        titleField.font = .systemFont(ofSize: 12)
        titleField.placeholderString = L10n.deleteDataTitleContains
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.cell?.wraps = false
        let titleRow = NSStackView(views: [label(L10n.deleteDataTitleContains), titleField])
        titleRow.orientation = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .centerY
        addFull(titleRow)

        // 创建时间范围(可选)
        createdCheck.state = .off
        picker(createdStart); picker(createdEnd)
        let createdRow = NSStackView(views: [label(L10n.deleteDataCreatedRange), createdCheck,
                                             createdStart, label("—", width: 8), createdEnd])
        createdRow.orientation = .horizontal
        createdRow.spacing = 8
        createdRow.alignment = .centerY
        addFull(createdRow)

        // 上次使用范围(可选)
        usedCheck.state = .off
        picker(usedStart); picker(usedEnd)
        let usedRow = NSStackView(views: [label(L10n.deleteDataLastUsedRange), usedCheck,
                                          usedStart, label("—", width: 8), usedEnd])
        usedRow.orientation = .horizontal
        usedRow.spacing = 8
        usedRow.alignment = .centerY
        addFull(usedRow)

        // 格式
        let formatOptions: [(value: String?, title: String)] = [
            (nil, L10n.deleteDataFormatAll),
            (ClipUTI.text, ClipUTI.text),
            (ClipUTI.rtf, ClipUTI.rtf),
            (ClipUTI.html, ClipUTI.html),
            (ClipUTI.png, ClipUTI.png),
            (ClipUTI.fileURL, ClipUTI.fileURL),
            ("extra", L10n.deleteDataFormatExtra),
        ]
        formatPopup.target = self
        for option in formatOptions {
            formatPopup.addItem(withTitle: option.title)
            formatPopup.lastItem?.representedObject = option.value ?? ""
        }
        let formatRow = NSStackView(views: [label(L10n.deleteDataFormat), formatPopup])
        formatRow.orientation = .horizontal
        formatRow.spacing = 8
        formatRow.alignment = .centerY
        addFull(formatRow)

        // 搜索按钮
        let search = NSButton(title: L10n.deleteDataSearch, target: self, action: #selector(searchAction))
        search.bezelStyle = .rounded
        container.addArrangedSubview(search)

        // 结果表(标题/大小/创建/上次使用,多选)
        let titleCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        titleCol.headerCell.stringValue = L10n.deleteDataColTitle
        titleCol.width = 260
        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeCol.headerCell.stringValue = L10n.deleteDataColSize
        sizeCol.width = 80
        let createdCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("created"))
        createdCol.headerCell.stringValue = L10n.deleteDataColCreated
        createdCol.width = 130
        let usedCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("used"))
        usedCol.headerCell.stringValue = L10n.deleteDataColLastUsed
        usedCol.width = 130
        for col in [titleCol, sizeCol, createdCol, usedCol] { table.addTableColumn(col) }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addFull(scroll)
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true

        // 页脚:数据库大小 / 已选大小 / 已选数量 / 跳过提示
        dbSizeLabel.font = .systemFont(ofSize: 11)
        dbSizeLabel.textColor = .secondaryLabelColor
        selectedSizeLabel.font = .systemFont(ofSize: 11)
        selectedSizeLabel.textColor = .secondaryLabelColor
        selectedCountLabel.font = .systemFont(ofSize: 11)
        selectedCountLabel.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [dbSizeLabel, selectedSizeLabel, selectedCountLabel])
        footer.orientation = .horizontal
        footer.spacing = 16
        addFull(footer)
        skippedNote.font = .systemFont(ofSize: 11)
        skippedNote.textColor = .systemOrange
        skippedNote.isHidden = true
        addFull(skippedNote)

        // 删除所选
        deleteButton.title = L10n.deleteDataDeleteButton
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelectedAction)
        deleteButton.attributedTitle = NSAttributedString(
            string: L10n.deleteDataDeleteButton,
            attributes: [.foregroundColor: NSColor.systemRed])
        deleteButton.isEnabled = false
        container.addArrangedSubview(deleteButton)

        window?.contentView = container
        container.widthAnchor.constraint(equalTo: (window?.contentView!.widthAnchor)!).isActive = true
    }

    // MARK: - 动作

    @objc private func searchAction() {
        let filters = currentFilters()
        results = store.searchForDelete(filters: filters)
        table.reloadData()
        refreshFooter()
    }

    private func currentFilters() -> ClipDeleteFilter {
        ClipDeleteFilter(
            titleContains: titleField.stringValue,
            createdStart: createdCheck.state == .on ? createdStart.dateValue : nil,
            createdEnd: createdCheck.state == .on ? endOfDay(createdEnd.dateValue) : nil,
            lastUsedStart: usedCheck.state == .on ? usedStart.dateValue : nil,
            lastUsedEnd: usedCheck.state == .on ? endOfDay(usedEnd.dateValue) : nil,
            format: {
                let raw = formatPopup.selectedItem?.representedObject as? String
                return (raw?.isEmpty == true) ? nil : raw
            }())
    }

    /// 结束时间含当天该时刻之后的一分钟内(选择器精度为分钟,闭区间口径)
    private func endOfDay(_ date: Date) -> Date {
        date.addingTimeInterval(59)
    }

    @objc private func deleteSelectedAction() {
        let ids = table.selectedRowIndexes.compactMap { $0 < results.count ? results[$0].id : nil }
        guard !ids.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.dlgDeleteConfirmTitle
        alert.informativeText = L10n.deleteDataConfirmBody(ids.count)
        alert.addButton(withTitle: L10n.dlgOk)
        alert.addButton(withTitle: L10n.dlgCancel)
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let outcome = store.deleteClips(ids: ids)
        // 从结果表移除已删行(受保护行保留显示)
        let deleted = Set(ids).subtracting(protectedIDs(in: ids))
        results.removeAll { deleted.contains($0.id) }
        table.reloadData()
        if outcome.skipped > 0 {
            skippedNote.stringValue = L10n.deleteDataSkippedNote(outcome.skipped)
            skippedNote.isHidden = false
        } else {
            skippedNote.isHidden = true
        }
        refreshFooter()
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
        // 被删条目可能带热键绑定 → 重注册
        NotificationCenter.default.post(name: .dittoClipHotkeysChanged, object: nil)
    }

    /// ids 中会被保护跳过的子集,与 deleteClips 共用清理保护规则。
    private func protectedIDs(in ids: [Int64]) -> Set<Int64> {
        var protected = Set<Int64>()
        for id in ids {
            if let row = results.first(where: { $0.id == id }),
               ClipStore.isProtectedFromCleanup(row) {
                protected.insert(id)
            }
        }
        return protected
    }

    private func refreshFooter() {
        dbSizeLabel.stringValue = L10n.deleteDataDbSize + Fmt.bytes(store.databaseSizeBytes())
        let selected = table.selectedRowIndexes.compactMap { $0 < results.count ? results[$0] : nil }
        selectedSizeLabel.stringValue = L10n.deleteDataSelectedSize
            + Fmt.bytes(selected.reduce(0) { $0 + $1.byteSize })
        selectedCountLabel.stringValue = L10n.deleteDataSelectedCount + "\(selected.count)"
        deleteButton.isEnabled = !selected.isEmpty
    }
}

// MARK: - 结果表数据源与委托

extension DeleteClipDataWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < results.count else { return nil }
        let item = results[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "title":
            text = item.title ?? ClipDescription.build(text: item.text)
        case "size":
            text = Fmt.bytes(item.byteSize)
        case "created":
            text = Self.formatter.string(from: item.createdAt)
        case "used":
            text = item.lastPasteAt.map { Self.formatter.string(from: $0) } ?? L10n.deleteDataNeverUsed
        default:
            text = ""
        }
        let label = NSTextField(labelWithString: text)
        label.font = (tableColumn?.identifier.rawValue == "size")
            ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshFooter()
    }
}
