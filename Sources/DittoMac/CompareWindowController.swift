import AppKit
import DittoMacKit

/// 对比条目窗口(原版 Compare,2.7.14):两条目并排等宽文本 + 行级 LCS 差异
/// (删除行红底、新增行绿底)
final class CompareWindowController: NSWindowController, NSWindowDelegate {

    /// "打开中"强持有表(关闭即释放;键 = 小id:大id,同对条目重复打开=聚焦)
    private static var live: [String: CompareWindowController] = [:]
    private let liveKey: String

    init(left: ClipItem, right: ClipItem, store: ClipStoring) {
        liveKey = "\(min(left.id, right.id)):\(max(left.id, right.id))"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L10n.compareTitle
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent(left: left, right: right, store: store)
        Self.live[liveKey] = self
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    func windowWillClose(_ notification: Notification) {
        Self.live.removeValue(forKey: liveKey)
    }

    static func focusOrCreate(left: ClipItem, right: ClipItem, store: ClipStoring) -> CompareWindowController {
        let key = "\(min(left.id, right.id)):\(max(left.id, right.id))"
        if let existing = live[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        return CompareWindowController(left: left, right: right, store: store)
    }

    // MARK: - 构建

    /// 条目的对比文本:全文优先;非文本条目(图片等)退回标题/描述
    private func compareText(of item: ClipItem, store: ClipStoring) -> String {
        if let full = store.payload(id: item.id)?.text, !full.isEmpty {
            return full
        }
        if let desc = item.text, !desc.isEmpty { return desc }
        return L10n.compareNoText
    }

    private func buildContent(left: ClipItem, right: ClipItem, store: ClipStoring) {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8
        container.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        // 并排:左/右标题 + 等宽全文
        let leftTitle = NSTextField(labelWithString: L10n.compareLeft + " · " + displayTitle(left))
        leftTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        leftTitle.lineBreakMode = .byTruncatingTail
        let rightTitle = NSTextField(labelWithString: L10n.compareRight + " · " + displayTitle(right))
        rightTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        rightTitle.lineBreakMode = .byTruncatingTail
        let titles = NSStackView(views: [leftTitle, rightTitle])
        titles.orientation = .horizontal
        titles.distribution = .fillEqually
        titles.spacing = 10
        container.addArrangedSubview(titles)
        titles.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        let leftText = compareText(of: left, store: store)
        let rightText = compareText(of: right, store: store)
        let texts = NSStackView(views: [makeMonoScroll(leftText), makeMonoScroll(rightText)])
        texts.orientation = .horizontal
        texts.distribution = .fillEqually
        texts.spacing = 10
        container.addArrangedSubview(texts)
        texts.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        texts.heightAnchor.constraint(equalToConstant: 180).isActive = true

        // 行级差异(红 = 删除,绿 = 新增)
        let diffHeader = NSTextField(labelWithString: L10n.compareDiffHeader)
        diffHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        diffHeader.textColor = .secondaryLabelColor
        container.addArrangedSubview(diffHeader)
        let diffScroll = makeDiffScroll(old: leftText, new: rightText)
        container.addArrangedSubview(diffScroll)
        diffScroll.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        diffScroll.heightAnchor.constraint(equalToConstant: 220).isActive = true

        window?.contentView = container
        container.widthAnchor.constraint(equalTo: (window?.contentView!.widthAnchor)!).isActive = true
    }

    private func displayTitle(_ item: ClipItem) -> String {
        let base = item.title ?? item.text ?? ""
        let first = base.split(separator: "\n").first.map(String.init) ?? ""
        return String(first.prefix(40))
    }

    private func makeMonoScroll(_ text: String) -> NSScrollView {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = NSFont.userFixedPitchFont(ofSize: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.string = text
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    /// 差异视图:TextDiff.lines 输出 → 带行背景色的等宽文本
    private func makeDiffScroll(old: String, new: String) -> NSScrollView {
        let mono = NSFont.userFixedPitchFont(ofSize: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        let result = NSMutableAttributedString()
        let removedBG = NSColor.systemRed.withAlphaComponent(0.22)
        let addedBG = NSColor.systemGreen.withAlphaComponent(0.22)
        for line in TextDiff.lines(old: old, new: new) {
            let (prefix, bg): (String, NSColor?) = {
                switch line.kind {
                case .same: return ("  ", nil)
                case .removed: return ("- ", removedBG)
                case .added: return ("+ ", addedBG)
                }
            }()
            var attrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor.labelColor]
            if let bg { attrs[.backgroundColor] = bg }
            result.append(NSAttributedString(string: prefix + line.text + "\n", attributes: attrs))
        }
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 220))
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textStorage?.setAttributedString(result)
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }
}
