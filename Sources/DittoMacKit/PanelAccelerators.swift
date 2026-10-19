import Carbon.HIToolbox
import Foundation

/// 快速粘贴窗口内的命令注册表:上游 Quick Paste Keyboard 页"命令重绑定"机制
/// (Accels.h 的 CAccels 键→命令映射)在 ditto-mac 完整命令集上的移植。
///
/// - 默认绑定必须逐一复刻现有硬编码按键行为(ClipListViewController.handleKey 的
///   原始实现)——零回归要求
/// - 一个命令可有多个默认组合(如 Delete 与 Backspace 都删条目)
/// - 持久化:UserDefaults `ditto.accel.<cmd>` = "keyCode+carbonMods";"-" = 显式解绑
/// - 未绑定 = 命令禁用;唯一例外:pasteSelected 必须永远有绑定(守卫,拒绝解绑)
public enum PanelCommand: String, CaseIterable, Sendable {
    case pasteSelected          // 回车粘贴(组行回车 = 进组,由执行方保留上下文语义)
    case pastePlain             // ⇧回车 纯文本粘贴
    case properties             // ⌥回车 属性
    case fullDescription        // F3 完整描述
    case deleteSelected         // Delete/⌫ 删除(组内 ⌫ = 返回上级,由执行方保留)
    case moveClipUp
    case moveClipDown
    case moveClipTop
    case moveClipLast
    case makeTopSticky
    case makeLastSticky
    case replaceTopSticky
    case removeSticky
    case selectAll              // ⌘A
    case copySelection          // ⌘C 复制选中到剪贴板
    case refresh                // F5
    case clearFilter            // ⌥C
    case toggleOrder
    case toggleSearchMethod
    case toggleAlwaysOnTop      // ⌃Space
    case showGroupTree          // ⌃G
    case newGroup               // ⌃F7
    case newGroupFromSelection  // F7
    case cutClips               // ⌃X 组间剪切
    case copyClips              // ⌃C 组间复制(与 ⌘C 的复制选中是两个命令,保持分离)
    case pasteClips             // ⌃V 组间粘贴
    case closeWindow            // Esc(三级退出链由面板保留)
    case forceClose             // ⇧Esc
    case rollUp
    case maximize
    case pastePosition1
    case pastePosition2
    case pastePosition3
    case pastePosition4
    case pastePosition5
    case pastePosition6
    case pastePosition7
    case pastePosition8
    case pastePosition9
    case pastePosition10
    case pasteDontReorder
}

/// 一组键(Carbon 键码 + Carbon 修饰键掩码;与 HotKeyCenter/录入控件同一表示)
public struct KeyCombo: Equatable, Sendable {
    public var keyCode: UInt16
    public var carbonModifiers: UInt

    public init(keyCode: UInt16, carbonModifiers: UInt) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }
}

public enum PanelAccels {

    public static let storagePrefix = "ditto.accel."
    /// 显式解绑标记(值本身是非法绑定串,不会与真实绑定混淆)
    static let unboundMarker = "-"

    private static func combo(_ code: UInt16, _ mods: UInt) -> KeyCombo {
        KeyCombo(keyCode: code, carbonModifiers: mods)
    }
    private static let cmd = UInt(cmdKey)
    private static let shift = UInt(shiftKey)
    private static let option = UInt(optionKey)
    private static let control = UInt(controlKey)

    /// 默认绑定 = 现有硬编码行为的逐一映射(零回归基线;未列出的命令默认未绑定 = 禁用,
    /// 与现状一致 —— 它们今天只有菜单入口,没有按键)
    public static let defaults: [PanelCommand: [KeyCombo]] = [
        .pasteSelected: [combo(36, 0), combo(76, 0)],            // Enter / 小键盘 Enter
        .pastePlain: [combo(36, shift)],                          // ⇧Enter
        .properties: [combo(36, option)],                         // ⌥Enter
        .fullDescription: [combo(99, 0)],                         // F3
        .deleteSelected: [combo(117, 0), combo(51, 0)],           // Delete / Backspace
        .selectAll: [combo(1, cmd)],                              // ⌘A
        .copySelection: [combo(8, cmd)],                          // ⌘C
        .refresh: [combo(96, 0)],                                 // F5
        .clearFilter: [combo(8, option)],                         // ⌥C
        .toggleAlwaysOnTop: [combo(49, control)],                 // ⌃Space
        .showGroupTree: [combo(5, control)],                      // ⌃G
        .newGroup: [combo(98, control)],                          // ⌃F7
        .newGroupFromSelection: [combo(98, 0)],                   // F7
        .cutClips: [combo(7, control)],                           // ⌃X
        .copyClips: [combo(8, control)],                          // ⌃C
        .pasteClips: [combo(9, control)],                         // ⌃V
        .closeWindow: [combo(53, 0)],                             // Esc
        .forceClose: [combo(53, shift)],                          // ⇧Esc
        .pastePosition1: [combo(18, cmd)],                        // ⌘1
        .pastePosition2: [combo(19, cmd)],                        // ⌘2
        .pastePosition3: [combo(20, cmd)],                        // ⌘3
        .pastePosition4: [combo(21, cmd)],                        // ⌘4
        .pastePosition5: [combo(23, cmd)],                        // ⌘5
        .pastePosition6: [combo(22, cmd)],                        // ⌘6
        .pastePosition7: [combo(26, cmd)],                        // ⌘7(26='7')
        .pastePosition8: [combo(28, cmd)],                        // ⌘8
        .pastePosition9: [combo(25, cmd)],                        // ⌘9(25='9')
        .pastePosition10: [combo(29, cmd)],                       // ⌘0
    ]

    // MARK: - 读写(UserDefaults;每次现读,改完即时生效,无需通知)

    /// 命令的生效绑定(pasteSelected 守卫:被解绑时回落默认,保证永不为空)
    public static func bindings(for command: PanelCommand) -> [KeyCombo] {
        if let raw = DittoSettings.defaults.string(forKey: storagePrefix + command.rawValue) {
            if raw == unboundMarker {
                return command == .pasteSelected ? (defaults[.pasteSelected] ?? []) : []
            }
            let parts = raw.split(separator: "+")
            guard parts.count == 2,
                  let code = UInt16(parts[0]),
                  let mods = UInt(parts[1]) else { return [] }
            return [KeyCombo(keyCode: code, carbonModifiers: mods)]
        }
        return defaults[command] ?? []
    }

    /// 是否处于"未绑定(禁用)"状态
    public static func isUnbound(_ command: PanelCommand) -> Bool {
        bindings(for: command).isEmpty
    }

    /// 设置绑定(nil = 解绑;pasteSelected 拒绝解绑并回落默认 —— 守卫)
    public static func setBinding(_ binding: KeyCombo?, for command: PanelCommand) {
        let key = storagePrefix + command.rawValue
        if let binding {
            DittoSettings.defaults.set("\(binding.keyCode)+\(binding.carbonModifiers)", forKey: key)
        } else if command == .pasteSelected {
            DittoSettings.defaults.removeObject(forKey: key)   // 守卫:永不无绑定
        } else {
            DittoSettings.defaults.set(unboundMarker, forKey: key)
        }
    }

    /// 恢复默认(移除覆盖)
    public static func resetToDefault(_ command: PanelCommand) {
        DittoSettings.defaults.removeObject(forKey: storagePrefix + command.rawValue)
    }

    /// 解析器:按键事件 → 命令(键码 + Carbon 修饰掩码精确匹配;未命中返回 nil)
    public static func command(forKeyCode keyCode: UInt16, carbonModifiers: UInt) -> PanelCommand? {
        for command in PanelCommand.allCases {
            for binding in bindings(for: command)
            where binding.keyCode == keyCode && binding.carbonModifiers == carbonModifiers {
                return command
            }
        }
        return nil
    }

    /// 全部命令恢复默认(设置页"恢复默认"入口)
    public static func resetAll() {
        for command in PanelCommand.allCases {
            DittoSettings.defaults.removeObject(forKey: storagePrefix + command.rawValue)
        }
    }
}
