import Foundation

// MARK: - 便携模式(原版 GetIsPortableDitto,Options.cpp:1957-1960 + 200-227 标记文件检测)
//
// 上游在 exe 同目录发现 "portable" 标记文件时,m_portable = true,数据库/ini/主题/
// 日志全部改落在 exe 所在目录。macOS 等价:应用 bundle 旁存在 `DittoMac.portable`
// 标记文件 → 便携根 = bundle 所在目录,数据全部落 <root>/DittoMac/:
//   数据库  <root>/DittoMac/ditto.sqlite
//   主题    <root>/DittoMac/Themes/
//   日志    <root>/DittoMac/logs/
//   设置    <root>/DittoMac/settings.plist(UserDefaults suite,见 bootstrap)

/// 便携模式路径解析:纯函数核心 + 一次性 bootstrap。
/// resolvedRoot 在进程内 set-once —— main.swift 里任何 DittoSettings 读取之前调用
/// bootstrap;测试可用 configureForTesting 注入/复位(不落盘、不碰 Bundle)。
public enum PortableMode {

    /// 标记文件名(上游用无扩展名的 "portable";此处带应用名避免与用户文件撞名)
    public static let markerFileName = "DittoMac.portable"

    /// 已生效的便携根(未进入便携模式 = nil)。bootstrap 设置;测试可改写
    public private(set) static var resolvedRoot: URL?

    /// 纯解析:标记存在 → 便携根 = 可执行目录;否则 nil。
    /// (markerExists + bundleURL 进,base 目录出 —— 与文件系统解耦便于单测)
    public static func portableRoot(markerExists: Bool, bundleURL: URL) -> URL? {
        guard markerExists else { return nil }
        // bundleURL.deletingLastPathComponent() = bundle 所在目录(bundle 自身算一段)
        return bundleURL.deletingLastPathComponent()
    }

    /// 纯解析:数据基目录。便携 → <root>/DittoMac;常规 → ~/Library/Application Support/DittoMac
    public static func baseDirectory(portableRoot: URL?) -> URL {
        if let portableRoot {
            return portableRoot.appendingPathComponent("DittoMac", isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DittoMac", isDirectory: true)
    }

    /// 基目录下的子目录(主题/日志)与数据库路径(便携与常规共用同一相对布局)
    public static func themesDirectory(base: URL) -> URL { base.appendingPathComponent("Themes", isDirectory: true) }
    public static func logsDirectory(base: URL) -> URL { base.appendingPathComponent("logs", isDirectory: true) }
    public static func databaseURL(base: URL) -> URL { base.appendingPathComponent("ditto.sqlite") }
    /// 设置 plist(便携模式的 UserDefaults suite 落盘位置)
    public static func settingsPlistURL(base: URL) -> URL { base.appendingPathComponent("settings.plist") }

    // MARK: - 运行时入口(main.swift 引导;任何 DittoSettings 读取之前)

    /// 检测标记并落地:设置 resolvedRoot、建目录、把 DittoSettings 切到便携 suite。
    /// 返回是否进入了便携模式。幂等(重复调用只做一次实际切换)
    @discardableResult
    public static func bootstrap(bundleURL: URL, fileManager: FileManager = .default) -> Bool {
        guard resolvedRoot == nil else { return true }
        let marker = bundleURL.deletingLastPathComponent().appendingPathComponent(markerFileName)
        guard fileManager.fileExists(atPath: marker.path) else { return false }

        let root = bundleURL.deletingLastPathComponent()
        resolvedRoot = root
        let base = baseDirectory(portableRoot: root)
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: themesDirectory(base: base), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: logsDirectory(base: base), withIntermediateDirectories: true)

        // 设置切到便携 suite:suiteName 直接给 plist 绝对路径,UserDefaults 会把
        // 该文件当持久域使用(读写都走它,不再碰 ~/Library/Preferences)
        let suite = UserDefaults(suiteName: settingsPlistURL(base: base).path)
        DittoSettings.defaults = suite ?? .standard
        return true
    }

    /// 当前数据基目录(便携已引导 → 便携根下;否则 Application Support)
    public static var currentBaseDirectory: URL { baseDirectory(portableRoot: resolvedRoot) }

    /// 当前数据库默认路径(ClipStore(path: nil) 用)
    public static var defaultDatabasePath: String { databaseURL(base: currentBaseDirectory).path }

    /// 当前日志目录(FileLog 用)
    public static var currentLogsDirectory: URL { logsDirectory(base: currentBaseDirectory) }

    /// 便携模式下禁用"登录时启动"注册(SMAppService 只对装在 /Applications 的
    /// bundle 有意义,便携目录里的副本注册了也找不到;上游 portable 同样跳过)
    public static var isPortable: Bool { resolvedRoot != nil }

    /// 测试注入口:直接设置/复位便携根(绕过 marker 检测与 DittoSettings 切换;
    /// 单测验证 ClipStore(path: nil) 的便携落盘用)
    static func setResolvedRootForTesting(_ root: URL?) {
        resolvedRoot = root
    }
}
