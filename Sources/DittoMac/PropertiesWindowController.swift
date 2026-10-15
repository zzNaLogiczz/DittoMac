import AppKit
import DittoMacKit

/// 条目属性窗口(原版 Properties 对话框的 macOS 等价):
/// 元数据行 + 按类型渲染全文/图片/文件/富文本,支持复制全文
final class PropertiesWindowController: NSWindowController, NSWindowDelegate {

    /// 写剪贴板前通知监控豁免(由调用方注入)
    var noteSelfWrite: (() -> Void)?
    /// windowWillClose 回调
    var onClose: (() -> Void)?

    /// "打开中"强持有表(窗口关闭即释放,不泄漏;按条目 id 去重前置)
    private static var live: [Int64: PropertiesWindowController] = [:]
    private var itemID: Int64?

    convenience init(item: ClipItem, payload: RawClip?) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L10n.propsTitle
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self          // 确保 windowWillClose 被回调以清理静态表
        buildContent(item: item, payload: payload)
    }

    func windowWillClose(_ notification: Notification) {
        if let id = itemID {
            Self.live.removeValue(forKey: id)
        }
        onClose?()
    }

    // MARK: - 构建

    private func buildContent(item: ClipItem, payload: RawClip?) {
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

        // 按钮行
        let copyButton = NSButton(title: L10n.propsCopyFull, target: self, action: #selector(copyFullText))
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "c"
        copyButton.keyEquivalentModifierMask = .command
        let closeButton = NSButton(title: L10n.propsClose, target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [copyButton, closeButton])
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
