import Foundation

// MARK: - 主题文件(上游 Theme.cpp:136-203 的 <Ditto_Theme_File> XML 格式)
//
// 上游用 TinyXML 逐标签 LoadColor/LoadInt(缺省字段保持默认,坏值只记日志),
// 此处等价实现:未知标签忽略、非法值跳过;颜色以 0-255 三元组保存
//(AppKit 无关的纯值,便于单测)。

/// 主题颜色三元组(上游 RGB(r,g,b))
public struct ThemeRGB: Equatable, Sendable {
    public var red: Int
    public var green: Int
    public var blue: Int

    public init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// "RGB(r, g, b)"(大小写不敏感,逗号前后允许空格)→ 三元组;非法返回 nil
    public static func parse(_ raw: String) -> ThemeRGB? {
        let pattern = "^RGB\\s*\\(\\s*(\\d{1,3})\\s*,\\s*(\\d{1,3})\\s*,\\s*(\\d{1,3})\\s*\\)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              m.numberOfRanges == 4,
              let r = Int(raw.substring(with: m.range(at: 1))),
              let g = Int(raw.substring(with: m.range(at: 2))),
              let b = Int(raw.substring(with: m.range(at: 3))),
              (0...255).contains(r), (0...255).contains(g), (0...255).contains(b)
        else { return nil }
        return ThemeRGB(red: r, green: g, blue: b)
    }
}

private extension String {
    /// NSRange → String 切片(仅解析内部用)
    func substring(with nsRange: NSRange) -> Substring {
        let start = index(startIndex, offsetBy: nsRange.location)
        let end = index(start, offsetBy: nsRange.length)
        return self[start..<end]
    }
}

/// 解析后的主题(全部字段可选:未出现的字段 = nil,应用时跳过 = 保持当前值;
/// 上游语义:LoadDefaults 先行,主题字段按需覆盖)
public struct DittoThemeFile: Equatable, Sendable {
    // 标题栏(上游 Caption 渐变两端 + 置顶/断开变体 + 文字色)
    public var captionLeft: ThemeRGB?
    public var captionRight: ThemeRGB?
    public var captionLeftTopMost: ThemeRGB?
    public var captionRightTopMost: ThemeRGB?
    public var captionLeftNotConnected: ThemeRGB?
    public var captionRightNotConnected: ThemeRGB?
    public var captionTextColor: ThemeRGB?
    // 列表(奇/偶行底色与文字、选中态 + 无焦点选中态;上游 ListBoxOddRows* 等)
    public var listBoxOddRowsBG: ThemeRGB?
    public var listBoxEvenRowsBG: ThemeRGB?
    public var listBoxOddRowsText: ThemeRGB?
    public var listBoxEvenRowsText: ThemeRGB?
    public var listBoxSelectedBG: ThemeRGB?
    public var listBoxSelectedNoFocusBG: ThemeRGB?
    public var listBoxSelectedText: ThemeRGB?
    public var listBoxSelectedNoFocusText: ThemeRGB?
    // 窗体(主窗口底色、边框三变体;上游 MainWindowBG / Border*)
    public var mainWindowBG: ThemeRGB?
    public var border: ThemeRGB?
    public var borderTopMost: ThemeRGB?
    public var borderNotConnected: ThemeRGB?
    // 组树(上游 GroupTree*)
    public var groupTreeBG: ThemeRGB?
    public var groupTreeText: ThemeRGB?
    // 描述浮窗(上游 DescriptionWindow*)
    public var descriptionWindowBG: ThemeRGB?
    public var descriptionWindowText: ThemeRGB?
    // 整数字段(标题栏厚度 / 标题字号)
    public var captionSize: Int?
    public var captionFontSize: Int?
    // 根元素属性(信息性)
    public var version: Int?
    public var author: String?
    public var notes: String?

    public init() {}

    /// 解析主题文本(容错:未知标签忽略、非法值跳过;根节点缺失仍尽力解析标签)
    public static func parse(_ text: String) -> DittoThemeFile {
        var theme = DittoThemeFile()

        // 根元素属性:<Ditto_Theme_File Version = "3" Author = ".." Notes = "..">
        if let header = firstMatch(#"<\s*Ditto_Theme_File([^>]*)>"#, in: text) {
            theme.version = attribute("Version", in: header).flatMap(Int.init)
            theme.author = attribute("Author", in: header)
            theme.notes = attribute("Notes", in: header)
        }

        // 全部 <Tag>value</Tag> 对(同名标签取首个,与上游FirstChildElement语义一致)
        let pairPattern = #"(?s)<\s*([A-Za-z_][A-Za-z0-9_]*)\s*>\s*([^<]*?)\s*<\s*/\s*\1\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pairPattern) else { return theme }
        let nsText = text as NSString
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { m, _, _ in
            guard let m, m.numberOfRanges == 3 else { return }
            let tag = nsText.substring(with: m.range(at: 1))
            let value = nsText.substring(with: m.range(at: 2))
            theme.assign(tag: tag, value: value)
        }
        return theme
    }

    /// 从文件读取并解析(读失败返回 nil;空内容按标签为空处理)
    public static func parse(contentsOf url: URL) -> DittoThemeFile? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            return nil
        }
        return parse(text)
    }

    /// 标签 → 字段(颜色走 RGB() 解析;整数字段直接 Int();未知标签忽略;
    /// 已赋值字段不被同名后续标签覆盖 —— 取首个,与上游单次读取一致)
    private mutating func assign(tag: String, value: String) {
        func color(_ current: ThemeRGB?) -> ThemeRGB? {
            current ?? ThemeRGB.parse(value)
        }
        func integer(_ current: Int?) -> Int? {
            current ?? Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        switch tag {
        case "CaptionLeft": captionLeft = color(captionLeft)
        case "CaptionRight": captionRight = color(captionRight)
        case "CaptionLeftTopMost": captionLeftTopMost = color(captionLeftTopMost)
        case "CaptionRightTopMost": captionRightTopMost = color(captionRightTopMost)
        case "CaptionLeftNotConnected": captionLeftNotConnected = color(captionLeftNotConnected)
        case "CaptionRightNotConnected": captionRightNotConnected = color(captionRightNotConnected)
        case "CaptionTextColor": captionTextColor = color(captionTextColor)
        case "ListBoxOddRowsBG": listBoxOddRowsBG = color(listBoxOddRowsBG)
        case "ListBoxEvenRowsBG": listBoxEvenRowsBG = color(listBoxEvenRowsBG)
        case "ListBoxOddRowsText": listBoxOddRowsText = color(listBoxOddRowsText)
        case "ListBoxEvenRowsText": listBoxEvenRowsText = color(listBoxEvenRowsText)
        case "ListBoxSelectedBG": listBoxSelectedBG = color(listBoxSelectedBG)
        case "ListBoxSelectedNoFocusBG": listBoxSelectedNoFocusBG = color(listBoxSelectedNoFocusBG)
        case "ListBoxSelectedText": listBoxSelectedText = color(listBoxSelectedText)
        case "ListBoxSelectedNoFocusText": listBoxSelectedNoFocusText = color(listBoxSelectedNoFocusText)
        case "MainWindowBG": mainWindowBG = color(mainWindowBG)
        case "Border": border = color(border)
        case "BorderTopMost": borderTopMost = color(borderTopMost)
        case "BorderNotConnected": borderNotConnected = color(borderNotConnected)
        case "GroupTreeBG": groupTreeBG = color(groupTreeBG)
        case "GroupTreeText": groupTreeText = color(groupTreeText)
        case "DescriptionWindowBG": descriptionWindowBG = color(descriptionWindowBG)
        case "DescriptionWindowText": descriptionWindowText = color(descriptionWindowText)
        case "CaptionSize": captionSize = integer(captionSize)
        case "CaptionFontSize": captionFontSize = integer(captionFontSize)
        default: break   // 未知标签(如 SearchTextBoxFocus*/ScrollBar*/ClipPastedColor)忽略
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges >= 2 else { return nil }
        let nsText = text as NSString
        return nsText.substring(with: m.range(at: 1))
    }

    private static func attribute(_ name: String, in tagBody: String) -> String? {
        let pattern = #"(?i)\b"#
            + NSRegularExpression.escapedPattern(for: name)
            + #"\s*=\s*("([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: tagBody, range: NSRange(tagBody.startIndex..., in: tagBody)) else {
            return nil
        }
        let nsBody = tagBody as NSString
        let quoted = nsBody.substring(with: m.range(at: 1))
        return String(quoted.dropFirst().dropLast())
    }
}

// MARK: - 主题注册表(内置主题 + 用户导入主题)
//
// 持久化口径(`ditto.themeFile`):
// - "" = 跟随系统(默认)
// - "builtin:<名称>" = 内置主题(随包分发;构建后 bundle 路径会变,存名字而非路径)
// - 其余 = 导入主题的绝对路径(拷入 ~/Library/Application Support/DittoMac/Themes)

public enum ThemeRegistry {

    /// 内置主题在存储值中的前缀
    public static let builtinPrefix = "builtin:"

    /// 用户主题目录(确保存在)。便携模式(上游 GetIsPortableDitto)落
    /// <便携根>/DittoMac/Themes,常规落 ~/Library/Application Support/DittoMac/Themes
    public static func userThemesDirectory() -> URL {
        let dir = PortableMode.currentBaseDirectory
            .appendingPathComponent("Themes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 内置主题目录(SPM 资源包;直连源码编译(测试)无 Bundle.module → 回退源码树)
    public static func bundledThemesDirectory() -> URL? {
        #if DITTO_NO_SPM_RESOURCES
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources/Themes", isDirectory: true)
        #else
        return Bundle.module.resourceURL?.appendingPathComponent("Themes", isDirectory: true)
        #endif
    }

    /// 内置主题名(文件名去扩展,按文件名排序稳定输出)
    public static func bundledThemeNames() -> [String] {
        guard let dir = bundledThemesDirectory(),
              let items = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.pathExtension.lowercased() == "xml" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// 用户导入的主题(文件名去扩展)
    public static func userThemeNames() -> [String] {
        let dir = userThemesDirectory()
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.pathExtension.lowercased() == "xml" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// 内置主题 URL(名字精确匹配,防路径穿越:仅允许安全字符)
    public static func bundledThemeURL(name: String) -> URL? {
        guard !name.isEmpty, name.allSatisfy({ !$0.isNewline && $0 != "/" && $0 != ":" && $0 != "\\" }) else {
            return nil
        }
        return bundledThemesDirectory()?.appendingPathComponent("\(name).xml")
    }

    /// 用户主题 URL
    public static func userThemeURL(name: String) -> URL? {
        guard !name.isEmpty, name.allSatisfy({ !$0.isNewline && $0 != "/" && $0 != ":" && $0 != "\\" }) else {
            return nil
        }
        return userThemesDirectory().appendingPathComponent("\(name).xml")
    }

    /// 按持久化值加载主题;"" / 无法解析 → nil(nil = 跟随系统)
    public static func load(storedValue: String) -> DittoThemeFile? {
        guard !storedValue.isEmpty else { return nil }
        if storedValue.hasPrefix(builtinPrefix) {
            let name = String(storedValue.dropFirst(builtinPrefix.count))
            guard let url = bundledThemeURL(name: name) else { return nil }
            return DittoThemeFile.parse(contentsOf: url)
        }
        return DittoThemeFile.parse(contentsOf: URL(fileURLWithPath: storedValue))
    }

    /// 导入主题文件:拷贝到用户主题目录(重名加序号),返回目标路径
    public static func importTheme(from source: URL) -> URL? {
        let dir = userThemesDirectory()
        let baseName = source.deletingPathExtension().lastPathComponent
        var name = baseName
        var dest = dir.appendingPathComponent("\(name).xml")
        var duplicateIndex = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            name = "\(baseName)-\(duplicateIndex)"
            dest = dir.appendingPathComponent("\(name).xml")
            duplicateIndex += 1
        }
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            return dest
        } catch {
            return nil
        }
    }
}
