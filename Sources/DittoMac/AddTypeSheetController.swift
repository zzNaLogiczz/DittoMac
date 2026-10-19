import AppKit
import DittoMacKit

// MARK: - 添加格式 sheet(原版 Add Type 对话框)

/// 枚举当前系统剪贴板上存在的格式供勾选 + 手动输入 UTI;
/// OK 后把勾选+输入的条目回调给调用方(去重由调用方处理)
final class AddTypeSheetController: NSObject {

    /// 确认添加的 UTI 列表(勾选项 + 手动输入,允许 ";"/空白分隔多条)
    var onAdd: (([String]) -> Void)?
    /// sheet 结束(提交/取消)后回调,供调用方释放持有
    var onDismiss: (() -> Void)?

    private let sheet: NSWindow
    private let manualField = NSTextField()
    private var checkboxes: [NSButton] = []

    override init() {
        let vc = NSViewController()
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
                         styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = L10n.setTypesSheetTitle
        sheet.isReleasedWhenClosed = false
        super.init()
        buildContent(into: vc)
        sheet.contentViewController = vc
    }

    func begin(on parent: NSWindow) {
        parent.beginSheet(sheet) { [weak self] _ in self?.onDismiss?() }
    }

    // MARK: 内容构建

    private func buildContent(into vc: NSViewController) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: vc.view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -24),
            // 固定内容宽度:contentViewController 会按 fitting size 重定 sheet(与设置窗同套路)
            vc.view.widthAnchor.constraint(equalToConstant: 440),
        ])

        // 当前剪贴板上的类型并集(去掉 dyn.* 与 6 个已知 UTI)
        let known: Set<String> = [ClipUTI.text, ClipUTI.rtf, ClipUTI.html,
                                  ClipUTI.png, ClipUTI.tiff, ClipUTI.fileURL]
        var present = Set<String>()
        for item in NSPasteboard.general.pasteboardItems ?? [] {
            for type in item.types { present.insert(type.rawValue) }
        }
        let extras = present.filter { !$0.hasPrefix("dyn.") && !known.contains($0) }.sorted()

        let hint = NSTextField(wrappingLabelWithString: L10n.setTypesSheetHint)
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        addFull(hint, to: stack)

        if extras.isEmpty {
            let empty = NSTextField(labelWithString: L10n.setTypesNoExtraTypes)
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            addFull(empty, to: stack)
        } else {
            addFull(makeCheckList(extras), to: stack)
        }

        // 手动输入行
        let manualLabel = NSTextField(labelWithString: L10n.setTypesManualField)
        manualLabel.font = .systemFont(ofSize: 12)
        manualLabel.textColor = .secondaryLabelColor
        manualLabel.setContentHuggingPriority(.required, for: .horizontal)
        manualField.font = .systemFont(ofSize: 12)
        manualField.placeholderString = "com.apple.pict"
        manualField.cell?.truncatesLastVisibleLine = true
        manualField.cell?.wraps = false
        manualField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let manualRow = NSStackView(views: [manualLabel, manualField])
        manualRow.orientation = .horizontal
        manualRow.spacing = 8
        manualRow.alignment = .centerY
        stack.addArrangedSubview(manualRow)
        manualRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // 按钮:取消 / 好(默认键 回车,Esc 取消)
        let cancel = NSButton(title: L10n.dlgCancel, target: self, action: #selector(cancelSheet))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: L10n.t("添加", "Add"), target: self, action: #selector(confirmSheet))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, ok])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        addFull(buttons, to: stack)
    }

    private func makeCheckList(_ extras: [String]) -> NSView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 3
        box.translatesAutoresizingMaskIntoConstraints = false
        for uti in extras {
            let cb = NSButton(checkboxWithTitle: uti, target: nil, action: nil)
            cb.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            checkboxes.append(cb)
            box.addArrangedSubview(cb)
        }

        let scroll = NSScrollView()
        scroll.documentView = box
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // 高度随条数收缩,封顶 ~110(与设置页表格一致)
        let height = min(110, CGFloat(extras.count) * 20 + 10)
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        // 勾选列表宽度铺满滚动视图(先入层级再激活,避免无共同祖先崩溃)
        box.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor).isActive = true
        box.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
        box.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }

    /// 全宽元素(stack 宽度 = 视图宽度 320 - 2×16)
    private func addFull(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    // MARK: 动作

    @objc private func confirmSheet() {
        var picked = checkboxes.filter { $0.state == .on }.map(\.title)
        // 手动输入允许 ";"/空白分隔多条
        let manual = manualField.stringValue
            .split(whereSeparator: { $0 == ";" || $0 == "," || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        picked += manual.filter { !$0.isEmpty }
        let handler = onAdd
        sheet.parent?.endSheet(sheet, returnCode: .OK)
        handler?(picked)
    }

    @objc private func cancelSheet() {
        sheet.parent?.endSheet(sheet, returnCode: .cancel)
    }
}
