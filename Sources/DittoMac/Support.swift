import Foundation
import AppKit
import Carbon.HIToolbox
import DittoMacKit
import os.log

/// 性能埋点:DITTO_STDOUT=1 时打 stdout(regress.sh 用),否则 os_log
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

    /// 刚刚 / N分钟前 / N小时前 / 昨天 HH:mm / MM-dd HH:mm / yyyy-MM-dd
    static func relativeTime(_ date: Date) -> String {
        let now = Date()
        let sec = Int(now.timeIntervalSince(date))
        if sec < 60 { return "刚刚" }
        if sec < 3600 { return "\(sec / 60) 分钟前" }
        if sec < 86_400 { return "\(sec / 3600) 小时前" }
        if calendar.isDateInYesterday(date) {
            return "昨天 " + timeFormatter.string(from: date)
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
        case .unknown: return "doc"
        }
    }

    /// ClipKind → 中文名
    static func kindLabel(for kind: ClipKind) -> String {
        switch kind {
        case .text: return "纯文本"
        case .rtf: return "富文本"
        case .html: return "网页"
        case .image: return "图片"
        case .files: return "文件"
        case .unknown: return "未知"
        }
    }

    // MARK: - 热键显示(设置录入控件与菜单标题共用)

    /// Carbon 键码+修饰掩码 → 显示串,如 "⌘⇧V" / "F6"
    static func hotKeyString(code: UInt32, mods: UInt) -> String {
        var result = ""
        if mods & UInt(cmdKey) != 0 { result += "⌘" }
        if mods & UInt(controlKey) != 0 { result += "⌃" }
        if mods & UInt(optionKey) != 0 { result += "⌥" }
        if mods & UInt(shiftKey) != 0 { result += "⇧" }
        return result + keyName(code)
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
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
            109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        ]
        return names[code] ?? "Key(\(code))"
    }
}
