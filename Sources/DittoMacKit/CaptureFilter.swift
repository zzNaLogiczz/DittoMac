import Foundation

// MARK: - 捕获排除规则(原版 RegExFilterHelper + ClipboardViewer 应用包含/排除列表)

/// 一条正则排除规则(原版 CRegExFilterData):
/// regex 命中复制的文本(整串匹配)→ 该条不入库;
/// processName 为 ';'-separated 的进程名通配模式,空或 "*" = 对所有进程生效
public struct ExcludeRule: Codable, Equatable, Sendable {
    public var regex: String
    public var processName: String

    public init(regex: String, processName: String) {
        self.regex = regex
        self.processName = processName
    }
}

/// 纯函数判定一条剪贴内容是否应被排除(原版 ValidActiveWnd + TextMatchFilters 的语义合并):
///
/// 1. 应用包含列表(非空时是白名单):无任何模式命中来源应用 → 排除
///    (原版:include 列表配了却没命中 → NOT SAVING COPY;列表留空 = 不限制)
/// 2. 应用排除列表:任一模式命中来源应用 → 排除
/// 3. 正则规则(最多 15 条,按序):规则进程过滤命中时,regex 整串匹配文本 → 排除
public enum CaptureFilter {

    /// 原版 MAX_REGEX_FILTERS = 15:规则槽位固定,超出部分不生效
    public static let maxRules = 15

    /// ';'-separated 列表的分隔符(原版 CopyAppSeparator 默认 ";")
    private static let separator: Character = ";"

    /// 判定是否丢弃。text 为空(nil/"")时不跑正则(原版空描述直接跳过 TextMatchFilters);
    /// appName 为空(nil/"")时进程过滤视为命中(原版 MatchesProcessFilters 对 "" 返回 true)
    public static func shouldExclude(text: String?,
                                     appName: String?,
                                     rules: [ExcludeRule],
                                     appInclude: String,
                                     appExclude: String) -> Bool {
        let app = appName ?? ""

        // 1) 应用包含列表:非空(有非空白模式)时必须命中其一
        let includePatterns = patterns(from: appInclude)
        if !includePatterns.isEmpty && !includePatterns.contains(where: { wildcardMatch($0, app) }) {
            return true
        }

        // 2) 应用排除列表:任一命中即排除(优先级高于包含)
        if patterns(from: appExclude).contains(where: { wildcardMatch($0, app) }) {
            return true
        }

        // 3) 正则规则:最多前 15 条生效(原版固定数组)
        let body = text ?? ""
        guard !body.isEmpty else { return false }
        for rule in rules.prefix(maxRules) {
            guard matchesProcessFilter(rule.processName, app) else { continue }
            if fullRegexMatch(rule.regex, body) {
                return true
            }
        }
        return false
    }

    // MARK: - 进程过滤(原版 MatchesProcessFilters)

    /// 空模式列表 = 所有进程;appName 为空串 = 直接命中;
    /// 模式支持 '*'/'?' 通配,大小写不敏感(原版两侧统一 MakeLower 后比较)
    static func matchesProcessFilter(_ processName: String, _ appName: String) -> Bool {
        if appName.isEmpty { return true }
        let list = patterns(from: processName)
        if list.isEmpty { return true }
        return list.contains(where: { wildcardMatch($0, appName) })
    }

    // MARK: - 正则(原版 MatchesRegEx:std::regex_match = 整串匹配)

    /// 整串匹配:"test" 不得命中 "this is a test",".*test.*" 才行;
    /// 空模式永不命中(原版 m_regEx == "" 直接返回 false);
    /// 非法模式忽略该条,不崩溃(原版捕获 regex_error 仅记日志)
    static func fullRegexMatch(_ pattern: String, _ text: String) -> Bool {
        guard !pattern.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        // rangeOfFirstMatch 覆盖整串 = regex_match;否则视为不命中
        guard let match = regex.firstMatch(in: text, range: range) else { return false }
        return match.range.location == 0 && match.range.length == range.length
    }

    // MARK: - 通配与分词

    /// ';' 分词,跳过空/空白片段(原版 CTokenizer + line != "" 判空)
    static func patterns(from list: String) -> [String] {
        list.split(separator: separator, omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 大小写不敏感的通配匹配,支持 '*'(任意串,含空)与 '?'(单字符)。
    /// 双指针回溯实现:无递归、无指数回溯,'*' 密集模式也线性过
    static func wildcardMatch(_ pattern: String, _ value: String) -> Bool {
        let p = Array(pattern.lowercased())
        let v = Array(value.lowercased())
        var si = 0, pi = 0
        var starIdx = -1, matchIdx = 0   // 最近一个 '*' 的位置与其匹配到的 value 下标
        while si < v.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == v[si]) {
                si += 1
                pi += 1
            } else if pi < p.count && p[pi] == "*" {
                starIdx = pi
                matchIdx = si
                pi += 1                  // 先假设 '*' 匹配空串
            } else if starIdx != -1 {
                pi = starIdx + 1         // 失配:回溯到最近 '*' 之后,'*' 多吞一个字符
                matchIdx += 1
                si = matchIdx
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
