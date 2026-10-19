import AppKit
import Foundation

/// 复制缓冲 1-3 引擎(上游 CDittoCopyBuffer,src/DittoCopyBuffer.cpp —— 已验证语义):
///
/// COPY 热键(DittoCopyBuffer.cpp:26-56 StartCopy):
///   快照剪贴板 → 发 ⌘C(可被每应用自定义串替换)→ 等 monitor 把新内容入库
///   (至多 1.5s,即上游 StartCopyTimer 的 1500ms,DittoCopyBuffer.cpp:53-70;
///   超时撤销并恢复快照)→ 把本次实际入库的 id 关联到缓冲号(EndCopy → PutClipOnDittoCopyBuffer,
///   DittoCopyBuffer.cpp:73-146 的 UPDATE CopyBuffers)→ 恢复原剪贴板快照
///   → 按设置播放提示音(PlaySound("ding.wav"))。
/// CUT 热键 = 同上但发 ⌘X(上游 bCut 分支 → SendCut)。
/// PASTE 热键(DittoCopyBuffer.cpp:148-199 PastCopyBuffer):
///   取缓冲条目 → 完整粘贴管线(PasteBack.paste:快照 → 写回 → 发粘贴键 → 延迟恢复);
///   空缓冲 / 条目已删 → 无操作(上游 q.eof() 直接跳过)。
///
/// 全部状态在主线程访问(热键回调与 Timer 都走主队列,与 monitor 轮询同队列)
public final class CopyBufferController {

    private let store: ClipStore
    private let monitor: ClipboardMonitor?

    /// 剪贴板/按键副作用集中在此；测试可替换为内存实现，不发送系统按键。
    struct CaptureIO {
        var snapshot: () -> PasteBack.ClipboardSnapshot
        var triggerKey: (PasteBack.ClipboardKeyKind) -> Bool
        var restore: (PasteBack.ClipboardSnapshot) -> Void
        var playSound: () -> Void
    }
    private let captureIO: CaptureIO

    /// 等待新剪贴板入库的上限(上游 1500ms)
    private let captureTimeout: TimeInterval

    private struct Pending {
        let bufferIndex: Int
        let snapshot: PasteBack.ClipboardSnapshot
        let timer: Timer
    }

    private var pending: Pending?

    /// 一次复制入缓冲进行中(上游 m_bActive;进行中忽略新触发)
    public var isCapturing: Bool { pending != nil }

    public convenience init(store: ClipStore, monitor: ClipboardMonitor) {
        self.init(store: store, monitor: monitor, captureIO: CaptureIO(
            snapshot: { PasteBack.snapshotClipboard() },
            triggerKey: { PasteBack.triggerKey($0) },
            restore: { PasteBack.restoreClipboard($0, monitor: monitor) },
            playSound: { Self.playDing() }
        ))
    }

    init(store: ClipStore, monitor: ClipboardMonitor? = nil,
         captureIO: CaptureIO, captureTimeout: TimeInterval = 1.5) {
        self.store = store
        self.monitor = monitor
        self.captureIO = captureIO
        self.captureTimeout = captureTimeout
    }

    deinit { pending?.timer.invalidate() }

    /// 热键入口(AppDelegate 注册后分发)
    public func handleHotkey(bufferIndex: Int, action: CopyBufferAction) {
        switch action {
        case .copy: startCapture(bufferIndex: bufferIndex, cut: false)
        case .cut: startCapture(bufferIndex: bufferIndex, cut: true)
        case .paste: pasteFromBuffer(bufferIndex: bufferIndex)
        }
    }

    // MARK: - 复制/剪切入缓冲

    private func startCapture(bufferIndex: Int, cut: Bool) {
        guard pending == nil else { return }   // 上游:上一次动作未完成时不重入
        let snapshot = captureIO.snapshot()
        let timer = Timer(timeInterval: captureTimeout, repeats: false) { [weak self] timer in
            guard let self, let p = self.pending, p.timer === timer else { return }
            self.pending = nil
            self.captureIO.restore(p.snapshot)
        }
        // 必须在发键前进入等待态；自定义按键串可能重入消息循环并完成捕获。
        pending = Pending(bufferIndex: bufferIndex, snapshot: snapshot, timer: timer)
        RunLoop.main.add(timer, forMode: .common)
        if !captureIO.triggerKey(cut ? .cut : .copy), pending?.timer === timer {
            pending = nil
            timer.invalidate()
        }
    }

    /// 仅由剪贴板监控器的成功入库路径通知(主线程)。排序、编辑、网络入库不得调用。
    /// 使用此次入库返回的 ID，支持去重命中，也不受可变 created_at/置顶顺序干扰。
    public func didCapture(clipID: Int64, changeCount: Int) {
        guard let p = pending,
              changeCount > p.snapshot.changeCountAtSnapshot,
              let item = store.item(id: clipID), !item.isGroup else { return }
        pending = nil
        p.timer.invalidate()
        store.setCopyBuffer(index: p.bufferIndex, clipID: clipID)
        captureIO.restore(p.snapshot)
        if DittoSettings.copyBufferPlaySound(index: p.bufferIndex) {
            captureIO.playSound()
        }
    }

    /// 入缓冲成功提示音(上游 PlaySound("ding.wav");macOS 用系统 "Pop" 音,无则 NSBeep)
    private static func playDing() {
        if let pop = NSSound(named: "Pop") {
            pop.play()
        } else {
            NSSound.beep()
        }
    }

    // MARK: - 从缓冲粘贴

    /// PASTE 热键:缓冲条目 → 完整粘贴管线;空缓冲无操作。
    /// 条目已删 → 缓冲视为空并顺手清理关联行
    public func pasteFromBuffer(bufferIndex: Int) {
        guard let clipID = store.copyBufferClipID(index: bufferIndex) else { return }
        guard let payload = store.payload(id: clipID) else {
            store.setCopyBuffer(index: bufferIndex, clipID: nil)
            return
        }
        if Permissions.isAccessibilityGranted {
            _ = PasteBack.paste(payload, monitor: monitor)
        } else {
            // 未授权:内容放到剪贴板可手动 ⌘V(与面板粘贴路径同一降级)
            PasteBack.write(payload, monitor: monitor)
        }
        store.markPasted(id: clipID, at: Date())
    }
}
