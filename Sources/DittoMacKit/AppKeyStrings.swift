import Foundation

/// 一条"每应用按键串"(上游 Custom Key Strokes / PasteStrings 注册表):
/// Options.cpp:1972 GetPasteString 按应用名查注册表,空 → 默认粘贴串
/// (默认串这里即系统 ⌘V/⌘C/⌘X,见 PasteBack.triggerKey)。
/// appPattern 为 ';'-分隔的应用名/Bundle ID 通配模式 —— 与捕获过滤
/// (CaptureFilter)同一套通配匹配器,大小写不敏感,支持 * 与 ?
public struct AppKeyStringEntry: Codable, Equatable, Sendable {
    public var appPattern: String
    public var pasteString: String
    public var copyString: String
    public var cutString: String

    public init(appPattern: String = "",
                pasteString: String = "",
                copyString: String = "",
                cutString: String = "") {
        self.appPattern = appPattern
        self.pasteString = pasteString
        self.copyString = copyString
        self.cutString = cutString
    }
}

/// 每应用按键串的存取与解析(JSON 数组持久化在 UserDefaults)
public enum AppKeyStrings {

    public static let storageKey = "ditto.appKeyStrings"
    /// 条目上限(注册表类配置,防误配无限增长;上游注册表同样是有限命名空间)
    public static let maxEntries = 20

    // MARK: - 存取(解析失败安全退化为空,与排除规则同口径)

    public static func load(defaults: UserDefaults = .standard) -> [AppKeyStringEntry] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([AppKeyStringEntry].self, from: data)) ?? []
    }

    public static func save(_ entries: [AppKeyStringEntry], defaults: UserDefaults = .standard) {
        let trimmed = Array(entries.prefix(maxEntries))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        defaults.set(data, forKey: storageKey)
    }

    // MARK: - 解析(纯函数)

    /// 前台应用对应的自定义串;无命中、或命中的条目该串为空 → nil(调用方用系统默认)。
    /// 匹配:条目的任一模式(通配、大小写不敏感)命中 localizedName 或 bundleID;
    /// 命中但该串为空 → 继续看下一条(上游语义:空串回落默认粘贴串)
    public static func matchedString(kind: PasteBack.ClipboardKeyKind,
                                     appName: String?,
                                     bundleID: String?,
                                     entries: [AppKeyStringEntry]) -> String? {
        let name = appName ?? ""
        let bundle = bundleID ?? ""
        for entry in entries {
            let patterns = CaptureFilter.patterns(from: entry.appPattern)
            guard !patterns.isEmpty,
                  patterns.contains(where: {
                      CaptureFilter.wildcardMatch($0, name) || CaptureFilter.wildcardMatch($0, bundle)
                  })
            else { continue }
            let value: String
            switch kind {
            case .paste: value = entry.pasteString
            case .copy: value = entry.copyString
            case .cut: value = entry.cutString
            }
            if !value.isEmpty { return value }
        }
        return nil
    }
}
