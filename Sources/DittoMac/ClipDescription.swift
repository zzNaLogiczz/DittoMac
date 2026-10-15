import AppKit

#if canImport(DittoMacKit)
import DittoMacKit
#endif

/// 列表条目描述与配套工具(对齐原版 MainTableFunctions / QListCtrl 的描述规则)
enum ClipDescription {

    /// 描述生成:tab→2 空格;剥除行首缩进且行首加 `» ` 标记;取首行;上限 500 字符
    static func build(text: String?) -> String {
        guard var text, !text.isEmpty else { return "" }
        // 剥除行首空格缩进并加 » 标记(原版 MainTableFunctions.cpp:99;tab 不算缩进,后面替换为 2 空格)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if let first = lines.first {
            let indent = first.prefix(while: { $0 == " " })
            if !indent.isEmpty {
                lines[0] = first.dropFirst(indent.count)
                text = "» " + lines.joined(separator: "\n")
            }
        }
        text = text.replacingOccurrences(of: "\t", with: "  ")
        var firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? text
        if firstLine.count > 500 {
            firstLine = String(firstLine.prefix(500)) + "…"
        }
        return firstLine
    }

    /// 颜色值识别(原版色块绘制):#RRGGBB / #RGB / rgb(r,g,b) / 255,0,0 / 常用色名。
    /// 匹配对象是"整个描述即颜色"或"描述以颜色值开头"。
    static func colorValue(in string: String) -> NSColor? {
        let s = string.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        // #RRGGBB / #RGB
        if s.hasPrefix("#") {
            let hex = String(s.dropFirst())
            if hex.count == 6, let v = UInt64(hex, radix: 16) {
                return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                               green: CGFloat((v >> 8) & 0xFF) / 255,
                               blue: CGFloat(v & 0xFF) / 255, alpha: 1)
            }
            if hex.count == 3, let v = UInt64(hex, radix: 16) {
                let r = CGFloat((v >> 8) & 0xF) / 15, g = CGFloat((v >> 4) & 0xF) / 15, b = CGFloat(v & 0xF) / 15
                return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            }
            return nil
        }

        // rgb(r,g,b)
        if s.lowercased().hasPrefix("rgb("), s.hasSuffix(")") {
            let inner = s.dropFirst(4).dropLast().split(separator: ",")
            if inner.count == 3,
               let r = Double(inner[0].trimmingCharacters(in: .whitespaces)),
               let g = Double(inner[1].trimmingCharacters(in: .whitespaces)),
               let b = Double(inner[2].trimmingCharacters(in: .whitespaces)) {
                return NSColor(srgbRed: min(max(r / 255, 0), 1), green: min(max(g / 255, 0), 1),
                               blue: min(max(b / 255, 0), 1), alpha: 1)
            }
            return nil
        }

        // 255,0,0 裸三段
        let parts = s.split(separator: ",")
        if parts.count == 3,
           let r = Double(parts[0].trimmingCharacters(in: .whitespaces)),
           let g = Double(parts[1].trimmingCharacters(in: .whitespaces)),
           let b = Double(parts[2].trimmingCharacters(in: .whitespaces)),
           r <= 255, g <= 255, b <= 255 {
            return NSColor(srgbRed: CGFloat(r / 255), green: CGFloat(g / 255),
                           blue: CGFloat(b / 255), alpha: 1)
        }

        // 常用色名(中英)
        let named: [String: NSColor] = [
            "red": .systemRed, "green": .systemGreen, "blue": .systemBlue,
            "orange": .systemOrange, "yellow": .systemYellow, "purple": .systemPurple,
            "pink": .systemPink, "black": .black, "white": .white, "gray": .systemGray,
            "红": .systemRed, "绿": .systemGreen, "蓝": .systemBlue, "黄": .systemYellow,
            "橙": .systemOrange, "紫": .systemPurple, "粉": .systemPink, "黑": .black,
            "白": .white, "灰": .systemGray, "红色": .systemRed, "绿色": .systemGreen,
            "蓝色": .systemBlue, "黄色": .systemYellow, "橙色": .systemOrange,
            "紫色": .systemPurple, "粉色": .systemPink, "黑色": .black, "白色": .white,
            "灰色": .systemGray, "金色": .systemYellow, "青色": .systemTeal, "cyan": .systemTeal,
        ]
        return named[s.lowercased()]
    }

    /// 搜索命中高亮:把 query 各词(空白分词)的所有(不区分大小写)命中范围着色
    static func highlight(_ attributed: NSMutableAttributedString, matchesOf query: String, color: NSColor) {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return }
        let plain = attributed.string
        for term in terms {
            guard !term.isEmpty else { continue }
            var searchStart = plain.startIndex
            while let range = plain.range(of: term, options: .caseInsensitive, range: searchStart..<plain.endIndex) {
                let ns = NSRange(range, in: plain)
                attributed.addAttribute(.foregroundColor, value: color, range: ns)
                searchStart = range.upperBound
            }
        }
    }

    /// 元数据行(原版 tooltip 格式):添加时间 | 上次使用 | 保护标记
    static func metaLine(item: ClipItem,
                         lastUsedAt: Date? = nil,
                         neverAutoDelete: Bool = false) -> String {
        let added = Self.metaDateFormatter.string(from: item.createdAt)
        let lastUsed = (lastUsedAt ?? item.lastPasteAt).map { "上次使用: " + Self.metaDateFormatter.string(from: $0) }
            ?? "上次使用: 从未粘贴"
        var parts = ["添加: " + added, lastUsed]
        if neverAutoDelete || item.noDelete { parts.append("永不自动删除") }
        if item.pinned { parts.append("置顶") }
        return parts.joined(separator: " | ")
    }

    private static let metaDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
