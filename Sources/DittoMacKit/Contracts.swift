import Foundation
import AppKit
import Carbon.HIToolbox

// MARK: - 剪贴板条目类型

public enum ClipKind: String, Codable, Sendable {
    case text
    case rtf
    case html
    case image
    case files
    case unknown
}

// MARK: - 从系统剪贴板捕获的原始数据(多种格式并存,恢复时原样写回)

public struct RawClip: @unchecked Sendable {
    public var text: String?
    public var rtfData: Data?
    public var htmlData: Data?
    public var imageData: Data?
    public var filePaths: [String]?
    public var appName: String?

    public init(text: String? = nil,
                rtfData: Data? = nil,
                htmlData: Data? = nil,
                imageData: Data? = nil,
                filePaths: [String]? = nil,
                appName: String? = nil) {
        self.text = text
        self.rtfData = rtfData
        self.htmlData = htmlData
        self.imageData = imageData
        self.filePaths = filePaths
        self.appName = appName
    }

    public var isEmpty: Bool {
        let hasText = (text?.isEmpty == false)
        let hasFiles = (filePaths?.isEmpty == false)
        return !hasText && !hasFiles && rtfData == nil && htmlData == nil && imageData == nil
    }

    /// 按 Ditto 的优先级归类:文件 > 图片 > 富文本 > HTML > 纯文本
    public var kind: ClipKind {
        if filePaths?.isEmpty == false { return .files }
        if imageData != nil { return .image }
        if rtfData != nil { return .rtf }
        if htmlData != nil { return .html }
        if text?.isEmpty == false { return .text }
        return .unknown
    }

    public var byteSize: Int {
        // Keep each optional addition separate for the Swift compiler on macOS 14 CI.
        var total = text?.utf8.count ?? 0
        total += rtfData?.count ?? 0
        total += htmlData?.count ?? 0
        total += imageData?.count ?? 0
        return total
    }

    /// 内容哈希,用于去重(同一内容再次复制 → 置顶而不是新建)。
    /// 必须跨进程稳定:不能用 Hasher(每进程随机播种,重启后同内容会被当成新条目),
    /// 用 FNV-1a 确定性摘要
    public var contentHash: String {
        var h = FNV1a64()
        h.update(text ?? "")
        h.update(Data([0x01]))          // 字段分隔,防拼接歧义
        h.update(rtfData ?? Data())
        h.update(Data([0x02]))
        h.update(htmlData ?? Data())
        h.update(Data([0x03]))
        h.update(imageData ?? Data())
        h.update(Data([0x04]))
        h.update(filePaths ?? [])
        return String(format: "%016llx-c%06d", h.digest, byteSize)
    }
}

/// FNV-1a 64 位确定性摘要(跨进程/跨平台稳定,无依赖)
public struct FNV1a64 {
    private var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    public init() {}

    public mutating func update(_ data: Data) {
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
    }

    public mutating func update(_ string: String) {
        update(Data(string.utf8))
    }

    public mutating func update(_ strings: [String]) {
        for s in strings {
            update(s)
            update(Data([0x1F]))
        }
    }

    public var digest: UInt64 { hash }
}

// MARK: - 列表展示用的轻量条目(blob 不随列表加载,按需取)

public struct ClipItem: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var kind: ClipKind
    public var createdAt: Date
    public var text: String?   // 预览文本;files 类型为路径按行拼接
    public var pinned: Bool
    public var byteSize: Int
    public var appName: String?
    public var contentHash: String
    /// 上次粘贴时间(原版 lastPasteDate;nil = 从未粘贴)
    public var lastPasteAt: Date?
    /// 永不自动删除(原版 lDontAutoDelete,列表显示黄星图标)
    public var noDelete: Bool

    public init(id: Int64, kind: ClipKind, createdAt: Date, text: String?,
                pinned: Bool, byteSize: Int, appName: String?, contentHash: String,
                lastPasteAt: Date? = nil, noDelete: Bool = false) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.text = text
        self.pinned = pinned
        self.byteSize = byteSize
        self.appName = appName
        self.contentHash = contentHash
        self.lastPasteAt = lastPasteAt
        self.noDelete = noDelete
    }

    /// 该条目是否粘贴过(lastPasteDate ≠ lDate → 原版列表行首画 2px 绿条)
    public var wasPasted: Bool { lastPasteAt != nil }
}

// MARK: - 存储层协议(SQLite 实现:ClipStore)

public protocol ClipStoring: AnyObject {
    /// 写入一条记录。内容与最近一条相同时:更新其时间戳并置顶(返回该条),不新建。
    /// 超过 maxDataBytes(单条体积上限,默认 20MB)的记录直接丢弃,返回 nil。
    @discardableResult
    func insert(_ raw: RawClip, maxDataBytes: Int) -> ClipItem?

    func recent(limit: Int) -> [ClipItem]
    /// 多关键词 AND、大小写不敏感、子串匹配 text 字段;空查询等价于 recent(limit:)
    func search(_ query: String, limit: Int) -> [ClipItem]

    /// 按 id 取回完整数据(含所有 blob),供预览与写回剪贴板
    func payload(id: Int64) -> RawClip?

    func setPinned(_ id: Int64, _ pinned: Bool)
    /// 标记条目已被粘贴(原版 MarkAsPasted:更新 lastPasteDate)
    func markPasted(id: Int64, at date: Date)
    /// 永不自动删除开关(原版 lDontAutoDelete;prune/clear 豁免)
    func setNoDelete(_ id: Int64, _ noDelete: Bool)
    /// 条目顺序移动(原版 Clip Order:Move To Top/Up/Down/Last)
    func moveClip(_ id: Int64, _ direction: ClipStore.ClipMove)
    func delete(id: Int64)
    func clear(keepingPinned: Bool)
    /// 清理:超过 maxItems 条或超过 maxAgeDays 天的(置顶/永不删除的除外)
    func prune(maxItems: Int, maxAgeDays: Int)
    var count: Int { get }
}

// MARK: - 全局设置(UserDefaults)键与默认值

public enum DittoSettings {
    public static let maxItemsKey = "ditto.maxItems"
    public static let maxAgeDaysKey = "ditto.maxAgeDays"
    public static let hotKeyCodeKey = "ditto.hotKey.keyCode"
    public static let hotKeyModsKey = "ditto.hotKey.modifiers"
    public static let pausedKey = "ditto.paused"
    public static let maxDataBytesKey = "ditto.maxDataBytes"
    /// 每条目行数(原版 LinesPerRow,1-5,默认 2;决定列表行高)
    public static let linesPerRowKey = "ditto.linesPerRow"
    /// 窗口出现位置:atCursor(原版 At Caret 的 macOS 等价:光标处)/ atPrevious(上次位置)
    public static let positionModeKey = "ditto.positionMode"

    public static let defaultMaxItems = 500
    public static let defaultMaxAgeDays = 30
    public static let defaultMaxDataBytes = 20 * 1024 * 1024
    public static let defaultLinesPerRow = 2
    public static let defaultPositionMode = "atCursor"

    public static let defaultHotKeyCode: UInt32 = 9
    public static let defaultHotKeyMods: UInt = UInt(cmdKey | shiftKey)

    public static func readDefaults() -> [String: Any] {
        let d = UserDefaults.standard
        return [
            maxItemsKey: d.integer(forKey: maxItemsKey) == 0 ? defaultMaxItems : d.integer(forKey: maxItemsKey),
            maxAgeDaysKey: d.integer(forKey: maxAgeDaysKey) == 0 ? defaultMaxAgeDays : d.integer(forKey: maxAgeDaysKey),
            hotKeyCodeKey: d.object(forKey: hotKeyCodeKey) == nil ? defaultHotKeyCode : d.object(forKey: hotKeyCodeKey)!,
            hotKeyModsKey: d.object(forKey: hotKeyModsKey) == nil ? defaultHotKeyMods : d.object(forKey: hotKeyModsKey)!,
            pausedKey: d.bool(forKey: pausedKey),
            maxDataBytesKey: d.object(forKey: maxDataBytesKey) == nil ? defaultMaxDataBytes : d.object(forKey: maxDataBytesKey)!,
        ]
    }
}

// MARK: - Carbon 修饰键常量(HotKeys.swift 使用)

public extension DittoSettings {
    /// NSEvent.ModifierFlags → Carbon 修饰键位掩码
    static func carbonMask(from mods: NSEvent.ModifierFlags) -> UInt {
        var m: UInt = 0
        if mods.contains(.command) { m |= UInt(cmdKey) }
        if mods.contains(.option) { m |= UInt(optionKey) }
        if mods.contains(.control) { m |= UInt(controlKey) }
        if mods.contains(.shift) { m |= UInt(shiftKey) }
        return m
    }
}
