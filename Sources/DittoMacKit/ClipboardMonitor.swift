import AppKit

/// 剪贴板监控:主线程 0.1s 轮询 changeCount(macOS 无剪贴板变更通知,轮询是标准做法;
/// 0.1s 保证 200ms 间隔的高频复制也零丢条,changeCount 读取本身开销可忽略),
/// 变化时读取一条 RawClip(多格式并存,与 Ditto 一条记录承载原有多格式的行为一致)
public final class ClipboardMonitor {

    /// 单例便捷访问
    public static let shared = ClipboardMonitor()

    /// 捕获到新内容时回调(主线程)
    public var onClip: ((RawClip) -> Void)?

    public private(set) var isPaused: Bool = false

    private let pollInterval: TimeInterval = 0.1
    private let pasteboard = NSPasteboard.general
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

    internal init() {}   // 测试需要独立实例;常规使用走 shared

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

    /// 立即捕获当前剪贴板一条(原版托盘 "Save Current Clipboard"),不受暂停影响
    @discardableResult
    public func captureNow() -> Bool {
        guard let clip = readRawClip(), !clip.isEmpty else { return false }
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

        var clip = RawClip()
        clip.appName = NSWorkspace.shared.frontmostApplication?.localizedName

        // 1) 文件:仅接受 file URL
        if types.contains(.fileURL),
           let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [NSURL] {
            let paths = urls.compactMap(\.path).filter { !$0.isEmpty }
            if !paths.isEmpty { clip.filePaths = paths }
        }

        // 2) 图片:优先 png,tiff 统一转 png;超过 8MB 不转码直接存原始 data
        let imageType: NSPasteboard.PasteboardType? = types.contains(.png) ? .png
            : (types.contains(.tiff) ? .tiff : nil)
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
        if types.contains(.rtf), let data = pb.data(forType: .rtf) {
            clip.rtfData = data
        }

        // 4) HTML
        if types.contains(.html), let data = pb.data(forType: .html) {
            clip.htmlData = data
        }

        // 5) 纯文本
        if types.contains(.string), let text = pb.string(forType: .string), !text.isEmpty {
            clip.text = text
        }

        return clip
    }
}
