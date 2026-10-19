import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// 把历史条目写回剪贴板并模拟 ⌘V(对照 Ditto:保存原剪贴板 → 写入 → 发 ⌘V → 延迟恢复)
public enum PasteBack {

    // MARK: - 粘贴/复制/剪切键(上游 SendPaste/SendCopy/SendCut + Custom Key Strokes)

    /// 触发哪种键
    public enum ClipboardKeyKind: String, Sendable {
        case paste   // ⌘V
        case copy    // ⌘C
        case cut     // ⌘X
    }

    /// 每应用自定义按键串解析器(上游 Custom Key Strokes / PasteStrings 注册表,
    /// Options.cpp:1972 GetPasteString:按前台应用查串,空 → 默认串)。
    /// 应用层注入;返回 nil 或空串 = 使用系统默认 ⌘V/⌘C/⌘X
    public static var keyStringResolver: ((ClipboardKeyKind) -> String?)?

    /// 发粘贴/复制/剪切键:先试自定义串(命中且发送成功 → 用它);
    /// 否则回退系统默认(⌘V / ⌘C / ⌘X,CGEvent 发到 HID 层;需辅助功能权限)
    @discardableResult
    public static func triggerKey(_ kind: ClipboardKeyKind) -> Bool {
        if let spec = keyStringResolver?(kind), !spec.isEmpty, KeyStrokeString.send(spec) {
            return true
        }
        switch kind {
        case .paste: return triggerCmdV()
        case .copy: return triggerCmdKey(CGKeyCode(kVK_ANSI_C))
        case .cut: return triggerCmdKey(CGKeyCode(kVK_ANSI_X))
        }
    }

    /// 写回剪贴板:单个 NSPasteboardItem 承载全部非空表示,文件以 NSURL 追加写入。
    /// 写完把实测 changeCount 区间报给 monitor(自写豁免按精确区间,不按次数假设)
    @discardableResult
    public static func write(_ payload: RawClip, monitor: ClipboardMonitor?) -> Bool {
        let pb = NSPasteboard.general
        let countBefore = pb.changeCount
        pb.clearContents()

        let item = NSPasteboardItem()
        if let text = payload.text, !text.isEmpty {
            item.setString(text, forType: .string)
        }
        if let rtf = payload.rtfData {
            item.setData(rtf, forType: .rtf)
        }
        if let html = payload.htmlData {
            item.setData(html, forType: .html)
        }
        if let image = payload.imageData {
            item.setData(image, forType: isTIFF(image) ? .tiff : .png)
        }
        // 附加自定义格式写到同一个 item 上(原版把记录的全部格式原样写回)
        for format in payload.extraFormats where !format.data.isEmpty {
            item.setData(format.data, forType: NSPasteboard.PasteboardType(rawValue: format.type))
        }

        var objects: [NSPasteboardWriting] = [item]
        if let paths = payload.filePaths {
            objects += paths.map { URL(fileURLWithPath: $0) as NSURL }
        }
        let ok = pb.writeObjects(objects)
        monitor?.noteSelfWrite(countBefore: countBefore, countAfter: pb.changeCount)
        return ok
    }

    /// 模拟 ⌘V(keyCode 9 = V),事件发到 HID 层;需辅助功能权限,失败返回 false
    @discardableResult
    public static func triggerCmdV() -> Bool {
        triggerCmdKey(9)
    }

    /// ⌘+任意键的实现(⌘V=9 / ⌘C=8 / ⌘X=7)
    @discardableResult
    private static func triggerCmdKey(_ keyCode: CGKeyCode) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// 完整粘贴时序:
    /// ① 快照当前剪贴板全部 item 的全部 (type,data)
    /// ② write(payload)(写后上报实测区间,monitor 不捕获)
    /// ③ triggerKey(.paste)(默认 ⌘V,可被每应用自定义串替换)
    /// ④ 延迟 restoreAfter 秒原样恢复①的内容(恢复前上报区间)
    @discardableResult
    public static func paste(_ payload: RawClip,
                             restoreAfter: TimeInterval = 0.4,
                             monitor: ClipboardMonitor?) -> Bool {
        let saved = snapshotClipboard()
        guard write(payload, monitor: monitor) else { return false }
        guard triggerKey(.paste) else {
            restoreClipboard(saved, monitor: monitor)   // 发送失败:立即恢复,不留脏数据
            return false
        }
        // 恢复必须与 monitor 轮询同队列(主线程):避免轮询读到"写了一半"的中间状态
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreAfter) { [saved] in
            restoreClipboard(saved, monitor: monitor)
        }
        return true
    }

    // MARK: - 快照与恢复(复制缓冲引擎复用,公开口)

    typealias ItemSnapshot = [(type: NSPasteboard.PasteboardType, data: Data)]

    /// 剪贴板快照(全部 item 的全部 (type,data) + 快照时的 changeCount)
    public struct ClipboardSnapshot {
        let items: [ItemSnapshot]
        let changeCountAtSnapshot: Int
    }

    /// 快照当前剪贴板(逐 item 记录所有可读的 (type,data);惰性/承诺类型自然跳过)
    public static func snapshotClipboard() -> ClipboardSnapshot {
        ClipboardSnapshot(items: snapshot(),
                          changeCountAtSnapshot: NSPasteboard.general.changeCount)
    }

    /// 恢复快照(写前上报区间,monitor 不捕获)。
    /// 快照后剪贴板从未变化 → 跳过无谓重写(少一次 changeCount 跳变)
    public static func restoreClipboard(_ snapshot: ClipboardSnapshot, monitor: ClipboardMonitor?) {
        guard NSPasteboard.general.changeCount != snapshot.changeCountAtSnapshot else { return }
        restore(snapshot.items, monitor: monitor)
    }

    /// 逐 item 记录所有可读的 (type,data);拿不到 data 的惰性/承诺类型自然跳过
    private static func snapshot() -> [ItemSnapshot] {
        guard let items = NSPasteboard.general.pasteboardItems else { return [] }
        return items.map { item in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
    }

    private static func restore(_ items: [ItemSnapshot], monitor: ClipboardMonitor?) {
        let pb = NSPasteboard.general
        let countBefore = pb.changeCount
        pb.clearContents()
        let restored = items.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for pair in pairs {
                item.setData(pair.data, forType: pair.type)
            }
            return item
        }
        if !restored.isEmpty {
            pb.writeObjects(restored)
        }
        monitor?.noteSelfWrite(countBefore: countBefore, countAfter: pb.changeCount)
    }

    /// TIFF 魔数判断(II* 小端 / MM* 大端),否则按 PNG 写入
    private static func isTIFF(_ data: Data) -> Bool {
        data.starts(with: [0x49, 0x49, 0x2A, 0x00]) ||
        data.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
    }
}
