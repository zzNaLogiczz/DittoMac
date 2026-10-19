import Foundation
import AppKit
import Carbon.HIToolbox
import DittoMacKit
import os.log

// MARK: - 窗口命令注册表的本地化标签(L10n 在应用层;注册表本体在 DittoMacKit)

extension PanelCommand {
    /// 设置页「窗口快捷键」表里显示的命令名(随语言即时切换)
    var displayName: String {
        switch self {
        case .pasteSelected: return L10n.cmdPasteSelected
        case .pastePlain: return L10n.cmdPastePlain
        case .properties: return L10n.cmdProperties
        case .fullDescription: return L10n.cmdFullDescription
        case .deleteSelected: return L10n.cmdDeleteSelected
        case .moveClipUp: return L10n.cmdMoveClipUp
        case .moveClipDown: return L10n.cmdMoveClipDown
        case .moveClipTop: return L10n.cmdMoveClipTop
        case .moveClipLast: return L10n.cmdMoveClipLast
        case .makeTopSticky: return L10n.cmdMakeTopSticky
        case .makeLastSticky: return L10n.cmdMakeLastSticky
        case .replaceTopSticky: return L10n.cmdReplaceTopSticky
        case .removeSticky: return L10n.cmdRemoveSticky
        case .selectAll: return L10n.cmdSelectAll
        case .copySelection: return L10n.cmdCopySelection
        case .refresh: return L10n.cmdRefresh
        case .clearFilter: return L10n.cmdClearFilter
        case .toggleOrder: return L10n.cmdToggleOrder
        case .toggleSearchMethod: return L10n.cmdToggleSearchMethod
        case .toggleAlwaysOnTop: return L10n.cmdToggleAlwaysOnTop
        case .showGroupTree: return L10n.cmdShowGroupTree
        case .newGroup: return L10n.cmdNewGroup
        case .newGroupFromSelection: return L10n.cmdNewGroupFromSelection
        case .cutClips: return L10n.cmdCutClips
        case .copyClips: return L10n.cmdCopyClips
        case .pasteClips: return L10n.cmdPasteClips
        case .closeWindow: return L10n.cmdCloseWindow
        case .forceClose: return L10n.cmdForceClose
        case .rollUp: return L10n.cmdRollUp
        case .maximize: return L10n.cmdMaximize
        case .pastePosition1: return L10n.cmdPastePosition(1)
        case .pastePosition2: return L10n.cmdPastePosition(2)
        case .pastePosition3: return L10n.cmdPastePosition(3)
        case .pastePosition4: return L10n.cmdPastePosition(4)
        case .pastePosition5: return L10n.cmdPastePosition(5)
        case .pastePosition6: return L10n.cmdPastePosition(6)
        case .pastePosition7: return L10n.cmdPastePosition(7)
        case .pastePosition8: return L10n.cmdPastePosition(8)
        case .pastePosition9: return L10n.cmdPastePosition(9)
        case .pastePosition10: return L10n.cmdPastePosition(10)
        case .pasteDontReorder: return L10n.cmdPasteDontReorder
        }
    }
}

/// 性能埋点:DITTO_STDOUT=1 时打 stdout(regress.sh 用),否则 os_log;
/// 「写调试日志到文件」开启时同时落 logs/ditto-YYYYMMDD.log(FileLog)
enum PerfLog {
    private static let stdoutMode = ProcessInfo.processInfo.environment["DITTO_STDOUT"] != nil
    private static let logger = Logger(subsystem: "local.dittomac.app", category: "perf")

    static func event(_ name: String, _ detail: String = "") {
        let ts = String(format: "%.3f", Date().timeIntervalSince1970)
        if stdoutMode {
            print("\(name) \(ts) \(detail)")
            fflush(stdout)
        } else {
            logger.info("\(name, privacy: .public) \(detail, privacy: .public)")
        }
        FileLog.shared?.append("PERF \(name) \(ts) \(detail)")
    }
}

/// 轻量格式化工具(相对时间 / 字节 / 类型图标与名称 / 热键显示)
enum Fmt {

    private static let calendar = Calendar.current

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 刚刚/N分钟前…(中英,随 L10n 即时切换)
    static func relativeTime(_ date: Date) -> String {
        let now = Date()
        let sec = Int(now.timeIntervalSince(date))
        if sec < 60 { return L10n.timeJustNow }
        if sec < 3600 { return L10n.timeMinutesAgo(sec / 60) }
        if sec < 86_400 { return L10n.timeHoursAgo(sec / 3600) }
        if calendar.isDateInYesterday(date) {
            return L10n.timeYesterday + " " + timeFormatter.string(from: date)
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return monthFormatter.string(from: date)
        }
        return yearFormatter.string(from: date)
    }

    /// B 整数显示;KB / MB 一位小数
    static func bytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        let kb = Double(n) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }

    /// ClipKind → SF Symbol 名称
    static func symbol(for kind: ClipKind) -> String {
        switch kind {
        case .text: return "doc.plaintext"
        case .rtf: return "doc.richtext"
        case .html: return "safari"
        case .image: return "photo"
        case .files: return "folder"
        case .group: return "folder.fill"
        case .unknown: return "doc"
        }
    }

    /// ClipKind → 本地化名(随 L10n)
    static func kindLabel(for kind: ClipKind) -> String {
        switch kind {
        case .text: return L10n.kindText
        case .rtf: return L10n.kindRTF
        case .html: return L10n.kindHTML
        case .image: return L10n.kindImage
        case .files: return L10n.kindFiles
        case .group: return L10n.kindGroup
        case .unknown: return L10n.kindUnknown
        }
    }

    // MARK: - 热键显示(设置录入控件与菜单标题共用)

    /// Carbon 键码+修饰掩码 → 显示串,如 "⇧⌘V" / "F6"(修饰键按 Apple 标准顺序 ⌃⌥⇧⌘)
    static func hotKeyString(code: UInt32, mods: UInt) -> String {
        modifierSymbols(mods).joined() + keyName(code)
    }

    /// 修饰键符号,按 macOS 菜单与 HIG 的标准顺序排列
    static func modifierSymbols(_ mods: UInt) -> [String] {
        var result: [String] = []
        if mods & UInt(controlKey) != 0 { result.append("⌃") }
        if mods & UInt(optionKey) != 0 { result.append("⌥") }
        if mods & UInt(shiftKey) != 0 { result.append("⇧") }
        if mods & UInt(cmdKey) != 0 { result.append("⌘") }
        return result
    }

    /// 常用 Carbon 键码 → 显示名
    static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
            27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc",
            117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
            115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
            109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        ]
        return names[code] ?? "Key(\(code))"
    }
}
