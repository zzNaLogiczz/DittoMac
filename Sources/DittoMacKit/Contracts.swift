import Foundation
import AppKit
import Carbon.HIToolbox

// MARK: - 快速选项枚举(设置存储值类型)

/// 标题栏位置(原版 View Caption Bar On Top/Right/Bottom/Left;默认右 = 既有布局)
public enum CaptionPosition: String, CaseIterable, Sendable {
    case top
    case right
    case bottom
    case left
}

/// 搜索范围(原版 Search Options:Search Full Text / Search Description)
public enum SearchScope: String, Sendable {
    case fullText
    case descriptionOnly
}

/// 搜索方式(原版 Search Options:Contains / Wildcard / Regular Expression)
public enum SearchMethod: String, Sendable {
    case contains
    case wildcard
    case regex
}

/// 失焦面板行为(原版 Auto Roll-up:开启 = 折叠而非隐藏;.none = 保持不动)
public enum FocusLossBehavior: Equatable, Sendable {
    case none
    case hide
    case rollUp
}

// MARK: - 剪贴板条目类型

public enum ClipKind: String, Codable, Sendable {
    case text
    case rtf
    case html
    case image
    case files
    /// 组条目(原版 Main 表 bIsGroup=1 的行):text 列存组名,无粘贴数据
    case group
    case unknown
}

// MARK: - 已知格式对应的代表性 UTI(白名单门控 / 格式列表 / 格式删除映射共用)

public enum ClipUTI {
    public static let text = "public.utf8-plain-text"
    public static let rtf = "public.rtf"
    public static let html = "public.html"
    public static let png = "public.png"
    public static let tiff = "public.tiff"
    public static let fileURL = "public.file-url"
}

// MARK: - 附加自定义格式(原版 Types 表:白名单内的任意剪贴板格式原样入库/写回)

public struct ClipFormat: Codable, Equatable, Sendable {
    /// UTI 标识(如 "com.microsoft.pdf"),动态 UTI(dyn.*)不稳定不入库
    public var type: String
    public var data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

// MARK: - 从系统剪贴板捕获的原始数据(多种格式并存,恢复时原样写回)

public struct RawClip: @unchecked Sendable {
    public var text: String?
    public var rtfData: Data?
    public var htmlData: Data?
    public var imageData: Data?
    public var filePaths: [String]?
    /// 白名单内的非已知类型,逐条 (UTI, data) 原样保存(ClipStore 落 clip_formats 表)
    public var extraFormats: [ClipFormat]
    public var appName: String?

    public init(text: String? = nil,
                rtfData: Data? = nil,
                htmlData: Data? = nil,
                imageData: Data? = nil,
                filePaths: [String]? = nil,
                extraFormats: [ClipFormat] = [],
                appName: String? = nil) {
        self.text = text
        self.rtfData = rtfData
        self.htmlData = htmlData
        self.imageData = imageData
        self.filePaths = filePaths
        self.extraFormats = extraFormats
        self.appName = appName
    }

    public var isEmpty: Bool {
        let hasText = (text?.isEmpty == false)
        let hasFiles = (filePaths?.isEmpty == false)
        return !hasText && !hasFiles && rtfData == nil && htmlData == nil && imageData == nil
            && extraFormats.isEmpty
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
        total += extraFormats.reduce(0) { $0 + $1.data.count }
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
        // 附加格式按 type 排序后参与哈希:捕获顺序可能不稳定,排序保证同内容同哈希
        for format in extraFormats.sorted(by: { $0.type < $1.type }) {
            h.update(Data([0x05]))
            h.update(format.type)
            h.update(Data([0x06]))
            h.update(format.data)
        }
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
    /// 所属组 id(-1 = 顶层;原版 lParentID)。组条目自身也用它构成组树
    public var parentID: Int64
    /// 是否为组条目(原版 bIsGroup)。组行不参与置顶/粘贴,回车=进入组
    public var isGroup: Bool
    /// 用户自定义标题(原版 Main.mTitle/Item Title;nil = 按内容派生描述)
    public var title: String?
    /// 置顶顺序(原版 stickyClipOrder,REAL;nil = 未置顶)。值越小越靠前;
    /// pinned 布尔与它保持同步(pinned = stickyOrder != nil)
    public var stickyOrder: Double?

    public init(id: Int64, kind: ClipKind, createdAt: Date, text: String?,
                pinned: Bool, byteSize: Int, appName: String?, contentHash: String,
                lastPasteAt: Date? = nil, noDelete: Bool = false,
                parentID: Int64 = -1, isGroup: Bool = false,
                title: String? = nil, stickyOrder: Double? = nil) {
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
        self.parentID = parentID
        self.isGroup = isGroup
        self.title = title
        self.stickyOrder = stickyOrder
    }

    /// 该条目是否粘贴过(lastPasteDate ≠ lDate → 原版列表行首画 2px 绿条)
    public var wasPasted: Bool { lastPasteAt != nil }
}

// MARK: - 组热键绑定(原版 Main 表 lShortCut/globalShortCut 列的等价拆分:
// 独立 group_hotkeys 表,随库备份/迁移一起走,不进 UserDefaults)

public struct GroupHotkey: Equatable, Sendable {
    /// Carbon 键码
    public var keyCode: UInt32
    /// Carbon 修饰键掩码(cmdKey/optionKey/controlKey/shiftKey)
    public var modifiers: UInt
    /// 全局可用(原版 "hotkey available globally"):全局=任意应用可触发,
    /// 非全局=仅面板在屏时生效(原版非全局热键只在快速粘贴窗口内派发)
    public var isGlobal: Bool

    public init(keyCode: UInt32, modifiers: UInt, isGlobal: Bool) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isGlobal = isGlobal
    }
}

/// 条目热键(原版 Main.lShortCut/globalShortCut):存储形态与组热键一致,
/// 直接复用同一值类型(独立 clip_hotkeys 表,随库备份/迁移)
public typealias ClipHotkey = GroupHotkey

// MARK: - 复制缓冲(原版 Copy Buffers,CDittoCopyBuffer;热键存 UserDefaults)

/// 复制缓冲的三种热键动作
public enum CopyBufferAction: String, CaseIterable, Sendable {
    case paste
    case copy
    case cut
}

// MARK: - 删除剪贴板数据对话框的过滤条件(原版 DeleteClipData.cpp 的已验证过滤器)

public struct ClipDeleteFilter: Sendable {
    /// 标题/描述包含(空 = 不过滤)
    public var titleContains: String
    /// 创建时间范围(闭区间;nil 端 = 不限)
    public var createdStart: Date?
    public var createdEnd: Date?
    /// 上次使用时间范围(闭区间;nil 端 = 不限;从未粘贴的条目不命中时间条件)
    public var lastUsedStart: Date?
    public var lastUsedEnd: Date?
    /// 格式过滤(nil = 全部;"extra" = 附加格式;否则为具体 UTI)
    public var format: String?

    public init(titleContains: String = "",
                createdStart: Date? = nil, createdEnd: Date? = nil,
                lastUsedStart: Date? = nil, lastUsedEnd: Date? = nil,
                format: String? = nil) {
        self.titleContains = titleContains
        self.createdStart = createdStart
        self.createdEnd = createdEnd
        self.lastUsedStart = lastUsedStart
        self.lastUsedEnd = lastUsedEnd
        self.format = format
    }
}

// MARK: - 存储层协议(SQLite 实现:ClipStore)

public protocol ClipStoring: AnyObject {
    /// 写入一条记录。内容与最近一条相同时:更新其时间戳并置顶(返回该条),不新建。
    /// 超过 maxDataBytes(单条体积上限,默认 20MB)的记录直接丢弃,返回 nil。
    @discardableResult
    func insert(_ raw: RawClip, maxDataBytes: Int) -> ClipItem?

    /// 带组普通写入:新条目落目标组；全库去重命中时保留已有条目的所在组。
    @discardableResult
    func insert(_ raw: RawClip, maxDataBytes: Int, parentID: Int64) -> ClipItem?

    /// 显式抓板入组：仅在目标组去重，必要时创建副本；不移动其他组或顶层原条目。
    @discardableResult
    func captureToGroup(_ raw: RawClip, maxDataBytes: Int, parentID: Int64) -> ClipItem?

    func recent(limit: Int) -> [ClipItem]
    /// 多关键词 AND、大小写不敏感、子串匹配 text 字段;空查询等价于 recent(limit:)
    func search(_ query: String, limit: Int) -> [ClipItem]
    /// 带搜索选项(原版 Search Options:范围 = 全文/仅描述,方式 = 包含/通配/正则)
    func search(_ query: String, limit: Int, scope: SearchScope, method: SearchMethod) -> [ClipItem]
    /// 组感知的列表查询(取代 UI 层对 recent/search 的直接使用)。
    /// parentID=-1 时列顶层;includeGroupClips 开(原版 ShowClipsInMainList)时顶层
    /// 额外包含所有组内条目;query 非空时按当前视图范围过滤(原版只搜当前视图,
    /// QPasteWnd.cpp:1500-1524 的 filter 叠加)。排序:pinned DESC(组行不受置顶影响)、
    /// created_at DESC,组与条目交错
    func list(parentID: Int64, includeGroupClips: Bool, query: String?, limit: Int) -> [ClipItem]
    /// 带搜索选项的组感知列表查询(同上;scope/method 见 SearchScope/SearchMethod)
    func list(parentID: Int64, includeGroupClips: Bool, query: String?, limit: Int,
              scope: SearchScope, method: SearchMethod) -> [ClipItem]

    /// 按 id 取回完整数据(含所有 blob),供预览与写回剪贴板
    func payload(id: Int64) -> RawClip?

    /// 单条条目(组名/父组查询用;不存在返回 nil)
    func item(id: Int64) -> ClipItem?

    /// 条目携带的全部格式(原版 Copy Properties 的 "Copy Data" 列表):
    /// 已知格式映射为代表性 UTI 在前(text/rtf/html/image/files),附加格式按入库序在后
    func formats(id: Int64) -> [ClipFormat]
    /// 删除条目的指定格式(原版 Delete Copy Data);会把删空的列/行清掉并重算 byte_size 与 hash。
    /// 全部格式都将被删时拒绝(不留空条目),返回 false
    @discardableResult
    func deleteFormats(id: Int64, types: [String]) -> Bool

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

    // MARK: 多置顶(原版 Sticky Clips:Make/Replace/Remove Top-Last Sticky)

    /// 设为首位置顶(原版 Make Top Sticky:新值 = 当前最小序 - 1)
    func setStickyTop(_ id: Int64)
    /// 设为末位置顶(原版 Make Last Sticky:新值 = 当前最大序 + 1)
    func setStickyLast(_ id: Int64)
    /// 替换首位置顶:当前首位置顶取消置顶,本条继承其序(原版 Replace Top Sticky,
    /// QPasteWnd.cpp:5321 DoActionReplaceTopStickyClip:先 RemoveSticky(首位) 再 MakeTopSticky)
    func replaceStickyTop(_ id: Int64)
    /// 置顶开关(false = 取消置顶,原版 Remove Sticky Setting)
    func setSticky(_ id: Int64, _ sticky: Bool)
    /// 修正置顶顺序(原版 Fixup Sticky Clip Order / ReOrderStickyClips,
    /// DatabaseUtilities.cpp:227):按当前顺序重排为连续序,消除空洞/重复
    func fixupStickyOrder()

    // MARK: 标题与内容编辑(原版 Properties Item Title / Edit Clip)

    /// 设置条目标题(nil = 清除,恢复按内容派生描述)
    func setTitle(_ id: Int64, _ title: String?)
    /// 编辑条目内容(text/rtf/html 三列;nil = 不改该列,空串/空数据 = 清空该列)。
    /// 保存后以剩余全部格式重算 byte_size 与 hash(口径同 deleteFormats),
    /// title/sticky/parent 等元数据保持不变。全部格式将被清空时拒绝,返回 false
    @discardableResult
    func updateClipContent(id: Int64, text: String?, rtfData: Data?, htmlData: Data?) -> Bool

    // MARK: 删除剪贴板数据(原版 DeleteClipData)

    /// 按过滤条件搜索可删除的候选条目(不含组行)
    func searchForDelete(filters: ClipDeleteFilter) -> [ClipItem]
    /// 批量删除(队列安全单方法):置顶/永不删除/组行豁免不删(同 prune 口径),
    /// 返回(实际删除数, 受保护跳过数);附加格式与热键孤儿随行清理
    @discardableResult
    func deleteClips(ids: [Int64]) -> (deleted: Int, skipped: Int)
    /// 数据库文件占用字节数(主文件 + WAL,供删除对话框显示"数据库大小")
    func databaseSizeBytes() -> Int

    // MARK: 条目热键(clip_hotkeys 表;原版 Main.lShortCut/globalShortCut)

    func clipHotkey(id: Int64) -> ClipHotkey?
    /// nil = 清除绑定
    func setClipHotkey(id: Int64, hotkey: ClipHotkey?)
    /// 全部绑定(启动时批量注册热键用)
    func allClipHotkeys() -> [(clipID: Int64, hotkey: ClipHotkey)]

    // MARK: 组(原版 Groups:单 Main 表 + lParentID/bIsGroup)

    /// 新建组(原版 NewGroupID:插 bIsGroup=1 行,text 列=组名),返回新组条目
    @discardableResult
    func createGroup(name: String, parentID: Int64) -> ClipItem?
    /// 指定父组的直接子组(组树/移动菜单用;按创建时间倒序)
    func childGroups(of parentID: Int64) -> [ClipItem]
    /// 移动条目/组到目标组(原版 CClipIDs::MoveTo)。移动组=改父;
    /// 目标是任一被移动组自身或其后代 → 拒绝(成环),返回 false
    @discardableResult
    func moveClips(ids: [Int64], toParent parentID: Int64) -> Bool
    /// 复制条目到目标组(原版组间 Ctrl+C/V 的"复制"语义):整行 + 附加格式
    /// 以新 id 复制(不走 insert 去重,同内容多份是合法状态)
    @discardableResult
    func duplicateClips(ids: [Int64], toParent parentID: Int64) -> Bool
    /// 组重命名(text 列即组名)
    @discardableResult
    func renameGroup(id: Int64, name: String) -> Bool
    /// 删除组:子条目与子组先移回该组的父组,再删组行(比原版"连同内容删除"保守,
    /// 防误删;偏差见 ClipStore.deleteGroup 注释)
    @discardableResult
    func deleteGroup(id: Int64) -> Bool

    // MARK: 组热键(group_hotkeys 表)

    func groupHotkey(id: Int64) -> GroupHotkey?
    /// nil = 清除绑定
    func setGroupHotkey(id: Int64, hotkey: GroupHotkey?)
    /// 全部绑定(启动时批量注册热键用)
    func allGroupHotkeys() -> [(groupID: Int64, hotkey: GroupHotkey)]
}

// MARK: - 全局设置(UserDefaults)键与默认值

public enum DittoSettings {

    /// 设置读取后端:默认 .standard;便携模式(上游 GetIsPortableDitto,
    /// Options.cpp:1957-1960)在 main.swift 引导阶段切到 <便携根>/DittoMac/
    /// settings.plist 支撑的 suite —— 必须在任何键读取之前完成
    /// (见 PortableMode.bootstrap)
    public static var defaults: UserDefaults = .standard

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
    /// 保存格式白名单(原版 OptionsTypes 的 Types 表:只有名单内的格式才入库)
    public static let typesWhitelistKey = "ditto.typesWhitelist"
    /// 排除规则(原版 RegExFilterHelper,JSON 编码的 [ExcludeRule],最多 15 条生效)
    public static let excludeRulesKey = "ditto.excludeRules"
    /// 应用包含/排除列表(原版 CopyAppInclude/CopyAppExclude,';' 分隔通配模式)
    public static let appIncludeKey = "ditto.appInclude"
    public static let appExcludeKey = "ditto.appExclude"
    /// 主列表显示组内条目(原版 ShowClipsInMainList;默认关)
    public static let includeGroupClipsKey = "ditto.includeGroupClips"
    /// 新建组时提示输入名称(原版 PrompForNewGroupName,注意原版即拼错;默认开)
    public static let promptForGroupNameKey = "ditto.promptForGroupName"
    /// 删除条目前确认(原版 Prompt to Delete Clip,2.7.5;默认关)
    public static let promptDeleteKey = "ditto.promptDelete"
    /// 最新在上(原版列表排序方向;默认开 = created_at DESC)
    public static let orderLatestOnTopKey = "ditto.orderLatestOnTop"
    /// 即输即搜(原版 Find As You Type;默认开。关 = 仅回车时搜索)
    public static let findAsYouTypeKey = "ditto.findAsYouType"

    public static let defaultMaxItems = 500
    public static let defaultMaxAgeDays = 30
    public static let defaultMaxDataBytes = 20 * 1024 * 1024
    public static let defaultLinesPerRow = 2
    public static let defaultPositionMode = "atCursor"
    /// 默认白名单 = 五类已知格式 + 文件(原版空 Types 表初始化时预填等价集合)
    public static let defaultTypesWhitelist = [
        ClipUTI.text, ClipUTI.rtf, ClipUTI.html, ClipUTI.png, ClipUTI.tiff, ClipUTI.fileURL,
    ]

    public static let defaultHotKeyCode: UInt32 = 9
    public static let defaultHotKeyMods: UInt = UInt(cmdKey | shiftKey)

    /// 生效白名单:UserDefaults 无该键 → 默认白名单;显式设置(含空数组)→ 按用户值。
    /// 空 = 什么都不记(原版空 Types 表时 LoadFromClipboard 直接返回 FALSE)
    public static func effectiveTypesWhitelist() -> Set<String> {
        guard let list = DittoSettings.defaults.stringArray(forKey: typesWhitelistKey) else {
            return Set(defaultTypesWhitelist)
        }
        return Set(list)
    }

    /// 主列表是否显示组内条目(原版 ShowClipsInMainList,默认关:
    /// bool(forKey:) 对"未设置"也返回 false,需按 object 判默认)
    public static func includeGroupClips() -> Bool {
        DittoSettings.defaults.object(forKey: includeGroupClipsKey) == nil
            ? false
            : DittoSettings.defaults.bool(forKey: includeGroupClipsKey)
    }

    /// 新建组时是否提示输入名称(原版 PrompForNewGroupName,默认开)
    public static func promptForGroupName() -> Bool {
        DittoSettings.defaults.object(forKey: promptForGroupNameKey) == nil
            ? true
            : DittoSettings.defaults.bool(forKey: promptForGroupNameKey)
    }

    /// 删除条目前是否确认(原版 Prompt to Delete Clip,默认关)
    public static func promptDelete() -> Bool {
        DittoSettings.defaults.object(forKey: promptDeleteKey) == nil
            ? false
            : DittoSettings.defaults.bool(forKey: promptDeleteKey)
    }

    /// 列表排序:最新是否在上(默认开 = created_at DESC;关 = 最旧在上)
    public static func orderLatestOnTop() -> Bool {
        DittoSettings.defaults.object(forKey: orderLatestOnTopKey) == nil
            ? true
            : DittoSettings.defaults.bool(forKey: orderLatestOnTopKey)
    }

    /// 即输即搜(原版 Find As You Type,默认开;关 = 搜索框仅回车触发查询)
    public static func findAsYouType() -> Bool {
        DittoSettings.defaults.object(forKey: findAsYouTypeKey) == nil
            ? true
            : DittoSettings.defaults.bool(forKey: findAsYouTypeKey)
    }

    // MARK: 快速选项新增(透明度/字体/主题/自动折叠/标题栏位置/描述行/RTF 绘制/搜索)

    /// 面板透明度百分比(0=无;原版 Transparency,菜单档 5..40)
    public static let transparencyPercentKey = "ditto.transparencyPercent"
    /// 列表字体(原版 Select Font;fontName 空 = 系统默认)
    public static let fontNameKey = "ditto.fontName"
    public static let fontSizeKey = "ditto.fontSize"
    /// 主题文件存储值(空 = 跟随系统;"builtin:<名>" = 内置;其余 = 导入路径)
    public static let themeFileKey = "ditto.themeFile"
    /// 失焦自动折叠(原版 Auto Roll-up;默认关)
    public static let autoRollUpKey = "ditto.autoRollUp"
    /// 标题栏位置(原版 View Caption Bar On:上/右/下/左;默认右 = 当前布局)
    public static let captionPositionKey = "ditto.captionPosition"
    /// 行内始终显示描述第二行(原版 Always Show Description;默认关)
    public static let alwaysShowDescriptionKey = "ditto.alwaysShowDescription"
    /// RTF/HTML 条目按富内容绘制(原版 Draw RTF Text;默认关)
    public static let drawRtfTextKey = "ditto.drawRtfText"
    /// 搜索范围(原版 Search Full Text / Search Description;默认全文)
    public static let searchScopeKey = "ditto.searchScope"
    /// 搜索方式(原版 Contains / Wildcard / Regular Expression;默认包含)
    public static let searchMethodKey = "ditto.searchMethod"

    public static let defaultFontSize: Double = 13

    /// 透明度取值夹取(上游 Options.cpp:867-873 SetTransparencyPercent 夹 0..上限;
    /// macOS alphaValue 必须保持 > 0,上限 90)
    public static func clampedTransparencyPercent(_ value: Int) -> Int {
        min(max(value, 0), 90)
    }

    /// 透明度 → 窗口 alpha(1 - pct/100;与上游 SetOpacity(MAX - pct*MAX) 等价)
    public static func transparencyAlpha(percent: Int) -> Double {
        1 - Double(clampedTransparencyPercent(percent)) / 100
    }

    /// 行高 = 每条行数(始终显示描述时 +1 行)× 字体行高 + 4
    /// (原版 QListCtrl.cpp:414-428 行高随字体行高与行数;纯函数便于单测)
    public static func rowHeight(lineHeight: Double, linesPerRow: Int, alwaysShowDescription: Bool) -> Double {
        let lines = max(linesPerRow, 1) + (alwaysShowDescription ? 1 : 0)
        return lineHeight * Double(lines) + 4
    }

    /// 标题栏位置读取(非法值回落 .right)
    public static func captionPosition() -> CaptionPosition {
        guard let raw = DittoSettings.defaults.string(forKey: captionPositionKey),
              let pos = CaptionPosition(rawValue: raw) else { return .right }
        return pos
    }

    public static func searchScope() -> SearchScope {
        guard let raw = DittoSettings.defaults.string(forKey: searchScopeKey),
              let scope = SearchScope(rawValue: raw) else { return .fullText }
        return scope
    }

    public static func searchMethod() -> SearchMethod {
        guard let raw = DittoSettings.defaults.string(forKey: searchMethodKey),
              let method = SearchMethod(rawValue: raw) else { return .contains }
        return method
    }

    /// 失焦行为决策(原版 Auto Roll-up:开启时失焦 → 折叠而非隐藏;常驻置顶豁免、
    /// 已折叠保持;纯函数单测覆盖)
    public static func focusLossBehavior(autoRollUp: Bool, persistent: Bool, rolled: Bool) -> FocusLossBehavior {
        if persistent { return .none }
        if autoRollUp { return rolled ? .none : .rollUp }
        return .hide
    }

    // MARK: 排除规则与应用列表(捕获过滤;写回原样,读取解析失败安全退化为空)

    public static func loadExcludeRules() -> [ExcludeRule] {
        guard let data = DittoSettings.defaults.data(forKey: excludeRulesKey) else { return [] }
        return (try? JSONDecoder().decode([ExcludeRule].self, from: data)) ?? []
    }

    public static func saveExcludeRules(_ rules: [ExcludeRule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        DittoSettings.defaults.set(data, forKey: excludeRulesKey)
    }

    public static func appInclude() -> String {
        DittoSettings.defaults.string(forKey: appIncludeKey) ?? ""
    }

    public static func appExclude() -> String {
        DittoSettings.defaults.string(forKey: appExcludeKey) ?? ""
    }

    public static func setAppInclude(_ value: String) {
        DittoSettings.defaults.set(value, forKey: appIncludeKey)
    }

    public static func setAppExclude(_ value: String) {
        DittoSettings.defaults.set(value, forKey: appExcludeKey)
    }

    public static func readDefaults() -> [String: Any] {
        let d = DittoSettings.defaults
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

// MARK: - 复制缓冲 1-3 的热键与设置(上游 CopyBufferCopyHotKey_N 等注册表项的 UserDefaults 等价)

public extension DittoSettings {

    /// 缓冲个数(上游 OptionsCopyBuffers 页实际可用的是前 3 个;任务口径 1-3)
    static let copyBufferCount = 3

    static func copyBufferKeyCodeKey(_ index: Int, _ action: CopyBufferAction) -> String {
        "ditto.copyBuffer.\(index).\(action.rawValue).keyCode"
    }

    static func copyBufferModsKey(_ index: Int, _ action: CopyBufferAction) -> String {
        "ditto.copyBuffer.\(index).\(action.rawValue).modifiers"
    }

    static func copyBufferPlaySoundKey(_ index: Int) -> String {
        "ditto.copyBuffer.\(index).playSound"
    }

    /// 上游默认(OptionsCopyBuffers 一带;Ctrl+plus / Ctrl+minus 的已验证口径):
    /// 美式键盘 plus 即 "=" 键(键码 24),minus 即 "-" 键(键码 27)——文档化映射。
    /// 仅缓冲 1/2 有默认;所有 CUT 默认未绑定,缓冲 3 默认全未绑定
    static func copyBufferDefaultKey(index: Int, action: CopyBufferAction) -> (code: UInt32, mods: UInt)? {
        switch (index, action) {
        case (1, .paste): return (24, UInt(controlKey))
        case (1, .copy): return (24, UInt(controlKey | shiftKey))
        case (2, .paste): return (27, UInt(controlKey))
        case (2, .copy): return (27, UInt(controlKey | shiftKey))
        default: return nil
        }
    }

    /// 生效绑定:用户显式解绑(keyCode 存 -1)→ nil;未设置 → 默认;无默认 → nil
    static func copyBufferKey(index: Int, action: CopyBufferAction) -> (code: UInt32, mods: UInt)? {
        let codeKey = copyBufferKeyCodeKey(index, action)
        guard let stored = DittoSettings.defaults.object(forKey: codeKey) as? NSNumber else {
            return copyBufferDefaultKey(index: index, action: action)
        }
        guard stored.intValue >= 0 else { return nil }   // -1 = 用户解绑
        let mods = (DittoSettings.defaults.object(forKey: copyBufferModsKey(index, action)) as? NSNumber)?
            .uintValue ?? 0
        return (UInt32(stored.intValue), mods)
    }

    /// 写绑定。code 非 nil = 显式绑定;nil = 有默认则显式解绑(-1),无默认则移除键
    static func setCopyBufferKey(index: Int, action: CopyBufferAction, code: UInt32?, mods: UInt = 0) {
        let codeKey = copyBufferKeyCodeKey(index, action)
        let modsKey = copyBufferModsKey(index, action)
        if let code {
            DittoSettings.defaults.set(Int(code), forKey: codeKey)
            DittoSettings.defaults.set(mods, forKey: modsKey)
        } else if copyBufferDefaultKey(index: index, action: action) != nil {
            DittoSettings.defaults.set(-1, forKey: codeKey)   // 清除 = 显式解绑默认键
        } else {
            DittoSettings.defaults.removeObject(forKey: codeKey)
            DittoSettings.defaults.removeObject(forKey: modsKey)
        }
    }

    /// 该缓冲全部热键恢复默认
    static func resetCopyBufferKeys(index: Int) {
        for action in CopyBufferAction.allCases {
            DittoSettings.defaults.removeObject(forKey: copyBufferKeyCodeKey(index, action))
            DittoSettings.defaults.removeObject(forKey: copyBufferModsKey(index, action))
        }
    }

    /// 入缓冲成功后是否播放提示音(上游 CopyBufferPlaySound_N,默认关)
    static func copyBufferPlaySound(index: Int) -> Bool {
        DittoSettings.defaults.bool(forKey: copyBufferPlaySoundKey(index))
    }

    static func setCopyBufferPlaySound(index: Int, _ on: Bool) {
        DittoSettings.defaults.set(on, forKey: copyBufferPlaySoundKey(index))
    }
}
