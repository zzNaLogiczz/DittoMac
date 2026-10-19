import Foundation

/// 纯 Swift 行级差异(对比条目窗口用):经典 LCS 动态规划求最长公共子序列,
/// 回溯标注 added/removed/same,输出保持两侧行的原始相对顺序
public enum TextDiff {

    /// 单行差异类型
    public enum LineKind: Equatable, Sendable {
        case same
        case added      // 仅新串有(旧串删除了内容 → 红色)
        case removed    // 仅旧串有(新串增加了内容 → 绿色)
    }

    public struct LineDiff: Equatable, Sendable {
        public var kind: LineKind
        public var text: String
        public init(kind: LineKind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// 按行拆分(保留空行;结尾无换行不产生多余空行)
    private static func splitLines(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        return s.components(separatedBy: "\n")
    }

    /// 行级 diff:old → new 的最小编辑标注。
    /// 行数较大时 LCS 表为 O(n·m);对比窗口输入为剪贴板文本,量级可控,
    /// 超大输入(>5000 行)直接退化为"全删 + 全加"避免卡顿
    public static func lines(old: String, new: String) -> [LineDiff] {
        let a = splitLines(old)
        let b = splitLines(new)
        guard !(a.isEmpty && b.isEmpty) else { return [] }

        // 防御:超大输入退化为整块替换(不占 O(n·m) 内存)
        if a.count > 5000 || b.count > 5000 {
            return a.map { LineDiff(kind: .removed, text: $0) }
                + b.map { LineDiff(kind: .added, text: $0) }
        }

        // LCS 长度表:lcs[i][j] = a[i...] 与 b[j...] 的最长公共子序列长度
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1),
                          count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                if a[i] == b[j] {
                    lcs[i][j] = lcs[i + 1][j + 1] + 1
                } else {
                    lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        // 回溯:相同行标 same;先走旧串独有行(removed)再走新串独有行(added),
        // 与常见 unified diff 的呈现一致(删除块在增加块之前)
        var result: [LineDiff] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                result.append(LineDiff(kind: .same, text: a[i]))
                i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                result.append(LineDiff(kind: .removed, text: a[i]))
                i += 1
            } else {
                result.append(LineDiff(kind: .added, text: b[j]))
                j += 1
            }
        }
        while i < a.count {
            result.append(LineDiff(kind: .removed, text: a[i])); i += 1
        }
        while j < b.count {
            result.append(LineDiff(kind: .added, text: b[j])); j += 1
        }
        return result
    }
}
