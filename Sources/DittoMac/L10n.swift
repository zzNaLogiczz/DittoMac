import Foundation

#if canImport(DittoMacKit)
import DittoMacKit
#endif

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

    /// 当前设置的语言(写入并广播;读取不触发通知)。
    /// 走 DittoSettings.defaults:便携模式下语言设置同样落在便携 plist
    static var lang: Lang {
        get { Lang(rawValue: DittoSettings.defaults.string(forKey: languageKey) ?? "") ?? .system }
        set {
            DittoSettings.defaults.set(newValue.rawValue, forKey: languageKey)
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

    // 多置顶子菜单(原版 Sticky Clips:Make Top/Last、Replace Top、Remove Sticky)
    static var menuStickySubmenu: String { t("置顶(Sticky)", "Sticky Clips") }
    static var menuStickySetTop: String { t("设为首位置顶", "Make Top Sticky") }
    static var menuStickySetLast: String { t("设为末位置顶", "Make Last Sticky") }
    static var menuStickyReplaceTop: String { t("替换首位置顶", "Replace Top Sticky") }
    static var menuStickyRemove: String { t("取消置顶", "Remove Sticky Setting") }
    static var menuFixupStickyOrder: String { t("修正置顶顺序", "Fixup Sticky Clip Order") }

    // 编辑 / 新建 / 对比(原版 Edit Clip / New Clip / Compare)
    static var menuEditClip: String { t("编辑条目…", "Edit Clip…") }
    static var menuNewClip: String { t("新建条目…", "New Clip…") }
    static var menuCompareClips: String { t("对比条目", "Compare Clips") }

    // 打包条目 / 二维码 / Google 翻译(原版 Export Clip(s) 包、View as QRCode、
    // Export to Google Translate;顺序对齐 CP_Main.rc:548-557)
    static var menuExportClipPackage: String { t("导出条目包…", "Export Clip Package…") }
    static var menuImportClipPackage: String { t("导入条目包…", "Import Clip Package…") }
    static var menuViewAsQRCode: String { t("查看二维码", "View as QRCode") }
    static var menuExportToTranslate: String { t("导出到 Google 翻译", "Export to Google Translate") }

    static var qrWindowTitle: String { t("二维码", "QR Code") }
    static var qrCopyImage: String { t("复制图片", "Copy Image") }
    static var qrCopied: String { t("已复制", "Copied") }
    static var qrTooLongTitle: String { t("文本过长,无法生成二维码", "Text too long for a QR code") }
    static func qrTooLongBody(_ limit: Int, _ actual: Int) -> String {
        t("二维码最多容纳约 \(limit) 个字符,当前 \(actual) 个。请缩短后重试。",
          "A QR code holds about \(limit) characters; this clip has \(actual). Shorten it and try again.")
    }
    static var translateTruncatedTitle: String { t("文本过长,将截断后翻译", "Text too long — it will be truncated") }
    static func translateTruncatedBody(_ limit: Int) -> String {
        t("仅前 \(limit) 个字符会发送到 Google 翻译。", "Only the first \(limit) characters will be sent to Google Translate.")
    }

    static var pkgExportDone: String { t("导出完成", "Export complete") }
    static var pkgInteropNote: String {
        t("注:与 Windows 版 Ditto 实际互导尚未实测。",
          "Note: interop with the Windows Ditto has not been verified yet.")
    }
    static var pkgExportFailed: String { t("导出失败", "Export failed") }
    static var pkgImportPrompt: String {
        t("选择 DittoMac 导出的 .dto 包文件", "Select a .dto package exported by DittoMac")
    }
    static var pkgImportFailed: String {
        t("导入失败:无法读取所选文件(可能不是有效的条目包)",
          "Import failed: could not read the file (it may not be a valid clip package)")
    }

    // 删除确认(原版 Prompt to Delete Clip)
    static var quickPromptDelete: String { t("删除条目前确认", "Prompt to Delete Clip") }
    static var dlgDeleteConfirmTitle: String { t("删除条目?", "Delete clip(s)?") }
    static func dlgDeleteConfirmBody(_ n: Int) -> String {
        t("将删除 \(n) 条条目,此操作不可撤销。", "\(n) clip(s) will be deleted. This cannot be undone.")
    }

    // 快速选项:排序方向 / 即输即搜(原版 Find As You Type)
    static var menuSortOrder: String { t("排序", "Sort Order") }
    static var menuSortLatestOnTop: String { t("最新在上", "Latest on Top") }
    static var menuSortLatestOnBottom: String { t("最新在下", "Latest on Bottom") }
    static var quickFindAsYouType: String { t("即输即搜", "Find As You Type") }

    // MARK: - 快速选项新增(透明度/字体/主题/折叠/标题栏位置/描述行/富文本/搜索/插入符)

    static var menuTransparency: String { t("透明度", "Transparency") }
    static var transparencyNone: String { t("无", "None") }
    static var menuFont: String { t("字体…", "Select Font…") }
    static var menuResetFont: String { t("重置字体", "Reset Font") }
    static var menuTheme: String { t("主题", "Theme") }
    static var themeFollowSystem: String { t("跟随系统", "Follow System") }
    static var themeImportFromFile: String { t("从文件导入…", "Import from File…") }
    static var dlgThemeImportFailed: String { t("主题导入失败", "Theme import failed") }
    static var menuAutoRollUp: String { t("失焦自动折叠", "Auto Roll-up") }
    static var menuCaptionPosition: String { t("标题栏位置", "Caption Bar On") }
    static var captionTop: String { t("上", "Top") }
    static var captionRight: String { t("右", "Right") }
    static var captionBottom: String { t("下", "Bottom") }
    static var captionLeft: String { t("左", "Left") }
    static var menuAlwaysShowDescription: String { t("始终显示描述", "Always Show Description") }
    static var menuDrawRtfText: String { t("绘制富文本内容", "Draw RTF Text") }
    static var menuSearch: String { t("搜索", "Search") }
    static var searchScopeLabel: String { t("范围", "Scope") }
    static var searchScopeFullText: String { t("全文", "Full Text") }
    static var searchScopeDescription: String { t("仅描述", "Description") }
    static var searchMethodLabel: String { t("方式", "Method") }
    static var searchMethodContains: String { t("包含", "Contains") }
    static var searchMethodWildcard: String { t("通配", "Wildcard") }
    static var searchMethodRegex: String { t("正则", "Regex") }
    static var menuAtCaret: String { t("插入符处", "At Caret") }

    // MARK: - 组(原版 Groups:树/移动/属性/热键)

    static var kindGroup: String { t("组", "Group") }
    static var menuNewGroup: String { t("新建组", "New Group") }
    static var menuNewGroupFromSelection: String { t("从选中新建组", "New Group from Selection") }
    static var menuMoveToGroup: String { t("移动到组", "Move to Group") }
    static var menuNewGroupEllipsis: String { t("新建组…", "New Group…") }
    static var menuOpenGroup: String { t("打开", "Open") }
    static var menuRenameGroup: String { t("重命名组…", "Rename Group…") }
    static var menuDeleteGroup: String { t("删除组…", "Delete Group…") }
    static var menuCopyToBuffer: String { t("复制(组间)", "Copy (between groups)") }
    static var menuCutToBuffer: String { t("剪切(组间)", "Cut (between groups)") }
    static var menuPasteIntoGroup: String { t("粘贴到当前组", "Paste into Current Group") }
    static var menuTopLevel: String { t("顶层(主列表)", "Top level (main list)") }
    static var groupTreePlaceholder: String { t("没有组", "No groups") }
    static var groupDefaultName: String { t("新建组", "New Group") }
    static var groupPromptTitle: String { t("新建组", "New Group") }
    static var groupPromptBody: String { t("输入组名:", "Enter group name:") }
    static var groupRenameTitle: String { t("重命名组", "Rename Group") }
    static var groupDeleteTitle: String { t("删除组?", "Delete group?") }
    static var groupDeleteBody: String {
        t("组内的条目与子组将移回上一层,不会丢失。",
          "Clips and sub-groups inside will be moved to the parent level — nothing is lost.")
    }
    static var groupMoveCycleAlert: String {
        t("不能把组移动到它自己或它的子组内", "A group cannot be moved into itself or its own sub-group")
    }
    static var quickShowGroupClips: String { t("主列表显示组内条目", "Show Clips that are in Groups in Main List") }
    static var quickPromptGroupName: String { t("新建组时提示输入名称", "Prompt For New Group Names") }
    static var menuRemoveHotKey: String { t("移除热键", "Remove Hot Key") }
    static var menuRemoveQuickPaste: String { t("移除快速粘贴文本", "Remove Quick Paste") }
    static var propsGroupNameLabel: String { t("名称", "Name") }
    static var propsGroupHotkeyLabel: String { t("组热键", "Group hot key") }
    static var propsGroupHotkeyGlobal: String { t("热键全局可用", "Hot key available globally") }
    static var propsGroupHotkeyClear: String { t("清除", "Clear") }
    static var propsGroupHotkeyHint: String {
        t("按一次打开该组;250ms 内按两次,把当前剪贴板直接存入该组。",
          "Press once to open the group; press twice within 250 ms to save the current clipboard into it.")
    }
    static var propsGroupSave: String { t("保存", "Save") }

    // 条目属性:标题 + 条目热键(原版 Properties:Item Title / Hot Key)
    static var propsTitleLabel: String { t("标题", "Item Title") }
    static var propsHotkeyLabel: String { t("热键", "Hot Key") }
    static var propsHotkeyGlobal: String { t("热键全局可用", "Hot key available globally") }
    static var propsHotkeyHint: String {
        t("按下热键 = 把该条目粘贴到当前应用(全局可用关闭时仅在面板在屏期间生效)。",
          "Press the hot key to paste this clip into the current app (unless global, effective only while the panel is visible).")
    }
    static var propsClipSave: String { t("保存", "Save") }

    // MARK: - 条目编辑器(原版 Edit Clip / New Clip)

    static var editorTitleEdit: String { t("编辑条目", "Edit Clip") }
    static var editorTitleNew: String { t("新建条目", "New Clip") }
    static var editorTabText: String { t("文本", "Text") }
    static var editorTabRTF: String { t("RTF", "RTF") }
    static var editorTabHTML: String { t("HTML", "HTML") }
    static var editorExtrasHeader: String { t("其他格式(只读)", "Other formats (read-only)") }
    static var editorNoExtras: String { t("(无附加格式)", "(no extra formats)") }
    static var editorSave: String { t("保存", "Save") }
    static var editorSaveAndPutBack: String { t("保存并放回剪贴板", "Save and Put on Clipboard") }
    static var editorClose: String { t("关闭", "Close") }
    static var editorEmptyNewClip: String {
        t("输入内容后保存;首次保存会在当前位置新建条目。",
          "Type something and save; the first save creates the clip here.")
    }
    static var editorSaveFailed: String { t("保存失败(至少保留一种格式)", "Save failed (at least one format must remain)") }
    static var editorNewClipEmpty: String { t("请先输入内容", "Type some content first") }

    // MARK: - 对比条目(原版 Compare)

    static var compareTitle: String { t("对比条目", "Compare Clips") }
    static var compareLeft: String { t("左侧条目", "Left clip") }
    static var compareRight: String { t("右侧条目", "Right clip") }
    static var compareDiffHeader: String { t("差异(红 = 删除,绿 = 新增)", "Diff (red = removed, green = added)") }
    static var compareNoText: String { t("(非文本条目,显示描述)", "(non-text clip; description shown)") }

    // MARK: - 删除剪贴板数据(原版 Delete Clip Data)

    static var deleteDataTitle: String { t("删除剪贴板数据", "Delete Clip Data") }
    static var deleteDataTitleContains: String { t("标题包含", "Title contains") }
    static var deleteDataCreatedRange: String { t("创建时间", "Created") }
    static var deleteDataLastUsedRange: String { t("上次使用", "Last used") }
    static var deleteDataFormat: String { t("格式", "Format") }
    static var deleteDataFormatAll: String { t("全部", "All") }
    static var deleteDataFormatExtra: String { t("附加格式", "Extra formats") }
    static var deleteDataSearch: String { t("搜索", "Search") }
    static var deleteDataColTitle: String { t("标题", "Title") }
    static var deleteDataColSize: String { t("大小", "Size") }
    static var deleteDataColCreated: String { t("创建时间", "Created") }
    static var deleteDataColLastUsed: String { t("上次使用", "Last used") }
    static var deleteDataNeverUsed: String { t("从未", "never") }
    static var deleteDataDbSize: String { t("数据库大小: ", "Database size: ") }
    static var deleteDataSelectedSize: String { t("已选大小: ", "Selected size: ") }
    static var deleteDataSelectedCount: String { t("已选数量: ", "Selected count: ") }
    static var deleteDataDeleteButton: String { t("删除所选…", "Delete Selected…") }
    static func deleteDataConfirmBody(_ n: Int) -> String {
        t("将删除 \(n) 条条目;置顶/永不删除/组条目会自动跳过。",
          "\(n) clip(s) will be deleted; sticky / never-delete / group entries are skipped automatically.")
    }
    static func deleteDataSkippedNote(_ n: Int) -> String {
        t("已跳过 \(n) 条受保护条目(置顶/永不删除/组)", "\(n) protected entrie(s) skipped (sticky / never delete / group)")
    }
    static var deleteDataNoResults: String { t("没有匹配的条目", "No matching clips") }

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

    // 统计(原版 Options→Statistics;设置入口 + 托盘 帮助→统计…)
    static var setStatsRowLabel: String { t("使用统计", "Usage stats") }
    static var setStatsButton: String { t("统计…", "Statistics…") }
    static var menuHelpRoot: String { t("帮助", "Help") }
    static var menuStats: String { t("统计…", "Statistics…") }
    static var statsWindowTitle: String { t("统计", "Statistics") }
    static var statsTotalCopies: String { t("累计复制:", "Total copies:") }
    static var statsTotalPastes: String { t("累计粘贴:", "Total pastes:") }
    static var statsSince: String { t("统计自:", "Since:") }
    static var statsSpanPrefix: String { t("已 ", "for ") }
    static var statsSpanSuffix: String { t(",D.H.M)", ", D.H.M)") }
    static var statsHint: String {
        t("复制与粘贴的累计计数,自首次启动本应用起累计。",
          "Cumulative copy/paste counters, kept since this app was first launched.")
    }

    // 高级(原版 Write debug to file)
    static var setSectionAdvanced: String { t("高级", "Advanced") }
    static var setWriteDebugLog: String { t("写调试日志到文件", "Write debug log to file") }
    static var setWriteDebugLogHint: String {
        t("性能事件与错误会追加到 logs/ditto-YYYYMMDD.log(超过 1MB 轮转,保留一份 .1)。",
          "Perf events and errors append to logs/ditto-YYYYMMDD.log (rotates past 1 MB, keeps one .1).")
    }

    // 捕获格式白名单(原版 Options → Supported Types)
    static var setSectionTypes: String { t("捕获格式", "Supported Types") }
    static var setTypesCaption: String {
        t("只记录下列格式;列表为空时将不记录任何内容",
          "Only the formats below are recorded; an empty list records nothing")
    }
    static var setTypesEmptyWarning: String {
        t("列表为空:将不记录任何内容", "Empty list: nothing will be recorded")
    }
    static var setTypesAdd: String { t("添加…", "Add…") }
    static var setTypesRemove: String { t("移除", "Remove") }
    static var setTypesSheetTitle: String { t("添加格式", "Add Type") }
    static var setTypesSheetHint: String {
        t("勾选当前剪贴板中存在的格式,或手动输入 UTI",
          "Check formats currently on the pasteboard, or type a UTI")
    }
    static var setTypesNoExtraTypes: String {
        t("当前剪贴板无其他格式,可手动输入 UTI",
          "No other formats on the pasteboard; you can type a UTI manually")
    }
    static var setTypesManualField: String { t("手动输入 UTI", "Manual UTI") }

    // 排除规则(原版 RegEx Filter + 应用包含/排除列表)
    static var setSectionExclude: String { t("排除规则", "Exclude") }
    static var setExcludeIncludeApps: String { t("仅记录这些应用", "Only record these apps") }
    static var setExcludeExcludeApps: String { t("不记录这些应用", "Never record these apps") }
    static var setExcludeAppsPlaceholder: String { t("Safari; Chrome* ; *Code", "Safari; Chrome* ; *Code") }
    static var setExcludeAppsHint: String {
        t("分号分隔,支持 * 和 ? 通配,大小写不敏感;两项均留空 = 记录所有应用",
          "Semicolon-separated; * and ? wildcards, case-insensitive; both empty = all apps")
    }
    static var setExcludeRegexCol: String { t("正则", "Regex") }
    static var setExcludeProcessCol: String { t("进程名", "Process") }
    static var setExcludeRuleHint: String {
        t("正则为整串匹配,子串请用 .*关键词.*;进程名留空 = 任意应用,支持 ; 分隔与通配",
          "Regex matches the whole string — use .*keyword.* for substrings; empty process = any app; semicolons and wildcards supported")
    }
    static var setExcludeMaxRules: String { t("最多 15 条规则", "Up to 15 rules") }

    // 热键录入控件
    static var recClickToSet: String { t("点击设置快捷键", "Click to set hot key") }
    static var recPressKeys: String { t("按下新的组合键…(Esc 取消)", "Press new combination… (Esc to cancel)") }
    static var recNeedModifier: String {
        t("需含 ⌘/⌥/⌃/⇧ 修饰键,或按 F 功能键", "Requires a ⌘/⌥/⌃/⇧ modifier or an F-key")
    }

    // MARK: - 复制缓冲(原版 Copy Buffers)

    static var setSectionCopyBuffers: String { t("复制缓冲", "Copy Buffers") }
    static func setCopyBufferName(_ n: Int) -> String { t("缓冲 \(n)", "Buffer \(n)") }
    static var setCopyBufferPaste: String { t("粘贴", "Paste") }
    static var setCopyBufferCopy: String { t("复制", "Copy") }
    static var setCopyBufferCut: String { t("剪切", "Cut") }
    static var setCopyBufferPlaySound: String { t("复制时播放提示音", "Play sound on copy") }
    static var setCopyBufferHint: String {
        t("复制热键:快照剪贴板 → 发 ⌘C → 内容入缓冲 → 恢复剪贴板;粘贴热键:把缓冲内容粘贴到当前应用。",
          "Copy hot key: snapshot the clipboard, send ⌘C, store the clip into the buffer, then restore; the paste hot key pastes the buffer into the current app.")
    }

    // MARK: - 应用按键串(原版 Custom Key Strokes)

    static var setSectionAppKeys: String { t("应用按键串", "Custom Key Strokes") }
    static var setAppKeysPatternCol: String { t("应用", "App") }
    static var setAppKeysPasteCol: String { t("粘贴串", "Paste string") }
    static var setAppKeysCopyCol: String { t("复制串", "Copy string") }
    static var setAppKeysCutCol: String { t("剪切串", "Cut string") }
    static var setAppKeysHint: String {
        t("按应用替换默认的 ⌘V/⌘C/⌘X。语法:^=⌃ %=⌥ +=⇧ @=⌘;字符直接输入;{ENTER} 等特殊键、{VKEY 键码}、{DELAY 毫秒}。应用支持 ; 分隔与 * ? 通配,匹配应用名或 Bundle ID。例:给终端把粘贴改成 ⌘V → @v",
          "Replaces the default ⌘V/⌘C/⌘X per app. Syntax: ^=Ctrl %=Alt +=Shift @=Cmd; plain characters type directly; {ENTER} and other special keys, {VKEY code}, {DELAY ms}. App patterns support ; separators and * ? wildcards, matching the app name or bundle ID. Example: paste as ⌘V for Terminal → @v")
    }

    // MARK: - 网络同步(原版 LAN CLIP SYNC / Friends:Server.cpp TCP 监听 + Send To)

    static var setSectionNetSync: String { t("网络同步", "Network Sync") }
    static var setNetReceiveEnabled: String { t("接收局域网发送的剪贴板", "Receive clips sent over the LAN") }
    static var setNetPort: String { t("端口", "Port") }
    static var setNetPassword: String { t("共享密码", "Shared password") }
    static var setNetPasswordHint: String {
        t("密码只存于钥匙串,双方一致时传输加密(AES-256);留空 = 明文传输。",
          "Stored only in the Keychain; when both sides match, transport is encrypted (AES-256); empty = plaintext.")
    }
    static var setNetFriendsCaption: String {
        t("好友列表(发送目标):条目右键「发送到」选择好友,全部选中条目经一次连接发出。",
          "Friends (send targets): right-click a clip and choose \"Send To\"; all selected clips go over one connection.")
    }
    static var setNetFriendNameCol: String { t("名称", "Name") }
    static var setNetFriendHostCol: String { t("主机", "Host") }
    static var setNetFriendPortCol: String { t("端口", "Port") }
    static var setNetFriendDefaultName: String { t("好友", "Friend") }
    static var menuSendTo: String { t("发送到", "Send To") }
    static var netSendDoneTitle: String { t("发送完成", "Sent") }
    static func netSendDoneBody(_ n: Int, _ name: String) -> String {
        t("已发送 \(n) 条条目到「\(name)」。", "Sent \(n) clip(s) to \"\(name)\".")
    }
    static var netSendFailedTitle: String { t("发送失败", "Send failed") }
    static func netSendFailedBody(_ host: String, _ port: Int) -> String {
        t("无法把条目发到 \(host):\(port)(对方未开接收、密码不一致或网络不可达)。",
          "Could not send clips to \(host):\(port) (receiving off, password mismatch, or unreachable).")
    }

    // MARK: - 窗口快捷键(原版 Quick Paste Keyboard 命令重绑定)

    static var setSectionWindowKeys: String { t("窗口快捷键", "Window Shortcuts") }
    static var setWindowKeysHint: String {
        t("快速粘贴窗口内命令的按键;清除 = 禁用该命令(「粘贴选中」必须始终有绑定)。",
          "Keys for commands inside the Quick Paste window; clear = disable the command (Paste Selected must always keep a binding).")
    }

    // 命令显示名(PanelCommand 注册表的 L10n 标签)
    static var cmdPasteSelected: String { t("粘贴选中", "Paste Selected") }
    static var cmdPastePlain: String { t("纯文本粘贴", "Paste Plain Text") }
    static var cmdProperties: String { t("属性", "Properties") }
    static var cmdFullDescription: String { t("完整描述", "Full Description") }
    static var cmdDeleteSelected: String { t("删除选中", "Delete Selected") }
    static var cmdMoveClipUp: String { t("条目上移", "Move Clip Up") }
    static var cmdMoveClipDown: String { t("条目下移", "Move Clip Down") }
    static var cmdMoveClipTop: String { t("条目移到顶部", "Move Clip to Top") }
    static var cmdMoveClipLast: String { t("条目移到底部", "Move Clip to Last") }
    static var cmdMakeTopSticky: String { t("设为首位置顶", "Make Top Sticky") }
    static var cmdMakeLastSticky: String { t("设为末位置顶", "Make Last Sticky") }
    static var cmdReplaceTopSticky: String { t("替换首位置顶", "Replace Top Sticky") }
    static var cmdRemoveSticky: String { t("取消置顶", "Remove Sticky") }
    static var cmdSelectAll: String { t("全选", "Select All") }
    static var cmdCopySelection: String { t("复制选中", "Copy Selection") }
    static var cmdRefresh: String { t("刷新", "Refresh") }
    static var cmdClearFilter: String { t("清除过滤", "Clear Filter") }
    static var cmdToggleOrder: String { t("切换排序方向", "Toggle Order") }
    static var cmdToggleSearchMethod: String { t("切换搜索方式", "Toggle Search Method") }
    static var cmdToggleAlwaysOnTop: String { t("常驻置顶", "Always on Top") }
    static var cmdShowGroupTree: String { t("显示组树", "Show Group Tree") }
    static var cmdNewGroup: String { t("新建组", "New Group") }
    static var cmdNewGroupFromSelection: String { t("从选中新建组", "New Group from Selection") }
    static var cmdCutClips: String { t("剪切条目(组间)", "Cut Clips (groups)") }
    static var cmdCopyClips: String { t("复制条目(组间)", "Copy Clips (groups)") }
    static var cmdPasteClips: String { t("粘贴条目(组间)", "Paste Clips (groups)") }
    static var cmdCloseWindow: String { t("关闭窗口", "Close Window") }
    static var cmdForceClose: String { t("强制关闭", "Force Close") }
    static var cmdRollUp: String { t("折叠窗口", "Roll Up") }
    static var cmdMaximize: String { t("最大化", "Maximize") }
    static func cmdPastePosition(_ n: Int) -> String { t("粘贴第 \(n) 条", "Paste Position \(n)") }
    static var cmdPasteDontReorder: String { t("粘贴(不改顺序)", "Paste, Don't Reorder") }

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

    // 格式列表(原版 Properties 的 "Saved Copy Data" + Delete Copy Data)
    static var propsFormatsHeader: String { t("格式", "Formats") }
    static var propsFormatDelete: String { t("删除所选格式…", "Delete Selected Formats…") }
    static var propsFormatDeleteConfirmTitle: String { t("删除所选格式?", "Delete the selected formats?") }
    static var propsFormatDeleteConfirmBody: String {
        t("删除后不可撤销。", "This cannot be undone.")
    }
    static var propsKeepOneFormat: String {
        t("至少保留一种格式", "At least one format must remain")
    }
    static var propsNoFormats: String { t("(无格式数据)", "(no format data)") }

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
