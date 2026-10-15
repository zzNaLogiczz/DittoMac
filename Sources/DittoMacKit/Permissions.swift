import AppKit
import ApplicationServices

/// 辅助功能权限(CGEvent 合成 ⌘V 需要)
public enum Permissions {

    /// 当前进程是否已获辅助功能授权
    public static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// 检查并弹出系统授权提示(不跳转设置面板;已授权时不弹)
    public static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 打开 系统设置 → 隐私与安全性 → 辅助功能
    public static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
