import AppKit
import DittoMacKit

/// 二维码查看窗口(原版 QRCodeViewer:码图 + 文本 + 「复制图片」)
///
/// 菜单「查看二维码 / View as QRCode」(原版 ID_MENU_VIEWASQRCODE,CP_Main.rc:553)
/// 打开:窗口内显示二维码图片、下方截断文本、「复制图片」按钮(PNG 写入系统
/// 剪贴板,带 monitor 豁免防止被自己录回历史)。文本超 2000 字符时菜单动作
/// 先弹「文本过长」提示而不开窗。
final class QRCodeWindowController: NSWindowController, NSWindowDelegate {

    /// "打开中"强持有表(关闭即释放;同文本重复打开 = 聚焦,键 = 文本哈希)
    private static var live: [String: QRCodeWindowController] = [:]
    private let liveKey: String

    private let text: String
    private var copiedFeedback: NSTextField!

    /// 同文本已开窗 = 聚焦;否则新建(键 = djb2 文本哈希)
    static func focusOrCreate(text: String) -> QRCodeWindowController {
        let key = liveKey(for: text)
        if let existing = live[key] {
            return existing
        }
        return QRCodeWindowController(text: text)
    }

    private static func liveKey(for text: String) -> String {
        String(format: "%016llx", text.utf8.reduce(UInt64(5381)) { ($0 << 5) &+ $0 &+ UInt64($1) })
    }

    init(text: String) {
        self.text = text
        liveKey = Self.liveKey(for: text)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = L10n.qrWindowTitle
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        Self.live[liveKey] = self
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    func windowWillClose(_ notification: Notification) {
        Self.live.removeValue(forKey: liveKey)
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16),
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
        ])

        // 码图(生成失败理论上不可达 —— 菜单入口已做过长度与空值门控)
        if let image = QRCodeExport.makeImage(for: text) {
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleNone
            stack.addArrangedSubview(imageView)
        }

        // 下方截断文本
        let label = NSTextField(wrappingLabelWithString: QRCodeExport.displayTruncation(of: text))
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.maximumNumberOfLines = 6
        stack.addArrangedSubview(label)

        // 「复制图片」:PNG 进剪贴板(monitor 豁免,不录回历史)
        let copyButton = NSButton(title: L10n.qrCopyImage, target: self, action: #selector(copyImage))
        copyButton.bezelStyle = .rounded
        stack.addArrangedSubview(copyButton)

        copiedFeedback = NSTextField(labelWithString: "")
        copiedFeedback.textColor = .systemGreen
        copiedFeedback.isHidden = true
        stack.addArrangedSubview(copiedFeedback)
    }

    /// 显示并置前(居中)
    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.center()
    }

    // MARK: - 动作

    @objc private func copyImage() {
        guard let png = QRCodeExport.makePNG(for: text) else { return }
        // 自写豁免先登记(noteExternalWrite 预占接下来的 changeCount 跳变区间),
        // 这条复制的图片不会被自己录回历史
        ClipboardMonitor.shared.noteExternalWrite()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        PerfLog.event("QR_IMAGE_COPIED", "bytes=\(png.count)")
        copiedFeedback.stringValue = L10n.qrCopied
        copiedFeedback.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copiedFeedback.isHidden = true
        }
    }
}
