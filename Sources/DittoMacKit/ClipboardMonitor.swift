import AppKit

/// 剪贴板监控:主线程 0.1s 轮询 changeCount(macOS 无剪贴板变更通知,轮询是标准做法;
/// 0.1s 保证 200ms 间隔的高频复制也零丢条,changeCount 读取本身开销可忽略),
/// 变化时读取一条 RawClip(多格式并存,与 Ditto 一条记录承载原有多格式的行为一致)
public final class ClipboardMonitor {

    /// 单例便捷访问
    public static let shared = ClipboardMonitor()

    /// 捕获到新内容时回调(主线程)
    public var onClip: ((RawClip) -> Void)?

    /// 当前 onClip 回调对应的剪贴板版本；复制缓冲只接受发键前快照之后的变化。
    public private(set) var lastCaptureChangeCount: Int = -1

    /// 保存格式白名单(原版 OptionsTypes 的 Types 表:只有名单内的格式才入库)。
    /// 每次读取现取,设置变更即时生效;测试可注入
    public var typesWhitelistProvider: () -> Set<String> = { DittoSettings.effectiveTypesWhitelist() }

    /// 捕获前过滤(原版 RegExFilter/应用包含排除列表):返回 true → 丢弃本次内容。
    /// 轮询捕获与 captureNow(手动"保存当前剪贴板")都会应用 —— 与上游 LoadFromClipboard 管线一致
    public var shouldDrop: ((RawClip) -> Bool)?

    /// 下一次入库的目标组 id(原版 COPY_TO_GROUP:组热键双击时 CopyThread 取
    /// theApp.GetActiveGroupId() 决定落组,CP_Main.cpp:1332-1359 的落组状态在此以
    /// "一次性字段"等价实现:-1 = 顶层;消费方读取后按需复位)。
    /// 主线程读写,组热键双击路径同步设置→captureNow→还原
    public var captureParentID: Int64 = -1

    public private(set) var isPaused: Bool = false

    private let pollInterval: TimeInterval = 0.1
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    /// 初始 -1:首次轮询会把启动前已存在的剪贴板内容当作一次变化导入(同 Ditto 启动导入)
    private var lastChangeCount: Int = -1
    /// PasteBack 每次写剪贴板后上报的 changeCount 区间(一次写可能产生多个跳变)。
    /// 轮询时当前 changeCount 落在任一未消费区间内 → 判定自写,消费该区间并跳过;
    /// 用户随后的复制 count 超出区间 → 正常捕获,不会被误吞
    private struct IgnoreRange {
        let lo: Int, hi: Int   // 闭区间
    }
    private var ignoreRanges: [IgnoreRange] = []
    private let flagLock = NSLock()

    /// 图片转 PNG 的体积上限,超过则原样保留原始 data 不转码
    private static let maxImageTranscodeBytes = 8 * 1024 * 1024
    /// 密码管理器(1Password 等)约定的隐藏类型:出现在 types 中时整条跳过
    private static let concealedType = NSPasteboard.PasteboardType(rawValue: "org.nspasteboard.ConcealedType")

    /// 已知类型的 UTI 原始值:额外格式扫描时跳过(它们已由固定五类逻辑处理)
    private static let knownTypeRawValues: Set<String> = [
        NSPasteboard.PasteboardType.string.rawValue,   // public.utf8-plain-text
        NSPasteboard.PasteboardType.rtf.rawValue,      // public.rtf
        NSPasteboard.PasteboardType.html.rawValue,     // public.html
        NSPasteboard.PasteboardType.png.rawValue,      // public.png
        NSPasteboard.PasteboardType.tiff.rawValue,     // public.tiff
        NSPasteboard.PasteboardType.fileURL.rawValue,  // public.file-url
    ]

    internal init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard   // 可用命名剪贴板验证捕获管线，不触碰系统剪贴板
    }

    // MARK: - 生命周期(主线程调用)

    public func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // .common:菜单/面板跟踪期间也持续轮询
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func setPaused(_ paused: Bool) {
        isPaused = paused
        // 暂停期间发生的变化不追溯:以当前计数为基准
        lastChangeCount = pasteboard.changeCount
    }

    /// PasteBack 在写完剪贴板后调用:上报本次写入造成的 changeCount 跳变区间。
    /// (一次写 = clearContents + 声明类型,可能 +1 或 +2,所以用实测区间而不是假设次数)
    public func noteSelfWrite(countBefore before: Int, countAfter: Int) {
        guard countAfter > before else { return }
        flagLock.lock()
        // 上限 8 个区间(防异常路径堆积),旧的丢弃
        if ignoreRanges.count > 8 { ignoreRanges.removeFirst(ignoreRanges.count - 8) }
        ignoreRanges.append(IgnoreRange(lo: before + 1, hi: countAfter))
        flagLock.unlock()
    }

    /// 非 PasteBack 的外部写剪贴板(如属性窗口"复制全文")豁免:一次写最多 +2 跳变
    public func noteExternalWrite() {
        let c = pasteboard.changeCount
        noteSelfWrite(countBefore: c, countAfter: c + 2)
    }

    // MARK: - 轮询

    /// 立即捕获当前剪贴板一条(原版托盘 "Save Current Clipboard"),不受暂停影响。
    /// 与原版一致:同样应用类型白名单与排除规则(上游该菜单走同一 LoadFromClipboard 管线)
    @discardableResult
    public func captureNow() -> Bool {
        let count = pasteboard.changeCount
        guard let clip = readRawClip(), !clip.isEmpty else { return false }
        guard count == pasteboard.changeCount else { return false }
        if shouldDrop?(clip) == true { return false }
        lastCaptureChangeCount = count
        onClip?(clip)
        return true
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }

        if consumeSelfWriteRange(containing: count) {
            lastChangeCount = count
            return
        }
        lastChangeCount = count
        guard !isPaused else { return }
        if pasteboard.types?.contains(Self.concealedType) == true { return }   // 密码管理器隐藏内容
        guard let clip = readRawClip(), !clip.isEmpty else { return }
        guard count == pasteboard.changeCount else { return }
        if shouldDrop?(clip) == true { return }   // 排除规则/应用列表命中 → 丢弃
        lastCaptureChangeCount = count
        onClip?(clip)
    }

    /// 当前 count 是否属于某次自写的结果区间;是则消费该区间
    private func consumeSelfWriteRange(containing count: Int) -> Bool {
        flagLock.lock()
        defer { flagLock.unlock() }
        if let idx = ignoreRanges.firstIndex(where: { count >= $0.lo && count <= $0.hi }) {
            ignoreRanges.remove(at: idx)
            return true
        }
        return false
    }

    // MARK: - 读取(优先级:文件 > 图片 > rtf > html > 纯文本;并存的格式全部保留)

    private func readRawClip() -> RawClip? {
        let pb = pasteboard
        let types = pb.types ?? []
        if types.isEmpty { return nil }
        // 白名单门控(原版 Types 表):每类已知格式按代表性 UTI 放行;
        // 白名单为空 → 五类全被门掉,额外格式也扫不到 → 自然返回空条目
        let whitelist = typesWhitelistProvider()

        var clip = RawClip()
        clip.appName = NSWorkspace.shared.frontmostApplication?.localizedName

        // 1) 文件:仅接受 file URL
        if whitelist.contains(ClipUTI.fileURL),
           types.contains(.fileURL),
           let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [NSURL] {
            let paths = urls.compactMap(\.path).filter { !$0.isEmpty }
            if !paths.isEmpty { clip.filePaths = paths }
        }

        // 2) 图片:优先 png,tiff 统一转 png;超过 8MB 不转码直接存原始 data
        let imageType: NSPasteboard.PasteboardType?
        if types.contains(.png) && whitelist.contains(ClipUTI.png) {
            imageType = .png
        } else if types.contains(.tiff) && whitelist.contains(ClipUTI.tiff) {
            imageType = .tiff
        } else {
            imageType = nil
        }
        if let type = imageType, let data = pb.data(forType: type) {
            if type == .png {
                clip.imageData = data
            } else if data.count > Self.maxImageTranscodeBytes {
                clip.imageData = data
            } else if let rep = NSBitmapImageRep(data: data),
                      let png = rep.representation(using: .png, properties: [:]) {
                clip.imageData = png
            } else {
                clip.imageData = data
            }
        }

        // 3) RTF
        if whitelist.contains(ClipUTI.rtf), types.contains(.rtf),
           let data = pb.data(forType: .rtf) {
            clip.rtfData = data
        }

        // 4) HTML
        if whitelist.contains(ClipUTI.html), types.contains(.html),
           let data = pb.data(forType: .html) {
            clip.htmlData = data
        }

        // 5) 纯文本
        if whitelist.contains(ClipUTI.text), types.contains(.string),
           let text = pb.string(forType: .string), !text.isEmpty {
            clip.text = text
        }

        // 6) 附加自定义格式(原版 Types 表支持的任意格式):白名单内的其余类型原样捕获
        clip.extraFormats = readExtraFormats(whitelist: whitelist)

        return clip
    }

    /// 扫描所有 pasteboard item 的类型并集(保持首见顺序):
    /// 跳过已知五类、密码隐藏类型、dyn.* 动态 UTI(跨次读取不稳定,无法写回)与
    /// 拿不到数据的惰性/承诺类型;白名单命中的类型从首个提供它的 item 读取
    private func readExtraFormats(whitelist: Set<String>) -> [ClipFormat] {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return [] }

        var ordered: [String] = []
        var seen = Set<String>()
        for item in items {
            for raw in item.types.map(\.rawValue) where !seen.contains(raw) {
                seen.insert(raw)
                ordered.append(raw)
            }
        }

        var result: [ClipFormat] = []
        for raw in ordered {
            guard whitelist.contains(raw),
                  !Self.knownTypeRawValues.contains(raw),
                  raw != Self.concealedType.rawValue,
                  !raw.hasPrefix("dyn.")
            else { continue }
            // 首个提供该类型的 item 即数据来源;nil/空数据(惰性/承诺类型)整条跳过
            for item in items {
                guard let data = item.data(forType: NSPasteboard.PasteboardType(rawValue: raw)) else {
                    continue
                }
                if !data.isEmpty {
                    result.append(ClipFormat(type: raw, data: data))
                }
                break
            }
        }
        return result
    }
}
