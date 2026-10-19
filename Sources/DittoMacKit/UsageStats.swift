import Foundation

// MARK: - 使用统计(原版 OptionsStats.cpp:81-98 的 Total/Startup 计数与 D.H.M 跨度)
//
// 上游在每次捕获入库与每次粘贴时累加 TotalCopyCount/TotalPasteCount(注册表),
// 并记录统计起点 TotalDate;统计页显示 "自 <日期>(已 D.H.M)"。
// 此处等价落 UserDefaults(UInt64 计数 + set-once 起点时间戳),默认走
// DittoSettings.defaults(便携模式下随便携 plist)。

/// 计数器:可注入 defaults(单测不污染全局)
public final class UsageStats {

    public static let copyCountKey = "ditto.stats.copyCount"
    public static let pasteCountKey = "ditto.stats.pasteCount"
    /// 统计起点(首次launch时间戳;set-once)
    public static let sinceKey = "ditto.stats.since"

    private let defaults: UserDefaults

    /// - Parameter defaults:注入存储后端(默认跟随后端 = DittoSettings.defaults)
    public init(defaults: UserDefaults = DittoSettings.defaults) {
        self.defaults = defaults
    }

    // MARK: - 计数

    /// 每次成功捕获(新插入或去重置顶)调一次
    public func noteCopy() {
        increment(Self.copyCountKey)
    }

    /// 每次 markPasted(条目被粘贴)调一次
    public func notePaste() {
        increment(Self.pasteCountKey)
    }

    public var copyCount: UInt64 {
        uint64(Self.copyCountKey)
    }

    public var pasteCount: UInt64 {
        uint64(Self.pasteCountKey)
    }

    /// 统计起点:已存在不动(set-once),不存在则记 now 并返回
    public func since(now: Date = Date()) -> Date {
        if let stored = defaults.object(forKey: Self.sinceKey) as? NSNumber {
            return Date(timeIntervalSince1970: stored.doubleValue)
        }
        defaults.set(now.timeIntervalSince1970, forKey: Self.sinceKey)
        return now
    }

    private func increment(_ key: String) {
        defaults.set(Int64(uint64(key) &+ 1), forKey: key)   // 饱和在 UInt64 顶(实际上限远不可达)
    }

    private func uint64(_ key: String) -> UInt64 {
        let raw = defaults.object(forKey: key) as? NSNumber ?? NSNumber(value: 0)
        // 负数/异常值安全回落 0
        let v = raw.int64Value
        return v > 0 ? UInt64(v) : 0
    }

    // MARK: - 跨度格式(纯函数)

    /// 上游 OptionsStats.cpp:94-98:`csSpan.Format("%d.%d.%d (D.H.M)", GetTotalDays(),
    /// GetHours(), GetMinutes())`。COleDateTimeSpan 语义:总天数 + 0-23 小时分量 +
    /// 0-59 分钟分量。任务口径 `%.0ld.%02ld.%02ld`(天.时.分,时/分两位补零)
    public static func spanComponents(from start: Date, to end: Date) -> (days: Int, hours: Int, minutes: Int) {
        let seconds = max(0, Int(end.timeIntervalSince(start).rounded()))
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        return (days, hours, minutes)
    }

    /// "D.HH.MM"(不含上游后缀文案;展示层自行拼 "已 …" / "(D.H.M)")
    /// 注:任务口径 `%.0ld.%02ld.%02ld`,但 printf 家族对"精度 0 + 值 0"输出
    /// 空串(0 天会显示成 ".00.00"),因此天数用 %ld —— 非零天数输出与任务口径
    /// 完全一致,且 0 天有可读的 "0" 前缀
    public static func spanString(from start: Date, to end: Date) -> String {
        let c = spanComponents(from: start, to: end)
        return String(format: "%ld.%02ld.%02ld", c.days, c.hours, c.minutes)
    }

    /// 起点日期显示(yyyy-MM-dd)
    public static func sinceDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}

// MARK: - 共享实例(应用接线用;测试用独立 init)

public extension UsageStats {
    static let shared = UsageStats()
}
