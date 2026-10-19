import Foundation

// MARK: - 导出到 Google 翻译(原版 DoExportToGoogleTranslate,QPasteWnd.cpp:4551-4600)
//
// 上游:取条目 Unicode 文本 → InternetEncode 百分号编码 → 拼 TranslateUrl 模板
// (默认 https://translate.google.com/?text=%s,Options.cpp:2425)→ 打开默认浏览器。
// 此处等价实现并显式给 sl=auto / tl=<目标语言>;目标语言 = 当前界面语言
// (zh → zh-CN,en → en)。URL 过长会被浏览器/服务端截断,按任务口径 ~1200 字符封顶。

/// URL 构建:纯函数便于单测
public enum TranslateExport {

    /// 参与翻译的文本上限(超出截断并提示;~1200 字符 ≈ 上游线上服务可接受的查询长度)
    public static let maxTextLength = 1200

    /// 目标语言代码:L10n 当前语言 → Google 翻译 tl 参数
    /// (中文界面 → 翻成中文 zh-CN;英文界面 → en)
    public static func targetLanguage(isChinese: Bool) -> String {
        isChinese ? "zh-CN" : "en"
    }

    /// 截断预处理:超长文本截到 maxTextLength(truncated 标记供 UI 先弹提示)
    public static func prepare(_ text: String) -> (text: String, truncated: Bool) {
        guard text.count > maxTextLength else { return (text, false) }
        return (String(text.prefix(maxTextLength)), true)
    }

    /// 组装完整 URL(文本已截断)。空文本 → nil。
    /// queryAllowed 集合剔除 `&+=?` 等保留字 → 全部百分号编码,防注入查询参数
    public static func url(for text: String, target: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !target.isEmpty else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return "https://translate.google.com/?sl=auto&tl=\(target)&text=\(encoded)"
    }

    /// 一步到位:截断 + URL(展示层用 truncated 决定是否先弹截断提示)
    public static func urlForExport(_ text: String, isChinese: Bool) -> (url: String?, truncated: Bool) {
        let prepared = prepare(text)
        return (url(for: prepared.text, target: targetLanguage(isChinese: isChinese)), prepared.truncated)
    }
}
