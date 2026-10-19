import Foundation

// MARK: - 空闲门控的自动删除(原版:删除在电脑空闲时才跑)
//
// 上游用 GetLastInputInfo(Misc.cpp:141-165 IdleSeconds)判定空闲;
// macOS 等价 = CGEventSource.secondsSinceLastEventType(.hidSystemState,
// eventType: kCGAnyInputEventType)。门控判定本身抽成纯函数便于单测:
// 600s 周期清理在空闲 ≥ 300s 时放行,否则本轮跳过等下个 tick;
// 启动后不久的首次清理不走门控(保持既有行为)。

public enum PruneGate {

    /// 空闲阈值(秒):达到才认为"电脑空闲"
    public static let idleThresholdSeconds: Double = 300

    /// 纯判定:是否放行本轮自动删除
    /// - Parameters:
    ///   - idleSeconds: 距上次任意输入的秒数(生产 = CGEventSource 读取;测试注入)
    ///   - threshold: 阈值(默认 300s)
    public static func shouldPrune(idleSeconds: Double, threshold: Double = idleThresholdSeconds) -> Bool {
        idleSeconds >= threshold
    }
}
