import AppKit
import DittoMacKit

/// 条目编辑器(原版 Edit Clip / New Clip,2.7.8/2.7.9):
/// 文本 / RTF / HTML 三个可编辑页签 + 附加格式只读列表;
/// 保存 → store.updateClipContent(体积与哈希按剩余内容重算);
/// 保存并放回剪贴板 → 额外把最新 payload 写回系统剪贴板(PasteBack.write 自带
/// monitor 豁免区间上报)。新建模式首次保存才 INSERT(落在当前组)
final class ClipEditorWindowController: NSWindowController, NSWindowDelegate {

    /// "打开中"强持有表(窗口关闭即释放;同一条目重复打开 = 聚焦已有窗口)
    private static var live: [String: ClipEditorWindowController] = [:]
    private let liveKey: String

    private let store: ClipStoring
    /// nil = 新建模式(首次保存 INSERT)
    private var clipID: Int64?
    private let parentID: Int64
    /// 打开时是否已带该格式:决定"页签清空"的语义(有 → 清空该列;无 → 不创建)
    private var hadRTF = false
    private var hadHTML = false
    /// 打开时是否已有文本列(files 条目的 text 只是路径预览,payload 口径为 nil;
    /// 空页签 + 原本无文本 → 不动该列,避免误清 files/image 条目的列表预览)
    private var hadText = false

    private let textTab = NSTextView()
    private let rtfTab = NSTextView()
    private let htmlTab = NSTextView()
    private var extrasStack: NSStackView?
    private var saveButton: NSButton?

    /// - Parameters:
    ///   - clip: nil = 新建条目(编辑器为空,首次保存入库)
    init(clip: ClipItem?, payload: RawClip?, store: ClipStoring, parentID: Int64) {
        self.store = store
        self.clipID = clip?.id
        self.parentID = parentID
        liveKey = clip.map { "edit-\($0.id)" } ?? "new-\(UUID().uuidString)"

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = (clip == nil) ? L10n.editorTitleNew : L10n.editorTitleEdit
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        hadRTF = payload?.rtfData != nil
        hadHTML = payload?.htmlData != nil
        hadText = payload?.text?.isEmpty == false
        buildContent(clip: clip, payload: payload)
        Self.live[liveKey] = self
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    func windowWillClose(_ notification: Notification) {
        Self.live.removeValue(forKey: liveKey)
    }

    /// 同一条目已有编辑器 → 聚焦;否则新建
    static func focusOrCreate(clip: ClipItem?, payload: RawClip?, store: ClipStoring, parentID: Int64)
        -> ClipEditorWindowController {
        if let clip, let existing = live["edit-\(clip.id)"] {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        return ClipEditorWindowController(clip: clip, payload: payload, store: store, parentID: parentID)
    }

    // MARK: - 构建

    private func buildContent(clip: ClipItem?, payload: RawClip?) {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8
        container.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        // 新建模式提示:首次保存才入库
        if clip == nil {
            let hint = NSTextField(labelWithString: L10n.editorEmptyNewClip)
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            container.addArrangedSubview(hint)
            hint.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }

        // 三页签:文本(纯)/ RTF(富)/ HTML(源码)
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let textItem = NSTabViewItem(identifier: nil)
        textItem.label = L10n.editorTabText
        textItem.view = makeEditorScroll(textTab, rich: false, monospace: true)
        tabView.addTabViewItem(textItem)

        let rtfItem = NSTabViewItem(identifier: nil)
        rtfItem.label = L10n.editorTabRTF
        rtfItem.view = makeEditorScroll(rtfTab, rich: true, monospace: false)
        tabView.addTabViewItem(rtfItem)

        let htmlItem = NSTabViewItem(identifier: nil)
        htmlItem.label = L10n.editorTabHTML
        htmlItem.view = makeEditorScroll(htmlTab, rich: false, monospace: true)
        tabView.addTabViewItem(htmlItem)

        // 初始内容:文本/HTML 直接字符串;RTF 渲染富文本(无数据页签留空)
        textTab.string = payload?.text ?? ""
        htmlTab.string = payload?.htmlData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if let rtfData = payload?.rtfData,
           let attr = try? NSAttributedString(data: rtfData,
                                              options: [.documentType: NSAttributedString.DocumentType.rtf],
                                              documentAttributes: nil) {
            rtfTab.textStorage?.setAttributedString(attr)
        }

        container.addArrangedSubview(tabView)
        tabView.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        tabView.heightAnchor.constraint(equalToConstant: 220).isActive = true

        // 附加格式只读列表(删除能力在属性窗口,这里仅展示)
        let extrasHeader = NSTextField(labelWithString: L10n.editorExtrasHeader)
        extrasHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        extrasHeader.textColor = .secondaryLabelColor
        container.addArrangedSubview(extrasHeader)
        let extras = NSStackView()
        extras.orientation = .vertical
        extras.alignment = .leading
        extras.spacing = 3
        let extraFormats = payload?.extraFormats ?? []
        if extraFormats.isEmpty {
            let empty = NSTextField(labelWithString: L10n.editorNoExtras)
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            extras.addArrangedSubview(empty)
        } else {
            for format in extraFormats {
                let line = NSTextField(labelWithString: "\(format.type) · \(Fmt.bytes(format.data.count))")
                line.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                extras.addArrangedSubview(line)
            }
        }
        container.addArrangedSubview(extras)
        extrasStack = extras

        // 按钮行:保存 / 保存并放回剪贴板 / 关闭
        let save = NSButton(title: L10n.editorSave, target: self, action: #selector(saveAction))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        saveButton = save
        let putBack = NSButton(title: L10n.editorSaveAndPutBack, target: self, action: #selector(saveAndPutBackAction))
        putBack.bezelStyle = .rounded
        let close = NSButton(title: L10n.editorClose, target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [save, putBack, close])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        container.addArrangedSubview(buttons)

        window?.contentView = container
        container.widthAnchor.constraint(equalTo: (window?.contentView!.widthAnchor)!).isActive = true
    }

    /// 可编辑文本视图(带滚动)
    private func makeEditorScroll(_ textView: NSTextView, rich: Bool, monospace: Bool) -> NSScrollView {
        textView.isEditable = true
        textView.isRichText = rich
        textView.allowsUndo = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.font = monospace
            ? (NSFont.userFixedPitchFont(ofSize: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular))
            : .systemFont(ofSize: 12)
        if rich {
            textView.usesFontPanel = true
            textView.allowsImageEditing = false
        }
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    // MARK: - 保存

    /// 各页签 → 更新参数。nil = 该列不动(原无内容且未输入 → 不创建该格式);
    /// 空 Data/空串 = 清空该列(原有内容被清空)
    private func contentArguments() -> (text: String?, rtf: Data?, html: Data?) {
        let rtfData = rtfDataFromTab()
        let htmlSource = htmlTab.string
        let htmlData = htmlSource.isEmpty ? nil : Data(htmlSource.utf8)
        let textArg = textTab.string.isEmpty ? (hadText ? "" : nil) : textTab.string
        return (text: textArg,
                rtf: rtfData ?? (hadRTF ? Data() : nil),          // 页签空但有旧值 → 清列;原本就无 → 不动
                html: htmlData ?? (hadHTML ? Data() : nil))
    }

    /// RTF 页签当前内容;空页签返回 nil(是否清列由 hadRTF 决定)
    private func rtfDataFromTab() -> Data? {
        guard let storage = rtfTab.textStorage, storage.length > 0 else { return nil }
        return try? storage.data(from: NSRange(location: 0, length: storage.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    /// 新建模式:由页签内容组装 RawClip(全部为空 → nil,提示输入)
    private func rawForNewClip() -> RawClip? {
        let text = textTab.string
        let rtf = rtfDataFromTab()
        let htmlSource = htmlTab.string
        let html = htmlSource.isEmpty ? nil : Data(htmlSource.utf8)
        let raw = RawClip(text: text.isEmpty ? nil : text, rtfData: rtf, htmlData: html)
        return raw.isEmpty ? nil : raw
    }

    @objc private func saveAction() {
        performSave(putBack: false)
    }

    @objc private func saveAndPutBackAction() {
        performSave(putBack: true)
    }

    private func performSave(putBack: Bool) {
        let savedID: Int64
        if let id = clipID {
            let args = contentArguments()
            guard store.updateClipContent(id: id, text: args.text, rtfData: args.rtf, htmlData: args.html) else {
                showAlert(L10n.editorSaveFailed)
                return
            }
            savedID = id
        } else {
            guard let raw = rawForNewClip(),
                  let item = store.insert(raw, maxDataBytes: AppDelegate.maxDataBytesSetting(),
                                          parentID: parentID) else {
                showAlert(L10n.editorNewClipEmpty)
                return
            }
            clipID = item.id
            savedID = item.id
            window?.title = L10n.editorTitleEdit
        }

        // 保存成功:刷新编辑器状态(体积/哈希/类型已重算)+ 通知面板刷新列表
        reloadFromStore(id: savedID)
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)

        if putBack, let payload = store.payload(id: savedID) {
            // PasteBack.write 内部按实测 changeCount 区间上报 monitor,自写豁免天然成立
            _ = PasteBack.write(payload, monitor: ClipboardMonitor.shared)
        }
    }

    /// 保存后按库内最新状态重建页签(清空的列消失、had* 标志更新)
    private func reloadFromStore(id: Int64) {
        let payload = store.payload(id: id)
        hadRTF = payload?.rtfData != nil
        hadHTML = payload?.htmlData != nil
        hadText = payload?.text?.isEmpty == false
        textTab.string = payload?.text ?? ""
        htmlTab.string = payload?.htmlData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if let rtfData = payload?.rtfData,
           let attr = try? NSAttributedString(data: rtfData,
                                              options: [.documentType: NSAttributedString.DocumentType.rtf],
                                              documentAttributes: nil) {
            rtfTab.textStorage?.setAttributedString(attr)
        } else {
            rtfTab.textStorage?.setAttributedString(NSAttributedString())
        }
        saveButton?.isEnabled = true
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: L10n.dlgOk)
        alert.runModal()
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }
}
