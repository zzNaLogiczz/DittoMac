import Foundation

/// 应用内国际化:中/英完整文案,支持设置里即时切换(无需重启)。
/// 每个文案内联双语(而非 key+字典),编译器保证永不缺译;
/// "跟随系统"按系统首选语言解析。
enum L10n {

    enum Lang: String, CaseIterable {
        case system   // 跟随系统
        case zh
        case en

        var displayName: String {
            switch self {
            case .system: return L10n.setFollowSystem
            case .zh: return "中文"
            case .en: return "English"
            }
        }
    }

    static let languageKey = "ditto.language"
    /// 语言切换通知(收到方即时重建 UI)
    static let changedNotification = Notification.Name("ditto.languageChanged")

    /// 当前设置的语言(写入并广播;读取不触发通知)
    static var lang: Lang {
        get { Lang(rawValue: UserDefaults.standard.string(forKey: languageKey) ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: languageKey)
            NotificationCenter.default.post(name: changedNotification, object: nil)
        }
    }

    /// 实际生效是否中文:.zh 强制中文,.en 强制英文,.system 按系统首选
    static var isChinese: Bool {
        switch lang {
        case .zh: return true
        case .en: return false
        case .system: return Locale.preferredLanguages.first?.hasPrefix("zh") == true
        }
    }

    /// 取词:文案属性统一走此入口
    static func t(_ zh: String, _ en: String) -> String { isChinese ? zh : en }

    // MARK: - 托盘与系统菜单

    static var menuShowQuickPaste: String { t("显示快速粘贴窗口", "Show Quick Paste") }
    static var menuOptions: String { t("选项…", "Options…") }
    static var menuStartupMessage: String { t("显示启动消息", "Show Startup Message") }
    static var menuGlobalHotKeys: String { t("全局热键…", "Global Hot Keys…") }
    static var menuClearClipData: String { t("清空剪贴板数据…", "Delete Clip Data…") }
    static var menuBackup: String { t("备份数据库…", "Backup Database…") }
    static var menuRestore: String { t("恢复数据库…", "Restore Database…") }
    static var menuImportClips: String { t("导入剪贴(文本文件)…", "Import Clip(s)…") }
    static var menuHelp: String { t("帮助…", "Help…") }
    static var menuConnectClipboard: String { t("连接剪贴板", "Connect to Clipboard") }
    static var menuSaveCurrentClip: String { t("保存当前剪贴板", "Save Current Clipboard") }
    static var menuExit: String { t("退出", "Exit") }
    static var menuQuickOptions: String { t("快速选项", "Quick Options") }
    static var menuLinesPerClip: String { t("每条行数", "Lines Per Clip") }
    static var menuPositioning: String { t("出现位置", "Positioning") }
    static var menuAtCursor: String { t("光标处", "At Cursor") }
    static var menuAtPrevious: String { t("上次位置", "At Previous") }
    static var menuAlwaysOnTop: String { t("常驻置顶", "Always on Top") }
    static var menuOpenHistory: String { t("打开历史", "Open History") }
    static var menuPause: String { t("暂停记录", "Pause Recording") }
    static var menuSettings: String { t("设置…", "Settings…") }

    // MARK: - 弹窗

    static var dlgOk: String { t("好", "OK") }
    static var dlgCancel: String { t("取消", "Cancel") }
    static var dlgClear: String { t("清空", "Clear") }

    static var dlgStartupTitle: String { t("DittoMac 正在菜单栏运行", "DittoMac is running in the menu bar") }
    static var dlgStartupBody: String {
        t("点击菜单栏图标或按全局热键(默认 ⌘⇧V)打开快速粘贴窗口。\n回车粘贴 / ⇧回车纯文本 / ⌥回车属性 / ⌘1..0 快选前十条 / Esc 关闭。",
          "Click the menu bar icon or press the global hot key (default ⌘⇧V) to open the Quick Paste window.\nEnter paste / ⇧Enter plain text / ⌥Enter properties / ⌘1..0 first ten / Esc close.")
    }
    static var dlgHelpTitle: String { t("DittoMac 快捷键", "DittoMac Shortcuts") }
    static var dlgHelpBody: String {
        t("Enter 粘贴 · ⇧Enter 纯文本粘贴 · ⌥Enter 属性 · 双击 粘贴\nEsc 三级退出(浮窗→清过滤→关窗) · ⇧Esc 强制关窗\nF3 完整描述 · N/P 上下一条 · F5 刷新 · ⌥C 清过滤\n⌘C 复制选中 · ⌘A 全选 · ⌘1..0 粘贴第 1-10 条\n⌃Space 常驻置顶 · 列表打字直接搜索 · Delete 删除条目",
          "Enter paste · ⇧Enter plain text · ⌥Enter properties · Double-click paste\nEsc 3-level dismiss (tooltip → clear filter → close) · ⇧Esc force close\nF3 full description · N/P next/prev · F5 refresh · ⌥C clear filter\n⌘C copy selected · ⌘A select all · ⌘1..0 paste items 1-10\n⌃Space always-on-top · type to search · Delete entry")
    }
    static var dlgClearTitle: String { t("清空历史?", "Clear history?") }
    static var dlgClearBody: String {
        t("将删除全部未置顶的条目,此操作不可撤销。",
          "All unpinned entries will be deleted. This cannot be undone.")
    }
    static var dlgDbRebuiltTitle: String { t("剪贴板历史数据库已重建", "Clipboard history database was rebuilt") }
    static var dlgDbRebuiltBody: String {
        t("原数据库疑似损坏,已自动备份到:\n", "The old database appeared corrupt and was backed up to:\n")
    }
    static var dlgBackupDone: String { t("备份完成", "Backup complete") }
    static var dlgBackupFailed: String { t("备份失败", "Backup failed") }
    static var dlgRestorePrompt: String {
        t("选择 DittoMac 备份的 .sqlite 文件(将替换当前历史并重启)",
          "Select a DittoMac backup .sqlite file (replaces current history and restarts)")
    }
    static var dlgRestoredTitle: String { t("已恢复,即将重启应用", "Restored. The app will restart.") }
    static var dlgRestoreFailed: String { t("恢复失败:", "Restore failed:") }
    static var hotkeyConflictSuffix: String {
        t("⚠️ 热键被其他应用占用,请到设置更换", "⚠️ Hot key is taken by another app — change it in Settings")
    }

    // MARK: - 辅助功能引导

    static var axStartupTitle: String { t("粘贴回需要辅助功能权限", "Accessibility permission needed for paste-back") }
    static var axPasteTitle: String { t("本次仅复制到剪贴板", "Copied to clipboard only") }
    static var axBody: String {
        t("模拟 ⌘V 把内容粘贴到原位置需要\"辅助功能\"权限。\n当前未授权,所以双击/回车只把内容放进了剪贴板,需要手动 ⌘V。\n(每次重新构建/覆盖安装后,系统可能要求重新授权)",
          "Simulating ⌘V to paste at the original location requires the Accessibility permission.\nIt is not granted yet, so Enter/double-click only copies to the clipboard — press ⌘V manually.\n(The system may require re-granting after each rebuild/reinstall.)")
    }
    static var btnOpenSettings: String { t("打开系统设置", "Open System Settings") }
    static var btnLater: String { t("稍后", "Later") }
    static var axDontAsk: String {
        t("不再提示(可在设置中查看状态)", "Don't ask again (status visible in Settings)")
    }

    // MARK: - 面板

    static var tagPinned: String { t("置顶", "Top") }
    static var tagDisconnected: String { t("断开", "Off") }
    static var emptyList: String { t("没有匹配的条目", "No matching clips") }
    static var descWindowTitle: String { t("完整描述", "Full Description") }
    static var noTextPlaceholder: String { t("(无文本)", "(no text)") }
    static var searchPlaceholder: String { t("搜索", "Search") }

    // MARK: - 列表右键菜单(原版英文命名的变换项保留原文,与 upstream 菜单对齐)

    static var menuViewFullDesc: String { t("查看完整描述", "View Full Description") }
    static var menuSpecialPaste: String { t("特殊粘贴", "Special Paste") }
    static var menuPastePlain: String { t("仅粘贴纯文本", "Plain Text Only") }
    static var menuPasteNoReorder: String { t("粘贴(不改剪贴顺序)", "Paste, Don't Change Clip Order") }
    static var menuFilterOnClip: String { t("以此条过滤列表", "Filter on Selected Clip") }
    static var menuDeleteEntry: String { t("删除条目", "Delete Entry") }
    static var menuProperties: String { t("属性", "Properties") }
    static var menuQuickProps: String { t("快速属性", "Quick Properties") }
    static var menuNeverDelete: String { t("永不自动删除", "Never Auto Delete") }
    static var menuAutoDelete: String { t("允许自动删除", "Auto Delete") }
    static var menuClipOrder: String { t("条目顺序", "Clip Order") }
    static var menuSticky: String { t("置顶(Sticky)", "Make Sticky") }
    static var menuUnsticky: String { t("取消置顶", "Remove Sticky") }
    static var menuImportExport: String { t("导入/导出", "Import/Export") }
    static var menuImportFromFiles: String { t("导入剪贴(文本文件)", "Import Clip(s) from text files") }
    static var menuExportText: String { t("导出为文本文件", "Export to Text File") }
    static var importedAppName: String { t("导入", "Imported") }

    // MARK: - 设置

    static var settingsTitle: String { t("设置", "Settings") }
    static var setSectionRecording: String { t("录制", "Recording") }
    static var setSectionShortcuts: String { t("快捷键", "Shortcuts") }
    static var setSectionBehavior: String { t("行为", "Behavior") }
    static var setSectionPrivacy: String { t("权限与数据", "Permissions & Data") }
    static var setKeepCount: String { t("保留条数", "Keep entries") }
    static var setKeepDays: String { t("保留天数", "Keep days") }
    static var setSizeLimit: String { t("单条上限", "Max item size") }
    static var setGlobalHotkey: String { t("全局热键", "Global hot key") }
    static var setLinesPerRow: String { t("每条行数", "Lines per row") }
    static var setPosition: String { t("出现位置", "Position") }
    static var setLanguage: String { t("语言", "Language") }
    static var setFollowSystem: String { t("跟随系统", "Follow System") }
    static var setLaunchAtLogin: String { t("登录时自动启动", "Launch at login") }
    static var setAccessibility: String { t("辅助功能", "Accessibility") }
    static var setGranted: String { t("已授权", "Granted") }
    static var setNotGranted: String { t("未授权(粘贴回原 App 需要此权限)", "Not granted (needed for paste-back)") }
    static var setResetHotkey: String { t("恢复默认", "Reset") }
    static var setDaysUnit: String { t("天", "days") }
    static var setLinesUnit: String { t("行", "lines") }

    // 热键录入控件
    static var recClickToSet: String { t("点击设置快捷键", "Click to set hot key") }
    static var recPressKeys: String { t("按下新的组合键…(Esc 取消)", "Press new combination… (Esc to cancel)") }
    static var recNeedModifier: String {
        t("需含 ⌘/⌥/⌃/⇧ 修饰键,或按 F 功能键", "Requires a ⌘/⌥/⌃/⇧ modifier or an F-key")
    }

    // MARK: - 属性窗口

    static var propsTitle: String { t("条目属性", "Clip Properties") }
    static var propsCopyFull: String { t("复制全文", "Copy All") }
    static var propsClose: String { t("关闭", "Close") }
    static var propsPlainRef: String { t("纯文本对照", "Plain text") }
    static var propsNoText: String { t("无文本内容", "No text content") }
    static var propsNoFiles: String { t("无文件路径", "No file paths") }
    static var propsNoImage: String { t("无图片数据或解码失败", "No image data or decoding failed") }
    static var propsRenderFailed: String { t("渲染失败或无数据", "Render failed or no data") }
    static var propsEmpty: String { t("(空)", "(empty)") }

    // MARK: - 时间与类型(Fmt / metaLine)

    static var timeJustNow: String { t("刚刚", "Just now") }
    static func timeMinutesAgo(_ n: Int) -> String { t("\(n) 分钟前", "\(n)m ago") }
    static func timeHoursAgo(_ n: Int) -> String { t("\(n) 小时前", "\(n)h ago") }
    static var timeYesterday: String { t("昨天", "Yesterday") }
    static var metaAdded: String { t("添加: ", "Added: ") }
    static var metaLastUsed: String { t("上次使用: ", "Last used: ") }
    static var metaNeverPasted: String { t("从未粘贴", "Never pasted") }
    static var metaNeverDelete: String { t("永不自动删除", "Never auto delete") }
    static var metaSticky: String { t("置顶", "Sticky") }
    static var kindText: String { t("纯文本", "Text") }
    static var kindRTF: String { t("富文本", "Rich Text") }
    static var kindHTML: String { t("网页", "HTML") }
    static var kindImage: String { t("图片", "Image") }
    static var kindFiles: String { t("文件", "Files") }
    static var kindUnknown: String { t("未知", "Unknown") }
}
