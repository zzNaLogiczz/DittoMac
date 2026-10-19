import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// 按键串:原版 SendKeys(CSendKeys,上游 src/SendKeys.cpp)语法的 macOS 移植。
///
/// 语法(对照上游 SendKeys.cpp:486-670 的解析循环):
/// - 修饰键前缀(只对其后的下一个按键生效,随后复位——上游 PopUpShiftKeys 语义):
///   `^` = Ctrl(⌃)、`%` = Alt(⌥)、`+` = Shift(⇧)、`@` = Win → 映射为 Command(⌘)
///   (macOS 无 Win 键;文档化映射,同上游 wiki Custom Key Strokes 的说明)
/// - `~` = 回车(同 `{ENTER}`)
/// - 普通字符按美式键盘布局转键码逐个击键(大写/符号自动附加 ⇧);非 ASCII 字符走
///   Unicode 注入(CGEventKeyboardSetUnicodeString)
/// - `{TOKEN}` 特殊键(大小写不敏感):ENTER/RETURN/TAB/ESC/BACKSPACE/BS/DELETE/DEL/
///   HOME/END/PGUP/PGDN/UP/DOWN/LEFT/RIGHT/INSERT/HELP/CAPSLOCK/NUMLOCK/SCROLLLOCK/PRTSC/
///   F1…F16/ADD/SUBTRACT/MULTIPLY/DIVIDE(小键盘)/PLUS/AT/CARET/TILDE/LEFTBRACE/RIGHTBRACE/
///   LEFTPAREN/RIGHTPAREN/PERCENT/LWIN/RWIN(→ 左右 ⌘)/APPS
/// - `{TOKEN n}` = 该键重复 n 次(上游的次数后缀,SendKeys.cpp:609-622)
/// - `{VKEY n}` = 原始虚拟键码(Windows 的 VK_ 值在此直接作为 macOS CGKeyCode 使用;
///   文档化映射:跨平台写法如 {VKEY 86} 不再等于字母 V,按 macOS 键码表理解)
/// - `{DELAY n}` = 立即睡眠 n 毫秒;`{DELAY =n}` = 之后每个键发送前都睡眠 n 毫秒
/// - `{BEEP f d}` = 提示音(macOS 无指定频率的 Beep API,用 NSBeep 等价——文档化偏差)
/// - 需要 + ^ % @ ( ) { } ~ 的字面量时用对应 token(PLUS/CARET/… /TILDE)转义
///
/// 平台偏差(与上游 Windows 实现的差异,均为等价语义):
/// 1. 上游把修饰键发成真实 key-down 并在下一键后 key-up;macOS 等价做法是把修饰键作为
///    CGEventFlags 附着在按键事件上(对目标应用的可见行为一致)
/// 2. macOS 无对应物理键的映射:NUMLOCK→小键盘 Clear(71)、SCROLLLOCK→F14(107)、
///   PRTSC→F13(105)、APPS→F16(106)、INSERT→Help(114)
/// 3. 上游 `(...)` 修饰键分组语法未移植;连续修饰直接叠前缀即可(如 `^%a`)
public enum KeyStrokeString {

    // MARK: - 事件描述(纯数据;解析产物,测试断言用,不发任何事件)

    /// 修饰键集合(@=⌘ 的 Win→Command 映射见类型头注释)
    public struct Modifiers: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift: Modifiers = .init(rawValue: 1 << 0)
        public static let ctrl: Modifiers = .init(rawValue: 1 << 1)
        public static let alt: Modifiers = .init(rawValue: 1 << 2)   // ⌥(上游 Alt)
        public static let cmd: Modifiers = .init(rawValue: 1 << 3)    // ⌘(上游 Win @)
    }

    /// 解析出的单个动作。unicode 非 nil = 非 ASCII 字符注入(无键码等价物)
    public enum Event: Equatable {
        case key(code: CGKeyCode, modifiers: Modifiers, unicode: String?)
        case delay(ms: Int)
        case setPerKeyDelay(ms: Int)
        case beep(frequency: Int, durationMs: Int)
    }

    // MARK: - 解析(纯函数)

    /// 解析按键串;非法输入(未闭合 `{`、未知 token、坏参数)返回 nil
    public static func parse(_ spec: String) -> [Event]? {
        var events: [Event] = []
        var pending = Modifiers()
        let chars = Array(spec)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case "^": pending.insert(.ctrl)
            case "%": pending.insert(.alt)
            case "+": pending.insert(.shift)
            case "@": pending.insert(.cmd)
            case "~":
                events.append(.key(code: CGKeyCode(kVK_Return), modifiers: pending, unicode: nil))
                pending = []
            case "{":
                guard let close = chars[(i + 1)...].firstIndex(of: "}") else { return nil }
                let body = String(chars[(i + 1)..<close])
                guard parseToken(body, pending: &pending, events: &events) else { return nil }
                i = close
            default:
                guard let ev = charEvent(ch, mods: pending) else { return nil }
                events.append(ev)
                pending = []
            }
            i += 1
        }
        return events
    }

    /// `{...}` 内部:VKEY/BEEP/DELAY/LWIN/RWIN/命名键(可带重复次数)
    private static func parseToken(_ body: String,
                                   pending: inout Modifiers,
                                   events: inout [Event]) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let upper = trimmed.uppercased()

        if upper.hasPrefix("VKEY") {
            guard let code = UInt16(trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)) else {
                return false
            }
            events.append(.key(code: code, modifiers: pending, unicode: nil))
            pending = []
            return true
        }
        if upper.hasPrefix("BEEP") {
            let parts = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
                .split(separator: " ").compactMap { Int($0) }
            guard parts.count == 2 else { return false }
            events.append(.beep(frequency: parts[0], durationMs: parts[1]))
            return true
        }
        if upper.hasPrefix("DELAY") {
            var rest = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            var always = false
            if rest.hasPrefix("=") {          // {DELAY =n} = 每键前延迟(上游 m_nDelayAlways)
                always = true
                rest = String(rest.dropFirst())
            }
            guard let ms = Int(rest), ms >= 0 else { return false }
            events.append(always ? .setPerKeyDelay(ms: ms) : .delay(ms: ms))
            return true
        }
        if upper == "LWIN" || upper == "RWIN" || upper == "WIN" {
            // Win 键按下并持续到下一个键完成(上游 SendKeyDown(VK_LWIN, 1, false));
            // macOS 等价:给后续按键附 ⌘ 标志(左右侧在 CGEventFlags 里不可区分)
            pending.insert(.cmd)
            return true
        }

        // 命名键:最长名优先,避免 DEL/DELETE、ESC/ESCAPE、LEFT/LEFTBRACE 前缀歧义
        // (上游 2004-05-21 修的 RIGHT/RIGHTPAREN 同类问题)
        let names = tokens.keys.sorted { $0.count > $1.count }
        for name in names where upper.hasPrefix(name) {
            let rest = trimmed.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
            var times = 1
            if !rest.isEmpty {
                guard let n = Int(rest), n > 0, n <= 1000 else { return false }
                times = n
            }
            switch tokens[name]! {
            case .key(let code):
                for _ in 0..<times { events.append(.key(code: code, modifiers: pending, unicode: nil)) }
            case .literal(let c):
                guard let ev = charEvent(c, mods: pending) else { return false }
                for _ in 0..<times { events.append(ev) }
            }
            pending = []
            return true
        }
        return false
    }

    /// 单个可见字符 → 键事件(美式布局;符号自动 ⇧;非 ASCII → Unicode 注入)
    private static func charEvent(_ c: Character, mods: Modifiers) -> Event? {
        if let (code, shift) = asciiTable[c] {
            var m = mods
            if shift { m.insert(.shift) }
            return .key(code: code, modifiers: m, unicode: nil)
        }
        guard c.unicodeScalars.count == 1, c.isASCII else {
            return .key(code: 0, modifiers: mods, unicode: String(c))
        }
        return nil   // ASCII 但不在表内(不可见控制字符):拒绝
    }

    // MARK: - 键码表(美式 ANSI 布局;kVK_ANSI_* 常量即 macOS 虚拟键码)

    private enum TokenTarget {
        case key(CGKeyCode)
        case literal(Character)
    }

    /// {TOKEN} 名 → 目标(对照上游 SendKeys.cpp:107-200 的 KeyNames 表;
    /// 平台映射键(NUMLOCK/SCROLLLOCK/PRTSC/APPS/INSERT)见类型头注释偏差 2)
    private static let tokens: [String: TokenTarget] = [
        "ENTER": .key(CGKeyCode(kVK_Return)), "RETURN": .key(CGKeyCode(kVK_Return)), "TAB": .key(CGKeyCode(kVK_Tab)),
        "ESC": .key(CGKeyCode(kVK_Escape)), "ESCAPE": .key(CGKeyCode(kVK_Escape)),
        "BACKSPACE": .key(CGKeyCode(kVK_Delete)), "BS": .key(CGKeyCode(kVK_Delete)),
        "DELETE": .key(CGKeyCode(kVK_ForwardDelete)), "DEL": .key(CGKeyCode(kVK_ForwardDelete)),
        "HOME": .key(CGKeyCode(kVK_Home)), "END": .key(CGKeyCode(kVK_End)),
        "PGUP": .key(CGKeyCode(kVK_PageUp)), "PGDN": .key(CGKeyCode(kVK_PageDown)),
        "UP": .key(CGKeyCode(kVK_UpArrow)), "DOWN": .key(CGKeyCode(kVK_DownArrow)),
        "LEFT": .key(CGKeyCode(kVK_LeftArrow)), "RIGHT": .key(CGKeyCode(kVK_RightArrow)),
        "INSERT": .key(CGKeyCode(kVK_Help)), "HELP": .key(CGKeyCode(kVK_Help)),
        "CAPSLOCK": .key(CGKeyCode(kVK_CapsLock)),
        "NUMLOCK": .key(CGKeyCode(kVK_ANSI_KeypadClear)),
        "SCROLLLOCK": .key(CGKeyCode(kVK_F14)), "PRTSC": .key(CGKeyCode(kVK_F13)), "APPS": .key(CGKeyCode(kVK_F16)),
        "ADD": .key(CGKeyCode(kVK_ANSI_KeypadPlus)), "SUBTRACT": .key(CGKeyCode(kVK_ANSI_KeypadMinus)),
        "MULTIPLY": .key(CGKeyCode(kVK_ANSI_KeypadMultiply)), "DIVIDE": .key(CGKeyCode(kVK_ANSI_KeypadDivide)),
        "F1": .key(CGKeyCode(kVK_F1)), "F2": .key(CGKeyCode(kVK_F2)), "F3": .key(CGKeyCode(kVK_F3)), "F4": .key(CGKeyCode(kVK_F4)),
        "F5": .key(CGKeyCode(kVK_F5)), "F6": .key(CGKeyCode(kVK_F6)), "F7": .key(CGKeyCode(kVK_F7)), "F8": .key(CGKeyCode(kVK_F8)),
        "F9": .key(CGKeyCode(kVK_F9)), "F10": .key(CGKeyCode(kVK_F10)), "F11": .key(CGKeyCode(kVK_F11)), "F12": .key(CGKeyCode(kVK_F12)),
        "F13": .key(CGKeyCode(kVK_F13)), "F14": .key(CGKeyCode(kVK_F14)), "F15": .key(CGKeyCode(kVK_F15)), "F16": .key(CGKeyCode(kVK_F16)),
        "PLUS": .literal("+"), "AT": .literal("@"), "CARET": .literal("^"), "TILDE": .literal("~"),
        "LEFTBRACE": .literal("{"), "RIGHTBRACE": .literal("}"),
        "LEFTPAREN": .literal("("), "RIGHTPAREN": .literal(")"), "PERCENT": .literal("%"),
    ]

    /// 可打印 ASCII → (键码, 是否需要 ⇧)。上游 VkKeyScan 的美式布局等价表
    private static let asciiTable: [Character: (code: CGKeyCode, shift: Bool)] = {
        var t: [Character: (code: CGKeyCode, shift: Bool)] = [:]
        let letters: [Character: CGKeyCode] = [
            "a": CGKeyCode(kVK_ANSI_A), "s": CGKeyCode(kVK_ANSI_S),
            "d": CGKeyCode(kVK_ANSI_D), "f": CGKeyCode(kVK_ANSI_F),
            "h": CGKeyCode(kVK_ANSI_H), "g": CGKeyCode(kVK_ANSI_G),
            "z": CGKeyCode(kVK_ANSI_Z), "x": CGKeyCode(kVK_ANSI_X),
            "c": CGKeyCode(kVK_ANSI_C), "v": CGKeyCode(kVK_ANSI_V),
            "b": CGKeyCode(kVK_ANSI_B), "q": CGKeyCode(kVK_ANSI_Q),
            "w": CGKeyCode(kVK_ANSI_W), "e": CGKeyCode(kVK_ANSI_E),
            "r": CGKeyCode(kVK_ANSI_R), "y": CGKeyCode(kVK_ANSI_Y),
            "t": CGKeyCode(kVK_ANSI_T), "o": CGKeyCode(kVK_ANSI_O),
            "u": CGKeyCode(kVK_ANSI_U), "i": CGKeyCode(kVK_ANSI_I),
            "p": CGKeyCode(kVK_ANSI_P), "l": CGKeyCode(kVK_ANSI_L),
            "j": CGKeyCode(kVK_ANSI_J), "n": CGKeyCode(kVK_ANSI_N),
            "m": CGKeyCode(kVK_ANSI_M),
        ]
        for (c, code) in letters {
            t[c] = (code, false)
            t[Character(c.uppercased())] = (code, true)   // 大写 = ⇧ + 字母
        }
        let digits: [Character: CGKeyCode] = [
            "1": CGKeyCode(kVK_ANSI_1), "2": CGKeyCode(kVK_ANSI_2),
            "3": CGKeyCode(kVK_ANSI_3), "4": CGKeyCode(kVK_ANSI_4),
            "5": CGKeyCode(kVK_ANSI_5), "6": CGKeyCode(kVK_ANSI_6),
            "7": CGKeyCode(kVK_ANSI_7), "8": CGKeyCode(kVK_ANSI_8),
            "9": CGKeyCode(kVK_ANSI_9), "0": CGKeyCode(kVK_ANSI_0),
        ]
        for (c, code) in digits { t[c] = (code, false) }
        let plain: [Character: CGKeyCode] = [
            "-": CGKeyCode(kVK_ANSI_Minus), "=": CGKeyCode(kVK_ANSI_Equal),
            "[": CGKeyCode(kVK_ANSI_LeftBracket), "]": CGKeyCode(kVK_ANSI_RightBracket),
            "\\": CGKeyCode(kVK_ANSI_Backslash), ";": CGKeyCode(kVK_ANSI_Semicolon),
            "'": CGKeyCode(kVK_ANSI_Quote), ",": CGKeyCode(kVK_ANSI_Comma),
            ".": CGKeyCode(kVK_ANSI_Period), "/": CGKeyCode(kVK_ANSI_Slash),
            "`": CGKeyCode(kVK_ANSI_Grave), " ": CGKeyCode(kVK_Space),
            "\t": CGKeyCode(kVK_Tab), "\r": CGKeyCode(kVK_Return), "\n": CGKeyCode(kVK_Return),
        ]
        for (c, code) in plain { t[c] = (code, false) }
        let shifted: [Character: CGKeyCode] = [
            "!": CGKeyCode(kVK_ANSI_1), "@": CGKeyCode(kVK_ANSI_2),
            "#": CGKeyCode(kVK_ANSI_3), "$": CGKeyCode(kVK_ANSI_4),
            "%": CGKeyCode(kVK_ANSI_5), "^": CGKeyCode(kVK_ANSI_6),
            "&": CGKeyCode(kVK_ANSI_7), "*": CGKeyCode(kVK_ANSI_8),
            "(": CGKeyCode(kVK_ANSI_9), ")": CGKeyCode(kVK_ANSI_0),
            "_": CGKeyCode(kVK_ANSI_Minus), "+": CGKeyCode(kVK_ANSI_Equal),
            "{": CGKeyCode(kVK_ANSI_LeftBracket), "}": CGKeyCode(kVK_ANSI_RightBracket),
            "|": CGKeyCode(kVK_ANSI_Backslash), ":": CGKeyCode(kVK_ANSI_Semicolon),
            "\"": CGKeyCode(kVK_ANSI_Quote), "<": CGKeyCode(kVK_ANSI_Comma),
            ">": CGKeyCode(kVK_ANSI_Period), "?": CGKeyCode(kVK_ANSI_Slash),
            "~": CGKeyCode(kVK_ANSI_Grave),
        ]
        for (c, code) in shifted { t[c] = (code, true) }
        return t
    }()

    // MARK: - 执行

    /// 共享事件源(同源事件状态一致;PasteBack.triggerCmdV 亦用 combinedSessionState)
    private static let eventSource = CGEventSource(stateID: .combinedSessionState)

    /// 执行按键串;解析失败或事件构造失败返回 false。
    /// 真实按键注入依赖辅助功能权限(与 PasteBack.triggerCmdV 同一约束);
    /// 单元测试只覆盖 parse(不发事件)
    @discardableResult
    public static func send(_ spec: String) -> Bool {
        guard let events = parse(spec) else { return false }
        var perKeyDelayMs = 0
        for event in events {
            switch event {
            case .delay(let ms):
                if ms > 0 { Thread.sleep(forTimeInterval: Double(ms) / 1000) }
            case .setPerKeyDelay(let ms):
                perKeyDelayMs = ms
            case .beep:
                NSSound.beep()
            case .key(let code, let modifiers, let unicode):
                if perKeyDelayMs > 0 { Thread.sleep(forTimeInterval: Double(perKeyDelayMs) / 1000) }
                guard postKeyEvent(code: code, modifiers: modifiers, unicode: unicode) else {
                    return false
                }
            }
        }
        return true
    }

    private static func postKeyEvent(code: CGKeyCode, modifiers: Modifiers, unicode: String?) -> Bool {
        guard let source = eventSource,
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { return false }
        var flags = CGEventFlags()
        if modifiers.contains(.cmd) { flags.insert(.maskCommand) }
        if modifiers.contains(.ctrl) { flags.insert(.maskControl) }
        if modifiers.contains(.alt) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        keyDown.flags = flags
        keyUp.flags = flags
        if let unicode, !unicode.isEmpty {
            // Unicode 注入:目标应用按文本解释(用于中文等无美式键码等价物的字符)
            let units = Array(unicode.utf16)
            units.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(stringLength: buffer.count,
                                                 unicodeString: buffer.baseAddress)
            }
        }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
