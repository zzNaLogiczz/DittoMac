import Foundation
import SQLite3
import os

/// SQLITE_TRANSIENT:让 SQLite 绑定时立即拷贝数据(Swift 侧指针只在调用瞬间有效)
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 剪贴板历史的 SQLite 存储:WAL 模式,内部串行队列保证线程安全
public final class ClipStore: ClipStoring {

    private let db: OpaquePointer?   // 打开失败时为 nil,所有操作安全退化为空结果
    private let dbPath: String
    private let queue = DispatchQueue(label: "DittoMacKit.ClipStore")   // 串行:所有公开方法 sync 派发

    /// 损坏恢复:打开/校验失败时旧库已备份重命名,并新建了空库(UI 层据此提示用户)
    public private(set) var lastRecoveryBackupPath: String?

    private static let log = Logger(subsystem: "com.dittomac.DittoMacKit", category: "ClipStore")

    /// 错误双写:os_log(常驻,Console 可查)+ DiagLog(设置开启「写调试日志到
    /// 文件」时随 DiagLog.sink 落盘;关闭时 sink=nil 零开销)
    private static func failLog(_ message: String) {
        log.error("\(message, privacy: .public)")
        DiagLog.error("ClipStore: \(message)")
    }

    /// 列表/搜索取的轻量列(blob 除外);item(from:) 的列序与此一致
    private static let itemColumns = "id, kind, created_at, text, pinned, byte_size, app_name, hash, last_paste_at, no_delete, parent_id, is_group, title, sticky_order"

    private static let schema = """
        CREATE TABLE IF NOT EXISTS clips(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          created_at REAL NOT NULL,
          kind TEXT NOT NULL,
          hash TEXT NOT NULL,
          text TEXT,
          rtf BLOB, html BLOB, image BLOB,
          file_paths TEXT,
          byte_size INTEGER NOT NULL DEFAULT 0,
          pinned INTEGER NOT NULL DEFAULT 0,
          app_name TEXT,
          last_paste_at REAL,
          no_delete INTEGER NOT NULL DEFAULT 0,
          parent_id INTEGER NOT NULL DEFAULT -1,
          is_group INTEGER NOT NULL DEFAULT 0,
          title TEXT,
          sticky_order REAL
        );
        CREATE INDEX IF NOT EXISTS idx_clips_time ON clips(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_clips_hash ON clips(hash);
        CREATE TABLE IF NOT EXISTS clip_formats(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          clip_id INTEGER NOT NULL,
          type TEXT NOT NULL,
          data BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_clip_formats_clip ON clip_formats(clip_id);
        CREATE TABLE IF NOT EXISTS group_hotkeys(
          group_id INTEGER PRIMARY KEY,
          key_code INTEGER NOT NULL,
          mods INTEGER NOT NULL,
          is_global INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS clip_hotkeys(
          clip_id INTEGER PRIMARY KEY,
          key_code INTEGER NOT NULL,
          mods INTEGER NOT NULL,
          is_global INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS copy_buffers(
          buffer_index INTEGER PRIMARY KEY,
          clip_id INTEGER NOT NULL
        );
        """

    /// 旧库迁移:增量补列(列已存在时 ALTER 报错,忽略即可)。
    /// parent_id 的索引必须排在补列之后建:老库 schema 先建索引会因列不存在而
    /// 整个 schema 执行失败 → 被误判损坏重建(丢历史),所以放迁移列表尾部
    private static let migrations = [
        "ALTER TABLE clips ADD COLUMN last_paste_at REAL",
        "ALTER TABLE clips ADD COLUMN no_delete INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE clips ADD COLUMN parent_id INTEGER NOT NULL DEFAULT -1",
        "ALTER TABLE clips ADD COLUMN is_group INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE clips ADD COLUMN title TEXT",
        "ALTER TABLE clips ADD COLUMN sticky_order REAL",
        "CREATE INDEX IF NOT EXISTS idx_clips_parent ON clips(parent_id)",
    ]

    /// 一次性数据迁移:旧库只有 pinned 布尔,升级到 sticky_order 后,
    /// 把"pinned=1 且 sticky_order 为空"的行按 created_at DESC 赋 0,1,2…
    /// (最新的置顶条目成为首位)。幂等:正常运行时两列在写入端保持同步,
    /// 只有旧库升级首轮会有命中行
    private static func migrateLegacyPinned(_ db: OpaquePointer) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT id FROM clips WHERE pinned = 1 AND sticky_order IS NULL ORDER BY created_at DESC",
                                 -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        var order = 0.0
        for id in ids {
            var update: OpaquePointer?
            defer { sqlite3_finalize(update) }
            guard sqlite3_prepare_v2(db, "UPDATE clips SET sticky_order = ? WHERE id = ?",
                                     -1, &update, nil) == SQLITE_OK, let update else { continue }
            sqlite3_bind_double(update, 1, order)
            sqlite3_bind_int64(update, 2, id)
            _ = sqlite3_step(update)
            order += 1
        }
    }

    // MARK: - 生命周期

    public convenience init() {
        self.init(path: nil)
    }

    /// path 为 nil 时使用默认位置:便携模式 → <便携根>/DittoMac/ditto.sqlite
    /// (PortableMode.bootstrap 在 main 引导阶段已完成),常规 → ~/Library/
    /// Application Support/DittoMac/ditto.sqlite
    init(path: String?) {
        let defaultPath = PortableMode.defaultDatabasePath
        let resolved = path ?? defaultPath
        dbPath = resolved

        // 目录不存在则建
        let dir = (resolved as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // 打开 + PRAGMA + 建表 + 完整性探测;任一失败 → 备份旧库重建(不再静默丢写)
        var handle = Self.openAndVerify(at: resolved)
        var recovery: String?
        if handle == nil {
            recovery = Self.backupCorruptFiles(at: resolved)
            handle = Self.openAndVerify(at: resolved)
            Self.failLog("数据库损坏,已备份并重建: \(recovery ?? "?")")
        }
        db = handle
        lastRecoveryBackupPath = recovery
    }

    /// 打开 + PRAGMA + 建表 + 完整性探测;全通过返回句柄,否则关闭并返回 nil
    private static func openAndVerify(at path: String) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let opened = handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 失败"
            if handle != nil { sqlite3_close_v2(handle) }
            Self.failLog("打开数据库失败: \(reason)")
            return nil
        }
        let verify: (OpaquePointer) -> Bool = { db in
            guard sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000;",
                               nil, nil, nil) == SQLITE_OK else { return false }
            guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { return false }
            for sql in migrations {
                _ = sqlite3_exec(db, sql, nil, nil, nil)   // 列已存在时失败,忽略
            }
            // 旧 pinned 布尔 → sticky_order 序(幂等,仅旧库升级首轮有命中行)
            migrateLegacyPinned(db)
            // 快速探测 1:库结构可查(损坏文件在 prepare/step 上暴露)
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM clips", -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return false }
            // 快速探测 2:quick_check 覆盖"索引完好但数据页损坏"的僵尸库
            // (COUNT(*) 走最小索引,查不出这种损坏 —— 会变成 recent=0 / insert 恒 nil 的静默丢写)
            var checkStmt: OpaquePointer?
            defer { sqlite3_finalize(checkStmt) }
            guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &checkStmt, nil) == SQLITE_OK,
                  sqlite3_step(checkStmt) == SQLITE_ROW,
                  let row = sqlite3_column_text(checkStmt, 0),
                  String(cString: row) == "ok" else { return false }
            return true
        }
        guard verify(opened) else {
            sqlite3_close_v2(opened)
            return nil
        }
        return opened
    }

    /// 把疑似损坏的库文件(含 -wal/-shm)改名备份,返回备份主文件路径
    private static func backupCorruptFiles(at path: String) -> String? {
        let fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = "\(path).corrupt-\(stamp)"
        for suffix in ["", "-wal", "-shm"] {
            let from = path + suffix
            let to = backup + suffix
            if fm.fileExists(atPath: from) {
                try? fm.moveItem(atPath: from, toPath: to)
            }
        }
        return fm.fileExists(atPath: backup) ? backup : nil
    }

    deinit {
        sqlite3_close_v2(db)
    }

    // MARK: - ClipStoring

    @discardableResult
    public func insert(_ raw: RawClip, maxDataBytes: Int) -> ClipItem? {
        insert(raw, maxDataBytes: maxDataBytes, parentID: -1)
    }

    /// 普通捕获按全库去重;命中旧记录时只更新时间戳/来源,不动 parent_id。
    /// 显式抓板入组使用 captureToGroup,避免将已有内容的目标组请求丢掉。
    @discardableResult
    public func insert(_ raw: RawClip, maxDataBytes: Int, parentID: Int64) -> ClipItem? {
        insert(raw, maxDataBytes: maxDataBytes, parentID: parentID, deduplicateInParentOnly: false)
    }

    /// 显式抓板入组:复用目标组中的同内容条目,否则新建组内副本。
    /// 不移动顶层或其他组的原条目;目标不存在或不是组时拒绝写入。
    @discardableResult
    public func captureToGroup(_ raw: RawClip, maxDataBytes: Int, parentID: Int64) -> ClipItem? {
        insert(raw, maxDataBytes: maxDataBytes, parentID: parentID, deduplicateInParentOnly: true)
    }

    private func insert(_ raw: RawClip, maxDataBytes: Int, parentID: Int64,
                        deduplicateInParentOnly: Bool) -> ClipItem? {
        queue.sync {
            guard let db, !raw.isEmpty else { return nil }
            let totalBytes = raw.byteSize + (raw.filePaths?.joined(separator: "\n").utf8.count ?? 0)
            guard totalBytes <= maxDataBytes else { return nil }   // 超限直接丢弃
            if deduplicateInParentOnly {
                guard items("SELECT \(Self.itemColumns) FROM clips WHERE id = ? AND is_group = 1",
                            bind: { sqlite3_bind_int64($0, 1, parentID) }).first != nil else { return nil }
            }

            let now = Date()
            let hash = raw.contentHash

            // 普通捕获全库去重;显式抓板只在目标组去重,不会修改其他组或顶层副本。
            let parentScope = deduplicateInParentOnly ? " AND parent_id = ? AND is_group = 0" : ""
            if let last = items("SELECT \(Self.itemColumns) FROM clips WHERE hash = ?\(parentScope) ORDER BY created_at DESC LIMIT 1",
                                bind: {
                                    sqlite3_bind_text($0, 1, hash, -1, sqliteTransient)
                                    if deduplicateInParentOnly { sqlite3_bind_int64($0, 2, parentID) }
                                }).first {
                guard run("UPDATE clips SET created_at = ?, app_name = ? WHERE id = ?",
                          bind: {
                            sqlite3_bind_double($0, 1, now.timeIntervalSince1970)
                            bindText($0, 2, raw.appName)
                            sqlite3_bind_int64($0, 3, last.id)
                          }) else { return nil }
                var bumped = last
                bumped.createdAt = now
                bumped.appName = raw.appName
                return bumped
            }

            // text 列:纯文本;无文本的文件条目存路径预览(换行拼接);图片存 nil
            let textColumn: String?
            if let text = raw.text, !text.isEmpty { textColumn = text }
            else if let paths = raw.filePaths, !paths.isEmpty { textColumn = paths.joined(separator: "\n") }
            else { textColumn = nil }

            guard run("""
                INSERT INTO clips(created_at, kind, hash, text, rtf, html, image, file_paths, byte_size, pinned, app_name, parent_id)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                """, bind: {
                    sqlite3_bind_double($0, 1, now.timeIntervalSince1970)
                    sqlite3_bind_text($0, 2, raw.kind.rawValue, -1, sqliteTransient)
                    sqlite3_bind_text($0, 3, hash, -1, sqliteTransient)
                    bindText($0, 4, textColumn)
                    bindBlob($0, 5, raw.rtfData)
                    bindBlob($0, 6, raw.htmlData)
                    bindBlob($0, 7, raw.imageData)
                    bindText($0, 8, raw.filePaths?.joined(separator: "\n"))
                    sqlite3_bind_int64($0, 9, Int64(totalBytes))
                    bindText($0, 10, raw.appName)
                    sqlite3_bind_int64($0, 11, parentID)
                }) else { return nil }

            // 附加自定义格式逐条落 clip_formats(空数据不入库:data 列 NOT NULL,且无意义)
            let clipID = sqlite3_last_insert_rowid(db)
            for format in raw.extraFormats where !format.data.isEmpty {
                _ = run("INSERT INTO clip_formats(clip_id, type, data) VALUES(?, ?, ?)", bind: {
                    sqlite3_bind_int64($0, 1, clipID)
                    sqlite3_bind_text($0, 2, format.type, -1, sqliteTransient)
                    bindBlob($0, 3, format.data)
                })
            }

            return ClipItem(id: clipID,
                            kind: raw.kind,
                            createdAt: now,
                            text: textColumn,
                            pinned: false,
                            byteSize: totalBytes,
                            appName: raw.appName,
                            contentHash: hash,
                            parentID: parentID)
        }
    }

    /// 列表排序口径(对齐原版 Main.stickyClipOrder DESC, bIsGroup ASC, clipOrder DESC,
    /// QPasteWnd.cpp:1482-1493;此处 sticky_order 取 ASC = 越小越靠前):
    /// ① 置顶条目浮顶(sticky_order ASC);② 组行视为未置顶,与非置顶条目按
    /// created_at 交错(方向随"最新在上"设置)。NULL 排最后由首键 (… IS NULL) 保证
    private static func orderClause() -> String {
        let dir = DittoSettings.orderLatestOnTop() ? "DESC" : "ASC"
        return "ORDER BY (CASE WHEN is_group = 1 THEN 1 ELSE (sticky_order IS NULL) END) ASC, sticky_order ASC, created_at \(dir)"
    }

    public func recent(limit: Int) -> [ClipItem] {
        queue.sync {
            // 组行不是剪辑条目,不进 recent(组由 list(parentID:) 按所在视图列出)
            items("SELECT \(Self.itemColumns) FROM clips WHERE is_group = 0 \(Self.orderClause()) LIMIT ?",
                  bind: { sqlite3_bind_int($0, 1, Int32(clamping: max(limit, 0))) })
        }
    }

    public func search(_ query: String, limit: Int) -> [ClipItem] {
        search(query, limit: limit, scope: .fullText, method: .contains)
    }

    /// 带搜索选项(原版 Search Options):contains/wildcard 全文 = 既有 SQL LIKE
    /// 路径;descriptionOnly(仅描述)/regex(正则)无法用该 LIKE 表达 → 内存过滤
    public func search(_ query: String, limit: Int, scope: SearchScope, method: SearchMethod) -> [ClipItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if (scope == .descriptionOnly || method == .regex), !trimmed.isEmpty {
            return filteredFullList(query: trimmed, limit: limit,
                                    scope: scope, method: method)
        }
        // 高级模式(对齐原版 FormatSQL):空格分词隐式 AND,支持 OR / NOT(或!)/ "引号短语" / * 通配
        let tokens = Self.parseQuery(query)
        guard !tokens.isEmpty else { return recent(limit: limit) }   // 空查询退化为 recent
        let tokenClause = Self.textMatchClause(for: tokens)   // 左结合括号,语义与用户直觉一致
        return queue.sync {
            items("SELECT \(Self.itemColumns) FROM clips WHERE (is_group = 0) AND \(tokenClause.clause) \(Self.orderClause()) LIMIT ?",
                  bind: { stmt in
                    for (i, pattern) in tokenClause.patterns.enumerated() {
                        bindText(stmt, Int32(i + 1), pattern)
                    }
                    sqlite3_bind_int(stmt, Int32(tokenClause.patterns.count + 1), Int32(clamping: max(limit, 0)))
                  })
        }
    }

    /// 组感知列表(UI 主入口)。范围规则对齐原版 QPasteWnd.cpp:1488-1524:
    /// - 顶层(parentID=-1):默认只列顶层组 + 顶层条目;includeGroupClips 开
    ///   (原版 ShowClipsInMainList+ShowGroupsInMainList)→ 顶层组 + 全部条目(含组内)
    /// - 组内:parent_id = parentID 的全部子项(条目与子组交错)
    /// 排序:sticky_order ASC(NULLs last)→ created_at(方向随设置);组行视为
    /// 未置顶(原版组用独立 order 列,此处统一 created_at 交错,组不受置顶影响)。
    /// query 非空时在上述范围内按 text/title 过滤(原版只搜当前视图)
    public func list(parentID: Int64, includeGroupClips: Bool, query: String?, limit: Int) -> [ClipItem] {
        list(parentID: parentID, includeGroupClips: includeGroupClips, query: query, limit: limit,
             scope: .fullText, method: .contains)
    }

    /// 带搜索选项的组感知列表(原版 Search Options)。contains/wildcard 全文 =
    /// 既有 SQL LIKE 路径(零回归);descriptionOnly(仅描述)/regex(正则)
    /// 无法用该 LIKE 分词语义表达 → 内存过滤(见 filteredList)
    public func list(parentID: Int64, includeGroupClips: Bool, query: String?, limit: Int,
                     scope: SearchScope, method: SearchMethod) -> [ClipItem] {
        let trimmed = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if (scope == .descriptionOnly || method == .regex), !trimmed.isEmpty {
            return filteredList(parentID: parentID, includeGroupClips: includeGroupClips,
                                query: trimmed, limit: limit, scope: scope, method: method)
        }

        let scope: String
        var scopeBind: Int64? = nil
        if parentID == -1 {
            scope = includeGroupClips
                ? "((is_group = 1 AND parent_id = -1) OR (is_group = 0))"
                : "((is_group = 1 AND parent_id = -1) OR (is_group = 0 AND parent_id = -1))"
        } else {
            scope = "(parent_id = ?)"
            scopeBind = parentID
        }

        // 排序:统一走 orderClause(置顶条目 sticky_order ASC 浮顶;组行视为
        // 未置顶,与普通条目按 created_at 交错,方向随"最新在上"设置)
        let order = Self.orderClause()

        let tokens = Self.parseQuery(query ?? "")
        let lim = Int32(clamping: max(limit, 0))
        guard !tokens.isEmpty else {
            return queue.sync {
                if let scopeBind {
                    items("SELECT \(Self.itemColumns) FROM clips WHERE \(scope) \(order) LIMIT ?",
                          bind: {
                            sqlite3_bind_int64($0, 1, scopeBind)
                            sqlite3_bind_int($0, 2, lim)
                          })
                } else {
                    items("SELECT \(Self.itemColumns) FROM clips WHERE \(scope) \(order) LIMIT ?",
                          bind: { sqlite3_bind_int($0, 1, lim) })
                }
            }
        }

        // 带查询:范围 AND 文本条件(文本条件自身左结合括号,语义与 search() 一致)
        let textClause = Self.textMatchClause(for: tokens)
        return queue.sync {
            items("SELECT \(Self.itemColumns) FROM clips WHERE \(scope) AND \(textClause.clause) \(order) LIMIT ?",
                  bind: { stmt in
                    var index: Int32 = 1
                    if let scopeBind {
                        sqlite3_bind_int64(stmt, index, scopeBind); index += 1
                    }
                    for pattern in textClause.patterns {
                        bindText(stmt, index, pattern); index += 1
                    }
                    sqlite3_bind_int(stmt, index, lim)
                  })
        }
    }

    // MARK: 内存过滤(原版 Search Options:仅描述 / 正则)
    //
    // 这两种方式按范围取候选后内存求值:批 = limit×4(下限 40),命中补齐到
    // limit,总扫描上限 2000 条(p95 可控);正则非法模式 → 无结果(记日志)。

    /// 内存过滤入口(search() 全库口径:仅条目,不含组行)
    private func filteredFullList(query: String, limit: Int,
                                  scope: SearchScope, method: SearchMethod) -> [ClipItem] {
        let order = Self.orderClause()
        return filteredList(query: query, limit: limit, scope: scope, method: method) { offset, batch in
            self.queue.sync {
                self.items("SELECT \(Self.itemColumns) FROM clips WHERE (is_group = 0) \(order) LIMIT ? OFFSET ?",
                           bind: {
                            sqlite3_bind_int($0, 1, Int32(batch))
                            sqlite3_bind_int($0, 2, Int32(offset))
                           })
            }
        }
    }

    /// 内存过滤入口(list() 组感知口径)
    private func filteredList(parentID: Int64, includeGroupClips: Bool, query: String, limit: Int,
                              scope: SearchScope, method: SearchMethod) -> [ClipItem] {
        let scopeSQL: String
        var scopeBind: Int64? = nil
        if parentID == -1 {
            scopeSQL = includeGroupClips
                ? "((is_group = 1 AND parent_id = -1) OR (is_group = 0))"
                : "((is_group = 1 AND parent_id = -1) OR (is_group = 0 AND parent_id = -1))"
        } else {
            scopeSQL = "(parent_id = ?)"
            scopeBind = parentID
        }
        let order = Self.orderClause()
        return filteredList(query: query, limit: limit, scope: scope, method: method) { offset, batch in
            self.queue.sync {
                if let scopeBind {
                    self.items("SELECT \(Self.itemColumns) FROM clips WHERE \(scopeSQL) \(order) LIMIT ? OFFSET ?",
                               bind: {
                                sqlite3_bind_int64($0, 1, scopeBind)
                                sqlite3_bind_int($0, 2, Int32(batch))
                                sqlite3_bind_int($0, 3, Int32(offset))
                               })
                } else {
                    self.items("SELECT \(Self.itemColumns) FROM clips WHERE \(scopeSQL) \(order) LIMIT ? OFFSET ?",
                               bind: {
                                sqlite3_bind_int($0, 1, Int32(batch))
                                sqlite3_bind_int($0, 2, Int32(offset))
                               })
                }
            }
        }
    }

    /// 批取 + 过滤通用循环
    private func filteredList(query: String, limit: Int,
                              scope: SearchScope, method: SearchMethod,
                              fetchBatch: (Int, Int) -> [ClipItem]) -> [ClipItem] {
        let matcher = Self.MemoryMatcher(query: query, scope: scope, method: method)
        if method == .regex, matcher.queryRegex == nil {
            Self.failLog("搜索正则非法,按无结果处理: \(query)")
            return []
        }
        var out: [ClipItem] = []
        let batchSize = max(limit * 4, 40)
        let maxScan = 2000
        var offset = 0
        while out.count < limit, offset < maxScan {
            let batch = fetchBatch(offset, min(batchSize, maxScan - offset))
            if batch.isEmpty { break }
            for item in batch where matcher.matches(item) {
                out.append(item)
                if out.count >= limit { break }
            }
            if batch.count < batchSize { break }   // 候选耗尽
            offset += batch.count
        }
        return out
    }

    public func item(id: Int64) -> ClipItem? {
        queue.sync {
            items("SELECT \(Self.itemColumns) FROM clips WHERE id = ?",
                  bind: { sqlite3_bind_int64($0, 1, id) }).first
        }
    }

    /// created_at 最新的条目(不含组行;置顶不影响)。
    /// 复制缓冲引擎判定"⌘C 后新内容已入库"用 —— 不能用 recent(limit:1):
    /// recent 按列表序返回,置顶条目在首位但未必是最新入库的
    public func newestClip() -> ClipItem? {
        queue.sync {
            items("SELECT \(Self.itemColumns) FROM clips WHERE is_group = 0 ORDER BY created_at DESC LIMIT ?",
                  bind: { sqlite3_bind_int($0, 1, 1) }).first
        }
    }

    public func payload(id: Int64) -> RawClip? {
        queue.sync { loadPayloadOf(id: id) }
    }

    /// 条目携带的全部格式(原版 Copy Properties 的 "Copy Data" 列表):
    /// 已知格式映射为代表性 UTI 在前(text/rtf/html/image/files),附加格式按入库序在后
    public func formats(id: Int64) -> [ClipFormat] {
        queue.sync { loadFormatsOf(id: id) }
    }

    /// 删除条目的指定格式(原版 Delete Copy Data):附加格式删 clip_formats 行,
    /// 已知 UTI 置对应列为 NULL;随后以剩余内容重算 byte_size 与 hash
    /// (保证与重新插入同样内容得到的 hash 一致,去重能命中更新后的条目)。
    /// 全部格式都将被删 → 拒绝(不留空条目),返回 false
    @discardableResult
    public func deleteFormats(id: Int64, types: [String]) -> Bool {
        queue.sync {
            let current = loadFormatsOf(id: id)
            guard !current.isEmpty else { return false }   // 条目不存在
            let remove = Set(types)
            guard current.contains(where: { !remove.contains($0.type) }) else {
                return false   // 全删 = 清空条目,拒绝
            }

            // 已知 UTI → 列名;其余按附加格式删行。
            // files 条目的 text 列只是路径预览而非保存的格式,不接受删除(见 loadFormatsOf)
            let kind = kindOf(id: id)
            var nullColumns: Set<String> = []
            var extraTypes: [String] = []
            for type in remove {
                switch type {
                case ClipUTI.text where kind != .files: nullColumns.insert("text")
                case ClipUTI.rtf: nullColumns.insert("rtf")
                case ClipUTI.html: nullColumns.insert("html")
                case ClipUTI.png, ClipUTI.tiff: nullColumns.insert("image")
                case ClipUTI.fileURL: nullColumns.insert("file_paths")
                default: extraTypes.append(type)
                }
            }
            if !nullColumns.isEmpty {
                let assignments = nullColumns.sorted().map { "\($0) = NULL" }.joined(separator: ", ")
                _ = run("UPDATE clips SET \(assignments) WHERE id = ?",
                        bind: { sqlite3_bind_int64($0, 1, id) })
            }
            for type in extraTypes {
                _ = run("DELETE FROM clip_formats WHERE clip_id = ? AND type = ?", bind: {
                    sqlite3_bind_int64($0, 1, id)
                    sqlite3_bind_text($0, 2, type, -1, sqliteTransient)
                })
            }

            // 以剩余列重建 payload 重算体积与哈希(text 列对 files 条目只是预览,
            // payload 已按 kind 置 nil,与其他条目"文本列即内容"的口径一致)
            guard let rebuilt = loadPayloadOf(id: id) else { return false }
            let totalBytes = rebuilt.byteSize + (rebuilt.filePaths?.joined(separator: "\n").utf8.count ?? 0)
            return run("UPDATE clips SET byte_size = ?, hash = ? WHERE id = ?", bind: {
                sqlite3_bind_int64($0, 1, Int64(totalBytes))
                sqlite3_bind_text($0, 2, rebuilt.contentHash, -1, sqliteTransient)
                sqlite3_bind_int64($0, 3, id)
            })
        }
    }

    /// payload 的无锁实现(调用方需已在 queue 内,公开方法再包 queue.sync)
    private func loadPayloadOf(id: Int64) -> RawClip? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT kind, text, rtf, html, image, file_paths, app_name FROM clips WHERE id = ?",
                                 -1, &stmt, nil) == SQLITE_OK, let stmt else {
            Self.failLog("payload prepare 失败: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let kind = ClipKind(rawValue: columnString(stmt, 0) ?? "") ?? .unknown
        // files 条目的 text 列只是路径预览,还原时置 nil,避免写回剪贴板时混入多余文本
        let text = (kind == .files) ? nil : columnString(stmt, 1)
        var clip = RawClip(text: text,
                           rtfData: columnBlob(stmt, 2),
                           htmlData: columnBlob(stmt, 3),
                           imageData: columnBlob(stmt, 4),
                           filePaths: columnString(stmt, 5)?
                               .split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
                           appName: columnString(stmt, 6))
        clip.extraFormats = loadExtraFormatsOf(clipID: id)
        return clip
    }

    /// formats(id:) 的无锁实现;已知格式只取实际有值的列,附加格式按 id 升序
    private func loadFormatsOf(id: Int64) -> [ClipFormat] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT kind, text, rtf, html, image, file_paths FROM clips WHERE id = ?",
                                 -1, &stmt, nil) == SQLITE_OK, let stmt,
              sqlite3_bind_int64(stmt, 1, id) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            return []
        }

        var result: [ClipFormat] = []
        // files 条目的 text 列只是路径预览(loadPayloadOf 同样置 nil),不算保存的格式
        let kind = ClipKind(rawValue: columnString(stmt, 0) ?? "") ?? .unknown
        if kind != .files, let text = columnString(stmt, 1), !text.isEmpty {
            result.append(ClipFormat(type: ClipUTI.text, data: Data(text.utf8)))
        }
        if let rtf = columnBlob(stmt, 2) {
            result.append(ClipFormat(type: ClipUTI.rtf, data: rtf))
        }
        if let html = columnBlob(stmt, 3) {
            result.append(ClipFormat(type: ClipUTI.html, data: html))
        }
        if let image = columnBlob(stmt, 4) {
            result.append(ClipFormat(type: Self.isTIFFBlob(image) ? ClipUTI.tiff : ClipUTI.png, data: image))
        }
        if let paths = columnString(stmt, 5), !paths.isEmpty {
            result.append(ClipFormat(type: ClipUTI.fileURL, data: Data(paths.utf8)))   // 存储形态即换行拼接
        }
        result += loadExtraFormatsOf(clipID: id)
        return result
    }

    /// 单条 kind 查询(deleteFormats 判 files 预览列用)
    private func kindOf(id: Int64) -> ClipKind {
        guard let db else { return .unknown }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT kind FROM clips WHERE id = ?", -1, &stmt, nil) == SQLITE_OK,
              let stmt, sqlite3_bind_int64(stmt, 1, id) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return .unknown }
        return ClipKind(rawValue: columnString(stmt, 0) ?? "") ?? .unknown
    }

    /// 附加格式按入库顺序(ORDER BY id)取回
    private func loadExtraFormatsOf(clipID: Int64) -> [ClipFormat] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT type, data FROM clip_formats WHERE clip_id = ? ORDER BY id",
                                 -1, &stmt, nil) == SQLITE_OK, let stmt,
              sqlite3_bind_int64(stmt, 1, clipID) == SQLITE_OK else {
            Self.failLog("clip_formats prepare 失败: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        var result: [ClipFormat] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let type = columnString(stmt, 0), let data = columnBlob(stmt, 1) {
                result.append(ClipFormat(type: type, data: data))
            }
        }
        return result
    }

    // MARK: - 置顶(sticky_order 与 pinned 两列同步维护:pinned = sticky_order IS NOT NULL)

    /// 单值 MIN/MAX 查询辅助(仅 sticky_order 用;nil = 无置顶行)
    private func stickyExtreme(_ sql: String) -> Double? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt,
              sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 0)
    }

    /// 置顶开关。true = 设为首位(原版 Make Sticky 等价 Make Top Sticky,
    /// Clip.cpp:818 走 GetNewTopSticky);false = 取消置顶(Remove Sticky Setting)
    public func setPinned(_ id: Int64, _ pinned: Bool) {
        setSticky(id, pinned)
    }

    /// 置顶开关(false = sticky_order 置 NULL;组行不受置顶影响)
    public func setSticky(_ id: Int64, _ sticky: Bool) {
        queue.sync {
            if sticky {
                // 新值 = 当前最小序 - 1 → 成为首位(原版 GetNewTopSticky,
                /// Clip.cpp:1388:新值 = 当前最大 + 1,因原版 DESC 排序方向相反)
                let next = (stickyExtreme("SELECT MIN(sticky_order) FROM clips WHERE sticky_order IS NOT NULL AND is_group = 0") ?? 1) - 1
                _ = run("UPDATE clips SET sticky_order = ?, pinned = 1 WHERE id = ? AND is_group = 0",
                        bind: {
                            sqlite3_bind_double($0, 1, next)
                            sqlite3_bind_int64($0, 2, id)
                        })
            } else {
                _ = run("UPDATE clips SET sticky_order = NULL, pinned = 0 WHERE id = ? AND is_group = 0",
                        bind: { sqlite3_bind_int64($0, 1, id) })
            }
        }
    }

    /// 设为首位置顶(原版 Make Top Sticky):新序 = MIN - 1
    public func setStickyTop(_ id: Int64) {
        setSticky(id, true)
    }

    /// 设为末位置顶(原版 Make Last Sticky,Clip.cpp:1388 附近 GetNewLastSticky):
    /// 新序 = MAX + 1
    public func setStickyLast(_ id: Int64) {
        queue.sync {
            let next = (stickyExtreme("SELECT MAX(sticky_order) FROM clips WHERE sticky_order IS NOT NULL AND is_group = 0") ?? -1) + 1
            _ = run("UPDATE clips SET sticky_order = ?, pinned = 1 WHERE id = ? AND is_group = 0",
                    bind: {
                        sqlite3_bind_double($0, 1, next)
                        sqlite3_bind_int64($0, 2, id)
                    })
        }
    }

    /// 替换首位置顶(原版 Replace Top Sticky,QPasteWnd.cpp:5321):
    /// 当前首位置顶被取消置顶,本条继承其序值(视觉结果与本条成为首位一致)
    public func replaceStickyTop(_ id: Int64) {
        queue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT id, sticky_order FROM clips WHERE sticky_order IS NOT NULL AND is_group = 0 ORDER BY sticky_order ASC LIMIT 1",
                                     -1, &stmt, nil) == SQLITE_OK, let stmt,
                  sqlite3_step(stmt) == SQLITE_ROW else {
                // 尚无置顶条目:直接设为首位
                let next = 0.0
                _ = run("UPDATE clips SET sticky_order = ?, pinned = 1 WHERE id = ? AND is_group = 0",
                        bind: {
                            sqlite3_bind_double($0, 1, next)
                            sqlite3_bind_int64($0, 2, id)
                        })
                return
            }
            let firstID = sqlite3_column_int64(stmt, 0)
            let firstOrder = sqlite3_column_double(stmt, 1)
            if firstID == id { return }   // 已是首位,无操作
            // 原首位取消置顶,本条继承其序
            _ = run("UPDATE clips SET sticky_order = NULL, pinned = 0 WHERE id = ? AND is_group = 0",
                    bind: { sqlite3_bind_int64($0, 1, firstID) })
            _ = run("UPDATE clips SET sticky_order = ?, pinned = 1 WHERE id = ? AND is_group = 0",
                    bind: {
                        sqlite3_bind_double($0, 1, firstOrder)
                        sqlite3_bind_int64($0, 2, id)
                    })
        }
    }

    /// 修正置顶顺序(原版 ReOrderStickyClips,DatabaseUtilities.cpp:227):
    /// 按当前顺序重排为连续的 0,1,2…,消除删除/替换留下的空洞与重复值
    public func fixupStickyOrder() {
        queue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT id FROM clips WHERE sticky_order IS NOT NULL AND is_group = 0 ORDER BY sticky_order ASC",
                                     -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
            var ids: [Int64] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(sqlite3_column_int64(stmt, 0))
            }
            var order = 0.0
            for id in ids {
                _ = run("UPDATE clips SET sticky_order = ? WHERE id = ?", bind: {
                    sqlite3_bind_double($0, 1, order)
                    sqlite3_bind_int64($0, 2, id)
                })
                order += 1
            }
        }
    }

    /// 条目顺序移动(原版 Clip Order 子菜单:Move To Top/Up/Down/Last;
    /// 仅在非置顶集合内移动 —— 置顶条目有自己的顺序,只受置顶菜单操控,upstream 同)
    public enum ClipMove { case toTop, toUp, toDown, toLast }

    /// 非置顶集合条件(置顶条目不参与 Clip Order 移动;组行有 NULL 序照常可移)
    private static let nonStickyCondition = "sticky_order IS NULL"

    public func moveClip(_ id: Int64, _ direction: ClipMove) {
        // "最新在下"时列表显示方向反转:向上移动 = 朝更旧一条,首/尾互换
        var direction = direction
        if !DittoSettings.orderLatestOnTop() {
            switch direction {
            case .toTop: direction = .toLast
            case .toLast: direction = .toTop
            case .toUp: direction = .toDown
            case .toDown: direction = .toUp
            }
        }
        queue.sync {
            guard let db else { return }
            // 自己的 created_at
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT created_at FROM clips WHERE id = ? AND \(Self.nonStickyCondition)", -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_bind_int64(stmt, 1, id) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return }
            let mine = sqlite3_column_double(stmt, 0)
            sqlite3_reset(stmt)

            switch direction {
            case .toTop:
                run("UPDATE clips SET created_at = (SELECT MAX(created_at) FROM clips WHERE \(Self.nonStickyCondition)) + 1 WHERE id = ? AND \(Self.nonStickyCondition)",
                    bind: { sqlite3_bind_int64($0, 1, id) })
            case .toLast:
                run("UPDATE clips SET created_at = (SELECT MIN(created_at) FROM clips WHERE \(Self.nonStickyCondition)) - 1 WHERE id = ? AND \(Self.nonStickyCondition)",
                    bind: { sqlite3_bind_int64($0, 1, id) })
            case .toUp, .toDown:
                // 相邻交换:toUp 与更新的一条换,toDown 与更旧的一条换
                let sql = direction == .toUp
                    ? "SELECT id, created_at FROM clips WHERE \(Self.nonStickyCondition) AND created_at > ? ORDER BY created_at ASC LIMIT 1"
                    : "SELECT id, created_at FROM clips WHERE \(Self.nonStickyCondition) AND created_at < ? ORDER BY created_at DESC LIMIT 1"
                var nStmt: OpaquePointer?
                defer { sqlite3_finalize(nStmt) }
                guard sqlite3_prepare_v2(db, sql, -1, &nStmt, nil) == SQLITE_OK,
                      sqlite3_bind_double(nStmt, 1, mine) == SQLITE_OK,
                      sqlite3_step(nStmt) == SQLITE_ROW else { return }
                let neighborID = sqlite3_column_int64(nStmt, 0)
                let neighborAt = sqlite3_column_double(nStmt, 1)
                run("UPDATE clips SET created_at = ? WHERE id = ?", bind: {
                    sqlite3_bind_double($0, 1, neighborAt)
                    sqlite3_bind_int64($0, 2, id)
                })
                run("UPDATE clips SET created_at = ? WHERE id = ?", bind: {
                    sqlite3_bind_double($0, 1, mine)
                    sqlite3_bind_int64($0, 2, neighborID)
                })
            }
        }
    }

    public func markPasted(id: Int64, at date: Date) {
        _ = queue.sync {
            run("UPDATE clips SET last_paste_at = ? WHERE id = ?", bind: {
                sqlite3_bind_double($0, 1, date.timeIntervalSince1970)
                sqlite3_bind_int64($0, 2, id)
            })
        }
    }

    public func setNoDelete(_ id: Int64, _ noDelete: Bool) {
        _ = queue.sync {
            run("UPDATE clips SET no_delete = ? WHERE id = ?", bind: {
                sqlite3_bind_int($0, 1, noDelete ? 1 : 0)
                sqlite3_bind_int64($0, 2, id)
            })
        }
    }

    // MARK: - 标题与内容编辑(原版 Properties Item Title / Edit Clip 保存)

    /// 设置条目标题(nil = 清除,恢复按内容派生描述);组行不适用(组名在 text 列)
    public func setTitle(_ id: Int64, _ title: String?) {
        _ = queue.sync {
            run("UPDATE clips SET title = ? WHERE id = ? AND is_group = 0",
                bind: {
                    bindText($0, 1, (title?.isEmpty == true) ? nil : title)
                    sqlite3_bind_int64($0, 2, id)
                })
        }
    }

    /// 编辑条目内容(text/rtf/html 三列;nil = 不改该列,空串/空数据 = 清空该列)。
    /// 保存后以剩余全部格式重算 byte_size 与 hash(与 deleteFormats 同口径,保证
    /// 编辑后同内容去重能命中本条);title/sticky/parent 等元数据不动,kind 随
    /// 剩余内容更新。全部格式将被清空时回滚拒绝,返回 false(不留空条目)
    @discardableResult
    public func updateClipContent(id: Int64, text: String?, rtfData: Data?, htmlData: Data?) -> Bool {
        queue.sync { () -> Bool in
            guard let db else { return false }
            guard itemExists(id: id) else { return false }

            // 旧值快照(全删空需回滚时恢复)
            var snapStmt: OpaquePointer?
            defer { sqlite3_finalize(snapStmt) }
            guard sqlite3_prepare_v2(db, "SELECT text, rtf, html FROM clips WHERE id = ? AND is_group = 0",
                                     -1, &snapStmt, nil) == SQLITE_OK,
                  let snap = snapStmt,
                  sqlite3_bind_int64(snap, 1, id) == SQLITE_OK,
                  sqlite3_step(snap) == SQLITE_ROW else { return false }
            let oldText = columnString(snap, 0)
            let oldRTF = columnBlob(snap, 1)
            let oldHTML = columnBlob(snap, 2)
            sqlite3_finalize(snap)
            snapStmt = nil

            // 组装 SET 子句(nil 参数的列不动;空值 → NULL)
            var assignments: [String] = []
            var binders: [(OpaquePointer, Int32) -> Void] = []
            if let text {
                assignments.append("text = ?")
                binders.append { self.bindText($0, $1, text.isEmpty ? nil : text) }
            }
            if let rtfData {
                assignments.append("rtf = ?")
                binders.append { self.bindBlob($0, $1, rtfData) }   // 空 Data → NULL(见 bindBlob)
            }
            if let htmlData {
                assignments.append("html = ?")
                binders.append { self.bindBlob($0, $1, htmlData) }
            }
            guard !assignments.isEmpty else { return true }   // 无改动 = 空操作成功

            var upStmt: OpaquePointer?
            defer { sqlite3_finalize(upStmt) }
            let updateSQL = "UPDATE clips SET \(assignments.joined(separator: ", ")) WHERE id = ?"
            guard sqlite3_prepare_v2(db, updateSQL, -1, &upStmt, nil) == SQLITE_OK, let upStmt else { return false }
            for (i, binder) in binders.enumerated() {
                binder(upStmt, Int32(i + 1))
            }
            sqlite3_bind_int64(upStmt, Int32(assignments.count + 1), id)
            guard sqlite3_step(upStmt) == SQLITE_DONE else { return false }

            // 以剩余内容重建 payload;全空 → 回滚拒绝(与 deleteFormats 的"至少留一种"一致)
            guard let rebuilt = loadPayloadOf(id: id), !rebuilt.isEmpty else {
                _ = run("UPDATE clips SET text = ?, rtf = ?, html = ? WHERE id = ?", bind: {
                    bindText($0, 1, oldText)
                    bindBlob($0, 2, oldRTF)
                    bindBlob($0, 3, oldHTML)
                    sqlite3_bind_int64($0, 4, id)
                })
                return false
            }
            let totalBytes = rebuilt.byteSize + (rebuilt.filePaths?.joined(separator: "\n").utf8.count ?? 0)
            // kind 随剩余内容更新(文本条目补了 RTF 后应显示富文本徽标)
            guard run("UPDATE clips SET byte_size = ?, hash = ?, kind = ? WHERE id = ?", bind: {
                sqlite3_bind_int64($0, 1, Int64(totalBytes))
                sqlite3_bind_text($0, 2, rebuilt.contentHash, -1, sqliteTransient)
                sqlite3_bind_text($0, 3, rebuilt.kind.rawValue, -1, sqliteTransient)
                sqlite3_bind_int64($0, 4, id)
            }) else { return false }
            return true
        }
    }

    /// id 是否存在(updateClipContent 防御:kindOf 对不存在的行返回 .unknown 但不报错)
    private func itemExists(id: Int64) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM clips WHERE id = ?", -1, &stmt, nil) == SQLITE_OK,
              let stmt, sqlite3_bind_int64(stmt, 1, id) == SQLITE_OK else { return false }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    public func delete(id: Int64) {
        queue.sync {
            run("DELETE FROM clips WHERE id = ?", bind: { sqlite3_bind_int64($0, 1, id) })
            run("DELETE FROM clip_hotkeys WHERE clip_id = ?", bind: { sqlite3_bind_int64($0, 1, id) })
            cleanOrphanFormats()
        }
    }

    // MARK: - 删除剪贴板数据(原版 DeleteClipData.cpp 的过滤搜索 + 批量删除)

    /// 按过滤条件搜索候选条目(不含组行;命中 text 或 title 的"标题包含")。
    /// last_paste_at 为 NULL(从未粘贴)的条目不命中任何"上次使用时间"条件
    public func searchForDelete(filters: ClipDeleteFilter) -> [ClipItem] {
        queue.sync {
            var conditions = ["is_group = 0"]
            var binders: [(OpaquePointer, Int32) -> Void] = []

            let contains = filters.titleContains.trimmingCharacters(in: .whitespacesAndNewlines)
            if !contains.isEmpty {
                conditions.append("((IFNULL(title, '') LIKE ? ESCAPE '\\') OR (IFNULL(text, '') LIKE ? ESCAPE '\\'))")
                let pattern = "%" + Self.likePattern(contains) + "%"
                binders.append { self.bindText($0, $1, pattern) }
                binders.append { self.bindText($0, $1, pattern) }
            }
            if let start = filters.createdStart {
                conditions.append("created_at >= ?")
                binders.append { sqlite3_bind_double($0, $1, start.timeIntervalSince1970) }
            }
            if let end = filters.createdEnd {
                conditions.append("created_at <= ?")
                binders.append { sqlite3_bind_double($0, $1, end.timeIntervalSince1970) }
            }
            if let start = filters.lastUsedStart {
                conditions.append("last_paste_at >= ?")
                binders.append { sqlite3_bind_double($0, $1, start.timeIntervalSince1970) }
            }
            if let end = filters.lastUsedEnd {
                conditions.append("last_paste_at <= ?")
                binders.append { sqlite3_bind_double($0, $1, end.timeIntervalSince1970) }
            }
            switch filters.format {
            case nil, "":
                break   // 全部
            case "extra":   // 附加格式(EXISTS 子查询,无需绑定)
                conditions.append("EXISTS (SELECT 1 FROM clip_formats WHERE clip_formats.clip_id = clips.id)")
            case ClipUTI.text:
                // files 条目的 text 列只是路径预览,不算"保存了纯文本格式"(口径同 formats())
                conditions.append("(text IS NOT NULL AND kind <> 'files')")
            case ClipUTI.rtf:
                conditions.append("rtf IS NOT NULL")
            case ClipUTI.html:
                conditions.append("html IS NOT NULL")
            case ClipUTI.png, ClipUTI.tiff:
                conditions.append("image IS NOT NULL")
            case ClipUTI.fileURL:
                conditions.append("file_paths IS NOT NULL")
            default:
                conditions.append("EXISTS (SELECT 1 FROM clip_formats WHERE clip_formats.clip_id = clips.id AND clip_formats.type = ?)")
                binders.append { self.bindText($0, $1, filters.format) }
            }

            let sql = "SELECT \(Self.itemColumns) FROM clips WHERE \(conditions.joined(separator: " AND ")) ORDER BY created_at DESC LIMIT 2000"
            guard let db else { return [] }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                Self.failLog("searchForDelete prepare 失败: \(String(cString: sqlite3_errmsg(db)))")
                return []
            }
            for (i, binder) in binders.enumerated() {
                binder(stmt, Int32(i + 1))
            }
            var result: [ClipItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(item(from: stmt))
            }
            return result
        }
    }

    /// 清理保护口径,供批量删除及清理窗口共同使用;与 prune 的 SQL 条件一致。
    public static func isProtectedFromCleanup(_ item: ClipItem) -> Bool {
        item.isGroup || item.parentID != -1 || item.pinned || item.noDelete
    }

    /// 批量删除:置顶/永不删除/组行/组内项豁免(与 prune 的保护口径一致,原版
    /// RemoveOldEntries 同样不碰受保护条目);附加格式与热键孤儿随行回收。
    /// 返回(实际删除数,受保护跳过数),供对话框提示"N 条受保护已跳过"
    @discardableResult
    public func deleteClips(ids: [Int64]) -> (deleted: Int, skipped: Int) {
        guard !ids.isEmpty else { return (0, 0) }
        let unique = Array(Set(ids))
        let placeholders = unique.map { _ in "?" }.joined(separator: ",")
        return queue.sync {
            // 先取回行(在同一队列内判断保护状态;item() 会重入队列,不能在 sync 内用)
            let rows = items("SELECT \(Self.itemColumns) FROM clips WHERE id IN (\(placeholders))",
                             bind: { stmt in
                                 for (i, id) in unique.enumerated() {
                                     sqlite3_bind_int64(stmt, Int32(i + 1), id)
                                 }
                             })
            let rowByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            var deleted = 0, skipped = 0
            for id in unique {
                guard let row = rowByID[id] else { continue }   // 不存在的 id 静默忽略
                if Self.isProtectedFromCleanup(row) {
                    skipped += 1
                    continue
                }
                if run("DELETE FROM clips WHERE id = ?", bind: { sqlite3_bind_int64($0, 1, id) }) {
                    deleted += 1
                }
            }
            cleanOrphanFormats()
            return (deleted, skipped)
        }
    }

    /// 数据库文件占用字节数(主文件 + WAL;删除对话框"数据库大小"显示用)
    public func databaseSizeBytes() -> Int {
        let fm = FileManager.default
        var total = 0
        for suffix in ["", "-wal"] {
            if let size = (try? fm.attributesOfItem(atPath: dbPath + suffix))?[.size] as? Int {
                total += size
            }
        }
        return total
    }

    public func clear(keepingPinned: Bool) {
        queue.sync {
            // 永不删除条目一并豁免(原版 Delete All Non Used Clips 不清受保护条目)
            run(keepingPinned ? "DELETE FROM clips WHERE pinned = 0 AND no_delete = 0" : "DELETE FROM clips")
            cleanOrphanFormats()
        }
    }

    public func prune(maxItems: Int, maxAgeDays: Int) {
        queue.sync {
            let cutoff = Date().timeIntervalSince1970 - Double(maxAgeDays) * 86400
            // 组内条目不参与自动删除(原版 RemoveOldEntries 要求 parentId <= 0,
            // DatabaseUtilities.cpp:873/899);组行自身(bIsGroup=1)同样不删。
            // 先删过期(置顶/永不删除豁免);再删非保护条目中超出 maxItems 的最旧部分
            run("DELETE FROM clips WHERE pinned = 0 AND no_delete = 0 AND parent_id = -1 AND is_group = 0 AND created_at < ?",
                bind: { sqlite3_bind_double($0, 1, cutoff) })
            run("""
                DELETE FROM clips WHERE id IN (
                  SELECT id FROM clips WHERE pinned = 0 AND no_delete = 0 AND parent_id = -1 AND is_group = 0
                  ORDER BY created_at DESC LIMIT -1 OFFSET ?
                )
                """, bind: { sqlite3_bind_int($0, 1, Int32(clamping: max(maxItems, 0))) })
            cleanOrphanFormats()
        }
    }

    /// 清理 clip_id 已不存在的附加格式行(删条目/清空/清理后的孤儿回收)
    private func cleanOrphanFormats() {
        _ = run("DELETE FROM clip_formats WHERE clip_id NOT IN (SELECT id FROM clips)")
        // 条目热键随行回收(组热键由 deleteGroup 单独清)
        _ = run("DELETE FROM clip_hotkeys WHERE clip_id NOT IN (SELECT id FROM clips)")
        // 复制缓冲孤儿随行回收(查询侧 JOIN 也会视为空,双保险)
        _ = run("DELETE FROM copy_buffers WHERE clip_id NOT IN (SELECT id FROM clips)")
    }

    // MARK: - 复制缓冲(原版 CopyBuffers 表:lCopyBuffer 主键 + lClipID,
    // DittoCopyBuffer.cpp:118-142 的 INSERT/UPDATE 语义)

    /// 关联缓冲号与条目 id(nil = 清除该缓冲的关联)
    public func setCopyBuffer(index: Int, clipID: Int64?) {
        queue.sync {
            if let clipID {
                _ = run("INSERT OR REPLACE INTO copy_buffers(buffer_index, clip_id) VALUES(?, ?)",
                        bind: {
                            sqlite3_bind_int64($0, 1, Int64(index))
                            sqlite3_bind_int64($0, 2, clipID)
                        })
            } else {
                _ = run("DELETE FROM copy_buffers WHERE buffer_index = ?",
                        bind: { sqlite3_bind_int64($0, 1, Int64(index)) })
            }
        }
    }

    /// 缓冲中的条目 id;缓冲空或条目已删 → nil(JOIN 保证,孤儿行由清理回收)
    public func copyBufferClipID(index: Int) -> Int64? {
        queue.sync {
            guard let db else { return nil }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, """
                    SELECT copy_buffers.clip_id FROM copy_buffers
                    JOIN clips ON clips.id = copy_buffers.clip_id
                    WHERE copy_buffers.buffer_index = ?
                    """, -1, &stmt, nil) == SQLITE_OK, let stmt,
                  sqlite3_bind_int64(stmt, 1, Int64(index)) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    /// 备份数据库(原版 Backup Database):checkpoint 合并 WAL 后整文件拷贝
    @discardableResult
    public func backup(to url: URL) -> Bool {
        queue.sync {
            guard let db else { return false }
            _ = sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
            do {
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.copyItem(atPath: dbPath, toPath: url.path)
                return true
            } catch {
                Self.failLog("备份数据库失败: \(error.localizedDescription)")
                return false
            }
        }
    }

    public var count: Int {
        queue.sync {
            guard let db else { return 0 }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM clips", -1, &stmt, nil) == SQLITE_OK,
                  let stmt, sqlite3_step(stmt) == SQLITE_ROW else {
                Self.failLog("count 查询失败: \(String(cString: sqlite3_errmsg(db)))")
                return 0
            }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    // MARK: - 组(原版 Groups:单 Main 表,lParentID=-1 为顶层,bIsGroup 标组行)

    /// 新建组(原版 NewGroupID,DatabaseUtilities.cpp:240 一带):插 is_group=1 行,
    /// text 列 = 组名。hash 用 "group:" 前缀命名空间,保证与剪辑内容哈希
    /// (十六进制-c 位数格式)永不相撞 —— insert() 的去重按 hash 全表查找,
    /// 组行混进去会被误"置顶"
    @discardableResult
    public func createGroup(name: String, parentID: Int64) -> ClipItem? {
        queue.sync {
            var h = FNV1a64()
            h.update("group:")
            h.update(name)
            let hash = "group:\(String(format: "%016llx", h.digest))"
            guard run("""
                INSERT INTO clips(created_at, kind, hash, text, byte_size, pinned, parent_id, is_group)
                VALUES(?, 'group', ?, ?, 0, 0, ?, 1)
                """, bind: {
                    sqlite3_bind_double($0, 1, Date().timeIntervalSince1970)
                    sqlite3_bind_text($0, 2, hash, -1, sqliteTransient)
                    bindText($0, 3, name)
                    sqlite3_bind_int64($0, 4, parentID)
                }) else { return nil }
            guard let db else { return nil }
            let id = sqlite3_last_insert_rowid(db)
            return ClipItem(id: id, kind: .group, createdAt: Date(), text: name,
                            pinned: false, byteSize: 0, appName: nil,
                            contentHash: hash, parentID: parentID, isGroup: true)
        }
    }

    public func childGroups(of parentID: Int64) -> [ClipItem] {
        queue.sync {
            items("SELECT \(Self.itemColumns) FROM clips WHERE is_group = 1 AND parent_id = ? ORDER BY created_at DESC",
                  bind: { sqlite3_bind_int64($0, 1, parentID) })
        }
    }

    /// 移动到组(原版 CClipIDs::MoveTo,ClipIds.cpp:194):
    /// - 条目 → 改 parent_id
    /// - 组 → 改父(reparent);目标是自身/自己的后代 → 拒绝(成环会把子树变孤岛)
    @discardableResult
    public func moveClips(ids: [Int64], toParent parentID: Int64) -> Bool {
        let moved = Set(ids)
        guard !moved.isEmpty else { return false }
        // 目标必须是顶层或组行(防 UI 外把条目挂到条目下)
        guard parentID == -1 || (item(id: parentID)?.isGroup == true) else { return false }
        // 成环检测:从目标向上走父链,碰上任一被移动 id 即拒绝
        // (visited 防御脏数据里已存在的环)。item() 各自走串行队列,须在进入
        // 本方法的 queue.sync 之前完成,否则重入死锁
        var ancestor = parentID
        var visited: Set<Int64> = []
        while ancestor != -1, !visited.contains(ancestor) {
            if moved.contains(ancestor) { return false }
            visited.insert(ancestor)
            guard let node = item(id: ancestor) else { break }
            ancestor = node.parentID
        }
        return queue.sync {
            var ok = true
            for id in moved {
                let success = run("UPDATE clips SET parent_id = ? WHERE id = ?",
                                  bind: {
                                    sqlite3_bind_int64($0, 1, parentID)
                                    sqlite3_bind_int64($0, 2, id)
                                  })
                ok = ok && success
            }
            return ok
        }
    }

    /// 复制条目到组(组间"复制"语义):整行以新 id 复制 + 附加格式随行。
    /// 不走 insert() 是刻意的:同内容已存在时 insert 会去重置顶旧条目,
    /// 那样"复制到组"就变成了"移动",多份同内容是本操作的合法结果
    @discardableResult
    public func duplicateClips(ids: [Int64], toParent parentID: Int64) -> Bool {
        queue.sync {
            guard let db else { return false }
            var ok = true
            for id in ids {
                guard run("""
                    INSERT INTO clips(created_at, kind, hash, text, rtf, html, image, file_paths,
                                      byte_size, pinned, app_name, last_paste_at, no_delete, parent_id, is_group, title)
                    SELECT created_at, kind, hash, text, rtf, html, image, file_paths,
                           byte_size, 0, app_name, NULL, no_delete, ?, 0, title
                    FROM clips WHERE id = ? AND is_group = 0
                    """, bind: {
                        sqlite3_bind_int64($0, 1, parentID)
                        sqlite3_bind_int64($0, 2, id)
                    }) else { ok = false; continue }
                let newID = sqlite3_last_insert_rowid(db)
                _ = run("INSERT INTO clip_formats(clip_id, type, data) SELECT ?, type, data FROM clip_formats WHERE clip_id = ?",
                        bind: {
                            sqlite3_bind_int64($0, 1, newID)
                            sqlite3_bind_int64($0, 2, id)
                        })
            }
            return ok
        }
    }

    @discardableResult
    public func renameGroup(id: Int64, name: String) -> Bool {
        // 只重命名组行(普通条目误传 → false,不误改其 text 内容列)。
        // item() 走串行队列,须在本方法的 queue.sync 外调用
        guard item(id: id)?.isGroup == true else { return false }
        return queue.sync {
            run("UPDATE clips SET text = ? WHERE id = ? AND is_group = 1",
                bind: {
                    bindText($0, 1, name)
                    sqlite3_bind_int64($0, 2, id)
                })
        }
    }

    /// 删除组:子条目与子组移回该组的父组,再删组行。
    /// 偏差说明:原版删除组时弹确认后连同组内条目一起删(Clip.cpp DeleteID 一带);
    /// 此处选择保守的"只删壳"—— 误删组不丢历史,真想清空可进组全选删除。
    /// 热键绑定一并清(组没了注册项也应消失)
    @discardableResult
    public func deleteGroup(id: Int64) -> Bool {
        // 只删组行(不存在/是普通条目 → false;也避免子查询落 NULL 污染子项)。
        // item() 走串行队列,须在本方法的 queue.sync 外调用
        guard item(id: id)?.isGroup == true else { return false }
        return queue.sync {
            guard run("UPDATE clips SET parent_id = (SELECT parent_id FROM clips WHERE id = ? AND is_group = 1) WHERE parent_id = ?",
                      bind: {
                        sqlite3_bind_int64($0, 1, id)
                        sqlite3_bind_int64($0, 2, id)
                      }) else { return false }
            guard run("DELETE FROM clips WHERE id = ? AND is_group = 1",
                      bind: { sqlite3_bind_int64($0, 1, id) }) else { return false }
            _ = run("DELETE FROM group_hotkeys WHERE group_id = ?",
                    bind: { sqlite3_bind_int64($0, 1, id) })
            return true
        }
    }

    // MARK: - 组热键(group_hotkeys 表;独立于 UserDefaults,随库备份迁移)

    public func groupHotkey(id: Int64) -> GroupHotkey? {
        queue.sync {
            guard let db else { return nil }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT key_code, mods, is_global FROM group_hotkeys WHERE group_id = ?",
                                     -1, &stmt, nil) == SQLITE_OK, let stmt,
                  sqlite3_bind_int64(stmt, 1, id) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return GroupHotkey(keyCode: UInt32(sqlite3_column_int64(stmt, 0)),
                               modifiers: UInt(sqlite3_column_int64(stmt, 1)),
                               isGlobal: sqlite3_column_int64(stmt, 2) != 0)
        }
    }

    public func setGroupHotkey(id: Int64, hotkey: GroupHotkey?) {
        queue.sync {
            if let hotkey {
                _ = run("""
                    INSERT OR REPLACE INTO group_hotkeys(group_id, key_code, mods, is_global) VALUES(?, ?, ?, ?)
                    """, bind: {
                        sqlite3_bind_int64($0, 1, id)
                        sqlite3_bind_int64($0, 2, Int64(hotkey.keyCode))
                        sqlite3_bind_int64($0, 3, Int64(hotkey.modifiers))
                        sqlite3_bind_int64($0, 4, hotkey.isGlobal ? 1 : 0)
                    })
            } else {
                _ = run("DELETE FROM group_hotkeys WHERE group_id = ?",
                        bind: { sqlite3_bind_int64($0, 1, id) })
            }
        }
    }

    public func allGroupHotkeys() -> [(groupID: Int64, hotkey: GroupHotkey)] {
        queue.sync {
            guard let db else { return [] }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT group_id, key_code, mods, is_global FROM group_hotkeys",
                                     -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            var result: [(Int64, GroupHotkey)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append((sqlite3_column_int64(stmt, 0),
                               GroupHotkey(keyCode: UInt32(sqlite3_column_int64(stmt, 1)),
                                           modifiers: UInt(sqlite3_column_int64(stmt, 2)),
                                           isGlobal: sqlite3_column_int64(stmt, 3) != 0)))
            }
            return result
        }
    }

    // MARK: - 条目热键(clip_hotkeys 表;原版 Main.lShortCut/globalShortCut 的等价拆分)

    public func clipHotkey(id: Int64) -> ClipHotkey? {
        queue.sync {
            guard let db else { return nil }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT key_code, mods, is_global FROM clip_hotkeys WHERE clip_id = ?",
                                     -1, &stmt, nil) == SQLITE_OK, let stmt,
                  sqlite3_bind_int64(stmt, 1, id) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return ClipHotkey(keyCode: UInt32(sqlite3_column_int64(stmt, 0)),
                              modifiers: UInt(sqlite3_column_int64(stmt, 1)),
                              isGlobal: sqlite3_column_int64(stmt, 2) != 0)
        }
    }

    public func setClipHotkey(id: Int64, hotkey: ClipHotkey?) {
        queue.sync {
            if let hotkey {
                _ = run("""
                    INSERT OR REPLACE INTO clip_hotkeys(clip_id, key_code, mods, is_global) VALUES(?, ?, ?, ?)
                    """, bind: {
                        sqlite3_bind_int64($0, 1, id)
                        sqlite3_bind_int64($0, 2, Int64(hotkey.keyCode))
                        sqlite3_bind_int64($0, 3, Int64(hotkey.modifiers))
                        sqlite3_bind_int64($0, 4, hotkey.isGlobal ? 1 : 0)
                    })
            } else {
                _ = run("DELETE FROM clip_hotkeys WHERE clip_id = ?",
                        bind: { sqlite3_bind_int64($0, 1, id) })
            }
        }
    }

    public func allClipHotkeys() -> [(clipID: Int64, hotkey: ClipHotkey)] {
        queue.sync {
            guard let db else { return [] }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, """
                    SELECT clip_id, key_code, mods, is_global FROM clip_hotkeys
                    JOIN clips ON clips.id = clip_hotkeys.clip_id AND clips.is_group = 0
                    """,
                                     -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            var result: [(Int64, ClipHotkey)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append((sqlite3_column_int64(stmt, 0),
                               ClipHotkey(keyCode: UInt32(sqlite3_column_int64(stmt, 1)),
                                          modifiers: UInt(sqlite3_column_int64(stmt, 2)),
                                          isGlobal: sqlite3_column_int64(stmt, 3) != 0)))
            }
            return result
        }
    }

    // MARK: - 测试辅助(经 @testable / 同单元使用)

    func rawExecForTesting(_ sql: String) {
        exec(sql)
    }

    /// 单列整型查询(如 COUNT(*) FROM clip_formats,验证孤儿回收)
    func scalarIntForTesting(_ sql: String) -> Int {
        guard let db else { return -1 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt,
              sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func dbPathForTesting() -> String {
        dbPath
    }

    // MARK: - 查询解析

    private enum QueryJoiner { case and, or }

    private struct QueryToken {
        var phrase: String
        var negated: Bool
        var joiner: QueryJoiner   // 与前一个词的连接方式(首词忽略)
    }

    /// 词元 → text/title 两列匹配 SQL 片段与绑定模式列表。
    /// 每个词在 text 与 title(用户自定义标题,原版 desc 搜索同样命中 mTitle)
    /// 任一列命中即算命中;NOT 词要求两列都不命中。
    /// 左结合累加括号(避免 SQL 原生 AND 优先于 OR,语义与用户直觉一致);
    /// search() 与 list() 的查询分支共用。IFNULL 保证 NULL title 参与 NOT 逻辑不出 NULL
    private static func textMatchClause(for tokens: [QueryToken])
        -> (clause: String, patterns: [String]) {
        var conditions: [String] = []
        var joiners: [String] = []          // joiners[i] 连接 conditions[i] 与 conditions[i+1]
        var patterns: [String] = []
        for (i, token) in tokens.enumerated() {
            patterns.append("%" + Self.likePattern(token.phrase) + "%")
            // 同一模式绑定两次(text 与 title 各一次)
            patterns.append("%" + Self.likePattern(token.phrase) + "%")
            let hit = "((IFNULL(text, '') LIKE ? ESCAPE '\\') OR (IFNULL(title, '') LIKE ? ESCAPE '\\'))"
            conditions.append(token.negated ? "NOT \(hit)" : hit)
            if i > 0 { joiners.append(token.joiner == .or ? " OR " : " AND ") }
        }
        var clause = conditions[0]
        for (i, joiner) in joiners.enumerated() {
            clause = "(\(clause) \(joiner) \(conditions[i + 1]))"
        }
        return (clause, patterns)
    }

    // MARK: 内存匹配器(仅描述 / 正则搜索;分词语义与 SQL 路径一致)

    /// 派生描述(原版"仅描述"搜索口径):自定义标题优先,否则取首行
    /// (与列表展示的 title ?? 首行派生描述口径一致)
    static func derivedDescription(of item: ClipItem) -> String {
        if let title = item.title, !title.isEmpty { return title }
        guard let text = item.text else { return "" }
        return String(text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
    }

    /// 内存匹配器:预编译各词(通配转正则),避免逐条目重复编译
    private struct MemoryMatcher {
        struct Term {
            let negated: Bool
            let joiner: QueryJoiner
            let containsPhrase: String?              // contains 方式:字面子串
            let wildcardRegex: NSRegularExpression?  // wildcard 方式:* 任意串 / ? 单字符
        }

        let terms: [Term]
        /// 正则方式:整条查询作为模式(case-insensitive;非法 = nil → 调用方按无结果处理)
        let queryRegex: NSRegularExpression?
        let scope: SearchScope
        let method: SearchMethod

        init(query: String, scope: SearchScope, method: SearchMethod) {
            self.scope = scope
            self.method = method
            self.queryRegex = method == .regex
                ? try? NSRegularExpression(pattern: query, options: [.caseInsensitive])
                : nil
            var terms: [Term] = []
            for token in ClipStore.parseQuery(query) {
                var wildcard: NSRegularExpression?
                if method == .wildcard {
                    // 词内 * → 任意串、? → 单字符,其余转义;整体为子串语义(前后 .*)
                    var pattern = ".*"
                    for ch in token.phrase {
                        switch ch {
                        case "*": pattern += ".*"
                        case "?": pattern += "."
                        default: pattern += NSRegularExpression.escapedPattern(for: String(ch))
                        }
                    }
                    pattern += ".*"
                    wildcard = try? NSRegularExpression(
                        pattern: pattern,
                        options: [.caseInsensitive, .dotMatchesLineSeparators])
                }
                terms.append(Term(negated: token.negated,
                                  joiner: token.joiner,
                                  containsPhrase: method == .contains ? token.phrase : nil,
                                  wildcardRegex: wildcard))
            }
            self.terms = terms
        }

        func matches(_ item: ClipItem) -> Bool {
            // 正则:整条查询作模式;全文口径匹配 text/title 任一(与 contains 两列口径一致)
            if method == .regex {
                return haystacks(for: item).contains { regexHit($0) }
            }
            return evaluate(haystacks: haystacks(for: item))
        }

        /// 匹配目标:全文 = text/title 两列;仅描述 = 派生描述(标题 ?? 首行)
        private func haystacks(for item: ClipItem) -> [String] {
            scope == .fullText ? [item.text ?? "", item.title ?? ""]
                               : [ClipStore.derivedDescription(of: item)]
        }

        private func regexHit(_ text: String) -> Bool {
            queryRegex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }

        /// 单词命中:任一目标列命中即算(与 SQL 路径 OR 两列的口径一致)
        private func termHit(_ term: Term, haystacks: [String]) -> Bool {
            for h in haystacks {
                let hit: Bool
                if let phrase = term.containsPhrase {
                    hit = h.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                } else if let regex = term.wildcardRegex {
                    hit = regex.firstMatch(in: h, range: NSRange(h.startIndex..., in: h)) != nil
                } else {
                    hit = true
                }
                if hit { return true }
            }
            return false
        }

        /// 左结合逐词求值(AND/OR/NOT,与 SQL 路径同语义;无词 = 全命中)
        private func evaluate(haystacks: [String]) -> Bool {
            var result: Bool?
            for term in terms {
                let hit = termHit(term, haystacks: haystacks)
                let value = term.negated ? !hit : hit
                if let r = result {
                    result = term.joiner == .or ? (r || value) : (r && value)
                } else {
                    result = value
                }
            }
            return result ?? true
        }
    }

    /// 解析:`a b` = a AND b;`a OR b`;`NOT a` / `!a`;`"精确 短语"`;词内 `*` → 任意串
    private static func parseQuery(_ query: String) -> [QueryToken] {        // 分词:引号内整体为一个词(引号内的 OR/NOT 不当操作符)
        var raw: [(text: String, quoted: Bool)] = []
        var current = ""
        var currentQuoted = false
        var inQuotes = false
        for ch in query {
            if ch == "\"" {
                if !current.isEmpty { raw.append((current, currentQuoted)) }
                current = ""
                inQuotes.toggle()
                currentQuoted = inQuotes
                continue
            }
            if ch.isWhitespace && !inQuotes {
                if !current.isEmpty { raw.append((current, currentQuoted)); current = ""; currentQuoted = false }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { raw.append((current, currentQuoted)) }

        var tokens: [QueryToken] = []
        var pendingJoiner: QueryJoiner = .and
        var pendingNegate = false
        for (word, quoted) in raw {
            let upper = word.uppercased()
            if !quoted {
                if upper == "OR" || upper == "||" {
                    if !tokens.isEmpty { pendingJoiner = .or }
                    continue
                }
                if upper == "NOT" || word == "!" {
                    pendingNegate = true
                    continue
                }
            }
            var negated = pendingNegate
            var phrase = word
            if !quoted, phrase.hasPrefix("!"), phrase.count > 1 {   // !word 粘写形式
                negated = true
                phrase = String(phrase.dropFirst())
            }
            guard !phrase.isEmpty else { continue }
            tokens.append(QueryToken(phrase: phrase, negated: negated,
                                     joiner: tokens.isEmpty ? .and : pendingJoiner))
            pendingJoiner = .and
            pendingNegate = false
        }
        return tokens
    }

    /// LIKE 模式:* → %;其余 % _ \ 转义
    private static func likePattern(_ term: String) -> String {
        var out = ""
        out.reserveCapacity(term.count)
        for ch in term {
            switch ch {
            case "*": out += "%"
            case "%": out += "\\%"
            case "_": out += "\\_"
            case "\\": out += "\\\\"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - SQLite 基础封装

    /// 无结果集 SQL;失败 os_log 一句并返回 false
    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK { return true }
        Self.failLog("SQL 执行失败: \(String(cString: sqlite3_errmsg(db)))")
        return false
    }

    /// 预处理 + 绑定 + 迭代行 → ClipItem 列表
    private func items(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }) -> [ClipItem] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            Self.failLog("查询 prepare 失败: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        bind(stmt)
        var result: [ClipItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(item(from: stmt))
        }
        return result
    }

    /// 预处理 + 绑定 + 单步写入;成功返回 true
    @discardableResult
    private func run(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            Self.failLog("写入 prepare 失败: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            Self.failLog("写入 step 失败: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }

    /// 列序与 itemColumns 一致
    private func item(from stmt: OpaquePointer) -> ClipItem {
        let lastPaste = sqlite3_column_type(stmt, 8) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
        return ClipItem(id: sqlite3_column_int64(stmt, 0),
                 kind: ClipKind(rawValue: columnString(stmt, 1) ?? "") ?? .unknown,
                 createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                 text: columnString(stmt, 3),
                 pinned: sqlite3_column_int64(stmt, 4) != 0,
                 byteSize: Int(sqlite3_column_int64(stmt, 5)),
                 appName: columnString(stmt, 6),
                 contentHash: columnString(stmt, 7) ?? "",
                 lastPasteAt: lastPaste,
                 noDelete: sqlite3_column_int64(stmt, 9) != 0,
                 parentID: sqlite3_column_int64(stmt, 10),
                 isGroup: sqlite3_column_int64(stmt, 11) != 0,
                 title: columnString(stmt, 12),
                 stickyOrder: sqlite3_column_type(stmt, 13) == SQLITE_NULL
                     ? nil : sqlite3_column_double(stmt, 13))
    }

    // MARK: - 绑定与取列

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindBlob(_ stmt: OpaquePointer, _ index: Int32, _ value: Data?) {
        guard let value, !value.isEmpty else {
            sqlite3_bind_null(stmt, index)
            return
        }
        value.withUnsafeBytes {
            _ = sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), sqliteTransient)
        }
    }

    private func columnString(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(stmt, index))
    }

    private func columnBlob(_ stmt: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) == SQLITE_BLOB,
              let raw = sqlite3_column_blob(stmt, index) else { return nil }
        return Data(bytes: raw, count: Int(sqlite3_column_bytes(stmt, index)))
    }

    /// TIFF 魔数判断(II* 小端 / MM* 大端;与 PasteBack 写回时的判定一致)
    private static func isTIFFBlob(_ data: Data) -> Bool {
        data.starts(with: [0x49, 0x49, 0x2A, 0x00]) ||
        data.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
    }
}
