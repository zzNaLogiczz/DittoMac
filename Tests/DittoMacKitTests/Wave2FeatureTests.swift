import Foundation
import Carbon.HIToolbox

/// 多置顶(sticky_order)/标题与内容编辑/条目热键/删除剪贴板数据/排序方向/行级 diff 回归
final class Wave2FeatureTests: XCTestCase {
    var store: ClipStore!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dittomac-wave2-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ClipStore(path: dir.appendingPathComponent("t.sqlite").path)
    }

    override func tearDown() {
        store = nil
        UserDefaults.standard.removeObject(forKey: DittoSettings.orderLatestOnTopKey)
        super.tearDown()
    }

    private func text(_ s: String) -> RawClip { RawClip(text: s) }

    private func insert(_ s: String) -> ClipItem {
        let item = store.insert(text(s), maxDataBytes: 20 << 20)!
        sleep(1)   // 保证 created_at 可区分
        return item
    }

    private func topIDs() -> [Int64] {
        store.list(parentID: -1, includeGroupClips: false, query: nil, limit: 100).map(\.id)
    }

    // MARK: 多置顶顺序

    func testStickyOrderingOperations() {
        let a = insert("A")   // 最旧
        let b = insert("B")
        let c = insert("C")   // 最新
        XCTAssertEqual(topIDs(), [c.id, b.id, a.id], "默认最新在上")

        // Make Sticky = 设为首位
        store.setSticky(c.id, true)
        XCTAssertEqual(topIDs(), [c.id, b.id, a.id], "最新条目置顶后仍在首位")
        XCTAssertEqual(store.item(id: c.id)?.pinned, true, "pinned 与 sticky_order 同步")
        XCTAssertEqual(store.item(id: c.id)?.stickyOrder, 0.0)

        // 再置顶一条 → 成为新首位
        store.setStickyTop(a.id)
        XCTAssertEqual(topIDs(), [a.id, c.id, b.id], "A 应成为首位置顶")
        XCTAssertEqual(store.item(id: a.id)?.stickyOrder, -1.0)

        // 设为末位置顶
        store.setStickyLast(b.id)
        XCTAssertEqual(topIDs(), [a.id, c.id, b.id], "B 应成为末位置顶(全部置顶后无非置顶条目)")

        // 替换首位置顶:当前首位 A 取消置顶,B 继承其序成为首位
        store.replaceStickyTop(b.id)
        XCTAssertEqual(topIDs(), [b.id, c.id, a.id], "B 替换首位后应居首,A 回到普通区")
        XCTAssertNil(store.item(id: a.id)?.stickyOrder, "被替换的原首位应取消置顶")
        let bOrder = store.item(id: b.id)?.stickyOrder
        let cOrder = store.item(id: c.id)?.stickyOrder
        XCTAssertEqual(bOrder != nil && cOrder != nil && bOrder! < cOrder!, true,
                       "B 继承首位序值(小于 C)")

        // 修正置顶顺序:重排为连续 0,1,…,顺序不变
        store.fixupStickyOrder()
        XCTAssertEqual(topIDs(), [b.id, c.id, a.id], "fixup 不得改变现有顺序")
        XCTAssertEqual(store.item(id: b.id)?.stickyOrder, 0.0)
        XCTAssertEqual(store.item(id: c.id)?.stickyOrder, 1.0)

        // 取消置顶 → 回到普通区按时间排
        store.setSticky(c.id, false)
        XCTAssertEqual(topIDs(), [b.id, c.id, a.id], "C 取消置顶后仍在 B 后(时间为最新)")
        XCTAssertNil(store.item(id: c.id)?.stickyOrder)
        XCTAssertEqual(store.item(id: c.id)?.pinned, false)
    }

    func testStickyNotAffectedByClipOrderMoves() {
        let s = insert("置顶S")
        let x = insert("X")
        let y = insert("Y")
        store.setStickyTop(s.id)
        XCTAssertEqual(topIDs(), [s.id, y.id, x.id])

        // 置顶条目不参与 Clip Order 移动:Move To Top 无效果(仍在其置顶位)
        store.moveClip(s.id, .toTop)
        XCTAssertEqual(topIDs(), [s.id, y.id, x.id], "置顶条目不受 Move To Top 影响")

        // 非置顶条目的移动也只在非置顶集合内进行(不会越过置顶条目)
        store.moveClip(x.id, .toTop)
        XCTAssertEqual(topIDs(), [s.id, x.id, y.id], "X 移到非置顶集合顶部,仍在置顶 S 之下")
    }

    func testLegacyPinnedMigrationAssignsStickyOrder() {
        let p1 = insert("置顶1")
        let p2 = insert("置顶2")   // 更新
        store.setPinned(p1.id, true)
        store.setPinned(p2.id, true)

        // 模拟旧库:pinned 已置位但 sticky_order 为空(升级前无此列的数据形态)
        store.rawExecForTesting("UPDATE clips SET sticky_order = NULL")
        let dbPath = store.dbPathForTesting()
        store = nil
        store = ClipStore(path: dbPath)

        // 按 created_at DESC 赋 0,1,…:最新的置顶条目成为首位
        XCTAssertEqual(store.item(id: p2.id)?.stickyOrder, 0.0, "最新置顶条目应为首位(序 0)")
        XCTAssertEqual(store.item(id: p1.id)?.stickyOrder, 1.0)
        XCTAssertEqual(store.item(id: p2.id)?.pinned, true, "pinned 状态保留")
        XCTAssertEqual(topIDs().first, p2.id, "置顶区按新序排列")
    }

    // MARK: 标题与内容编辑

    func testSetTitleAndTitleSearch() {
        let a = store.insert(text("苹果正文"), maxDataBytes: 20 << 20)!
        _ = store.insert(text("普通正文"), maxDataBytes: 20 << 20)!

        store.setTitle(a.id, "会议纪要 Alpha")
        XCTAssertEqual(store.item(id: a.id)?.title, "会议纪要 Alpha")

        // 搜索命中标题列(原版同样搜 desc/title)
        XCTAssertEqual(store.search("会议", limit: 10).map(\.id), [a.id])
        XCTAssertEqual(store.search("Alpha", limit: 10).map(\.id), [a.id])

        // NOT 词:标题命中也参与排除(NULL title 不得因三值逻辑被误伤)
        XCTAssertEqual(store.search("正文 NOT 会议", limit: 10).count, 1, "标题含排除词的条目应被排除")
        XCTAssertEqual(store.search("正文", limit: 10).count, 2)

        // 清除标题 → 恢复按内容派生
        store.setTitle(a.id, nil)
        XCTAssertNil(store.item(id: a.id)?.title)
        XCTAssertEqual(store.search("会议", limit: 10).count, 0)

        // 组视图搜索同样命中标题
        let g = store.createGroup(name: "组", parentID: -1)!
        let c = store.insert(text("组内内容"), maxDataBytes: 20 << 20, parentID: g.id)!
        store.setTitle(c.id, "组内标题XYZ")
        XCTAssertEqual(store.list(parentID: g.id, includeGroupClips: false, query: "XYZ", limit: 10)
            .map(\.id), [c.id])
    }

    func testUpdateClipContentRecomputesHashAndKeepsMeta() {
        let item = store.insert(RawClip(text: "旧文本", rtfData: Data("{\\rtf1旧}".utf8)),
                                maxDataBytes: 20 << 20)!
        store.setTitle(item.id, "我的标题")
        store.setPinned(item.id, true)

        // 改文本列并清空 rtf(空 Data = 置 NULL);nil = 不动该列
        XCTAssertTrue(store.updateClipContent(id: item.id, text: "新文本内容",
                                              rtfData: Data(), htmlData: nil))
        let payload = store.payload(id: item.id)
        XCTAssertEqual(payload?.text, "新文本内容")
        XCTAssertNil(payload?.rtfData, "空 Data 应清空该列")

        // byte_size / hash 以剩余内容重算 → 同内容再插入会去重命中本条
        let again = store.insert(text("新文本内容"), maxDataBytes: 20 << 20)
        XCTAssertEqual(store.count, 1, "哈希重算一致 → 同内容去重,不新建")
        XCTAssertEqual(again?.id, item.id)

        // title / sticky / parent 等元数据不动
        XCTAssertEqual(store.item(id: item.id)?.title, "我的标题")
        XCTAssertEqual(store.item(id: item.id)?.pinned, true)
        XCTAssertEqual(store.item(id: item.id)?.parentID, -1)

        // 新增 HTML 列(此前没有 → 保存后创建;kind 随之更新)
        XCTAssertTrue(store.updateClipContent(id: item.id, text: nil, rtfData: nil,
                                              htmlData: Data("<b>h</b>".utf8)))
        XCTAssertEqual(store.payload(id: item.id)?.htmlData, Data("<b>h</b>".utf8))
        XCTAssertEqual(store.item(id: item.id)?.kind, .html, "kind 随剩余内容更新")

        // 清空全部格式 → 拒绝并回滚(不留空条目,口径同 deleteFormats)
        XCTAssertFalse(store.updateClipContent(id: item.id, text: "", rtfData: Data(), htmlData: Data()),
                       "全删空应拒绝")
        XCTAssertNotNil(store.payload(id: item.id)?.text, "拒绝后内容保持原样")
        XCTAssertNotNil(store.item(id: item.id))
    }

    func testUpdateClipContentEmptyMeansClearColumn() {
        let item = store.insert(RawClip(text: "文本", htmlData: Data("<i>x</i>".utf8)),
                                maxDataBytes: 20 << 20)!
        // 清空 html 列(空 Data = 置 NULL),文本保留 → 仍允许(还有文本)
        XCTAssertTrue(store.updateClipContent(id: item.id, text: nil, rtfData: nil, htmlData: Data()))
        XCTAssertNil(store.payload(id: item.id)?.htmlData)
        XCTAssertEqual(store.payload(id: item.id)?.text, "文本")

        // 空串文本 = 清空 text 列;此时唯一格式将失去 → 拒绝(false)且内容不变
        XCTAssertFalse(store.updateClipContent(id: item.id, text: "", rtfData: nil, htmlData: nil),
                       "唯一格式清空应拒绝")
        XCTAssertEqual(store.payload(id: item.id)?.text, "文本", "拒绝后保持原样")
    }

    func testUpdateClipContentRejectsGroupAndMissing() {
        let g = store.createGroup(name: "组", parentID: -1)!
        XCTAssertFalse(store.updateClipContent(id: g.id, text: "x", rtfData: nil, htmlData: nil),
                       "组行不接受内容编辑")
        XCTAssertFalse(store.updateClipContent(id: 999, text: "x", rtfData: nil, htmlData: nil),
                       "不存在的条目 → false")
    }

    // MARK: 条目热键

    func testClipHotkeyCRUDAndLifecycle() {
        let a = store.insert(text("热键条目"), maxDataBytes: 20 << 20)!
        XCTAssertNil(store.clipHotkey(id: a.id))

        let hk = ClipHotkey(keyCode: 9, modifiers: UInt(cmdKey | shiftKey), isGlobal: true)
        store.setClipHotkey(id: a.id, hotkey: hk)
        XCTAssertEqual(store.clipHotkey(id: a.id), hk)

        // 更新(含非全局)
        let local = ClipHotkey(keyCode: 98, modifiers: 4, isGlobal: false)
        store.setClipHotkey(id: a.id, hotkey: local)
        XCTAssertEqual(store.clipHotkey(id: a.id)?.keyCode, 98)
        XCTAssertEqual(store.clipHotkey(id: a.id)?.isGlobal, false)

        // 全量枚举
        XCTAssertEqual(store.allClipHotkeys().count, 1)
        XCTAssertEqual(store.allClipHotkeys().first?.clipID, a.id)

        // 跨重启持久化(随库,不进 UserDefaults)
        let dbPath = store.dbPathForTesting()
        store = nil
        store = ClipStore(path: dbPath)
        XCTAssertEqual(store.clipHotkey(id: a.id), local, "条目热键应持久化在库中")

        // 删除条目 → 绑定随行清理
        store.delete(id: a.id)
        XCTAssertNil(store.clipHotkey(id: a.id))
        XCTAssertTrue(store.allClipHotkeys().isEmpty)
    }

    // MARK: 删除剪贴板数据

    func testDeleteClipsRespectsProtections() {
        let normal = insert("普通")
        let sticky = insert("置顶保护")
        let noDelete = insert("永不删除保护")
        let g = store.createGroup(name: "组行", parentID: -1)!
        let child = store.insert(RawClip(text: "组内保护",
                                         extraFormats: [ClipFormat(type: "x.child", data: Data([2]))]),
                                 maxDataBytes: 20 << 20, parentID: g.id)!
        let extra = store.insert(RawClip(text: "带附加格式",
                                         extraFormats: [ClipFormat(type: "x.y", data: Data("1".utf8))]),
                                 maxDataBytes: 20 << 20)!
        store.setPinned(sticky.id, true)
        store.setNoDelete(noDelete.id, true)

        let selectedIDs = [normal.id, sticky.id, noDelete.id, g.id, child.id, extra.id]
        let protected = selectedIDs.compactMap { store.item(id: $0) }.filter(ClipStore.isProtectedFromCleanup)
        XCTAssertEqual(Set(protected.map(\.id)), Set([sticky.id, noDelete.id, g.id, child.id]),
                       "清理窗口共用的保护口径包含组内项")
        let result = store.deleteClips(ids: selectedIDs + [normal.id, child.id, 999])
        XCTAssertEqual(result.deleted, 2, "普通条目与附加格式条目可删")
        XCTAssertEqual(result.skipped, protected.count, "置顶/永不删除/组行/子项跳过,重复 ID 不重复计数")
        XCTAssertNil(store.item(id: normal.id))
        XCTAssertNil(store.item(id: extra.id))
        XCTAssertNotNil(store.item(id: sticky.id))
        XCTAssertNotNil(store.item(id: noDelete.id))
        XCTAssertNotNil(store.item(id: g.id))
        XCTAssertNotNil(store.item(id: child.id))
        XCTAssertEqual(store.payload(id: child.id)?.extraFormats.first?.data, Data([2]))
        XCTAssertEqual(store.scalarIntForTesting("SELECT COUNT(*) FROM clip_formats"), 1,
                       "仅回收被删条目的附加格式,保留组内条目格式")
    }

    func testSearchForDeleteFilters() {
        let t0 = Date().timeIntervalSince1970
        let apple = insert("苹果内容")
        let rtf = store.insert(RawClip(text: "富文本", rtfData: Data("{\\rtf1}".utf8)),
                               maxDataBytes: 20 << 20)!
        let files = store.insert(RawClip(filePaths: ["/tmp/a.png"]), maxDataBytes: 20 << 20)!
        let withExtra = store.insert(RawClip(text: "带附加",
                                             extraFormats: [ClipFormat(type: "z.z", data: Data("9".utf8))]),
                                     maxDataBytes: 20 << 20)!
        // 显式钉住创建时间,避免测试对真实时钟敏感
        for (item, offset) in [(apple, 0.0), (rtf, 2.0), (files, 4.0), (withExtra, 6.0)] {
            store.rawExecForTesting("UPDATE clips SET created_at = \(t0 + offset) WHERE id = \(item.id)")
        }
        store.setTitle(apple.id, "标题命中词")
        store.markPasted(id: apple.id, at: Date(timeIntervalSince1970: t0 + 5))
        store.markPasted(id: files.id, at: Date(timeIntervalSince1970: t0 + 100))

        // 无过滤 → 全部条目(不含组)
        XCTAssertEqual(store.searchForDelete(filters: ClipDeleteFilter()).count, 4)

        // 标题包含:命中 title 或 text
        XCTAssertEqual(store.searchForDelete(filters: ClipDeleteFilter(titleContains: "标题命中")).count, 1)
        XCTAssertEqual(store.searchForDelete(filters: ClipDeleteFilter(titleContains: "苹果内容")).count, 1)

        // 创建时间:只含窗口 [t0+1.5, t0+3.5] 内创建的(rtf)
        let win = ClipDeleteFilter(createdStart: Date(timeIntervalSince1970: t0 + 1.5),
                                   createdEnd: Date(timeIntervalSince1970: t0 + 3.5))
        XCTAssertEqual(store.searchForDelete(filters: win).map(\.id), [rtf.id])

        // 上次使用:apple(用过)在窗口内;从未粘贴的 rtf 不命中
        let used = ClipDeleteFilter(lastUsedStart: Date(timeIntervalSince1970: t0),
                                    lastUsedEnd: Date(timeIntervalSince1970: t0 + 10))
        XCTAssertEqual(store.searchForDelete(filters: used).map(\.id), [apple.id])

        // 格式:rtf 列
        XCTAssertEqual(store.searchForDelete(filters: ClipDeleteFilter(format: ClipUTI.rtf)).count, 1)
        // 文本格式:files 条目的 text 只是路径预览,不算
        XCTAssertEqual(Set(store.searchForDelete(filters: ClipDeleteFilter(format: ClipUTI.text)).map(\.id)),
                       Set([apple.id, rtf.id, withExtra.id]))
        // 文件
        XCTAssertEqual(store.searchForDelete(filters: ClipDeleteFilter(format: ClipUTI.fileURL)).map(\.id),
                       [files.id])
        // 附加格式
        XCTAssertEqual(store.searchForDelete(filters: ClipDeleteFilter(format: "extra")).map(\.id),
                       [withExtra.id])
    }

    // MARK: 排序方向(最新在上/在下)

    func testOrderDirectionSetting() {
        let a = insert("旧")
        let b = insert("新")
        XCTAssertEqual(topIDs(), [b.id, a.id], "默认最新在上")

        UserDefaults.standard.set(false, forKey: DittoSettings.orderLatestOnTopKey)
        XCTAssertEqual(topIDs(), [a.id, b.id], "关闭后最旧在上")

        // 置顶条目仍在最前(置顶区不随方向翻转)
        store.setStickyTop(b.id)
        XCTAssertEqual(topIDs(), [b.id, a.id])

        UserDefaults.standard.removeObject(forKey: DittoSettings.orderLatestOnTopKey)
        store.setSticky(b.id, false)
        XCTAssertEqual(topIDs(), [b.id, a.id], "恢复默认:最新在上")

        // search 结果同样跟随方向
        UserDefaults.standard.set(false, forKey: DittoSettings.orderLatestOnTopKey)
        XCTAssertEqual(store.search("旧", limit: 10).count, 1)
        UserDefaults.standard.removeObject(forKey: DittoSettings.orderLatestOnTopKey)
    }

    static var registrations: [(String, (Wave2FeatureTests) -> Void)] {
        [
            ("testStickyOrderingOperations", { $0.testStickyOrderingOperations() }),
            ("testStickyNotAffectedByClipOrderMoves", { $0.testStickyNotAffectedByClipOrderMoves() }),
            ("testLegacyPinnedMigrationAssignsStickyOrder", { $0.testLegacyPinnedMigrationAssignsStickyOrder() }),
            ("testSetTitleAndTitleSearch", { $0.testSetTitleAndTitleSearch() }),
            ("testUpdateClipContentRecomputesHashAndKeepsMeta", { $0.testUpdateClipContentRecomputesHashAndKeepsMeta() }),
            ("testUpdateClipContentEmptyMeansClearColumn", { $0.testUpdateClipContentEmptyMeansClearColumn() }),
            ("testUpdateClipContentRejectsGroupAndMissing", { $0.testUpdateClipContentRejectsGroupAndMissing() }),
            ("testClipHotkeyCRUDAndLifecycle", { $0.testClipHotkeyCRUDAndLifecycle() }),
            ("testDeleteClipsRespectsProtections", { $0.testDeleteClipsRespectsProtections() }),
            ("testSearchForDeleteFilters", { $0.testSearchForDeleteFilters() }),
            ("testOrderDirectionSetting", { $0.testOrderDirectionSetting() }),
        ]
    }
}

// MARK: - 行级 diff(对比条目窗口的 TextDiff)

final class TextDiffTests: XCTestCase {

    func testIdenticalInputsAllSame() {
        let diff = TextDiff.lines(old: "a\nb\nc", new: "a\nb\nc")
        XCTAssertEqual(diff.count, 3)
        XCTAssertTrue(diff.allSatisfy { $0.kind == .same })
    }

    func testRemovedAndAddedLines() {
        let diff = TextDiff.lines(old: "a\nb\nc", new: "a\nc")
        XCTAssertEqual(diff.map(\.kind), [.same, .removed, .same])
        XCTAssertEqual(diff[1].text, "b")

        let added = TextDiff.lines(old: "a\nc", new: "a\nb\nc")
        XCTAssertEqual(added.map(\.kind), [.same, .added, .same])
        XCTAssertEqual(added[1].text, "b")
    }

    func testEmptyInputs() {
        XCTAssertTrue(TextDiff.lines(old: "", new: "").isEmpty)
        let fromEmpty = TextDiff.lines(old: "", new: "x\ny")
        XCTAssertEqual(fromEmpty.map(\.kind), [.added, .added])
        let toEmpty = TextDiff.lines(old: "x\ny", new: "")
        XCTAssertEqual(toEmpty.map(\.kind), [.removed, .removed])
    }

    func testMiddleBlockChangeKeepsOrder() {
        // 中段整块替换:公共前后缀保留为 same,旧中段 removed、新中段 added
        let diff = TextDiff.lines(old: "head\nold1\nold2\ntail", new: "head\nnew1\ntail")
        XCTAssertEqual(diff.first?.kind, .same)
        XCTAssertEqual(diff.first?.text, "head")
        XCTAssertEqual(diff.last?.kind, .same)
        XCTAssertEqual(diff.last?.text, "tail")
        let removed = diff.filter { $0.kind == .removed }.map(\.text)
        let added = diff.filter { $0.kind == .added }.map(\.text)
        XCTAssertEqual(removed, ["old1", "old2"])
        XCTAssertEqual(added, ["new1"])
        // 呈现顺序:removed 块在 added 块之前(与常见 unified diff 一致)
        XCTAssertLessThanOrEqual(diff.firstIndex { $0.kind == .removed } ?? -1,
                                 diff.firstIndex { $0.kind == .added } ?? -1)
    }

    func testSharedLinesMatchedNotDuplicated() {
        // 重复行:LCS 保证删除/新增数量互补,不产生幻影
        let diff = TextDiff.lines(old: "x\nx", new: "x")
        XCTAssertEqual(diff.filter { $0.kind == .same }.count, 1)
        XCTAssertEqual(diff.filter { $0.kind == .removed }.count, 1)
    }

    static var registrations: [(String, (TextDiffTests) -> Void)] {
        [
            ("testIdenticalInputsAllSame", { $0.testIdenticalInputsAllSame() }),
            ("testRemovedAndAddedLines", { $0.testRemovedAndAddedLines() }),
            ("testEmptyInputs", { $0.testEmptyInputs() }),
            ("testMiddleBlockChangeKeepsOrder", { $0.testMiddleBlockChangeKeepsOrder() }),
            ("testSharedLinesMatchedNotDuplicated", { $0.testSharedLinesMatchedNotDuplicated() }),
        ]
    }
}
