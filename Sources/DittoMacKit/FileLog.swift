import Foundation

// MARK: - 调试日志落盘(原版 "Write debug to file",Options → 高级开关)
//
// 开启后 PerfLog 事件与 ClipStore/monitor 的错误同时追加到
// <appSupport-or-portable>/logs/ditto-YYYYMMDD.log:逐行带时间戳、逐行 flush;
// 单文件超过 1MB 轮转为 .1(仅保留一代,上游滚动日志同款保守策略)。

/// 错误诊断汇聚点:kit 内各处错误(原 os_log)同时转发到此处。
/// FileLog 开启时 sink 指向文件;关闭时 sink = nil(零开销)
public enum DiagLog {
    /// 文件日志注入点(FileLog.install 设置;测试/关闭时为 nil)
    public static var sink: ((String) -> Void)?

    public static func error(_ message: String) {
        sink?(message)
    }
}

/// 按天分文件 + 大小轮转的追加式日志
public final class FileLog {

    /// 超过该字节数轮转(>1MB → .1)
    public static let rotateThresholdBytes = 1_000_000

    private let directory: URL
    private let fileManager: FileManager
    private let dateProvider: () -> Date
    private let queue = DispatchQueue(label: "DittoMacKit.FileLog")
    /// 当前打开的文件句柄 + 对应文件名(按天切换时重开)
    private var handle: FileHandle?
    private var currentFileName: String?

    /// - Parameters:
    ///   - directory: 日志目录(调用方保证已创建;未创建则写入静默失败)
    ///   - dateProvider: 注入时钟(测试用固定日期验证按天分文件/轮转名)
    public init(directory: URL, fileManager: FileManager = .default, dateProvider: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.fileManager = fileManager
        self.dateProvider = dateProvider
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - 单例装配(app 层调用)

    /// 共享实例:设置开关打开时由 PerfLog 侧装配,关闭时卸载
    public static var shared: FileLog?

    /// 按设置开关装配/卸载共享实例(sink 同时挂到 DiagLog)
    public static func setEnabled(_ enabled: Bool, directory: URL) {
        if enabled {
            let log = FileLog(directory: directory)
            shared = log
            DiagLog.sink = { line in log.append(line) }
        } else {
            shared = nil
            DiagLog.sink = nil
        }
    }

    // MARK: - 写入

    /// 追加一行(自动带时间戳前缀;逐行 flush)
    public func append(_ line: String) {
        queue.sync {
            let stamp = Self.lineFormatter.string(from: dateProvider())
            let data = Data("\(stamp) \(line)\n".utf8)
            rotateIfNeeded(appending: data.count)
            if handle == nil, !openCurrentFile() { return }   // 目录不可写等 → 静默丢弃
            handle?.write(data)
            handle?.synchronizeFile()   // 逐行 flush(崩溃也不丢已写行)
        }
    }

    /// 强制关闭句柄(测试与进程收尾用)
    public func close() {
        queue.sync {
            try? handle?.close()
            handle = nil
            currentFileName = nil
        }
    }

    // MARK: - 文件管理

    private static let fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let lineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func fileName(for date: Date) -> String {
        "ditto-\(Self.fileFormatter.string(from: date)).log"
    }

    /// 打开(或按天切换)当前日志文件;失败返回 false
    private func openCurrentFile() -> Bool {
        let name = fileName(for: dateProvider())
        if name == currentFileName, handle != nil { return true }
        try? handle?.close()
        let url = directory.appendingPathComponent(name)
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                handle = nil
                currentFileName = nil
                return false
            }
        }
        guard let h = FileHandle(forWritingAtPath: url.path) else {
            handle = nil
            currentFileName = nil
            return false
        }
        // 追加模式:跳到末尾(FileHandle(forWritingAtPath:) 定位在 0)
        _ = try? h.seekToEnd()
        handle = h
        currentFileName = name
        return true
    }

    /// 当前文件超过阈值 → 改名为 .1(旧的 .1 先删;只保留一代)
    private func rotateIfNeeded(appending bytes: Int) {
        let name = fileName(for: dateProvider())
        let url = directory.appendingPathComponent(name)
        // 跨天:直接关句柄,下次 append 落新文件
        if name != currentFileName, handle != nil {
            try? handle?.close()
            handle = nil
            currentFileName = nil
        }
        guard let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size + bytes > Self.rotateThresholdBytes else { return }
        try? handle?.close()
        handle = nil
        currentFileName = nil
        let rotated = directory.appendingPathComponent(name + ".1")
        if fileManager.fileExists(atPath: rotated.path) {
            try? fileManager.removeItem(at: rotated)
        }
        try? fileManager.moveItem(at: url, to: rotated)
    }
}

// MARK: - 设置键(高级开关,默认关)

public extension DittoSettings {
    /// 写调试日志到文件(原版 "Write debug to file";默认关)
    static let writeDebugLogFileKey = "ditto.writeDebugLogFile"

    static func writeDebugLogFile() -> Bool {
        defaults.bool(forKey: writeDebugLogFileKey)
    }

    static func setWriteDebugLogFile(_ on: Bool) {
        defaults.set(on, forKey: writeDebugLogFileKey)
    }
}
