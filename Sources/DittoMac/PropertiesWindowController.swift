import AppKit
import Carbon.HIToolbox
import DittoMacKit

extension Notification.Name {
    /// 组热键绑定变化(属性窗口保存后 post);AppDelegate 监听并重注册组热键
    static let dittoGroupHotkeysChanged = Notification.Name("ditto.groupHotkeysChanged")
    /// 条目热键绑定变化(属性窗口/快速属性 post);AppDelegate 监听并重注册条目热键
    static let dittoClipHotkeysChanged = Notification.Name("ditto.clipHotkeysChanged")
}

/// 条目属性窗口(原版 Properties 对话框的 macOS 等价):
/// 元数据行 + 格式列表(Copy Data)+ 按类型渲染全文/图片/文件/富文本,支持复制全文与删除格式;
/// 组条目时切换为组属性:名称 + 组热键 + 全局可用(原版组属性对话框)
final class PropertiesWindowController: NSWindowController, NSWindowDelegate {

    /// 写剪贴板前通知监控豁免(由调用方注入)
    var noteSelfWrite: (() -> Void)?
    /// windowWillClose 回调
    var onClose: (() -> Void)?

    /// "打开中"强持有表(窗口关闭即释放,不泄漏;按条目 id 去重前置)
    private static var live: [Int64: PropertiesWindowController] = [:]
    private var itemID: Int64?
    /// 存储层(为空时隐藏格式块,仅展示不可删除的静态内容)
    private var store: ClipStoring?
    /// 当前条目(删除格式后按新 payload 重建窗口用)
    private var currentItem: ClipItem?
    /// 格式列表数据与控件(每次 buildContent 重建)
    private var formats: [ClipFormat] = []
    private var formatsTable: NSTableView?
    private var formatsDeleteButton: NSButton?
    /// 条目属性的可编辑字段(原版 Properties:Item Title + Hot Key)
    private var clipTitleField: NSTextField?
    private var clipHotkeyRecorder: HotKeyRecorderView?
    private var clipGlobalCheck: NSButton?

    convenience init(item: ClipItem, payload: RawClip?, store: ClipStoring?) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L10n.propsTitle
        window.isReleasedWhenClosed = false
        self.init(window: window)
        self.store = store
        window.delegate = self          // 确保 windowWillClose 被回调以清理静态表
        buildContent(item: item, payload: payload)
        // 注册强持有表:窗口打开期间 controller 存活(按钮 target 不失效),关闭即移除
        Self.live[item.id] = self
    }

    func windowWillClose(_ notification: Notification) {
        if let id = itemID {
            Self.live.removeValue(forKey: id)
        }
        onClose?()
    }

    // MARK: - 构建

    private func buildContent(item: ClipItem, payload: RawClip?) {
        currentItem = item
        // 组条目 → 组属性界面(名称/热键/全局可用)
        if item.isGroup {
            itemID = item.id
            buildGroupContent(item: item)
            return
        }
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8
        container.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        // 元数据行
        let meta = ClipDescription.metaLine(item: item,
                                            lastUsedAt: item.lastPasteAt,
                                            neverAutoDelete: item.noDelete)
        let metaLabel = NSTextField(labelWithString: meta)
        metaLabel.font = .systemFont(ofSize: 10)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.maximumNumberOfLines = 2
        container.addArrangedSubview(metaLabel)

        // 可编辑元数据(原版 Properties:Item Title + Hot Key(+全局))
        if let titleBlock = buildTitleAndHotkeyBlock(item: item) {
            container.addArrangedSubview(titleBlock)
            titleBlock.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }

        // 格式块(原版 "Saved Copy Data" + Delete Copy Data);无存储时整体隐藏
        if let formatsBlock = buildFormatsBlock(item: item) {
            container.addArrangedSubview(formatsBlock)
            formatsBlock.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }

        // 主体
        var preview: NSView?
        var plainText = ""
        switch item.kind {
        case .image:
            let (view, text) = buildImageBody(payload)
            preview = view; plainText = text
        case .files:
            let (view, text) = buildFilesBody(payload)
            preview = view; plainText = text
        case .rtf, .html:
            let (view, text) = buildRichTextBody(payload, html: item.kind == .html)
            preview = view; plainText = text
        default:
            let (view, text) = buildTextBody(payload)
            preview = view; plainText = text
        }

        if let preview {
            preview.translatesAutoresizingMaskIntoConstraints = false
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
            container.addArrangedSubview(preview)
            preview.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -0).isActive = true
        }

        // 按钮行:保存(标题/热键)/ 复制全文 / 关闭
        let saveButton = NSButton(title: L10n.propsClipSave, target: self, action: #selector(saveClipAction))
        saveButton.bezelStyle = .rounded
        let copyButton = NSButton(title: L10n.propsCopyFull, target: self, action: #selector(copyFullText))
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "c"
        copyButton.keyEquivalentModifierMask = .command
        let closeButton = NSButton(title: L10n.propsClose, target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [saveButton, copyButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        container.addArrangedSubview(buttons)

        // 复制行为需要全文(含图片条目则无文本可复制,置灰)
        copyButton.isEnabled = !plainText.isEmpty
        itemID = item.id
        fullTextCache = plainText

        window?.contentView = container
        container.widthAnchor.constraint(equalTo: (window?.contentView!.widthAnchor)!).isActive = true
    }

    // MARK: - 组属性(原版组属性对话框:名称 + 热键 + "hotkey available globally")

    private var groupNameField: NSTextField?
    private var groupHotkeyRecorder: HotKeyRecorderView?
    private var groupGlobalCheck: NSButton?

    private func buildGroupContent(item: ClipItem) {
        window?.title = L10n.propsTitle + " - " + L10n.kindGroup

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 10
        container.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        // 名称
        let nameLabel = NSTextField(labelWithString: L10n.propsGroupNameLabel)
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.alignment = .right
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        let nameField = NSTextField()
        nameField.stringValue = item.text ?? ""
        nameField.font = .systemFont(ofSize: 13)
        nameField.placeholderString = L10n.groupDefaultName
        let nameRow = NSStackView(views: [nameLabel, nameField])
        nameRow.orientation = .horizontal
        nameRow.spacing = 8
        nameRow.alignment = .centerY
        nameField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        container.addArrangedSubview(nameRow)
        groupNameField = nameField

        // 热键(录入控件复用设置页)+ 全局可用
        let hotkeyLabel = NSTextField(labelWithString: L10n.propsGroupHotkeyLabel)
        hotkeyLabel.font = .systemFont(ofSize: 12)
        hotkeyLabel.textColor = .secondaryLabelColor
        hotkeyLabel.alignment = .right
        hotkeyLabel.setContentHuggingPriority(.required, for: .horizontal)
        let recorder = HotKeyRecorderView()
        if let hk = store?.groupHotkey(id: item.id) {
            recorder.display(code: hk.keyCode, mods: hk.modifiers)
        }
        let clearKey = NSButton(title: L10n.propsGroupHotkeyClear, target: self, action: #selector(clearGroupHotkeyAction))
        clearKey.bezelStyle = .rounded
        clearKey.controlSize = .small
        let hotkeyRow = NSStackView(views: [hotkeyLabel, recorder, clearKey])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.spacing = 8
        hotkeyRow.alignment = .centerY
        container.addArrangedSubview(hotkeyRow)
        groupHotkeyRecorder = recorder
        recorder.onCommit = { [weak self, weak recorder] code, mods in
            recorder?.display(code: code, mods: mods)
            self?.saveGroupBindings(name: nil)
        }

        let global = NSButton(checkboxWithTitle: L10n.propsGroupHotkeyGlobal, target: nil, action: nil)
        global.state = (store?.groupHotkey(id: item.id)?.isGlobal ?? false) ? .on : .off
        container.addArrangedSubview(global)
        groupGlobalCheck = global

        let hint = NSTextField(labelWithString: L10n.propsGroupHotkeyHint)
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        container.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        // 保存 / 关闭
        let save = NSButton(title: L10n.propsGroupSave, target: self, action: #selector(saveGroupAction))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let close = NSButton(title: L10n.propsClose, target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [save, close])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        container.addArrangedSubview(buttons)

        window?.contentView = container
        container.widthAnchor.constraint(equalTo: (window?.contentView!.widthAnchor)!).isActive = true
    }

    /// 保存组属性:name 非 nil 时重命名;热键按录入控件当前显示态落库。
    /// 录入控件只能"设新值",清除热键走"清空热键"按钮(设为无绑定)
    @objc private func saveGroupAction() {
        let name = groupNameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        saveGroupBindings(name: (name?.isEmpty == false) ? name : nil)
        closeWindow()
    }

    private func saveGroupBindings(name: String?) {
        guard let store, let id = itemID else { return }
        if let name {
            _ = store.renameGroup(id: id, name: name)
            currentItem?.text = name
        }
        // 热键:录入控件有显示值 → 写入(全局勾选随行);没有 → 保持原绑定
        if let recorder = groupHotkeyRecorder, let hk = recorder.currentValue {
            let isGlobal = (groupGlobalCheck?.state == .on)
            store.setGroupHotkey(id: id, hotkey: GroupHotkey(keyCode: hk.code, modifiers: hk.mods, isGlobal: isGlobal))
        }
        // AppDelegate 重注册组热键 + 在屏面板刷新(重命名/全局标记即时生效)
        NotificationCenter.default.post(name: .dittoGroupHotkeysChanged, object: nil)
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
    }

    /// 清除组热键绑定(属性窗口的"清除"按钮)
    @objc private func clearGroupHotkeyAction() {
        guard let store, let id = itemID else { return }
        store.setGroupHotkey(id: id, hotkey: nil)
        groupHotkeyRecorder?.clear()
        NotificationCenter.default.post(name: .dittoGroupHotkeysChanged, object: nil)
    }

    // MARK: - 条目属性:标题 + 热键(原版 Properties:Item Title / Hot Key)

    /// 元数据行下方的可编辑块:标题输入 + 热键录入 + 全局可用(默认开)+ 清除
    private func buildTitleAndHotkeyBlock(item: ClipItem) -> NSView? {
        guard let store else { return nil }

        let block = NSStackView()
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 8

        func rightLabel(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            l.alignment = .right
            l.setContentHuggingPriority(.required, for: .horizontal)
            l.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
            return l
        }

        // 标题(空 = 按内容派生描述)
        let titleField = NSTextField()
        titleField.stringValue = item.title ?? ""
        titleField.font = .systemFont(ofSize: 13)
        titleField.placeholderString = L10n.propsTitleLabel
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.cell?.wraps = false
        let titleRow = NSStackView(views: [rightLabel(L10n.propsTitleLabel), titleField])
        titleRow.orientation = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .centerY
        titleField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        block.addArrangedSubview(titleRow)
        clipTitleField = titleField

        // 热键录入 + 清除
        let recorder = HotKeyRecorderView()
        if let hk = store.clipHotkey(id: item.id) {
            recorder.display(code: hk.keyCode, mods: hk.modifiers)
        }
        recorder.onCommit = { [weak recorder] code, mods in
            recorder?.display(code: code, mods: mods)
        }
        let clearKey = NSButton(title: L10n.propsGroupHotkeyClear, target: self,
                                action: #selector(clearClipHotkeyAction))
        clearKey.bezelStyle = .rounded
        clearKey.controlSize = .small
        let hotkeyRow = NSStackView(views: [rightLabel(L10n.propsHotkeyLabel), recorder, clearKey])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.spacing = 8
        hotkeyRow.alignment = .centerY
        block.addArrangedSubview(hotkeyRow)
        clipHotkeyRecorder = recorder

        // 全局可用(默认开:原版新录热键默认全局)
        let global = NSButton(checkboxWithTitle: L10n.propsHotkeyGlobal, target: nil, action: nil)
        let existing = store.clipHotkey(id: item.id)
        global.state = (existing?.isGlobal ?? true) ? .on : .off
        block.addArrangedSubview(global)
        clipGlobalCheck = global

        let hint = NSTextField(labelWithString: L10n.propsHotkeyHint)
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        block.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true

        return block
    }

    /// 保存条目标题与热键(标题空 = 清除;录入控件无值 → 保持原绑定)
    @objc private func saveClipAction() {
        guard let store, let id = itemID else { return }
        let trimmed = clipTitleField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        store.setTitle(id, trimmed.isEmpty ? nil : trimmed)
        currentItem?.title = trimmed.isEmpty ? nil : trimmed
        if let hk = clipHotkeyRecorder?.currentValue {
            store.setClipHotkey(id: id, hotkey: ClipHotkey(keyCode: hk.code,
                                                           modifiers: hk.mods,
                                                           isGlobal: clipGlobalCheck?.state == .on))
        }
        // 重注册条目热键 + 在屏面板刷新(标题变化反映到列表)
        NotificationCenter.default.post(name: .dittoClipHotkeysChanged, object: nil)
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
        closeWindow()
    }

    /// 清除条目热键绑定(原版 Remove Hot Key)
    @objc private func clearClipHotkeyAction() {
        guard let store, let id = itemID else { return }
        store.setClipHotkey(id: id, hotkey: nil)
        clipHotkeyRecorder?.clear()
        NotificationCenter.default.post(name: .dittoClipHotkeysChanged, object: nil)
    }

    // MARK: - 格式块(原版 Copy Data 列表 + Delete Copy Data)

    /// 元数据行下方的格式列表:单列 "UTI · 大小",多选,可删除所选格式
    private func buildFormatsBlock(item: ClipItem) -> NSView? {
        guard let store else { return nil }   // 无存储(调用方无法提供)→ 整块隐藏
        formats = store.formats(id: item.id)
        formatsTable = nil
        formatsDeleteButton = nil

        let block = NSStackView()
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 6

        let header = NSTextField(labelWithString: L10n.propsFormatsHeader)
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.textColor = .secondaryLabelColor
        block.addArrangedSubview(header)

        if formats.isEmpty {
            let empty = NSTextField(labelWithString: L10n.propsNoFormats)
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            block.addArrangedSubview(empty)
            return block
        }

        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue: "format"))
        column.width = 380
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 20
        table.style = .sourceList
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.autoresizingMask = [.width]   // 跟随滚动视图宽度铺满(窗口可拉伸)
        formatsTable = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
        block.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true

        let delete = NSButton(title: L10n.propsFormatDelete, target: self, action: #selector(deleteSelectedFormats))
        delete.bezelStyle = .rounded
        delete.attributedTitle = NSAttributedString(
            string: L10n.propsFormatDelete,
            attributes: [.foregroundColor: NSColor.systemRed])
        formatsDeleteButton = delete
        block.addArrangedSubview(delete)

        delete.isEnabled = false   // 无选中时置灰,选中态由 tableViewSelectionDidChange 维护
        return block
    }

    /// 删除所选格式:确认 → store.deleteFormats;拒绝(会删空/条目不在)→ 提示至少保留一种
    @objc private func deleteSelectedFormats() {
        guard let store, let id = itemID else { return }
        let rows = formatsTable?.selectedRowIndexes ?? IndexSet()
        let types = rows.compactMap { $0 < formats.count ? formats[$0].type : nil }
        guard !types.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.propsFormatDeleteConfirmTitle
        alert.informativeText = L10n.propsFormatDeleteConfirmBody + "\n" + types.joined(separator: "\n")
        alert.addButton(withTitle: L10n.dlgOk)
        alert.addButton(withTitle: L10n.dlgCancel)
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard store.deleteFormats(id: id, types: types) else {
            let info = NSAlert()
            info.alertStyle = .informational
            info.messageText = L10n.propsKeepOneFormat
            info.addButton(withTitle: L10n.dlgOk)
            info.runModal()
            return
        }
        rebuildAfterFormatDeletion(store: store, id: id)
    }

    /// 删除成功后:按新 payload 重建整窗内容(体积/哈希已重算,预览随剩余格式切换),
    /// 并广播面板已在监听的设置变更通知刷新在屏列表
    private func rebuildAfterFormatDeletion(store: ClipStoring, id: Int64) {
        let freshPayload = store.payload(id: id)
        if var item = currentItem {
            item.kind = freshPayload?.kind ?? item.kind
            item.byteSize = freshPayload?.byteSize ?? item.byteSize
            currentItem = item
            buildContent(item: item, payload: freshPayload)
        }
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
    }

    private var fullTextCache = ""

    @objc private func copyFullText() {
        guard let noteSelfWrite else { return }
        noteSelfWrite()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(fullTextCache, forType: .string)
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }

    // MARK: - 各类型主体

    /// 文本:只读、可选择、等宽字体全文(可滚动)
    private func buildTextBody(_ payload: RawClip?) -> (NSView, String) {
        let text = payload?.text ?? ""
        let placeholder = text.isEmpty
        let content = plainAttr(placeholder ? L10n.propsNoText : text,
                                font: NSFont.userFixedPitchFont(ofSize: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular),
                                color: placeholder ? .secondaryLabelColor : .labelColor)
        return (makeScrollableText(content), text)
    }

    /// 文件:路径列表(每行一条,等宽,可滚动)
    private func buildFilesBody(_ payload: RawClip?) -> (NSView, String) {
        let joined = (payload?.filePaths ?? []).joined(separator: "\n")
        let placeholder = joined.isEmpty
        let content = plainAttr(placeholder ? L10n.propsNoFiles : joined,
                                font: NSFont.userFixedPitchFont(ofSize: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular),
                                color: placeholder ? .secondaryLabelColor : .labelColor)
        return (makeScrollableText(content), joined)
    }

    /// 富文本:渲染视图(RTF/HTML)+ 纯文本对照
    private func buildRichTextBody(_ payload: RawClip?, html: Bool) -> (NSView, String) {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6

        var rendered: NSView?
        var plain = payload?.text ?? ""
        if html, let htmlData = payload?.htmlData {
            rendered = renderAttributed(htmlData, type: .html)
        } else if let rtfData = payload?.rtfData {
            rendered = renderAttributed(rtfData, type: .rtf)
        }

        let renderedScroll = rendered ?? makeScrollableText(
            plainAttr(L10n.propsRenderFailed, font: .systemFont(ofSize: 12), color: .secondaryLabelColor))
        let caption = NSTextField(labelWithString: L10n.propsPlainRef)
        caption.font = NSFont.systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        let plainScroll = makeScrollableText(
            plainAttr(plain.isEmpty ? L10n.propsEmpty : plain,
                      font: NSFont.userFixedPitchFont(ofSize: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)))
        for v: NSView in [renderedScroll, caption, plainScroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            renderedScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            renderedScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            renderedScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            caption.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            plainScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            plainScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            plainScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])
        return (container, plain)
    }

    private func renderAttributed(_ data: Data, type: NSAttributedString.DocumentType) -> NSView? {
        let attr = try? NSAttributedString(data: data,
                                           options: [.documentType: type],
                                           documentAttributes: nil)
        guard let attr, attr.length > 0 else { return nil }
        return makeScrollableText(attr)
    }

    /// 图片:aspect-fit + 尺寸/字节标注
    private func buildImageBody(_ payload: RawClip?) -> (NSView, String) {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .centerY
        container.spacing = 6

        var dims = ""
        if let data = payload?.imageData, let image = NSImage(data: data) {
            let iv = NSImageView()
            iv.image = image
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.heightAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
            container.addArrangedSubview(iv)
            if let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0 {
                dims = "\(rep.pixelsWide)×\(rep.pixelsHigh)"
            }
            let caption = NSTextField(labelWithString: dims + " · " + Fmt.bytes(data.count))
            caption.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            caption.textColor = .secondaryLabelColor
            container.addArrangedSubview(caption)
            return (container, "")
        }
        let preview = makeScrollableText(plainAttr(L10n.propsNoImage,
                                                   font: .systemFont(ofSize: 12),
                                                   color: .secondaryLabelColor))
        container.addArrangedSubview(preview)
        return (container, "")
    }

    // MARK: - 工具

    private func plainAttr(_ string: String,
                           font: NSFont,
                           color: NSColor = .labelColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }

    private func makeScrollableText(_ attributed: NSAttributedString) -> NSView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 200))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(attributed)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }
}

// MARK: - 格式表数据源与委托

extension PropertiesWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { formats.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < formats.count else { return nil }
        let format = formats[row]
        let label = NSTextField(labelWithString: "\(format.type) · \(Fmt.bytes(format.data.count))")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView, table === formatsTable else { return }
        formatsDeleteButton?.isEnabled = !table.selectedRowIndexes.isEmpty
    }
}
