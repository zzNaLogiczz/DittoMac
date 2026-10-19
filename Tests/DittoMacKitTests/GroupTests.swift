import Foundation
import Carbon.HIToolbox

/// 组系统回归(原版 Groups:单 Main 表 + lParentID/bIsGroup 的 macOS 等价)
final class GroupTests: XCTestCase {
    var store: ClipStore!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dittomac-groups-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ClipStore(path: dir.appendingPathComponent("t.sqlite").path)
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    private func text(_ s: String) -> RawClip { RawClip(text: s) }

    // MARK: 建组与父子范围

    func testCreateGroupAndListScoping() {
        let work = store.createGroup(name: "工作", parentID: -1)
        XCTAssertNotNil(work)
        XCTAssertEqual(work?.isGroup, true)
        XCTAssertEqual(work?.parentID, -1)
        XCTAssertEqual(work?.text, "工作")

        let sub = store.createGroup(name: "子组", parentID: work!.id)
        let inside = store.insert(text("组内条目"), maxDataBytes: 20 << 20, parentID: work!.id)
        let top = store.insert(text("顶层条目"), maxDataBytes: 20 << 20)
        XCTAssertNotNil(inside)
        XCTAssertNotNil(top)

        // 顶层(默认):顶层组 + 顶层条目,组内条目不可见(原版 QPasteWnd.cpp:1509)
        let topView = store.list(parentID: -1, includeGroupClips: false, query: nil, limit: 100)
        XCTAssertEqual(Set(topView.map(\.id)), Set([work!.id, top!.id]), "顶层只含顶层组+顶层条目")

        // 顶层(ShowClipsInMainList 开):顶层组 + 全部条目(原版 QPasteWnd.cpp:1500)
        let allView = store.list(parentID: -1, includeGroupClips: true, query: nil, limit: 100)
        XCTAssertEqual(Set(allView.map(\.id)), Set([work!.id, top!.id, inside!.id]))

        // 组内:只列直接子项(条目与子组)
        let groupView = store.list(parentID: work!.id, includeGroupClips: false, query: nil, limit: 100)
        XCTAssertEqual(Set(groupView.map(\.id)), Set([sub!.id, inside!.id]))

        // 子组为空
        XCTAssertTrue(store.list(parentID: sub!.id, includeGroupClips: false, query: nil, limit: 10).isEmpty)
    }

    func testListSearchScopedToCurrentView() {
        let g = store.createGroup(name: "搜索组", parentID: -1)!
        _ = store.insert(text("苹果 香蕉"), maxDataBytes: 20 << 20, parentID: g.id)
        _ = store.insert(text("苹果 樱桃"), maxDataBytes: 20 << 20)   // 顶层

        // 组内搜索:只命中组内的(原版只搜当前视图)
        let inGroup = store.list(parentID: g.id, includeGroupClips: false, query: "苹果", limit: 10)
        XCTAssertEqual(inGroup.count, 1)
        XCTAssertEqual(inGroup.first?.text, "苹果 香蕉")
        let inGroupMiss = store.list(parentID: g.id, includeGroupClips: false, query: "樱桃", limit: 10)
        XCTAssertTrue(inGroupMiss.isEmpty, "顶层条目不得出现在组内搜索")

        // 顶层默认:组内条目不参与;开 includeGroupClips 后参与
        XCTAssertTrue(store.list(parentID: -1, includeGroupClips: false, query: "香蕉", limit: 10).isEmpty)
        XCTAssertEqual(store.list(parentID: -1, includeGroupClips: true, query: "香蕉", limit: 10).count, 1)

        // recent/search 不含组行
        XCTAssertTrue(store.recent(limit: 10).allSatisfy { !$0.isGroup })
        XCTAssertTrue(store.search("苹果", limit: 10).allSatisfy { !$0.isGroup })
    }

    func testListOrderingGroupNotAffectedByPin() {
        let g = store.createGroup(name: "组行", parentID: -1)!
        let a = store.insert(text("普通"), maxDataBytes: 20 << 20)!
        let pinned = store.insert(text("置顶条目"), maxDataBytes: 20 << 20)!
        store.setPinned(pinned.id, true)

        // 置顶条目浮顶;组行视为未置顶,与普通条目按时间交错
        let view = store.list(parentID: -1, includeGroupClips: false, query: nil, limit: 10)
        XCTAssertEqual(view.first?.id, pinned.id, "置顶条目浮顶")
        XCTAssertEqual(view.map(\.id), [pinned.id, a.id, g.id], "组行按创建时间排在普通条目之后")

        // 直接给组行 setPinned(防御):列表排序仍不受影响
        store.setPinned(g.id, true)
        let view2 = store.list(parentID: -1, includeGroupClips: false, query: nil, limit: 10)
        XCTAssertEqual(view2.last?.id, g.id, "组行不受置顶影响")
    }

    // MARK: 移动与成环

    func testMoveClipsAndCyclePrevention() {
        let a = store.createGroup(name: "A", parentID: -1)!
        let b = store.createGroup(name: "B", parentID: a.id)!
        let c = store.createGroup(name: "C", parentID: b.id)!
        let clip = store.insert(text("移动我"), maxDataBytes: 20 << 20)!

        // 条目移动
        XCTAssertTrue(store.moveClips(ids: [clip.id], toParent: a.id))
        XCTAssertEqual(store.item(id: clip.id)?.parentID, a.id)
        // 组 reparent
        XCTAssertTrue(store.moveClips(ids: [c.id], toParent: -1))
        XCTAssertEqual(store.item(id: c.id)?.parentID, -1)

        // 成环:A → 自身 / A → 自己的后代 B → 拒绝
        XCTAssertFalse(store.moveClips(ids: [a.id], toParent: a.id), "移入自身应拒绝")
        XCTAssertFalse(store.moveClips(ids: [a.id], toParent: b.id), "移入子组应拒绝")
        XCTAssertEqual(store.item(id: a.id)?.parentID, -1, "拒绝后父组不变")
        // 间接后代:C 挂回 B 后,A → C 也要拒绝
        XCTAssertTrue(store.moveClips(ids: [c.id], toParent: b.id))
        XCTAssertFalse(store.moveClips(ids: [a.id], toParent: c.id), "移入深层后代应拒绝")

        // 目标不是组行 → 拒绝
        XCTAssertFalse(store.moveClips(ids: [clip.id], toParent: clip.id), "目标是普通条目应拒绝")

        // 移动后范围生效
        XCTAssertTrue(store.list(parentID: a.id, includeGroupClips: false, query: nil, limit: 10)
            .contains { $0.id == clip.id })
    }

    // MARK: 删除组:子项归位

    func testDeleteGroupReparentsChildren() {
        let top = store.createGroup(name: "顶层组", parentID: -1)!
        let outer = store.createGroup(name: "外组", parentID: top.id)!
        let inner = store.createGroup(name: "内组", parentID: outer.id)!
        let clip = store.insert(text("组内"), maxDataBytes: 20 << 20, parentID: outer.id)!

        store.setGroupHotkey(id: outer.id, hotkey: GroupHotkey(keyCode: 98, modifiers: 12, isGlobal: true))

        XCTAssertTrue(store.deleteGroup(id: outer.id))
        XCTAssertNil(store.item(id: outer.id), "组行应被删除")
        // 子项(条目与子组)移回被删组的父组
        XCTAssertEqual(store.item(id: clip.id)?.parentID, top.id)
        XCTAssertEqual(store.item(id: inner.id)?.parentID, top.id)
        // 热键绑定随组清理
        XCTAssertNil(store.groupHotkey(id: outer.id))
        XCTAssertTrue(store.allGroupHotkeys().isEmpty)

        // 删不存在的组 → false;删普通条目 id → false
        XCTAssertFalse(store.deleteGroup(id: 999))
        XCTAssertFalse(store.deleteGroup(id: clip.id))
    }

    func testRenameGroup() {
        let g = store.createGroup(name: "旧名", parentID: -1)!
        XCTAssertTrue(store.renameGroup(id: g.id, name: "新名"))
        XCTAssertEqual(store.item(id: g.id)?.text, "新名")
        XCTAssertEqual(store.list(parentID: -1, includeGroupClips: false, query: nil, limit: 10).first?.text, "新名")
        // 对普通条目重命名 → false(不误伤 text 列)
        let clip = store.insert(text("条目"), maxDataBytes: 20 << 20)!
        XCTAssertFalse(store.renameGroup(id: clip.id, name: "x"))
        XCTAssertEqual(store.item(id: clip.id)?.text, "条目")
    }

    // MARK: 清理豁免(原版 RemoveOldEntries 要求 parentId<=0)

    func testPruneExemptsInGroupClips() {
        let g = store.createGroup(name: "豁免组", parentID: -1)!
        let old = store.insert(text("组内旧条目"), maxDataBytes: 20 << 20, parentID: g.id)!
        let pinned = store.insert(text("旧置顶条目"), maxDataBytes: 20 << 20)!
        let noDelete = store.insert(text("旧永不删除条目"), maxDataBytes: 20 << 20)!
        let expired = store.insert(text("顶层过期条目"), maxDataBytes: 20 << 20)!
        store.setPinned(pinned.id, true)
        store.setNoDelete(noDelete.id, true)
        store.rawExecForTesting("UPDATE clips SET created_at = strftime('%s','now') - 40*86400")

        // 按年龄:组内条目不删
        store.prune(maxItems: 1000, maxAgeDays: 30)
        XCTAssertNotNil(store.item(id: old.id), "组内条目不受过期清理")
        XCTAssertNil(store.item(id: expired.id), "普通顶层过期条目仍清理")
        XCTAssertNotNil(store.item(id: g.id))
        XCTAssertNotNil(store.item(id: pinned.id))
        XCTAssertNotNil(store.item(id: noDelete.id))

        // 按条数:组内条目不计入也不删
        for i in 0..<5 { _ = store.insert(text("顶层\(i)"), maxDataBytes: 20 << 20) }
        store.prune(maxItems: 2, maxAgeDays: 3650)
        XCTAssertNotNil(store.item(id: old.id), "组内条目不受条数清理")
        let topCount = store.list(parentID: -1, includeGroupClips: false, query: nil, limit: 100)
            .filter { !ClipStore.isProtectedFromCleanup($0) }.count
        XCTAssertEqual(topCount, 2, "顶层条目仍按上限清理")

        // 组行自身也不清理
        store.prune(maxItems: 0, maxAgeDays: 0)
        XCTAssertNotNil(store.item(id: g.id), "组行不受清理")
        XCTAssertNotNil(store.item(id: old.id))
        XCTAssertNotNil(store.item(id: pinned.id))
        XCTAssertNotNil(store.item(id: noDelete.id))
    }

    // MARK: 组内入库与去重

    func testInsertWithParentAndDedupKeepsParent() {
        let g1 = store.createGroup(name: "组一", parentID: -1)!
        let g2 = store.createGroup(name: "组二", parentID: -1)!

        let first = store.insert(text("同内容"), maxDataBytes: 20 << 20, parentID: g1.id)
        XCTAssertEqual(first?.parentID, g1.id, "按 parentID 入库")

        // 再次复制同内容(即使指向别的组):去重置顶旧记录,条目留在原组
        let again = store.insert(text("同内容"), maxDataBytes: 20 << 20, parentID: g2.id)
        XCTAssertEqual(again?.id, first?.id, "去重应命中旧记录")
        XCTAssertEqual(store.item(id: first!.id)?.parentID, g1.id, "去重不得偷走条目的组")
        XCTAssertEqual(store.recent(limit: 10).count, 1, "去重不新建行(count 只数条目行)")
        XCTAssertTrue(store.list(parentID: g2.id, includeGroupClips: false, query: nil, limit: 10).isEmpty)

        // 新内容按当前 parentID 落组
        let second = store.insert(text("新内容"), maxDataBytes: 20 << 20, parentID: g2.id)
        XCTAssertEqual(store.item(id: second!.id)?.parentID, g2.id)
    }

    func testExplicitCaptureCopiesIntoTargetAndReusesItsOwnDuplicate() {
        let g1 = store.createGroup(name: "目标一", parentID: -1)!
        let g2 = store.createGroup(name: "目标二", parentID: -1)!
        let raw = RawClip(text: "已记录内容", htmlData: Data("<b>已记录内容</b>".utf8),
                          extraFormats: [ClipFormat(type: "test.capture", data: Data([1, 2, 3]))])
        let top = store.insert(raw, maxDataBytes: 20 << 20)!
        let storedCreatedAt = store.item(id: top.id)?.createdAt
        let first = store.captureToGroup(raw, maxDataBytes: 20 << 20, parentID: g1.id)!
        XCTAssertNotEqual(first.id, top.id)
        XCTAssertEqual(first.parentID, g1.id)
        XCTAssertEqual(store.item(id: top.id)?.parentID, -1, "顶层原条目保留")
        XCTAssertEqual(store.item(id: top.id)?.createdAt, storedCreatedAt, "抓板不更新其他副本")
        XCTAssertEqual(store.payload(id: first.id)?.htmlData, raw.htmlData)
        XCTAssertEqual(store.payload(id: first.id)?.extraFormats.first?.data, Data([1, 2, 3]))

        let second = store.captureToGroup(raw, maxDataBytes: 20 << 20, parentID: g2.id)!
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(second.parentID, g2.id)
        XCTAssertEqual(store.item(id: first.id)?.parentID, g1.id, "其他组原条目保留")

        // 即使全库最新同内容在别处,仍复用目标组自己的条目。
        store.rawExecForTesting("UPDATE clips SET created_at = 9999999999 WHERE id = \(top.id)")
        let again = store.captureToGroup(raw, maxDataBytes: 20 << 20, parentID: g1.id)!
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(again.parentID, g1.id)
        XCTAssertEqual(store.recent(limit: 20).count, 3)
        XCTAssertEqual(store.list(parentID: g1.id, includeGroupClips: false, query: nil, limit: 20).count, 1)
        XCTAssertEqual(store.scalarIntForTesting("SELECT COUNT(*) FROM clip_formats"), 3,
                       "组内复用不会重复写入附加格式")

        let automatic = store.insert(raw, maxDataBytes: 20 << 20, parentID: g2.id)
        XCTAssertEqual(automatic?.id, top.id, "普通捕获仍按全库去重")
        XCTAssertEqual(automatic?.parentID, -1)
        XCTAssertEqual(store.recent(limit: 20).count, 3)
    }

    func testExplicitCaptureValidatesTargetAndPayload() {
        let raw = text("抓板内容")
        let top = store.insert(raw, maxDataBytes: 20 << 20)!
        let storedCreatedAt = store.item(id: top.id)?.createdAt
        let group = store.createGroup(name: "有效目标", parentID: -1)!
        for invalidParent in [Int64(-1), top.id, Int64(999999)] {
            XCTAssertNil(store.captureToGroup(raw, maxDataBytes: 20 << 20, parentID: invalidParent),
                         "无效目标不能回退成顶层捕获或创建孤儿条目")
        }
        XCTAssertNil(store.captureToGroup(RawClip(), maxDataBytes: 20 << 20, parentID: group.id))
        XCTAssertNil(store.captureToGroup(raw, maxDataBytes: 0, parentID: group.id))
        XCTAssertTrue(store.list(parentID: group.id, includeGroupClips: false, query: nil, limit: 20).isEmpty)
        XCTAssertEqual(store.recent(limit: 20).count, 1)
        XCTAssertEqual(store.item(id: top.id)?.createdAt, storedCreatedAt)
    }

    // MARK: 组间复制(duplicate)

    func testDuplicateClips() {
        let g = store.createGroup(name: "目标组", parentID: -1)!
        let src = store.insert(RawClip(text: "可复制",
                                       extraFormats: [ClipFormat(type: "x.y", data: Data("1".utf8))]),
                               maxDataBytes: 20 << 20)!

        XCTAssertTrue(store.duplicateClips(ids: [src.id], toParent: g.id))
        let copies = store.list(parentID: g.id, includeGroupClips: false, query: nil, limit: 10)
            .filter { !$0.isGroup }
        XCTAssertEqual(copies.count, 1, "应复制出一条新行")
        let copy = copies[0]
        XCTAssertNotEqual(copy.id, src.id, "复制=新 id")
        XCTAssertEqual(copy.parentID, g.id)
        XCTAssertEqual(copy.text, "可复制")
        XCTAssertEqual(store.payload(id: copy.id)?.extraFormats.first?.type, "x.y", "附加格式随行复制")

        // 同内容再复制一份仍可(不走去重,多份是合法状态)
        XCTAssertTrue(store.duplicateClips(ids: [src.id], toParent: g.id))
        XCTAssertEqual(store.list(parentID: g.id, includeGroupClips: false, query: nil, limit: 10)
            .filter { !$0.isGroup }.count, 2)

        // 组行不参与复制
        XCTAssertTrue(store.duplicateClips(ids: [g.id], toParent: -1))
        XCTAssertEqual(store.list(parentID: -1, includeGroupClips: false, query: nil, limit: 10)
            .filter { $0.isGroup }.count, 1)
    }

    // MARK: 组热键存储

    func testGroupHotkeyStorage() {
        let g1 = store.createGroup(name: "有热键", parentID: -1)!
        let g2 = store.createGroup(name: "无热键", parentID: -1)!

        XCTAssertNil(store.groupHotkey(id: g1.id))
        let hk = GroupHotkey(keyCode: 98, modifiers: UInt(cmdKey | shiftKey), isGlobal: true)
        store.setGroupHotkey(id: g1.id, hotkey: hk)
        XCTAssertEqual(store.groupHotkey(id: g1.id), hk)

        // 更新为非全局
        let local = GroupHotkey(keyCode: 99, modifiers: 4, isGlobal: false)
        store.setGroupHotkey(id: g1.id, hotkey: local)
        XCTAssertEqual(store.groupHotkey(id: g1.id)?.keyCode, 99)
        XCTAssertEqual(store.groupHotkey(id: g1.id)?.isGlobal, false)

        // 全量枚举 / 清除
        XCTAssertEqual(store.allGroupHotkeys().count, 1)
        XCTAssertEqual(store.allGroupHotkeys().first?.groupID, g1.id)
        store.setGroupHotkey(id: g1.id, hotkey: nil)
        XCTAssertNil(store.groupHotkey(id: g1.id))
        XCTAssertTrue(store.allGroupHotkeys().isEmpty)

        // 跨重启保留(随库迁移,不进 UserDefaults)
        store.setGroupHotkey(id: g2.id, hotkey: hk)
        let dbPath = store.dbPathForTesting()
        store = nil
        store = ClipStore(path: dbPath)
        XCTAssertEqual(store.groupHotkey(id: g2.id), hk, "组热键应持久化在库中")
    }

    /// 旧库升级:老 schema(无 parent_id/is_group、无 group_hotkeys 表)经
    /// 迁移 ALTER 补列后组功能可用,原有数据不丢
    func testMigrationAddsGroupColumns() {
        let clip = store.insert(text("迁移前条目"), maxDataBytes: 20 << 20)
        XCTAssertNotNil(clip)
        let pinned = store.insert(text("迁移前置顶"), maxDataBytes: 20 << 20)!
        store.setPinned(pinned.id, true)
        // 模拟旧库:剥掉组列与组热键表(先删引用列的索引)
        store.rawExecForTesting("DROP INDEX idx_clips_parent")
        store.rawExecForTesting("ALTER TABLE clips DROP COLUMN parent_id")
        store.rawExecForTesting("ALTER TABLE clips DROP COLUMN is_group")
        store.rawExecForTesting("DROP TABLE group_hotkeys")
        XCTAssertEqual(store.scalarIntForTesting(
            "SELECT COUNT(*) FROM pragma_table_info('clips') WHERE name IN ('parent_id','is_group')"), 0)

        // 重开:建表(IF NOT EXISTS 不动旧表)+ 迁移 ALTER 补列 + 重建组热键表
        let dbPath = store.dbPathForTesting()
        store = nil
        store = ClipStore(path: dbPath)
        XCTAssertEqual(store.scalarIntForTesting(
            "SELECT COUNT(*) FROM pragma_table_info('clips') WHERE name IN ('parent_id','is_group')"), 2,
            "迁移应补出 parent_id/is_group")
        XCTAssertEqual(store.recent(limit: 10).count, 2, "原数据保留")
        XCTAssertEqual(store.item(id: clip!.id)?.parentID, -1, "旧行默认顶层")
        XCTAssertEqual(store.item(id: pinned.id)?.pinned, true, "置顶状态保留")

        // 迁移后组功能完整可用
        let g = store.createGroup(name: "迁移后建组", parentID: -1)
        XCTAssertNotNil(g)
        _ = store.insert(text("迁移后组内"), maxDataBytes: 20 << 20, parentID: g!.id)
        let view = store.list(parentID: -1, includeGroupClips: false, query: nil, limit: 10)
        XCTAssertEqual(view.filter(\.isGroup).count, 1)
        XCTAssertEqual(view.filter { !$0.isGroup }.count, 2)
        XCTAssertEqual(store.list(parentID: g!.id, includeGroupClips: false, query: nil, limit: 10).count, 1)
        store.setGroupHotkey(id: g!.id, hotkey: GroupHotkey(keyCode: 98, modifiers: 4, isGlobal: true))
        XCTAssertEqual(store.allGroupHotkeys().count, 1)
    }

    static var registrations: [(String, (GroupTests) -> Void)] {
        [
            ("testCreateGroupAndListScoping", { $0.testCreateGroupAndListScoping() }),
            ("testListSearchScopedToCurrentView", { $0.testListSearchScopedToCurrentView() }),
            ("testListOrderingGroupNotAffectedByPin", { $0.testListOrderingGroupNotAffectedByPin() }),
            ("testMoveClipsAndCyclePrevention", { $0.testMoveClipsAndCyclePrevention() }),
            ("testDeleteGroupReparentsChildren", { $0.testDeleteGroupReparentsChildren() }),
            ("testRenameGroup", { $0.testRenameGroup() }),
            ("testPruneExemptsInGroupClips", { $0.testPruneExemptsInGroupClips() }),
            ("testInsertWithParentAndDedupKeepsParent", { $0.testInsertWithParentAndDedupKeepsParent() }),
            ("testExplicitCaptureCopiesIntoTargetAndReusesItsOwnDuplicate", { $0.testExplicitCaptureCopiesIntoTargetAndReusesItsOwnDuplicate() }),
            ("testExplicitCaptureValidatesTargetAndPayload", { $0.testExplicitCaptureValidatesTargetAndPayload() }),
            ("testDuplicateClips", { $0.testDuplicateClips() }),
            ("testGroupHotkeyStorage", { $0.testGroupHotkeyStorage() }),
            ("testMigrationAddsGroupColumns", { $0.testMigrationAddsGroupColumns() }),
        ]
    }
}
