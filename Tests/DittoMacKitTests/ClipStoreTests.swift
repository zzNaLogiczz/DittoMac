import Foundation

/// ClipStore 正确性回归(F1/F2/F3/F6/F7)
final class ClipStoreTests: XCTestCase {
    var store: ClipStore!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dittomac-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ClipStore(path: dir.appendingPathComponent("t.sqlite").path)
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    private func textClip(_ s: String, app: String? = nil) -> RawClip {
        RawClip(text: s, appName: app)
    }

    func testInsertAndRecent() {
        let a = store.insert(textClip("你好 ditto"), maxDataBytes: 20 << 20)
        XCTAssertNotNil(a)
        _ = store.insert(textClip("second"), maxDataBytes: 20 << 20)
        let rows = store.recent(limit: 10)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.text, "second", "最新应在最前")
        XCTAssertEqual(rows.first?.kind, .text)
    }

    func testDedupBumpsTimestamp() {
        let first = store.insert(textClip("重复内容"), maxDataBytes: 20 << 20)
        sleep(1) // 保证时间戳可区分
        let other = store.insert(textClip("干扰"), maxDataBytes: 20 << 20)
        let again = store.insert(textClip("重复内容"), maxDataBytes: 20 << 20)

        XCTAssertEqual(store.count, 2, "重复内容不得新建行")
        XCTAssertEqual(again?.id, first?.id, "应置顶旧记录")
        XCTAssertGreaterThan(again!.createdAt, first!.createdAt, "时间戳应被更新")
        XCTAssertEqual(store.recent(limit: 10).first?.id, first?.id, "旧记录应回到顶部")
        _ = other
    }

    func testMultiFormatPayloadRoundtrip() {
        let rtf = "{\\rtf1\\ansi Hello}".data(using: .utf8)!
        let html = "<b>Hello</b>".data(using: .utf8)!
        let item = store.insert(RawClip(text: "Hello", rtfData: rtf, htmlData: html, appName: "TextEdit"),
                                maxDataBytes: 20 << 20)
        let payload = store.payload(id: item!.id)
        XCTAssertEqual(payload?.text, "Hello")
        XCTAssertEqual(payload?.rtfData, rtf)
        XCTAssertEqual(payload?.htmlData, html)
        XCTAssertEqual(payload?.appName, "TextEdit")
        XCTAssertEqual(item?.kind, .rtf, "有 RTF 时 kind 应为 rtf(文本之外的最富格式)")
    }

    func testSearchMultiTermANDCaseInsensitive() {
        for t in ["GitHub Release Notes", "github actions 用法", "Homebrew GitHub", "完全无关条目"] {
            _ = store.insert(textClip(t), maxDataBytes: 20 << 20)
        }
        XCTAssertEqual(store.search("github", limit: 10).count, 3, "大小写不敏感")
        XCTAssertEqual(store.search("GITHUB notes", limit: 10).count, 1, "多词 AND")
        XCTAssertEqual(store.search("github 用法", limit: 10).count, 1, "中英混合 AND")
        XCTAssertEqual(store.search("", limit: 10).count, 4, "空查询=全部")
        XCTAssertEqual(store.search("zzz 不存在", limit: 10).count, 0)
    }

    func testSearchEscapesLikeWildcards() {
        _ = store.insert(textClip("100% 命中 \\ 路径 _下划线_"), maxDataBytes: 20 << 20)
        XCTAssertEqual(store.search("100%", limit: 10).count, 1, "% 不得当通配符")
        XCTAssertEqual(store.search("路径 _下", limit: 10).count, 1, "_ 不得当通配符")
        XCTAssertEqual(store.search("%_", limit: 10).count, 0)
    }

    func testFilesKindAndPathJoin() {
        let item = store.insert(RawClip(filePaths: ["/a/b.png", "/c/d.txt"], appName: "Finder"),
                                maxDataBytes: 20 << 20)
        XCTAssertEqual(item?.kind, .files)
        XCTAssertTrue(item?.text?.contains("/a/b.png") == true, "文件条目 text 应含路径")
        let payload = store.payload(id: item!.id)
        XCTAssertEqual(payload?.filePaths, ["/a/b.png", "/c/d.txt"])
    }

    func testPinnedFloatsAndSurvivesPruneAndClear() {
        let p = store.insert(textClip("置顶条目"), maxDataBytes: 20 << 20)
        store.setPinned(p!.id, true)
        for i in 0..<10 { _ = store.insert(textClip("普通\(i)"), maxDataBytes: 20 << 20) }
        XCTAssertTrue(store.recent(limit: 100).first?.pinned == true, "置顶浮顶")

        store.prune(maxItems: 5, maxAgeDays: 3650)
        XCTAssertEqual(store.count, 6, "5 条普通 + 1 条置顶")
        XCTAssertNotNil(store.payload(id: p!.id), "置顶不得被 prune 删除")

        store.clear(keepingPinned: true)
        XCTAssertEqual(store.count, 1, "清空保留置顶")
        XCTAssertNotNil(store.payload(id: p!.id))
    }

    func testPruneByAge() {
        _ = store.insert(textClip("旧的"), maxDataBytes: 20 << 20)
        // 直接用 SQL 把第一条改成 40 天前
        store.rawExecForTesting("UPDATE clips SET created_at = strftime('%s','now') - 40*86400 WHERE text='旧的'")
        _ = store.insert(textClip("新的"), maxDataBytes: 20 << 20)
        store.prune(maxItems: 1000, maxAgeDays: 30)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.recent(limit: 10).first?.text, "新的")
    }

    func testOversizedInsertRejected() {
        let big = RawClip(imageData: Data(repeating: 0xAB, count: 5 << 20))
        XCTAssertNil(store.insert(big, maxDataBytes: 1 << 20), "超限应丢弃")
    }

    func testPersistenceAcrossReopen() {
        _ = store.insert(RawClip(text: "重启保留", rtfData: Data([0x7B, 0x7D])), maxDataBytes: 20 << 20)
        let dbPath = store.dbPathForTesting()
        store = nil
        store = ClipStore(path: dbPath)
        let rows = store.recent(limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(store.payload(id: rows[0].id)?.rtfData, Data([0x7B, 0x7D]))
    }

    // MARK: QA 缺口修复的回归

    func testSearchAdvancedOperators() {
        for t in ["苹果 香蕉", "苹果 樱桃", "榴莲 单独", "OR 这个词"] {
            _ = store.insert(textClip(t), maxDataBytes: 20 << 20)
        }
        // OR
        XCTAssertEqual(store.search("香蕉 OR 樱桃", limit: 10).count, 2)
        // NOT(两种写法)与 AND 组合
        XCTAssertEqual(store.search("苹果 NOT 樱桃", limit: 10).count, 1)
        XCTAssertEqual(store.search("苹果 !樱桃", limit: 10).count, 1)
        // 引号短语:精确顺序匹配
        XCTAssertEqual(store.search("\"苹果 香蕉\"", limit: 10).count, 1)
        XCTAssertEqual(store.search("\"香蕉 苹果\"", limit: 10).count, 0, "短语不应乱序命中")
        // 引号内的 OR 是字面词
        XCTAssertEqual(store.search("\"OR 这个词\"", limit: 10).count, 1)
        // 通配符 *
        XCTAssertEqual(store.search("榴*", limit: 10).count, 1)
        XCTAssertEqual(store.search("苹果 OR 榴* NOT 樱桃", limit: 10).count, 2)
    }

    func testHashDistinguishesHtml() {
        let a = store.insert(RawClip(text: "同文本", htmlData: Data("<b>1</b>".utf8)), maxDataBytes: 20 << 20)
        let b = store.insert(RawClip(text: "同文本", htmlData: Data("<b>2</b>".utf8)), maxDataBytes: 20 << 20)
        XCTAssertEqual(store.count, 2, "同文本不同 HTML 不得合并")
        XCTAssertNotEqual(a?.id, b?.id)
    }

    /// F2 跨会话去重:哈希必须跨进程稳定(Hasher 每进程随机播种,会漏检;故用确定性 FNV-1a)
    func testDedupAcrossReopen() {
        let first = store.insert(RawClip(text: "重启后再次复制相同内容", appName: "AppA"), maxDataBytes: 20 << 20)
        XCTAssertNotNil(first)
        // 模拟"新进程":重开同一 DB
        let dbPath = store.dbPathForTesting()
        store = nil
        store = ClipStore(path: dbPath)
        _ = store.insert(RawClip(text: "干扰项"), maxDataBytes: 20 << 20)
        let again = store.insert(RawClip(text: "重启后再次复制相同内容", appName: "AppB"), maxDataBytes: 20 << 20)
        XCTAssertEqual(store.count, 2, "跨重启同内容不得新建行")
        XCTAssertEqual(again?.id, first?.id, "应置顶旧记录")
        XCTAssertEqual(store.recent(limit: 10).first?.id, first?.id)
        XCTAssertEqual(store.recent(limit: 10).first?.appName, "AppB", "来源更新为新值")
    }

    func testCorruptDatabaseRecovers() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dittomac-corrupt-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("bad.sqlite").path
        FileManager.default.createFile(atPath: dbPath, contents: Data("这不是一个 sqlite 文件而是一堆垃圾字节 0123456789".utf8))
        let recovered = ClipStore(path: dbPath)
        XCTAssertNotNil(recovered.lastRecoveryBackupPath, "应报告备份路径")
        XCTAssertEqual(recovered.count, 0)
        let item = recovered.insert(RawClip(text: "重建后可写"), maxDataBytes: 20 << 20)
        XCTAssertNotNil(item, "重建后不得静默丢写")
        XCTAssertEqual(recovered.recent(limit: 10).first?.text, "重建后可写")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.lastRecoveryBackupPath!))
    }

    func testMoveClipOrder() {
        let a = store.insert(textClip("A"), maxDataBytes: 20 << 20)!
        sleep(1)
        let b = store.insert(textClip("B"), maxDataBytes: 20 << 20)!
        sleep(1)
        let c = store.insert(textClip("C"), maxDataBytes: 20 << 20)!
        XCTAssertEqual(store.recent(limit: 10).map(\.text), ["C", "B", "A"])
        store.moveClip(c.id, .toDown)
        XCTAssertEqual(store.recent(limit: 10).map(\.text), ["B", "C", "A"])
        store.moveClip(c.id, .toUp)
        XCTAssertEqual(store.recent(limit: 10).map(\.text), ["C", "B", "A"])
        store.moveClip(c.id, .toLast)
        XCTAssertEqual(store.recent(limit: 10).map(\.text), ["B", "A", "C"])
        store.moveClip(c.id, .toTop)
        XCTAssertEqual(store.recent(limit: 10).map(\.text), ["C", "B", "A"])
        _ = a; _ = b
    }

    // MARK: 附加自定义格式 + 格式删除(原版 Types 表 / Copy Properties "Copy Data")

    func testExtraFormatRoundtrip() {
        let extras = [ClipFormat(type: "com.dittomac.testfmt", data: Data("payload".utf8)),
                      ClipFormat(type: "public.xml", data: Data("<a/>".utf8))]
        let raw = RawClip(text: "extras-roundtrip", extraFormats: extras, appName: "AppX")
        let item = store.insert(raw, maxDataBytes: 20 << 20)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.byteSize, raw.byteSize, "体积应包含附加格式")
        let back = store.payload(id: item!.id)
        XCTAssertEqual(back?.extraFormats, extras, "附加格式应按入库序完整取回")
        XCTAssertEqual(back?.text, "extras-roundtrip")

        // 哈希按 type 排序参与:捕获顺序不同(数组乱序)的同内容仍是同一条
        let shuffled = RawClip(text: "extras-roundtrip", extraFormats: extras.reversed(), appName: "AppX")
        XCTAssertEqual(shuffled.contentHash, raw.contentHash)
        _ = store.insert(shuffled, maxDataBytes: 20 << 20)
        XCTAssertEqual(store.count, 1, "附加格式乱序不得新建行")

        // 超限守卫也要把附加格式算进去
        let big = RawClip(text: "t", extraFormats: [ClipFormat(type: "x", data: Data(repeating: 1, count: 2 << 20))])
        XCTAssertNil(store.insert(big, maxDataBytes: 1 << 20), "附加格式计入体积上限")

        // 重开库仍能取回
        let dbPath = store.dbPathForTesting()
        store = nil
        store = ClipStore(path: dbPath)
        XCTAssertEqual(store.payload(id: item!.id)?.extraFormats, extras)
    }

    func testFormatsListsKnownAndExtras() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])   // PNG 魔数
        let item = store.insert(RawClip(text: "多格式",
                                        rtfData: Data("r".utf8),
                                        htmlData: Data("h".utf8),
                                        imageData: png,
                                        extraFormats: [ClipFormat(type: "a.x", data: Data("1".utf8)),
                                                       ClipFormat(type: "b.y", data: Data("2".utf8))]),
                                maxDataBytes: 20 << 20)!
        let fmts = store.formats(id: item.id)
        XCTAssertEqual(fmts.map(\.type),
                       [ClipUTI.text, ClipUTI.rtf, ClipUTI.html, ClipUTI.png, "a.x", "b.y"],
                       "已知格式在前(text/rtf/html/image/files),附加格式按入库序在后")
        if fmts.count == 6 {
            XCTAssertEqual(fmts[0].data, Data("多格式".utf8))
            XCTAssertEqual(fmts[3].data, png)
        }

        // TIFF 魔数 → public.tiff
        let tiff = store.insert(RawClip(imageData: Data([0x49, 0x49, 0x2A, 0x00, 0x00])), maxDataBytes: 20 << 20)!
        XCTAssertEqual(store.formats(id: tiff.id).map(\.type), [ClipUTI.tiff])

        // files 条目:file_paths 列换行拼接为 public.file-url 数据;
        // text 列只是路径预览(payload 口径置 nil),不算保存的格式、不列出
        let files = store.insert(RawClip(filePaths: ["/a", "/b"]), maxDataBytes: 20 << 20)!
        let fileFmts = store.formats(id: files.id)
        XCTAssertEqual(fileFmts.map(\.type), [ClipUTI.fileURL])
        XCTAssertEqual(fileFmts.last?.data, Data("/a\n/b".utf8))
    }

    func testDeleteFormatsUpdatesHashAndDedup() {
        let extra = ClipFormat(type: "com.dittomac.testfmt", data: Data("extra-1".utf8))
        let item = store.insert(RawClip(text: "剩余内容", rtfData: Data("{\\rtf1}".utf8), extraFormats: [extra]),
                                maxDataBytes: 20 << 20)!

        // 删 rtf(置列 NULL)+ 附加格式(删行)
        XCTAssertTrue(store.deleteFormats(id: item.id, types: [ClipUTI.rtf, "com.dittomac.testfmt"]))
        let payload = store.payload(id: item.id)
        XCTAssertEqual(payload?.text, "剩余内容")
        XCTAssertNil(payload?.rtfData, "已知格式删除应置列 NULL")
        XCTAssertTrue(payload?.extraFormats.isEmpty == true, "附加格式行应被删除")

        // byte_size 以剩余内容重算;哈希与"重插同样剩余内容"一致 → 去重命中更新后的条目
        XCTAssertEqual(store.recent(limit: 10).first { $0.id == item.id }?.byteSize,
                       "剩余内容".utf8.count)
        let again = store.insert(RawClip(text: "剩余内容"), maxDataBytes: 20 << 20)
        XCTAssertEqual(store.count, 1, "哈希重算一致 → 同内容去重,不新建")
        XCTAssertEqual(again?.id, item.id, "应命中更新后的原条目")
    }

    func testDeleteFormatsRefusesEmptyingClip() {
        let item = store.insert(RawClip(text: "only-text",
                                        extraFormats: [ClipFormat(type: "x.y", data: Data("z".utf8))]),
                                maxDataBytes: 20 << 20)!
        XCTAssertFalse(store.deleteFormats(id: item.id, types: [ClipUTI.text, "x.y"]), "全删 = 清空条目,应拒绝")
        XCTAssertEqual(store.payload(id: item.id)?.text, "only-text", "拒绝后内容保持原样")
        XCTAssertTrue(store.payload(id: item.id)?.extraFormats.isEmpty == false)

        XCTAssertTrue(store.deleteFormats(id: item.id, types: ["x.y"]), "删部分允许")
        XCTAssertFalse(store.deleteFormats(id: item.id, types: [ClipUTI.text]), "只剩文本时删文本应拒绝")
        XCTAssertFalse(store.deleteFormats(id: 999, types: [ClipUTI.text]), "条目不存在 → false")
    }

    func testOrphanFormatsCleanupAfterDeleteClearPrune() {
        let a = store.insert(RawClip(text: "孤儿-a",
                                     extraFormats: [ClipFormat(type: "o.a", data: Data("1".utf8))]),
                             maxDataBytes: 20 << 20)!
        let pinned = store.insert(RawClip(text: "孤儿-置顶",
                                          extraFormats: [ClipFormat(type: "o.p", data: Data("2".utf8))]),
                                  maxDataBytes: 20 << 20)!
        store.setPinned(pinned.id, true)
        XCTAssertEqual(store.scalarIntForTesting("SELECT COUNT(*) FROM clip_formats"), 2)

        store.delete(id: a.id)
        XCTAssertEqual(store.scalarIntForTesting("SELECT COUNT(*) FROM clip_formats"), 1,
                       "删条目应回收其附加格式行")

        store.clear(keepingPinned: true)
        XCTAssertEqual(store.scalarIntForTesting("SELECT COUNT(*) FROM clip_formats"), 1,
                       "置顶条目及其附加格式保留")

        store.clear(keepingPinned: false)
        XCTAssertEqual(store.scalarIntForTesting("SELECT COUNT(*) FROM clip_formats"), 0)

        _ = store.insert(RawClip(text: "孤儿-prune",
                                 extraFormats: [ClipFormat(type: "o.c", data: Data("3".utf8))]),
                         maxDataBytes: 20 << 20)
        XCTAssertEqual(store.scalarIntForTesting("SELECT COUNT(*) FROM clip_formats"), 1)
        store.prune(maxItems: 0, maxAgeDays: 3650)
        XCTAssertEqual(store.scalarIntForTesting("SELECT COUNT(*) FROM clip_formats"), 0,
                       "prune 删除的条目同样回收附加格式行")
    }

    /// files 条目的 text 列只是路径预览:格式列表不得把它当 public.utf8-plain-text 暴露,
    /// 直接按 UTI 请求删除也不得清掉预览;删除其唯一真实格式(file-url)应被拒绝
    func testFilesKindPreviewTextNotListedAsFormat() {
        let item = store.insert(RawClip(filePaths: ["/tmp/a.txt", "/tmp/b.txt"], appName: "Finder"),
                                maxDataBytes: 20 << 20)!
        let types = store.formats(id: item.id).map(\.type)
        XCTAssertEqual(types, [ClipUTI.fileURL], "files 条目只应列出 file-url 格式,预览文本不算")
        XCTAssertFalse(types.contains(ClipUTI.text))

        // 防御性:即使按 text UTI 显式请求,也不清预览列
        XCTAssertTrue(store.deleteFormats(id: item.id, types: [ClipUTI.text]))
        XCTAssertEqual(store.payload(id: item.id)?.text, nil, "payload 口径:files 条目 text 本就置 nil")
        XCTAssertEqual(store.recent(limit: 10).first?.text, "/tmp/a.txt\n/tmp/b.txt",
                       "列表预览列不得被误删")

        // 唯一真实格式(file-url)不可删 → 拒绝,不留空条目
        XCTAssertFalse(store.deleteFormats(id: item.id, types: [ClipUTI.fileURL]))
        XCTAssertEqual(store.payload(id: item.id)?.filePaths?.count, 2)
    }

    static var registrations: [(String, (ClipStoreTests) -> Void)] {
        [
            ("testInsertAndRecent", { $0.testInsertAndRecent() }),
            ("testDedupBumpsTimestamp", { $0.testDedupBumpsTimestamp() }),
            ("testMultiFormatPayloadRoundtrip", { $0.testMultiFormatPayloadRoundtrip() }),
            ("testSearchMultiTermANDCaseInsensitive", { $0.testSearchMultiTermANDCaseInsensitive() }),
            ("testSearchEscapesLikeWildcards", { $0.testSearchEscapesLikeWildcards() }),
            ("testFilesKindAndPathJoin", { $0.testFilesKindAndPathJoin() }),
            ("testPinnedFloatsAndSurvivesPruneAndClear", { $0.testPinnedFloatsAndSurvivesPruneAndClear() }),
            ("testPruneByAge", { $0.testPruneByAge() }),
            ("testOversizedInsertRejected", { $0.testOversizedInsertRejected() }),
            ("testPersistenceAcrossReopen", { $0.testPersistenceAcrossReopen() }),
            ("testSearchAdvancedOperators", { $0.testSearchAdvancedOperators() }),
            ("testHashDistinguishesHtml", { $0.testHashDistinguishesHtml() }),
            ("testDedupAcrossReopen", { $0.testDedupAcrossReopen() }),
            ("testCorruptDatabaseRecovers", { $0.testCorruptDatabaseRecovers() }),
            ("testMoveClipOrder", { $0.testMoveClipOrder() }),
            ("testExtraFormatRoundtrip", { $0.testExtraFormatRoundtrip() }),
            ("testFormatsListsKnownAndExtras", { $0.testFormatsListsKnownAndExtras() }),
            ("testDeleteFormatsUpdatesHashAndDedup", { $0.testDeleteFormatsUpdatesHashAndDedup() }),
            ("testDeleteFormatsRefusesEmptyingClip", { $0.testDeleteFormatsRefusesEmptyingClip() }),
            ("testOrphanFormatsCleanupAfterDeleteClearPrune", { $0.testOrphanFormatsCleanupAfterDeleteClearPrune() }),
            ("testFilesKindPreviewTextNotListedAsFormat", { $0.testFilesKindPreviewTextNotListedAsFormat() }),
        ]
    }
}
