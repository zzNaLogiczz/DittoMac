import Foundation
import SQLite3
import Compression
import zlib
import AppKit

// MARK: - 打包条目导出/导入(原版 "Export Clip(s)" .dto 包,ClipIds.cpp:436-470
// + Clip_ImportExport.cpp:29-84 ExportToSqliteDB / 205-282 ImportFromSqliteV1)
//
// 包 = 独立 sqlite 文件,表结构对齐上游(ExportToSqliteDB Clip_ImportExport.cpp:29-84
// + CreateExportSqliteDB ClipIds.cpp:406-421):
//   Main(lID INTEGER PRIMARY KEY, lVersion INTEGER, mText TEXT)   // lVersion=1
//   Data(lID INTEGER PRIMARY KEY, lParentID INTEGER,
//        strClipboardFormat TEXT, lOriginalSize INTEGER, ooData BLOB)
// Data.ooData 为 zlib 压缩;导出按捕获序【倒序】逐行写(上游 for 循环从尾部遍历),
// 导入按 Data 主键倒序读回恢复捕获序(上游 SQL `ORDER BY Data.lID desc`)。
// mText = 条目描述(导入时无时间信息,取导入时刻)。
// ⚠️ 与 Windows 版实际互导未实测(标待人工验证):命名映射/DROPFILES/DIB 按公开
// 结构实现,真机对导前请先备份。

// MARK: zlib 编解码(RFC1950 容器)

/// Apple Compression 的 COMPRESSION_ZLIB 输出的是裸 DEFLATE(RFC1951),
/// Windows zlib uncompress() 需要 RFC1950 容器 → 手工补 2 字节头 + Adler-32 尾
public enum ZlibCodec {

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    /// zlib compress():0x78 0x9C + raw deflate + adler32(大端)
    public static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }   // 空数据上游 compressBound(0) 也无意义,直接拒
        let dstCapacity = data.count + data.count / 2 + 128   // deflate 最坏膨胀上界 + 头尾余量
        var dst = Data(count: dstCapacity)
        let written = dst.withUnsafeMutableBytes { dstPtr -> Int in
            data.withUnsafeBytes { srcPtr -> Int in
                compression_encode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!, dstCapacity,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }

        var out = Data([0x78, 0x9C])   // CM=8 CINFO=7 FCHECK=28(0x789C % 31 == 0)
        out.append(dst.prefix(written))
        var adler = adler32(data).bigEndian
        withUnsafeBytes(of: &adler) { out.append(contentsOf: $0) }
        return out
    }

    /// 验证 RFC1950 容器、完整 DEFLATE 流、原始长度和 Adler-32。
    public static func decompress(_ data: Data, originalSize: Int) -> Data? {
        decompress(data, originalSize: originalSize, allowLegacyChecksum: false)
    }

    // 仅旧 Mac Data.id 包可使用旧版错误的模 65536 校验值。网络等通用调用保持严格。
    fileprivate static func decompressLegacyMacPackage(_ data: Data, originalSize: Int) -> Data? {
        decompress(data, originalSize: originalSize, allowLegacyChecksum: true)
    }

    private static func decompress(_ data: Data, originalSize: Int,
                                   allowLegacyChecksum: Bool) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, originalSize >= 0 else { return nil }
        let cmf = bytes[0], flg = bytes[1]
        guard cmf & 0x0F == 8, cmf >> 4 <= 7,
              (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0,
              flg & 0x20 == 0 else { return nil }
        let checksum = bytes.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let payload = Data(bytes[2..<(bytes.count - 4)])
        // 固定大小缓冲避免相信包中的长度分配大块内存；输出超过声明长度即拒绝。
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        var output = Data()
        let complete = payload.withUnsafeBytes { source -> Bool in
            scratch.withUnsafeMutableBytes { destination -> Bool in
                guard source.count <= Int(UInt32.max) else { return false }
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
                        == Z_OK else { return false }
                defer { inflateEnd(&stream) }
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress!)
                stream.avail_in = uInt(source.count)
                while true {
                    stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress!
                    stream.avail_out = uInt(destination.count)
                    let remainingInput = stream.avail_in
                    let status = inflate(&stream, Z_FINISH)
                    let written = destination.count - Int(stream.avail_out)
                    guard written <= originalSize - output.count else { return false }
                    output.append(destination.bindMemory(to: UInt8.self).baseAddress!, count: written)
                    if status == Z_STREAM_END {
                        return stream.avail_in == 0 && output.count == originalSize
                    }
                    guard status == Z_OK || status == Z_BUF_ERROR,
                          written > 0 || stream.avail_in < remainingInput else { return false }
                }
            }
        }
        guard complete else { return nil }
        if checksum == adler32(output) { return output }
        if allowLegacyChecksum {
            var a: UInt32 = 1, b: UInt32 = 0
            for byte in output {
                a = (a + UInt32(byte)) & 0xFFFF
                b = (b + a) & 0xFFFF
            }
            if checksum == (b << 16 | a) { return output }
        }
        return nil
    }

}

// MARK: CF_HDROP 编解码(DROPFILES 结构)

/// DROPFILES(20 字节头 + 双 null 结尾的宽字符路径列表)读写。
/// 结构:DWORD pFiles=20 | POINT pt(2×DWORD) | BOOL fNC | BOOL fWide=1
public enum DropFilesCodec {

    public static func encode(paths: [String]) -> Data {
        // 20 字节头:pFiles=20(列表偏移)| pt.x=0 | pt.y=0 | fNC=0 | fWide=1
        var header = [UInt8]()
        func append32(_ v: UInt32) {
            header.append(UInt8(v & 0xFF))
            header.append(UInt8((v >> 8) & 0xFF))
            header.append(UInt8((v >> 16) & 0xFF))
            header.append(UInt8((v >> 24) & 0xFF))
        }
        append32(20)         // pFiles:文件列表起始偏移
        append32(0); append32(0)   // pt.x / pt.y(客户区坐标,fNC=0 时无意义)
        append32(0)          // fNC
        append32(1)          // fWide:UTF-16
        // 双 null 结尾的 UTF-16LE 路径列表
        var body = [UInt8]()
        for path in paths {
            for unit in path.utf16 {
                body.append(UInt8(unit & 0xFF))
                body.append(UInt8(unit >> 8))
            }
            body.append(0); body.append(0)   // 串尾 null
        }
        body.append(0); body.append(0)       // 列表尾第二 null
        return Data(header + body)
    }

    public static func decode(_ data: Data) -> [String]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 20 else { return nil }
        func le32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        let pFiles = Int(le32(0))
        let fWide = le32(16) != 0
        guard pFiles >= 20, pFiles <= bytes.count else { return nil }

        var paths: [String] = []
        if fWide {
            var units: [UInt16] = []
            var i = pFiles
            while i + 1 < bytes.count {
                let unit = UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
                i += 2
                if unit == 0 {
                    if units.isEmpty { break }   // 双 null = 列表结束
                    paths.append(String(decoding: units, as: UTF16.self))
                    units = []
                } else {
                    units.append(unit)
                }
            }
        } else {
            // 窄字符路径(老程序写的包):按 UTF-8 近似解(失败字符替换)
            var chunk: [UInt8] = []
            var i = pFiles
            while i < bytes.count {
                let byte = bytes[i]
                i += 1
                if byte == 0 {
                    if chunk.isEmpty { break }
                    paths.append(String(decoding: chunk, as: UTF8.self))
                    chunk = []
                } else {
                    chunk.append(byte)
                }
            }
        }
        return paths
    }
}

// MARK: CF_DIB ↔ 位图数据(BMP 容器包装)

/// Windows DIB(去 14 字节文件头的 BMP)与 macOS 位图数据互转。
/// 失败返回 nil(调用方跳过该格式并记日志 —— 任务允许的降级路径)
public enum DIBCodec {

    /// PNG/TIFF 数据 → DIB(NSBitmapImageRep 输出 BMP 文件后剥 14 字节头)
    public static func dibFromImageData(_ data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data),
              let bmp = rep.representation(using: .bmp, properties: [:]),
              bmp.count > 14 else { return nil }
        return bmp.dropFirst(14)   // BITMAPFILEHEADER 恰为 14 字节
    }

    /// DIB → PNG(手工补 BITMAPFILEHEADER 还原 BMP 文件再解码)
    public static func imageDataFromDIB(_ dib: Data) -> Data? {
        // BITMAPINFOHEADER/V2/V3/V4/V5。OS/2 64 字节头的布局不同，明确拒绝。
        guard dib.count >= 40, dib.count <= Int(UInt32.max) - 14 else { return nil }
        let bytes = [UInt8](dib)
        func le16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func le32(_ o: Int) -> Int {
            Int(bytes[o]) | Int(bytes[o + 1]) << 8
                | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
        }
        let headerSize = le32(0)
        guard [40, 52, 56, 108, 124].contains(headerSize), headerSize <= bytes.count else { return nil }
        let width = Int(Int32(bitPattern: UInt32(le32(4))))
        let height = Int(Int32(bitPattern: UInt32(le32(8))))
        let bitCount = le16(14), compression = le32(16), clrUsed = le32(32)
        guard width > 0, height != 0, height != Int(Int32.min), le16(12) == 1,
              [1, 4, 8, 16, 24, 32].contains(bitCount),
              [0, 3, 6].contains(compression) else { return nil }
        if compression != 0 {
            guard [16, 32].contains(bitCount), compression != 6 || headerSize == 40 || headerSize >= 56
            else { return nil }
        }
        let paletteEntries = clrUsed == 0 && bitCount <= 8 ? 1 << bitCount : clrUsed
        guard bitCount > 8 || paletteEntries <= 1 << bitCount else { return nil }
        let masks = headerSize == 40 ? (compression == 3 ? 12 : compression == 6 ? 16 : 0) : 0
        let pixelOffset = headerSize + masks + paletteEntries * 4
        guard pixelOffset <= bytes.count else { return nil }
        let stride = ((width * bitCount + 31) / 32) * 4
        let (pixelBytes, overflow) = stride.multipliedReportingOverflow(by: abs(height))
        guard !overflow, pixelBytes <= bytes.count - pixelOffset else { return nil }
        let declaredImageBytes = le32(20)
        guard declaredImageBytes == 0 || (declaredImageBytes >= pixelBytes && declaredImageBytes <= bytes.count - pixelOffset)
        else { return nil }
        let offset = 14 + pixelOffset

        var bmp = Data()
        func appendLE32(_ v: UInt32) { withUnsafeBytes(of: UInt32(v).littleEndian) { bmp.append(contentsOf: $0) } }
        bmp.append(contentsOf: [0x42, 0x4D])                    // "BM"
        appendLE32(UInt32(14 + dib.count))                      // 文件总长
        appendLE32(0)                                           // 保留
        appendLE32(UInt32(offset))                              // 像素偏移
        bmp.append(dib)
        guard let rep = NSBitmapImageRep(data: bmp) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: Windows 格式名 ↔ UTI 映射表(双向)

/// 上游 GetFormatName/CF 名称与 macOS UTI 的对照(任务给定表;双向查询)
public enum WindowsFormatNames {

    public static let unicodeText = "CF_UNICODETEXT"
    public static let ansiText = "CF_TEXT"
    public static let rtf = "Rich Text Format"
    public static let html = "HTML Format"
    public static let png = "PNG"
    public static let dib = "CF_DIB"
    public static let hdrop = "CF_HDROP"

    /// Windows 名 → 代表性 UTI(CF_UNICODETEXT/CF_TEXT 都归纯文本)
    public static let nameToUTI: [String: String] = [
        unicodeText: ClipUTI.text,
        ansiText: ClipUTI.text,
        rtf: ClipUTI.rtf,
        html: ClipUTI.html,
        png: ClipUTI.png,
        dib: ClipUTI.tiff,
        hdrop: ClipUTI.fileURL,
    ]

    /// UTI → Windows 名(文本取规范名 CF_UNICODETEXT)
    public static let utiToName: [String: String] = [
        ClipUTI.text: unicodeText,
        ClipUTI.rtf: rtf,
        ClipUTI.html: html,
        ClipUTI.png: png,
        ClipUTI.tiff: dib,
        ClipUTI.fileURL: hdrop,
    ]
}

// MARK: 包条目模型与 IO

/// 一个待导出/已导入的包条目:描述 + 时间 + 捕获序格式列表
public struct PackagedClip {
    public var desc: String
    public var createdAt: Date
    /// 捕获顺序(文本在前,与 loadFormatsOf 的已知格式顺序一致)
    public var formats: [ClipFormat]

    public init(desc: String, createdAt: Date, formats: [ClipFormat]) {
        self.desc = desc
        self.createdAt = createdAt
        self.formats = formats
    }
}

/// 导出/导入本体:独立 sqlite 文件(与主库无关,自开自关)
public enum ClipPackage {

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // Main 第二列 = lVersion(CURRENT_EXPORT_VERSION=1,上游 Clip_ImportExport.cpp:17)
    private static let schema = """
        CREATE TABLE Main(lID INTEGER PRIMARY KEY, lVersion INTEGER, mText TEXT);
        CREATE TABLE Data(lID INTEGER PRIMARY KEY, lParentID INTEGER, strClipboardFormat TEXT, lOriginalSize INTEGER, ooData BLOB);
        """

    // MARK: - 模型 ↔ 格式行

    /// RawClip → 捕获序格式列表(导出用):
    /// text 转 UTF-16LE + null;rtf/html/png 原样;tiff 转 CF_DIB(BMP-DIB);files 转 CF_HDROP(DROPFILES);
    /// 附加格式保留 UTI 名(未知名原样往返,导入侧同规则回收)
    public static func formats(fromRaw raw: RawClip) -> [ClipFormat] {
        var result: [ClipFormat] = []
        if let text = raw.text, !text.isEmpty {
            result.append(ClipFormat(type: WindowsFormatNames.unicodeText, data: encodeUnicodeText(text)))
        }
        if let rtf = raw.rtfData {
            result.append(ClipFormat(type: WindowsFormatNames.rtf, data: rtf))
        }
        if let html = raw.htmlData {
            result.append(ClipFormat(type: WindowsFormatNames.html, data: html))
        }
        if let image = raw.imageData {
            // TIFF 走 CF_DIB(DIB 化);PNG 原样;其余位图尝试 DIB,失败仍按 PNG 名带原始数据
            if let dib = DIBCodec.dibFromImageData(image), !isPNGData(image) {
                result.append(ClipFormat(type: WindowsFormatNames.dib, data: dib))
            } else {
                result.append(ClipFormat(type: WindowsFormatNames.png, data: image))
            }
        }
        if let paths = raw.filePaths, !paths.isEmpty {
            result.append(ClipFormat(type: WindowsFormatNames.hdrop, data: DropFilesCodec.encode(paths: paths)))
        }
        result += raw.extraFormats.filter { !$0.data.isEmpty }
        return result
    }

    /// 格式行 → RawClip(导入用):名称映射回模型;CF_DIB 包 BMP 失败 → 跳过并记日志;
    /// 未知名 → 附加格式保留原始数据
    public static func rawClip(from formats: [ClipFormat]) -> RawClip {
        var raw = RawClip()
        var extras: [ClipFormat] = []
        for format in formats {
            switch format.type {
            case WindowsFormatNames.unicodeText:
                if let text = decodeUnicodeText(format.data) { raw.text = text }
            case WindowsFormatNames.ansiText:
                if raw.text == nil || raw.text?.isEmpty == true {
                    let content = Data(format.data.prefix { $0 != 0 })
                    raw.text = String(data: content, encoding: .utf8)
                        ?? String(data: content, encoding: .isoLatin1)
                }
            case WindowsFormatNames.rtf:
                raw.rtfData = format.data
            case WindowsFormatNames.html:
                raw.htmlData = format.data
            case WindowsFormatNames.png:
                if raw.imageData == nil { raw.imageData = format.data }
            case WindowsFormatNames.dib:
                if raw.imageData == nil {
                    if let png = DIBCodec.imageDataFromDIB(format.data) {
                        raw.imageData = png
                    } else {
                        // DIB 结构超出已实现的头变体:跳过(任务允许的降级路径)
                        DiagLog.error("导入:CF_DIB 解码失败,已跳过该格式(size=\(format.data.count))")
                    }
                }
            case WindowsFormatNames.hdrop:
                if let paths = DropFilesCodec.decode(format.data), !paths.isEmpty, raw.filePaths == nil {
                    raw.filePaths = paths
                }
            default:
                extras.append(format)   // 未知名原样保留(UTI 即名字,导出导入对称)
            }
        }
        raw.extraFormats = extras
        return raw
    }

    private static func encodeUnicodeText(_ text: String) -> Data {
        var bytes = Data()
        for unit in text.utf16 {
            bytes.append(UInt8(unit & 0xFF)); bytes.append(UInt8(unit >> 8))
        }
        bytes.append(contentsOf: [0, 0])
        return bytes
    }

    private static func decodeUnicodeText(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2, bytes.count % 2 == 0 else { return nil }
        var units: [UInt16] = []
        var end = 0
        while end + 1 < bytes.count {
            let unit = UInt16(bytes[end]) | UInt16(bytes[end + 1]) << 8
            if unit == 0 { return decodeStrictUTF16(units) }
            units.append(unit)
            end += 2
        }
        return nil   // CF_UNICODETEXT 必须以 UTF-16 null 终止
    }

    /// 严格 UTF-16 解码:孤立代理项视为损坏(macOS 14 及更早的 Foundation 会容错解码,不能依赖)
    private static func decodeStrictUTF16(_ units: [UInt16]) -> String? {
        var scalars = String.UnicodeScalarView()
        var iterator = units.makeIterator()
        var decoder = UTF16()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: return String(scalars)
            case .error: return nil
            }
        }
    }

    static func isPNGData(_ data: Data) -> Bool {
        data.count > 8 && data[data.startIndex] == 0x89 && data[data.startIndex + 1] == 0x50
    }

    // MARK: - 导出

    /// 把若干条目写入包文件(覆盖已存在文件)。全部行写成功返回 true
    public static func export(clips: [PackagedClip], to url: URL) -> Bool {
        guard !clips.isEmpty else { return false }
        try? FileManager.default.removeItem(at: url)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let db else {
            _ = db.map { String(cString: sqlite3_errmsg($0)) }.map { DiagLog.error("导出:打开包失败 \($0)") }
            sqlite3_close_v2(db)
            return false
        }
        defer { sqlite3_close_v2(db) }
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            DiagLog.error("导出:建表失败 \(String(cString: sqlite3_errmsg(db)))")
            return false
        }

        var ok = true
        for clip in clips {
            // Main 行:lVersion=1(上游 CURRENT_EXPORT_VERSION,Clip_ImportExport.cpp:17);mText = 描述
            guard insertRow(db, "INSERT INTO Main(lID, lVersion, mText) VALUES(NULL, ?, ?)", bind: {
                sqlite3_bind_int64($0, 1, 1)
                sqlite3_bind_text($0, 2, clip.desc, -1, sqliteTransient)
            }) else { ok = false; continue }
            let rowID = sqlite3_last_insert_rowid(db)

            // Data 行:捕获序倒序写入(上游 ExportToSqliteDB 的尾遍历,Clip_ImportExport.cpp:44-46)
            for format in clip.formats.reversed() {
                guard let zipped = ZlibCodec.compress(format.data) else {
                    DiagLog.error("导出:格式 \(format.type) 压缩失败,跳过")
                    ok = false
                    continue
                }
                guard insertRow(db, """
                    INSERT INTO Data(lID, lParentID, strClipboardFormat, lOriginalSize, ooData)
                    VALUES(NULL, ?, ?, ?, ?)
                    """, bind: {
                    sqlite3_bind_int64($0, 1, rowID)
                    sqlite3_bind_text($0, 2, format.type, -1, sqliteTransient)
                    sqlite3_bind_int64($0, 3, Int64(format.data.count))
                    sqlite3_bind_blob($0, 4, [UInt8](zipped), Int32(zipped.count), sqliteTransient)
                }) else { ok = false; continue }
            }
        }
        return ok
    }

    @discardableResult
    private static func insertRow(_ db: OpaquePointer, _ sql: String,
                                  bind: (OpaquePointer) -> Void) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        bind(stmt)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    // MARK: - 导入

    /// 读包文件:返回包条目(捕获序格式)。打不开/无 Main 表 → nil
    public static func importClips(from url: URL) -> [PackagedClip]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let db else {
            sqlite3_close_v2(db)
            return nil
        }
        defer { sqlite3_close_v2(db) }

        // 列名探测:标准包 = (lID,lVersion,mText);我们早期测试包 = (lID,lDate,mText),兼容读
        guard let mainColumns = columns(of: "Main", in: db),
              let dataColumns = columns(of: "Data", in: db) else { return nil }
        let mainID = mainColumns.first(where: { $0.hasSuffix("ID") || $0 == "id" }) ?? "lID"
        let hasDate = mainColumns.contains("lDate")
        guard dataColumns.contains("lID") || dataColumns.contains("id") else { return nil }
        let isLegacyMacPackage = !dataColumns.contains("lID") && dataColumns.contains("id")
        let dataID = isLegacyMacPackage ? "id" : "lID"

        // Main 倒序读(上游 `Select * from Main order by lID DESC`)
        let mainSQL = "SELECT \(mainID), mText\(hasDate ? ", lDate" : "") FROM Main ORDER BY \(mainID) DESC"
        var mainStmt: OpaquePointer?
        defer { sqlite3_finalize(mainStmt) }
        guard sqlite3_prepare_v2(db, mainSQL, -1, &mainStmt, nil) == SQLITE_OK, let mainStmt else { return nil }

        var result: [PackagedClip] = []
        while sqlite3_step(mainStmt) == SQLITE_ROW {
            let desc = mainStmt.columnText(1) ?? ""
            let createdAt = hasDate
                ? Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(mainStmt, 2)))
                : Date()   // 旧版包(lVersion 列):无时间 → 导入时刻
            let parentID = sqlite3_column_int64(mainStmt, 0)

            // Data 倒序读恢复捕获序(导出倒序写的对称操作,上游 ImportFromSqliteV1 同款 SQL)
            var dataStmt: OpaquePointer?
            defer { sqlite3_finalize(dataStmt) }
            let dataSQL = """
                SELECT strClipboardFormat, lOriginalSize, ooData FROM Data
                WHERE lParentID = ? ORDER BY \(dataID) DESC
                """
            guard sqlite3_prepare_v2(db, dataSQL, -1, &dataStmt, nil) == SQLITE_OK, let dataStmt else {
                continue
            }
            sqlite3_bind_int64(dataStmt, 1, parentID)
            var formats: [ClipFormat] = []
            while sqlite3_step(dataStmt) == SQLITE_ROW {
                guard let name = dataStmt.columnText(0) else { continue }
                let originalSize = Int(sqlite3_column_int64(dataStmt, 1))
                guard let blob = dataStmt.columnBlob(2) else { continue }
                let decoded = isLegacyMacPackage
                    ? ZlibCodec.decompressLegacyMacPackage(blob, originalSize: originalSize)
                    : ZlibCodec.decompress(blob, originalSize: originalSize)
                guard var raw = decoded else {
                    DiagLog.error("导入:格式 \(name) 解压失败,跳过(size=\(originalSize))")
                    continue
                }
                if isLegacyMacPackage, name == WindowsFormatNames.unicodeText {
                    // 旧版 Data.id 包将 CF_UNICODETEXT 写成 UTF-8；只在已识别的旧 schema 迁移。
                    guard let text = String(data: raw, encoding: .utf8) else { continue }
                    raw = encodeUnicodeText(text)
                }
                formats.append(ClipFormat(type: name, data: raw))
            }
            guard !formats.isEmpty else { continue }   // 上游同样丢弃无格式行
            result.append(PackagedClip(desc: desc, createdAt: createdAt, formats: formats))
        }
        return result
    }

    /// 表的列名列表(表不存在 → nil;用于兼容新旧列名)
    private static func columns(of table: String, in db: OpaquePointer) -> [String]? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT name FROM pragma_table_info('\(table)')"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            names.append(stmt.columnText(0) ?? "")
        }
        return names.isEmpty ? nil : names
    }
}

// MARK: - sqlite 取值辅助(本文件内复用)

private extension OpaquePointer {
    func columnText(_ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(self, index) else { return nil }
        return String(cString: cString)
    }

    func columnBlob(_ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(self, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(self, index)))
    }
}
