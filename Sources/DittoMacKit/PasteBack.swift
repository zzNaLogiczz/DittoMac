import AppKit
import CoreGraphics

/// 把历史条目写回剪贴板并模拟 ⌘V(对照 Ditto:保存原剪贴板 → 写入 → 发 ⌘V → 延迟恢复)
public enum PasteBack {

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
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
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
    /// ③ triggerCmdV()
    /// ④ 延迟 restoreAfter 秒原样恢复①的内容(恢复前上报区间)
    @discardableResult
    public static func paste(_ payload: RawClip,
                             restoreAfter: TimeInterval = 0.4,
                             monitor: ClipboardMonitor?) -> Bool {
        let saved = snapshot()
        guard write(payload, monitor: monitor) else { return false }
        guard triggerCmdV() else {
            restore(saved, monitor: monitor)   // 发送失败:立即恢复,不留脏数据
            return false
        }
        // 恢复必须与 monitor 轮询同队列(主线程):避免轮询读到"写了一半"的中间状态
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreAfter) {
            restore(saved, monitor: monitor)
        }
        return true
    }

    // MARK: - 快照与恢复

    private typealias ItemSnapshot = [(type: NSPasteboard.PasteboardType, data: Data)]

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
