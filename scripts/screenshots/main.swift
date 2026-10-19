import AppKit
import DittoMacKit

// A read-only fixture: never opens the user's database or starts clipboard monitoring.
final class ScreenshotStore: ClipStoring {
    let items: [ClipItem]
    init(chinese: Bool) {
        let texts = chinese ? [
            "DittoMac 发布检查清单", "团队晨会记录模板", "#FF3B30",
            "curl -fsSL https://example.com/api", "let greeting = \"Hello, Ditto!\"",
            "git tag v1.0.0 && git push --tags", "ssh -p 22 user@example.com",
            "设计评审：搜索、预览与快捷粘贴", "https://github.com/zzNaLogiczz/DittoMac"
        ] : [
            "DittoMac release checklist", "Team standup notes template", "#FF3B30",
            "curl -fsSL https://example.com/api", "let greeting = \"Hello, Ditto!\"",
            "git tag v1.0.0 && git push --tags", "ssh -p 22 user@example.com",
            "Design review: search, preview, paste", "https://github.com/zzNaLogiczz/DittoMac"
        ]
        let minutes = [2, 9, 15, 25, 40, 60, 90, 120, 180]
        items = texts.enumerated().map { index, text in
            ClipItem(id: Int64(index + 1), kind: .text,
                     createdAt: Date().addingTimeInterval(-Double(minutes[index] * 60)),
                     text: text, pinned: index == 0, byteSize: text.utf8.count,
                     appName: "Demo", contentHash: "demo-\(index)",
                     lastPasteAt: index == 2 ? Date() : nil, noDelete: index == 1)
        }
    }
    var count: Int { items.count }
    func recent(limit: Int) -> [ClipItem] { Array(items.prefix(limit)) }
    func search(_ query: String, limit: Int) -> [ClipItem] {
        Array(items.filter { query.isEmpty || ($0.text?.localizedCaseInsensitiveContains(query) == true) }.prefix(limit))
    }
    func list(parentID: Int64, includeGroupClips: Bool, query: String?, limit: Int) -> [ClipItem] {
        // 演示数据全部在顶层:按查询过滤后沿用置顶优先的既有顺序
        search(query ?? "", limit: limit)
    }
    func item(id: Int64) -> ClipItem? { items.first { $0.id == id } }
    func payload(id: Int64) -> RawClip? { items.first { $0.id == id }.map { RawClip(text: $0.text) } }
    func formats(id: Int64) -> [ClipFormat] { [] }
    @discardableResult func deleteFormats(id: Int64, types: [String]) -> Bool { false }
    func insert(_ raw: RawClip, maxDataBytes: Int) -> ClipItem? { nil }
    func insert(_ raw: RawClip, maxDataBytes: Int, parentID: Int64) -> ClipItem? { nil }
    func setPinned(_ id: Int64, _ pinned: Bool) {}
    func markPasted(id: Int64, at date: Date) {}
    func setNoDelete(_ id: Int64, _ noDelete: Bool) {}
    func moveClip(_ id: Int64, _ direction: ClipStore.ClipMove) {}
    func delete(id: Int64) {}
    func clear(keepingPinned: Bool) {}
    func prune(maxItems: Int, maxAgeDays: Int) {}

    // 组系统:只读演示夹具,组操作全部空实现(面板只读展示)
    @discardableResult func createGroup(name: String, parentID: Int64) -> ClipItem? { nil }
    func childGroups(of parentID: Int64) -> [ClipItem] { [] }
    @discardableResult func moveClips(ids: [Int64], toParent parentID: Int64) -> Bool { false }
    @discardableResult func duplicateClips(ids: [Int64], toParent parentID: Int64) -> Bool { false }
    @discardableResult func renameGroup(id: Int64, name: String) -> Bool { false }
    @discardableResult func deleteGroup(id: Int64) -> Bool { false }
    func groupHotkey(id: Int64) -> GroupHotkey? { nil }
    func setGroupHotkey(id: Int64, hotkey: GroupHotkey?) {}
    func allGroupHotkeys() -> [(groupID: Int64, hotkey: GroupHotkey)] { [] }

    // 多置顶/标题与内容编辑/删除数据/条目热键:同样只读空实现(补齐 ClipStoring 全量成员)
    func setStickyTop(_ id: Int64) {}
    func setStickyLast(_ id: Int64) {}
    func replaceStickyTop(_ id: Int64) {}
    func setSticky(_ id: Int64, _ sticky: Bool) {}
    func fixupStickyOrder() {}
    func setTitle(_ id: Int64, _ title: String?) {}
    @discardableResult func updateClipContent(id: Int64, text: String?, rtfData: Data?, htmlData: Data?) -> Bool { false }
    func searchForDelete(filters: ClipDeleteFilter) -> [ClipItem] { [] }
    @discardableResult func deleteClips(ids: [Int64]) -> (deleted: Int, skipped: Int) { (0, 0) }
    func databaseSizeBytes() -> Int { 0 }
    func clipHotkey(id: Int64) -> ClipHotkey? { nil }
    func setClipHotkey(id: Int64, hotkey: ClipHotkey?) {}
    func allClipHotkeys() -> [(clipID: Int64, hotkey: ClipHotkey)] { [] }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.appearance = NSAppearance(named: .aqua)
let language = CommandLine.arguments[1]
let output = CommandLine.arguments[2]
// Volatile overrides apply only to this process, never the installed app's preferences.
UserDefaults.standard.setVolatileDomain([
    L10n.languageKey: language,
    DittoSettings.linesPerRowKey: 2,
    DittoSettings.positionModeKey: "atPrevious",
    DittoSettings.pausedKey: false
], forName: UserDefaults.argumentDomain)
let controller = HistoryPanelController(store: ScreenshotStore(chinese: language == "zh"))
let window = controller.window!
window.setContentSize(NSSize(width: 560, height: 400))
window.center()
controller.show()
window.contentView!.layoutSubtreeIfNeeded()
window.displayIfNeeded()
let view = window.contentView!
let bounds = view.bounds
let scale = 3
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
    pixelsWide: Int(bounds.width) * scale, pixelsHigh: Int(bounds.height) * scale,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = bounds.size
view.cacheDisplay(in: bounds, to: bitmap)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("\(output): \(bitmap.pixelsWide)×\(bitmap.pixelsHigh), rendered at \(scale)×")
window.orderOut(nil)
