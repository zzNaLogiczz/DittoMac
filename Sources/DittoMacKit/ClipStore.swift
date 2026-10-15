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

    /// 列表/搜索取的轻量列(blob 除外);item(from:) 的列序与此一致
    private static let itemColumns = "id, kind, created_at, text, pinned, byte_size, app_name, hash, last_paste_at, no_delete"

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
          no_delete INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_clips_time ON clips(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_clips_hash ON clips(hash);
        """

    /// 旧库迁移:增量补列(列已存在时 ALTER 报错,忽略即可)
    private static let migrations = [
        "ALTER TABLE clips ADD COLUMN last_paste_at REAL",
        "ALTER TABLE clips ADD COLUMN no_delete INTEGER NOT NULL DEFAULT 0",
    ]

    // MARK: - 生命周期

    public convenience init() {
        self.init(path: nil)
    }

    /// path 为 nil 时使用默认位置 ~/Library/Application Support/DittoMac/ditto.sqlite
    init(path: String?) {
        let defaultPath = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DittoMac/ditto.sqlite").path
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
            Self.log.error("数据库损坏,已备份并重建: \(recovery ?? "?", privacy: .public)")
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
            log.error("打开数据库失败: \(reason, privacy: .public)")
            return nil
        }
        let verify: (OpaquePointer) -> Bool = { db in
            guard sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000;",
                               nil, nil, nil) == SQLITE_OK else { return false }
            guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { return false }
            for sql in migrations {
                _ = sqlite3_exec(db, sql, nil, nil, nil)   // 列已存在时失败,忽略
            }
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
        queue.sync {
            guard let db, !raw.isEmpty else { return nil }
            let totalBytes = raw.byteSize + (raw.filePaths?.joined(separator: "\n").utf8.count ?? 0)
            guard totalBytes <= maxDataBytes else { return nil }   // 超限直接丢弃

            let now = Date()
            let hash = raw.contentHash

            // 去重(Ditto 行为):最近一条同 hash 记录 → 只更新时间戳与来源,置顶旧记录
            if let last = items("SELECT \(Self.itemColumns) FROM clips WHERE hash = ? ORDER BY created_at DESC LIMIT 1",
                                bind: { sqlite3_bind_text($0, 1, hash, -1, sqliteTransient) }).first {
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
                INSERT INTO clips(created_at, kind, hash, text, rtf, html, image, file_paths, byte_size, pinned, app_name)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
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
                }) else { return nil }

            return ClipItem(id: sqlite3_last_insert_rowid(db),
                            kind: raw.kind,
                            createdAt: now,
                            text: textColumn,
                            pinned: false,
                            byteSize: totalBytes,
                            appName: raw.appName,
                            contentHash: hash)
        }
    }

    public func recent(limit: Int) -> [ClipItem] {
        queue.sync {
            items("SELECT \(Self.itemColumns) FROM clips ORDER BY pinned DESC, created_at DESC LIMIT ?",
                  bind: { sqlite3_bind_int($0, 1, Int32(clamping: max(limit, 0))) })
        }
    }

    public func search(_ query: String, limit: Int) -> [ClipItem] {
        // 高级模式(对齐原版 FormatSQL):空格分词隐式 AND,支持 OR / NOT(或!)/ "引号短语" / * 通配
        let tokens = Self.parseQuery(query)
        guard !tokens.isEmpty else { return recent(limit: limit) }   // 空查询退化为 recent
        var conditions: [String] = []
        var joiners: [String] = []          // joiners[i] 连接 conditions[i] 与 conditions[i+1]
        var patterns: [String] = []
        for (i, token) in tokens.enumerated() {
            patterns.append("%" + Self.likePattern(token.phrase) + "%")
            conditions.append(token.negated
                              ? "(text NOT LIKE ? ESCAPE '\\')"
                              : "(text LIKE ? ESCAPE '\\')")
            if i > 0 { joiners.append(token.joiner == .or ? " OR " : " AND ") }
        }
        // 左结合累加括号:语义与用户直觉一致(避免 SQL 原生 AND 优先于 OR)
        var whereClause = conditions[0]
        for (i, joiner) in joiners.enumerated() {
            whereClause = "(\(whereClause) \(joiner) \(conditions[i + 1]))"
        }
        return queue.sync {
            items("SELECT \(Self.itemColumns) FROM clips WHERE \(whereClause) ORDER BY pinned DESC, created_at DESC LIMIT ?",
                  bind: { stmt in
                    for (i, pattern) in patterns.enumerated() {
                        bindText(stmt, Int32(i + 1), pattern)
                    }
                    sqlite3_bind_int(stmt, Int32(patterns.count + 1), Int32(clamping: max(limit, 0)))
                  })
        }
    }

    public func payload(id: Int64) -> RawClip? {
        queue.sync {
            guard let db else { return nil }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT kind, text, rtf, html, image, file_paths, app_name FROM clips WHERE id = ?",
                                     -1, &stmt, nil) == SQLITE_OK, let stmt else {
                Self.log.error("payload prepare 失败: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                return nil
            }
            sqlite3_bind_int64(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

            let kind = ClipKind(rawValue: columnString(stmt, 0) ?? "") ?? .unknown
            // files 条目的 text 列只是路径预览,还原时置 nil,避免写回剪贴板时混入多余文本
            let text = (kind == .files) ? nil : columnString(stmt, 1)
            return RawClip(text: text,
                           rtfData: columnBlob(stmt, 2),
                           htmlData: columnBlob(stmt, 3),
                           imageData: columnBlob(stmt, 4),
                           filePaths: columnString(stmt, 5)?
                               .split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
                           appName: columnString(stmt, 6))
        }
    }

    public func setPinned(_ id: Int64, _ pinned: Bool) {
        _ = queue.sync {
            run("UPDATE clips SET pinned = ? WHERE id = ?", bind: {
                sqlite3_bind_int($0, 1, pinned ? 1 : 0)
                sqlite3_bind_int64($0, 2, id)
            })
        }
    }

    /// 条目顺序移动(原版 Clip Order 子菜单:Move To Top/Up/Down/Last;仅在非置顶集合内移动)
    public enum ClipMove { case toTop, toUp, toDown, toLast }

    public func moveClip(_ id: Int64, _ direction: ClipMove) {
        queue.sync {
            guard let db else { return }
            // 自己的 created_at
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT created_at FROM clips WHERE id = ? AND pinned = 0", -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_bind_int64(stmt, 1, id) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return }
            let mine = sqlite3_column_double(stmt, 0)
            sqlite3_reset(stmt)

            switch direction {
            case .toTop:
                run("UPDATE clips SET created_at = (SELECT MAX(created_at) FROM clips WHERE pinned = 0) + 1 WHERE id = ? AND pinned = 0",
                    bind: { sqlite3_bind_int64($0, 1, id) })
            case .toLast:
                run("UPDATE clips SET created_at = (SELECT MIN(created_at) FROM clips WHERE pinned = 0) - 1 WHERE id = ? AND pinned = 0",
                    bind: { sqlite3_bind_int64($0, 1, id) })
            case .toUp, .toDown:
                // 相邻交换:toUp 与更新的一条换,toDown 与更旧的一条换
                let sql = direction == .toUp
                    ? "SELECT id, created_at FROM clips WHERE pinned = 0 AND created_at > ? ORDER BY created_at ASC LIMIT 1"
                    : "SELECT id, created_at FROM clips WHERE pinned = 0 AND created_at < ? ORDER BY created_at DESC LIMIT 1"
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

    public func delete(id: Int64) {
        _ = queue.sync {
            run("DELETE FROM clips WHERE id = ?", bind: { sqlite3_bind_int64($0, 1, id) })
        }
    }

    public func clear(keepingPinned: Bool) {
        _ = queue.sync {
            // 永不删除条目一并豁免(原版 Delete All Non Used Clips 不清受保护条目)
            run(keepingPinned ? "DELETE FROM clips WHERE pinned = 0 AND no_delete = 0" : "DELETE FROM clips")
        }
    }

    public func prune(maxItems: Int, maxAgeDays: Int) {
        queue.sync {
            let cutoff = Date().timeIntervalSince1970 - Double(maxAgeDays) * 86400
            // 先删过期(置顶/永不删除豁免);再删非保护条目中超出 maxItems 的最旧部分
            run("DELETE FROM clips WHERE pinned = 0 AND no_delete = 0 AND created_at < ?",
                bind: { sqlite3_bind_double($0, 1, cutoff) })
            run("""
                DELETE FROM clips WHERE id IN (
                  SELECT id FROM clips WHERE pinned = 0 AND no_delete = 0
                  ORDER BY created_at DESC LIMIT -1 OFFSET ?
                )
                """, bind: { sqlite3_bind_int($0, 1, Int32(clamping: max(maxItems, 0))) })
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
                Self.log.error("备份数据库失败: \(error.localizedDescription, privacy: .public)")
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
                Self.log.error("count 查询失败: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
                return 0
            }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    // MARK: - 测试辅助(经 @testable / 同单元使用)

    func rawExecForTesting(_ sql: String) {
        exec(sql)
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

    /// 解析:`a b` = a AND b;`a OR b`;`NOT a` / `!a`;`"精确 短语"`;词内 `*` → 任意串
    private static func parseQuery(_ query: String) -> [QueryToken] {
        // 分词:引号内整体为一个词(引号内的 OR/NOT 不当操作符)
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
        Self.log.error("SQL 执行失败: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
        return false
    }

    /// 预处理 + 绑定 + 迭代行 → ClipItem 列表
    private func items(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }) -> [ClipItem] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            Self.log.error("查询 prepare 失败: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
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
            Self.log.error("写入 prepare 失败: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            return false
        }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            Self.log.error("写入 step 失败: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
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
                 noDelete: sqlite3_column_int64(stmt, 9) != 0)
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
}
