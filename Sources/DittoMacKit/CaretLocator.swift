import AppKit
import ApplicationServices

// MARK: - 插入符定位(上游 "At Caret" 出现位置的 macOS 等价)
//
// 链路(需要已有的辅助功能权限):systemWide 元素 → 焦点元素 → 选中范围
// → kAXBoundsForRange 参数化属性取范围矩形 → 中点即插入符位置。
// AX 全局坐标为"主屏左上原点、y 向下",AppKit 为"左下原点、y 向上",
// 翻转用主屏高度(纯函数,可注入单测);任何失败 → 调用方回落鼠标位置。

public enum CaretLocator {

    /// 当前插入符的屏幕坐标(AppKit 全局坐标);取不到返回 nil
    public static func caretScreenPoint() -> NSPoint? {
        guard let axPoint = axCaretPoint() else { return nil }
        // 主屏 = 含菜单栏的屏(NSScreen.screens 首个,原点恒为 (0,0))
        let primaryHeight = NSScreen.screens.first?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        return flipToAppKit(axPoint, primaryHeight: primaryHeight)
    }

    /// AX → AppKit 纵轴翻转:axY 自主屏顶边向下计 → appKitY 自底边向上计
    public static func flipToAppKit(_ point: NSPoint, primaryHeight: CGFloat) -> NSPoint {
        NSPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// 参考点选择:插入符优先,失败回落鼠标(纯函数,单测覆盖)
    public static func referencePoint(caret: NSPoint?, mouse: NSPoint) -> NSPoint {
        caret ?? mouse
    }

    /// 点所在的屏幕(frame 列表注入便于单测);多屏含菜单栏屏优先,未命中返回 nil
    public static func screenFrame(containing point: NSPoint, frames: [NSRect]) -> NSRect? {
        // 命中多屏交集时取列表靠前者(NSScreen.screens 主屏在前,与视觉栈顶一致)
        frames.first { $0.contains(point) }
    }

    // MARK: - AX 链路(系统调用;见类注释)

    private static func axCaretPoint() -> NSPoint? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
            let focusedRef else { return nil }
        // Copy 成功保证返回焦点元素;CFTypeRef → AXUIElement 无法条件转换,按类型位换
        let focused = unsafeBitCast(focusedRef, to: AXUIElement.self)

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
            let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        let rangeValue = unsafeBitCast(rangeRef, to: AXValue.self)
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue, .cfRange, &range), range.location >= 0 else {
            return nil
        }

        guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused, kAXBoundsForRangeParameterizedAttribute as CFString, axRange, &boundsRef) == .success,
            let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }
        let boundsValue = unsafeBitCast(boundsRef, to: AXValue.self)
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &rect),
              rect.width > 0 || rect.height > 0 else { return nil }
        return NSPoint(x: rect.midX, y: rect.midY)   // AX 坐标,由调用方翻转
    }
}
