import AppKit
import DittoMacKit

/// 统计窗口(原版 Options → Statistics 页的独立小窗等价,OptionsStats.cpp:81-98):
/// 累计复制 / 累计粘贴 / 统计起点(已 D.H.M)。设置「统计…」按钮与托盘
/// 帮助→统计… 都打开这里。每次打开现读计数(不用常驻观察,数字量级低)。
final class StatsWindowController: NSWindowController, NSWindowDelegate {

    /// 关闭即释放(持有方清引用)
    var onClose: (() -> Void)?

    private let stats: UsageStats

    init(stats: UsageStats = .shared) {
        self.stats = stats
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = L10n.statsWindowTitle
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
        ])

        // 起点 set-once(首次打开统计时即钉住)
        let since = stats.since()
        func addRow(_ label: String, _ value: String) {
            let row = NSStackView(views: [
                NSTextField(labelWithString: label),
                NSTextField(labelWithString: value),
            ])
            row.orientation = .horizontal
            row.spacing = 8
            stack.addArrangedSubview(row)
        }
        // 上游口径:D.H.M = 总天数.小时分量(0-23).分钟分量(0-59)
        addRow(L10n.statsTotalCopies, "\(stats.copyCount)")
        addRow(L10n.statsTotalPastes, "\(stats.pasteCount)")
        addRow(L10n.statsSince,
               "\(UsageStats.sinceDateString(since)) (\(L10n.statsSpanPrefix)\(UsageStats.spanString(from: since, to: Date()))\(L10n.statsSpanSuffix))")

        let hint = NSTextField(wrappingLabelWithString: L10n.statsHint)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.center()
    }
}
