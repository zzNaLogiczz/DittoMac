import Carbon.HIToolbox
import Foundation

/// 自定义热键签名 'DTMK'(C 函数指针不能捕获类型,提到文件级)
private let hotKeySignature: OSType = 0x4454_4D4B

/// 全局热键注册中心:Carbon RegisterEventHotKey(修饰键直接用 cmdKey/optionKey/controlKey/shiftKey 掩码)
public final class HotKeyCenter {

    public static let shared = HotKeyCenter()

    /// id 字符串 → 内部分配的 UInt32 槽位(Carbon 的 EventHotKeyID 只能携带 UInt32)
    private var slotByID: [String: UInt32] = [:]
    private var idBySlot: [UInt32: String] = [:]
    private var handlerBySlot: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var nextSlot: UInt32 = 1
    private var carbonEventHandler: EventHandlerRef?

    /// 自定义热键签名 'DTMK'(用于过滤本中心注册的热键)
    private static let signature: OSType = hotKeySignature

    private init() {
        installCarbonHandler()
    }

    deinit {
        unregisterAll()
        if let handler = carbonEventHandler {
            RemoveEventHandler(handler)
        }
    }

    /// 注册全局热键,同 id 重复注册时先注销旧的;成功返回 true
    @discardableResult
    public func register(keyCode: UInt32,
                         carbonModifiers: UInt,
                         id: String,
                         handler: @escaping () -> Void) -> Bool {
        unregister(id: id)

        let slot = nextSlot
        nextSlot += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode,
                                         UInt32(carbonModifiers),
                                         EventHotKeyID(signature: Self.signature, id: slot),
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else { return false }

        hotKeyRefs[slot] = ref
        handlerBySlot[slot] = handler
        idBySlot[slot] = id
        slotByID[id] = slot
        return true
    }

    public func unregister(id: String) {
        guard let slot = slotByID[id] else { return }
        release(slot: slot)
    }

    public func unregisterAll() {
        for slot in Array(hotKeyRefs.keys) {
            release(slot: slot)
        }
    }

    /// 注销所有 id 以指定前缀开头的热键(组热键 "group.<id>" 批量重注册用;
    /// 多命名热键运行期增删本就支持,这是便捷批量口)
    public func unregisterAll(matchingPrefix prefix: String) {
        for id in Array(slotByID.keys) where id.hasPrefix(prefix) {
            unregister(id: id)
        }
    }

    private func release(slot: UInt32) {
        if let ref = hotKeyRefs.removeValue(forKey: slot) {
            UnregisterEventHotKey(ref)
        }
        if let id = idBySlot.removeValue(forKey: slot) {
            slotByID[id] = nil
        }
        handlerBySlot[slot] = nil
    }

    // MARK: - Carbon 事件分发

    private func installCarbonHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event,
                                        EventParamName(UInt32(kEventParamDirectObject)),
                                        EventParamType(UInt32(typeEventHotKeyID)),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hotKeyID)
            guard err == noErr, hotKeyID.signature == hotKeySignature else { return noErr }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            center.dispatch(slot: hotKeyID.id)
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &carbonEventHandler)
    }

    /// Carbon 事件在主线程事件循环送达;仍统一派发到主队列
    private func dispatch(slot: UInt32) {
        guard let handler = handlerBySlot[slot] else { return }
        DispatchQueue.main.async(execute: handler)
    }
}
