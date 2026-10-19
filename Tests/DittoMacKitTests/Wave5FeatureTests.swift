import AppKit
import Foundation
import SQLite3

/// Wave5 特性:二维码 / Google 翻译 / 打包条目导出导入 / 统计 / 空闲清理门控 /
/// 便携模式 / 调试日志落盘
final class Wave5FeatureTests: XCTestCase {

    /// 每个测试独享的临时目录(导出文件/日志/便携根)
    private var tmp: URL!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dittomac-wave5-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tmp = dir
    }

    override func tearDown() {
        PortableMode.setResolvedRootForTesting(nil)
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        super.tearDown()
    }

    // MARK: - 二维码(上游 CreateQRCodeImage.cpp:29-95 的 CoreImage 等价)

    /// 生成器返回图片;输入更长 → 码更大(模块更多);PNG 可导出
    func testQRGeneratorImageAndScaling() {
        let short = QRCodeExport.makeImage(for: "hello ditto")
        XCTAssertNotNil(short, "短文本应生成二维码")
        XCTAssertNotNil(QRCodeExport.makePNG(for: "hello ditto"), "PNG 导出应成功")

        // 800 字符比 12 字符需要更多模块 → 输出像素尺寸更大
        let long = QRCodeExport.makeImage(for: String(repeating: "x", count: 800))
        XCTAssertNotNil(long)
        XCTAssertGreaterThan(long!.size.width, short!.size.width, "长文本码图应更大")
        // ≥10px/module 保证:最短的二维码(21 模块)至少 210px 宽
        XCTAssertGreaterThan(short!.size.width, 200, "每模块 ≥10px")

        // 门控:空文本 / 超 2000 字符 → nil
        XCTAssertNil(QRCodeExport.makeImage(for: "   \n  "), "空白文本拒绝")
        XCTAssertNil(QRCodeExport.makeImage(for: String(repeating: "y", count: QRCodeExport.maxTextLength + 1)),
                     "超长文本拒绝(由 UI 弹提示)")
        XCTAssertEqual(QRCodeExport.correctionLevel, "H", "上游 CreateQRCodeImage.cpp 用纠错级 H")
    }

    /// 展示截断:短文本原样;长文本截断加省略号
    func testQRDisplayTruncation() {
        XCTAssertEqual(QRCodeExport.displayTruncation(of: "abc"), "abc")
        let long = QRCodeExport.displayTruncation(of: String(repeating: "a", count: 400))
        XCTAssertEqual(long.count, 301, "300 字符 + 省略号")
        XCTAssertTrue(long.hasSuffix("…"))
    }

    // MARK: - Google 翻译(上游 QPasteWnd.cpp:4551-4600)

    /// URL 构建:编码 / 目标语言映射 / 空文本
    func testTranslateURLBuilding() {
        XCTAssertEqual(TranslateExport.targetLanguage(isChinese: true), "zh-CN")
        XCTAssertEqual(TranslateExport.targetLanguage(isChinese: false), "en")

        let url = TranslateExport.url(for: "hello world", target: "en")
        XCTAssertEqual(url, "https://translate.google.com/?sl=auto&tl=en&text=hello%20world",
                       "空格应百分号编码")
        // 保留字符必须编码,防注入查询参数
        let tricky = TranslateExport.url(for: "a&b=c?d+e", target: "zh-CN")
        XCTAssertNotNil(tricky)
        XCTAssertTrue(tricky!.hasPrefix("https://translate.google.com/?sl=auto&tl=zh-CN&text="))
        XCTAssertFalse(tricky!.hasSuffix("a&b=c?d+e"), "保留字符不能原样出现在 text 值里")
        XCTAssertTrue(tricky!.contains("%26"), "& 应编码为 %26")

        // 中文进入路径也应被编码且可还原
        let zh = TranslateExport.url(for: "你好世界", target: "zh-CN")
        XCTAssertNotNil(zh)
        XCTAssertFalse(zh!.contains("你好"), "非 ASCII 应百分号编码")

        XCTAssertNil(TranslateExport.url(for: "  ", target: "en"), "空白文本 → nil")
    }

    /// 截断:超 1200 字符截断并标记
    func testTranslateTruncation() {
        let short = TranslateExport.prepare("abc")
        XCTAssertFalse(short.truncated)
        let long = TranslateExport.prepare(String(repeating: "z", count: 1500))
        XCTAssertTrue(long.truncated)
        XCTAssertEqual(long.text.count, TranslateExport.maxTextLength)
        let (url, truncated) = TranslateExport.urlForExport(String(repeating: "z", count: 1300),
                                                            isChinese: false)
        XCTAssertTrue(truncated)
        XCTAssertNotNil(url)
        // 截断后 text 参数只含 maxTextLength 个 z(1200,不是原始 1300)
        XCTAssertEqual(url!.filter { $0 == "z" }.count, TranslateExport.maxTextLength)
    }

    // MARK: - zlib 容器(上游 ooData 列的压缩格式)

    func testZlibRoundtrip() {
        let payload = Data("剪贴板内容 clipboard payload 0123456789".utf8)
        let zipped = ZlibCodec.compress(payload)
        XCTAssertNotNil(zipped)
        XCTAssertEqual(Array(zipped!.prefix(2)), [0x78, 0x9C], "RFC1950 头 0x78 0x9C")
        let restored = ZlibCodec.decompress(zipped!, originalSize: payload.count)
        XCTAssertEqual(restored, payload, "压缩往返应还原")

        // 大数据(跨多个 deflate 块)
        let big = Data((0..<100_000).map { UInt8($0 % 251) })
        let bigZip = ZlibCodec.compress(big)
        XCTAssertNotNil(bigZip)
        XCTAssertTrue(bigZip!.count < big.count, "重复数据应显著压缩")
        XCTAssertEqual(ZlibCodec.decompress(bigZip!, originalSize: big.count), big)

        // 坏头拒绝:FDICT 位置位 / 非 deflate CM
        XCTAssertNil(ZlibCodec.decompress(Data([0x78, 0xBB] + [UInt8](repeating: 0, count: 10)),
                                          originalSize: 4), "坏容器拒绝")
        XCTAssertNil(ZlibCodec.decompress(Data([0x08, 0x1D] + [UInt8](repeating: 0, count: 10)),
                                          originalSize: 4), "CM≠8 拒绝")
    }

    /// Python zlib.compress fixtures; expectations do not use this codec to create inputs.
    func testZlibStandardFixturesAndIntegrity() {
        let fixture = hexData("789c7374a40c0000107e1041") // b"A" * 64
        let payload = Data(repeating: 65, count: 64)
        XCTAssertEqual(ZlibCodec.decompress(fixture, originalSize: 64), payload)
        XCTAssertEqual(ZlibCodec.compress(payload)?.suffix(4), Data([0x10, 0x7e, 0x10, 0x41]))
        XCTAssertEqual(ZlibCodec.decompress(hexData("789c030000000001"), originalSize: 0), Data())
        XCTAssertNil(ZlibCodec.decompress(fixture, originalSize: 63), "No silently truncated output")
        XCTAssertNil(ZlibCodec.decompress(fixture, originalSize: 65))
        XCTAssertNil(ZlibCodec.decompress(fixture, originalSize: 0))
        XCTAssertNil(ZlibCodec.decompress(fixture, originalSize: -1))
        var corrupt = fixture
        corrupt[corrupt.count - 1] ^= 1
        XCTAssertNil(ZlibCodec.decompress(corrupt, originalSize: 64), "Adler must match")
        XCTAssertNil(ZlibCodec.decompress(hexData("789c7374a40c000010601041"), originalSize: 64),
                     "General decoder must reject legacy invalid Adler")
        var truncated = fixture
        truncated.remove(at: truncated.count - 5)
        XCTAssertNil(ZlibCodec.decompress(truncated, originalSize: 64), "Stream must end")
        var trailing = fixture
        trailing.insert(0, at: trailing.count - 4)
        XCTAssertNil(ZlibCodec.decompress(trailing, originalSize: 64), "Reject trailing DEFLATE bytes")
        var invalidWindow = fixture
        invalidWindow[0] = 0x88; invalidWindow[1] = 0x1c
        XCTAssertNil(ZlibCodec.decompress(invalidWindow, originalSize: 64), "CINFO > 7")
    }

    func testPackageWindowsUnicodeFixtureAndSchema() {
        let expected = "中文A😀"
        let bytes = hexData("2d4e876541003dd800de0000")
        let fixture = makePackageFixture(primaryKey: "lID", size: bytes.count,
                                         compressed: hexData("789cd3f56b4f7564b0bdc1708f810100189d039c"))
        guard let imported = ClipPackage.importClips(from: fixture), imported.count == 1 else {
            XCTFail("Standard Windows schema and zlib fixture should import"); return
        }
        XCTAssertEqual(imported[0].formats[0].data, bytes)
        XCTAssertEqual(ClipPackage.rawClip(from: imported[0].formats).text, expected)
        let formats = ClipPackage.formats(fromRaw: RawClip(text: expected))
        XCTAssertEqual(formats.first?.data, bytes, "Export UTF-16LE including terminating null")
        let exported = tmp.appendingPathComponent("standard.dto")
        XCTAssertTrue(ClipPackage.export(clips: [PackagedClip(desc: expected, createdAt: Date(), formats: formats)], to: exported))
        var db: OpaquePointer?
        guard sqlite3_open_v2(exported.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            XCTFail("Open exported database"); return
        }
        defer { sqlite3_close(db) }
        // The upstream import query explicitly orders by Data.lID.
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT ooData, lOriginalSize FROM Data WHERE lParentID=1 ORDER BY Data.lID DESC", -1, &stmt, nil), SQLITE_OK)
        guard let stmt, sqlite3_step(stmt) == SQLITE_ROW, let blob = sqlite3_column_blob(stmt, 0) else {
            XCTFail("Windows SQL must read the exported row"); return
        }
        let compressed = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
        XCTAssertEqual(sqlite3_column_int(stmt, 1), Int32(bytes.count))
        XCTAssertEqual(compressed.suffix(4), hexData("189d039c"), "Python zlib Adler fixture")
        XCTAssertEqual(ZlibCodec.decompress(compressed, originalSize: bytes.count), bytes)
    }

    func testPackageLegacyMacCompatibilityIsScoped() {
        let legacy = hexData("789c7374a40c000010601041") // Old modulo-65536 checksum
        let oldURL = makePackageFixture(primaryKey: "id", size: 64, compressed: legacy)
        let imported = ClipPackage.importClips(from: oldURL)
        XCTAssertEqual(imported?.count, 1)
        XCTAssertEqual(imported.flatMap { $0.first }.map { ClipPackage.rawClip(from: $0.formats).text },
                       String(repeating: "A", count: 64))
        let unicodeURL = makePackageFixture(primaryKey: "id", size: 19,
            compressed: hexData("789c7b367db9826f62b2c2b369edcfe6ac51f8307f46030065180a6e"))
        let unicode = ClipPackage.importClips(from: unicodeURL)
        XCTAssertEqual(unicode.flatMap { $0.first }.map { ClipPackage.rawClip(from: $0.formats).text }, "旧 Mac 文本 😀")
        let standardURL = makePackageFixture(primaryKey: "lID", size: 64, compressed: legacy)
        XCTAssertEqual(ClipPackage.importClips(from: standardURL)?.count, 0, "Legacy checksum forbidden for standard packages")
        var corrupt = legacy
        corrupt[corrupt.count - 1] ^= 1
        let corruptURL = makePackageFixture(primaryKey: "id", size: 64, compressed: corrupt)
        XCTAssertEqual(ClipPackage.importClips(from: corruptURL)?.count, 0, "Legacy schema cannot bypass checksum verification")
        if let clip = imported?.first {
            let reexport = tmp.appendingPathComponent("migrated.dto")
            XCTAssertTrue(ClipPackage.export(clips: [clip], to: reexport))
            XCTAssertEqual(ClipPackage.importClips(from: reexport)?.first.map { ClipPackage.rawClip(from: $0.formats).text },
                           String(repeating: "A", count: 64), "Migrated formats must re-export as standard Unicode")
        }
    }

    func testPackageUnicodeBoundaries() {
        for text in ["A", "中文", "😀", "A😀中文", "é"] {
            XCTAssertEqual(ClipPackage.rawClip(from: ClipPackage.formats(fromRaw: RawClip(text: text))).text, text)
        }
        for malformed in [hexData("41"), hexData("4100"), hexData("00d80000")] {
            XCTAssertNil(ClipPackage.rawClip(from: [ClipFormat(type: "CF_UNICODETEXT", data: malformed)]).text)
        }
        let formats = [ClipFormat(type: "CF_TEXT", data: Data([65, 0, 66])),
                       ClipFormat(type: "CF_UNICODETEXT", data: hexData("2d4e0000"))]
        XCTAssertEqual(ClipPackage.rawClip(from: formats).text, "中", "Prefer Unicode over ANSI regardless of row order")
        XCTAssertEqual(ClipPackage.rawClip(from: formats.reversed()).text, "中")
        XCTAssertEqual(ClipPackage.rawClip(from: [formats[0]]).text, "A")
    }

    func testDIBSmallAndIndexedFixtures() {
        let tiny = makeDIB(width: 1, height: 1, bits: 24, pixels: [0, 0, 255, 0])
        XCTAssertEqual(tiny.count, 44, "Smallest 24-bit fixture previously read past the end")
        guard let png = DIBCodec.imageDataFromDIB(tiny), let image = NSBitmapImageRep(data: png) else {
            XCTFail("Valid 1x1 DIB must decode"); return
        }
        XCTAssertEqual(image.pixelsWide, 1); XCTAssertEqual(image.pixelsHigh, 1)
        let indexed = makeDIB(width: 2, height: 2, bits: 8, colors: 2,
                              palette: [0, 0, 0, 0, 255, 255, 255, 0], pixels: [0, 1, 0, 0, 1, 0, 0, 0])
        guard let indexedPNG = DIBCodec.imageDataFromDIB(indexed), let indexedImage = NSBitmapImageRep(data: indexedPNG) else {
            XCTFail("biClrUsed=2 at offset 32 must preserve indexed palette"); return
        }
        XCTAssertEqual(indexedImage.pixelsWide, 2); XCTAssertEqual(indexedImage.pixelsHigh, 2)
        XCTAssertNotEqual(indexedImage.colorAt(x: 0, y: 0), indexedImage.colorAt(x: 1, y: 0))
        let topDown = makeDIB(width: 1, height: -1, bits: 24, pixels: [0, 0, 255, 0])
        XCTAssertNotNil(DIBCodec.imageDataFromDIB(topDown))
    }

    func testDIBRejectsMalformedBounds() {
        let valid = makeDIB(width: 1, height: 1, bits: 24, pixels: [0, 0, 255, 0])
        for count in 0..<valid.count {
            XCTAssertNil(DIBCodec.imageDataFromDIB(Data(valid.prefix(count))), "Truncated DIB \(count)")
        }
        for (offset, value) in [(0, UInt32(124)), (4, 0), (4, UInt32.max), (8, 0),
                                (8, 0x80000000), (12, 0), (16, 1), (20, UInt32.max), (32, UInt32.max)] {
            var malformed = valid
            setDIBWord(&malformed, offset: offset, value: value)
            XCTAssertNil(DIBCodec.imageDataFromDIB(malformed), "Reject invalid field at \(offset)")
        }
        XCTAssertNil(DIBCodec.imageDataFromDIB(makeDIB(width: 1, height: 1, bits: 8, colors: 257,
                                                      palette: [], pixels: [0, 0, 0, 0])))
        var noMasks = makeDIB(width: 1, height: 1, bits: 32, pixels: [0, 0, 255, 0])
        setDIBWord(&noMasks, offset: 16, value: 3)
        XCTAssertNil(DIBCodec.imageDataFromDIB(noMasks), "BITFIELDS requires masks before pixels")
        XCTAssertNil(DIBCodec.imageDataFromDIB(makeDIB(width: Int32.max, height: Int32.max, bits: 32, pixels: [])))
    }

    private func hexData(_ hex: String) -> Data {
        let chars = Array(hex)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0..<$0 + 2]), radix: 16)! })
    }

    private func makePackageFixture(primaryKey: String, size: Int, compressed: Data) -> URL {
        let url = tmp.appendingPathComponent("fixture-\(UUID().uuidString).dto")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { XCTFail("fixture db"); return url }
        defer { sqlite3_close(db) }
        let hex = compressed.map { String(format: "%02x", $0) }.joined()
        let sql = """
            CREATE TABLE Main(lID INTEGER PRIMARY KEY, lVersion INTEGER, mText TEXT);
            CREATE TABLE Data(\(primaryKey) INTEGER PRIMARY KEY, lParentID INTEGER, strClipboardFormat TEXT, lOriginalSize INTEGER, ooData BLOB);
            INSERT INTO Main VALUES(1, 1, 'fixture');
            INSERT INTO Data VALUES(1, 1, 'CF_UNICODETEXT', \(size), X'\(hex)');
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        return url
    }

    private func setDIBWord(_ data: inout Data, offset: Int, value: UInt32) {
        for i in 0..<4 { data[offset + i] = UInt8((value >> (i * 8)) & 0xff) }
    }

    private func makeDIB(width: Int32, height: Int32, bits: UInt16, colors: UInt32 = 0,
                         palette: [UInt8] = [], pixels: [UInt8]) -> Data {
        var result = Data(repeating: 0, count: 40)
        setDIBWord(&result, offset: 0, value: 40)
        setDIBWord(&result, offset: 4, value: UInt32(bitPattern: width))
        setDIBWord(&result, offset: 8, value: UInt32(bitPattern: height))
        setDIBWord(&result, offset: 12, value: UInt32(bits) << 16 | 1)
        setDIBWord(&result, offset: 32, value: colors)
        result.append(contentsOf: palette); result.append(contentsOf: pixels)
        return result
    }

    // MARK: - DROPFILES(CF_HDROP 载体)

    func testDropFilesRoundtrip() {
        let paths = ["/Users/tom/文件 one.txt", "/tmp/second-file.png"]
        let data = DropFilesCodec.encode(paths: paths)
        let stringBytes: Int = paths.reduce(0) { $0 + $1.utf16.count * 2 + 2 }
        XCTAssertEqual(data.count, 20 + stringBytes + 2,
                       "头 20 字节 + 逐串(含 null)+ 列表尾 null")
        // 头字段:pFiles=20,fWide=1
        let bytes = [UInt8](data)
        XCTAssertEqual(Array(bytes[0..<4]), [20, 0, 0, 0])
        XCTAssertEqual(Array(bytes[16..<20]), [1, 0, 0, 0], "fWide=1(UTF-16)")
        XCTAssertEqual(DropFilesCodec.decode(data), paths, "编码往返应还原路径")

        // 非法输入:短于头 / pFiles 偏移非法 → nil;合法空列表 → []
        XCTAssertNil(DropFilesCodec.decode(Data([0, 0, 0])), "短于头的输入拒绝")
        XCTAssertNil(DropFilesCodec.decode(Data(repeating: 0, count: 20)), "pFiles=0 非法拒绝")
        var empty = Data([UInt8]())
        for v: UInt32 in [20, 0, 0, 0, 1] {   // pFiles=20,fWide=1,列表区为空
            withUnsafeBytes(of: v.littleEndian) { empty.append(contentsOf: $0) }
        }
        XCTAssertEqual(DropFilesCodec.decode(empty), [], "合法空列表解出空数组")
    }

    // MARK: - Windows 格式名映射表

    func testFormatNameMappingTable() {
        XCTAssertEqual(WindowsFormatNames.nameToUTI["CF_UNICODETEXT"], ClipUTI.text)
        XCTAssertEqual(WindowsFormatNames.nameToUTI["CF_TEXT"], ClipUTI.text)
        XCTAssertEqual(WindowsFormatNames.nameToUTI["Rich Text Format"], ClipUTI.rtf)
        XCTAssertEqual(WindowsFormatNames.nameToUTI["HTML Format"], ClipUTI.html)
        XCTAssertEqual(WindowsFormatNames.nameToUTI["PNG"], ClipUTI.png)
        XCTAssertEqual(WindowsFormatNames.nameToUTI["CF_DIB"], ClipUTI.tiff)
        XCTAssertEqual(WindowsFormatNames.nameToUTI["CF_HDROP"], ClipUTI.fileURL)
        // 反向:文本取规范名 CF_UNICODETEXT;双向表键值一一对应
        XCTAssertEqual(WindowsFormatNames.utiToName[ClipUTI.text], "CF_UNICODETEXT")
        XCTAssertEqual(WindowsFormatNames.utiToName[ClipUTI.rtf], "Rich Text Format")
        XCTAssertEqual(WindowsFormatNames.utiToName[ClipUTI.html], "HTML Format")
        XCTAssertEqual(WindowsFormatNames.utiToName[ClipUTI.png], "PNG")
        XCTAssertEqual(WindowsFormatNames.utiToName[ClipUTI.tiff], "CF_DIB")
        XCTAssertEqual(WindowsFormatNames.utiToName[ClipUTI.fileURL], "CF_HDROP")
        // 双向表键数:nameToUTI 多一名(CF_TEXT 归并到纯文本),其余一一对应
        XCTAssertEqual(WindowsFormatNames.utiToName.count + 1, WindowsFormatNames.nameToUTI.count)
        for (name, uti) in WindowsFormatNames.nameToUTI where name != "CF_TEXT" {
            XCTAssertEqual(WindowsFormatNames.utiToName[uti], name,
                           "已知名应对称(\(name))")
        }
    }

    // MARK: - 打包条目导出/导入(上游 Clip_ImportExport.cpp:29-84 / ClipIds.cpp:406-470)

    /// 完整往返:文本 + RTF + 附加格式 经 .dittoexport 文件后无损还原
    func testPackageExportImportRoundtrip() {
        let store = ClipStore(path: tmp.appendingPathComponent("pkg.sqlite").path)
        let rtf = Data("{\\rtf1\\ansi hello rtf}".utf8)
        let pdf = Data("%PDF-1.4 extra-format".utf8)
        let raw = RawClip(text: "round trip 文本", rtfData: rtf, htmlData: nil,
                          imageData: nil, filePaths: nil,
                          extraFormats: [ClipFormat(type: "com.microsoft.pdf", data: pdf)],
                          appName: "tester")
        guard let item = store.insert(raw, maxDataBytes: 20 << 20) else {
            XCTFail("插入失败"); return
        }
        let pkgURL = tmp.appendingPathComponent("clips.dittoexport")
        let packages = [PackagedClip(desc: ClipDescription.build(text: raw.text),
                                     createdAt: item.createdAt,
                                     formats: ClipPackage.formats(fromRaw: raw))]
        XCTAssertTrue(ClipPackage.export(clips: packages, to: pkgURL), "导出应成功")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pkgURL.path))

        let imported = ClipPackage.importClips(from: pkgURL)
        XCTAssertNotNil(imported)
        XCTAssertEqual(imported!.count, 1)
        XCTAssertEqual(imported![0].desc, "round trip 文本", "mText = 描述")
        // 标准包无时间列(lVersion=1,同上游):导入时间 = 导入时刻,应≈现在
        XCTAssertTrue(abs(imported![0].createdAt.timeIntervalSince(Date())) < 60)

        let restored = ClipPackage.rawClip(from: imported![0].formats)
        XCTAssertEqual(restored.text, "round trip 文本", "CF_UNICODETEXT 还原文本")
        XCTAssertEqual(restored.rtfData, rtf, "Rich Text Format 还原 RTF")
        XCTAssertEqual(restored.extraFormats,
                       [ClipFormat(type: "com.microsoft.pdf", data: pdf)],
                       "未知名按 UTI 原样保留")
        XCTAssertNil(restored.imageData)
        XCTAssertTrue(restored.htmlData == nil)
    }

    /// 文件条目往返(CF_HDROP);组内插入导入(去重口径在 ClipStore 既有测试覆盖)
    func testPackageFileClipRoundtrip() {
        let raw = RawClip(filePaths: ["/Users/a/图片 1.png", "/Users/a/b.txt"])
        let formats = ClipPackage.formats(fromRaw: raw)
        XCTAssertEqual(formats.count, 1)
        XCTAssertEqual(formats[0].type, "CF_HDROP")
        let restored = ClipPackage.rawClip(from: formats)
        XCTAssertEqual(restored.filePaths, raw.filePaths, "CF_HDROP 往返还原路径列表")
    }

    /// 图片往返:PNG 原样;TIFF 转 CF_DIB(DIB 化)再还原为可解码图片数据
    func testPackageImageRoundtrip() {
        // 造一张 6x4 红色位图 → PNG / TIFF
        var pixels = [UInt8](repeating: 0, count: 6 * 4 * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 255; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 255
        }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 6, pixelsHigh: 4,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 6 * 4, bitsPerPixel: 32)!
        rep.bitmapData!.update(from: pixels, count: pixels.count)
        let png = rep.representation(using: .png, properties: [:])!
        let tiff = rep.tiffRepresentation!

        // PNG:原名带出
        let pngFormats = ClipPackage.formats(fromRaw: RawClip(imageData: png))
        XCTAssertEqual(pngFormats.first?.type, "PNG")
        XCTAssertEqual(pngFormats.first?.data, png)

        // TIFF:转 CF_DIB(DIB),导入端还原成可解码位图
        let tiffFormats = ClipPackage.formats(fromRaw: RawClip(imageData: tiff))
        XCTAssertEqual(tiffFormats.first?.type, "CF_DIB", "TIFF 走 CF_DIB 通道")
        let restored = ClipPackage.rawClip(from: tiffFormats)
        XCTAssertNotNil(restored.imageData, "DIB 应还原为位图数据")
        XCTAssertNotNil(NSBitmapImageRep(data: restored.imageData!), "还原数据应可解码")
    }

    /// 空选择导出拒绝;坏文件导入返回 nil
    func testPackageEdgeCases() {
        XCTAssertFalse(ClipPackage.export(clips: [], to: tmp.appendingPathComponent("x.dittoexport")))
        XCTAssertNil(ClipPackage.importClips(from: tmp.appendingPathComponent("not-exist.dittoexport")))
        let junk = tmp.appendingPathComponent("junk.dittoexport")
        try? Data("not a sqlite".utf8).write(to: junk)
        XCTAssertNil(ClipPackage.importClips(from: junk), "非 sqlite 文件 → nil")
    }

    // MARK: - 统计(上游 OptionsStats.cpp:81-98)

    /// D.H.M 跨度:总天数.小时分量(0-23).分钟分量(0-59)
    func testStatsSpanFormatting() {
        let end = Date(timeIntervalSince1970: 1_700_000_000)
        // 3天5小时42分10秒前
        let days: TimeInterval = 3 * 86400
        let hours: TimeInterval = 5 * 3600
        let minutes: TimeInterval = 42 * 60
        let start = end.addingTimeInterval(-(days + hours + minutes + 10))
        let c = UsageStats.spanComponents(from: start, to: end)
        XCTAssertEqual(c.days, 3)
        XCTAssertEqual(c.hours, 5)
        XCTAssertEqual(c.minutes, 42)
        XCTAssertEqual(UsageStats.spanString(from: start, to: end), "3.05.42",
                       "%.0ld.%02ld.%02ld 口径")

        // 26 小时 = 1天2小时;负跨度夹 0
        let c2 = UsageStats.spanComponents(from: end.addingTimeInterval(-26 * 3600), to: end)
        XCTAssertEqual(c2.days, 1); XCTAssertEqual(c2.hours, 2); XCTAssertEqual(c2.minutes, 0)
        XCTAssertEqual(UsageStats.spanString(from: end, to: end), "0.00.00")
        XCTAssertEqual(UsageStats.spanString(from: end.addingTimeInterval(100), to: end), "0.00.00",
                       "起点在终点之后(负跨度)夹 0")
        XCTAssertEqual(UsageStats.sinceDateString(Date(timeIntervalSince1970: 0)), "1970-01-01")
    }

    /// 计数器:注入 defaults 累加;set-once 起点
    func testStatsCounters() {
        let suiteName = "wave5-stats-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stats = UsageStats(defaults: defaults)

        XCTAssertEqual(stats.copyCount, 0)
        XCTAssertEqual(stats.pasteCount, 0)
        for _ in 0..<7 { stats.noteCopy() }
        for _ in 0..<3 { stats.notePaste() }
        XCTAssertEqual(stats.copyCount, 7)
        XCTAssertEqual(stats.pasteCount, 3)
        stats.noteCopy()
        XCTAssertEqual(stats.copyCount, 8, "持续累加")

        // 起点 set-once:两次调用返回同一时间,第二次的 now 不覆盖
        let first = stats.since(now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(first.timeIntervalSince1970, 1_000)
        let second = stats.since(now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(second.timeIntervalSince1970, 1_000, "起点只记首次")

        // 异常负值安全回落 0
        defaults.set(-5, forKey: UsageStats.copyCountKey)
        XCTAssertEqual(stats.copyCount, 0)
    }

    // MARK: - 空闲门控(纯函数)

    func testPruneGate() {
        XCTAssertFalse(PruneGate.shouldPrune(idleSeconds: 0), "活跃中不放行")
        XCTAssertFalse(PruneGate.shouldPrune(idleSeconds: 299.9), "未到 300s 不放行")
        XCTAssertTrue(PruneGate.shouldPrune(idleSeconds: 300), "阈值边界放行(≥)")
        XCTAssertTrue(PruneGate.shouldPrune(idleSeconds: 3600))
        XCTAssertFalse(PruneGate.shouldPrune(idleSeconds: 9, threshold: 10), "自定义阈值")
        XCTAssertTrue(PruneGate.shouldPrune(idleSeconds: 10, threshold: 10))
    }

    // MARK: - 便携模式(上游 GetIsPortableDitto,Options.cpp:200-227/1957-1960)

    /// 纯解析:标记存在与否 → 基目录/子路径
    func testPortableResolverPure() {
        let bundleURL = URL(fileURLWithPath: "/Volumes/USB/DittoMac.app")
        XCTAssertNil(PortableMode.portableRoot(markerExists: false, bundleURL: bundleURL),
                     "无标记 → 非便携")
        let root = PortableMode.portableRoot(markerExists: true, bundleURL: bundleURL)
        XCTAssertEqual(root?.path, "/Volumes/USB", "便携根 = bundle 所在目录")

        let base = PortableMode.baseDirectory(portableRoot: root)
        XCTAssertEqual(base.path, "/Volumes/USB/DittoMac")
        XCTAssertEqual(PortableMode.databaseURL(base: base).path, "/Volumes/USB/DittoMac/ditto.sqlite")
        XCTAssertEqual(PortableMode.themesDirectory(base: base).path, "/Volumes/USB/DittoMac/Themes")
        XCTAssertEqual(PortableMode.logsDirectory(base: base).path, "/Volumes/USB/DittoMac/logs")
        XCTAssertEqual(PortableMode.settingsPlistURL(base: base).path, "/Volumes/USB/DittoMac/settings.plist")

        // 非便携:标准 Application Support 布局
        let normal = PortableMode.baseDirectory(portableRoot: nil)
        XCTAssertTrue(normal.path.hasSuffix("DittoMac"))
        XCTAssertTrue(normal.path.contains("Application Support"))
    }

    /// 持久化:设便携根后 ClipStore(path: nil) 落便携目录
    func testPortableClipStorePersistence() {
        let root = tmp.appendingPathComponent("portable-root", isDirectory: true)
        PortableMode.setResolvedRootForTesting(root)
        XCTAssertEqual(PortableMode.isPortable, true)

        let store = ClipStore(path: nil)   // nil = 走默认位置解析
        _ = store.insert(RawClip(text: "portable"), maxDataBytes: 1 << 20)
        XCTAssertTrue(store.count >= 1)
        let dbPath = root.appendingPathComponent("DittoMac/ditto.sqlite").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath),
                      "数据库应落在 <便携根>/DittoMac/ditto.sqlite")

        // 复位后回到标准位置(非便携)
        PortableMode.setResolvedRootForTesting(nil)
        XCTAssertFalse(PortableMode.isPortable)
    }

    /// bootstrap:标记文件检测 + 目录落地 + DittoSettings 切换到便携 suite
    func testPortableBootstrap() {
        let root = tmp.appendingPathComponent("boot-root", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let appDir = root.appendingPathComponent("App", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let bundleURL = appDir.appendingPathComponent("DittoMac.app")
        // 无标记:bootstrap 返回 false,不切设置
        let originalDefaults = DittoSettings.defaults
        XCTAssertFalse(PortableMode.bootstrap(bundleURL: bundleURL))
        XCTAssertEqual(DittoSettings.defaults, originalDefaults)

        // 有标记:进入便携,目录创建,suite 生效
        let marker = appDir.appendingPathComponent(PortableMode.markerFileName)
        FileManager.default.createFile(atPath: marker.path, contents: Data("p".utf8))
        XCTAssertTrue(PortableMode.bootstrap(bundleURL: bundleURL))
        XCTAssertEqual(PortableMode.resolvedRoot?.path, appDir.path)
        let base = root.appendingPathComponent("App/DittoMac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("logs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("Themes").path))
        // 便携 suite 可读写(写入后能读回;离开测试前清理)
        DittoSettings.defaults.set("portable-test", forKey: "wave5.portableProbe")
        XCTAssertEqual(DittoSettings.defaults.string(forKey: "wave5.portableProbe"), "portable-test")

        // 复位(resolvedRoot 是 private(set);测试钩子清态 + 还原默认后端)
        PortableMode.setResolvedRootForTesting(nil)
        DittoSettings.defaults = originalDefaults
    }

    // MARK: - 调试日志落盘(上游 "Write debug to file")

    func testFileLogWriteAndRotate() {
        let logDir = tmp.appendingPathComponent("logs", isDirectory: true)
        let box = DateBox(Date(timeIntervalSince1970: 1_700_000_000))   // 2023-11-14(UTC)
        let log = FileLog(directory: logDir, dateProvider: { box.date })
        log.append("EVENT_A detail")
        log.append("EVENT_B")

        // 期望文件名按本机时区计算(与 FileLog.fileFormatter 同规则)
        let nameFmt = DateFormatter()
        nameFmt.dateFormat = "yyyyMMdd"
        let fileName = "ditto-\(nameFmt.string(from: box.date)).log"
        let fileURL = logDir.appendingPathComponent(fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "按日期命名")
        let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(content.contains("EVENT_A detail"), "行内容写入")
        XCTAssertTrue(content.contains("EVENT_B"))
        // 行首 = "yyyy-MM-dd HH:mm:ss.SSS " 时间戳(正则近似:前 24 字符为时间戳+空格)
        let firstLine = content.split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertEqual(firstLine.dropFirst(24), "EVENT_A detail", "时间戳前缀恰好 24 字符")
        XCTAssertTrue(firstLine.prefix(10).contains("-"), "含日期分隔")
        XCTAssertEqual(content.split(separator: "\n").count, 2, "两行")

        // 轮转:追加一行超 1MB → 当前文件改名 .1,新文件重建
        let big = String(repeating: "x", count: FileLog.rotateThresholdBytes + 10)
        log.append(big)
        let rotated = logDir.appendingPathComponent(fileName + ".1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path), "超限轮转为 .1")
        // 当前文件重新存在且只含新行(轮转后重建)
        let currentContent = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(currentContent.contains("xxxx"), "轮转后新文件含最新行")

        // 再次超限:旧 .1 被替换(只保留一代),不产生 .2
        log.append(big)
        log.append(big)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logDir.appendingPathComponent(fileName + ".2").path))
        log.close()
    }

    /// DiagLog sink 联动:开启即汇聚,关闭即静默
    func testDiagLogSinkToggle() {
        let logDir = tmp.appendingPathComponent("diag", isDirectory: true)
        FileLog.setEnabled(true, directory: logDir)
        DiagLog.error("boom-树")
        FileLog.shared?.close()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: logDir.path)) ?? []
        XCTAssertTrue(files.contains { $0.hasPrefix("ditto-") && $0.hasSuffix(".log") },
                      "错误应落盘")
        let content = files.compactMap { try? String(contentsOf: logDir.appendingPathComponent($0), encoding: .utf8) }
                       .joined()
        XCTAssertTrue(content.contains("boom-树"))
        FileLog.setEnabled(false, directory: logDir)
        XCTAssertNil(DiagLog.sink, "关闭后 sink 卸载")
        XCTAssertNil(FileLog.shared)
    }

    // MARK: - L10n 新词(Wave5)

    func testWave5Tokens() {
        L10n.lang = .zh
        XCTAssertEqual(L10n.menuViewAsQRCode, "查看二维码")
        XCTAssertEqual(L10n.menuExportToTranslate, "导出到 Google 翻译")
        XCTAssertEqual(L10n.menuExportClipPackage, "导出条目包…")
        XCTAssertEqual(L10n.menuImportClipPackage, "导入条目包…")
        XCTAssertEqual(L10n.setWriteDebugLog, "写调试日志到文件")
        XCTAssertEqual(L10n.statsTotalCopies, "累计复制:")
        L10n.lang = .en
        XCTAssertEqual(L10n.menuViewAsQRCode, "View as QRCode")
        XCTAssertEqual(L10n.menuExportToTranslate, "Export to Google Translate")
        XCTAssertEqual(L10n.setSectionAdvanced, "Advanced")
        XCTAssertEqual(L10n.menuStats, "Statistics…")
        L10n.lang = .system
    }

    static var registrations: [(String, (Wave5FeatureTests) -> Void)] {
        [
            ("qrGeneratorImageAndScaling", { $0.testQRGeneratorImageAndScaling() }),
            ("qrDisplayTruncation", { $0.testQRDisplayTruncation() }),
            ("translateURLBuilding", { $0.testTranslateURLBuilding() }),
            ("translateTruncation", { $0.testTranslateTruncation() }),
            ("zlibRoundtrip", { $0.testZlibRoundtrip() }),
            ("zlibStandardFixturesAndIntegrity", { $0.testZlibStandardFixturesAndIntegrity() }),
            ("packageWindowsUnicodeFixtureAndSchema", { $0.testPackageWindowsUnicodeFixtureAndSchema() }),
            ("packageLegacyMacCompatibilityIsScoped", { $0.testPackageLegacyMacCompatibilityIsScoped() }),
            ("packageUnicodeBoundaries", { $0.testPackageUnicodeBoundaries() }),
            ("dibSmallAndIndexedFixtures", { $0.testDIBSmallAndIndexedFixtures() }),
            ("dibRejectsMalformedBounds", { $0.testDIBRejectsMalformedBounds() }),
            ("dropFilesRoundtrip", { $0.testDropFilesRoundtrip() }),
            ("formatNameMappingTable", { $0.testFormatNameMappingTable() }),
            ("packageExportImportRoundtrip", { $0.testPackageExportImportRoundtrip() }),
            ("packageFileClipRoundtrip", { $0.testPackageFileClipRoundtrip() }),
            ("packageImageRoundtrip", { $0.testPackageImageRoundtrip() }),
            ("packageEdgeCases", { $0.testPackageEdgeCases() }),
            ("statsSpanFormatting", { $0.testStatsSpanFormatting() }),
            ("statsCounters", { $0.testStatsCounters() }),
            ("pruneGate", { $0.testPruneGate() }),
            ("portableResolverPure", { $0.testPortableResolverPure() }),
            ("portableClipStorePersistence", { $0.testPortableClipStorePersistence() }),
            ("portableBootstrap", { $0.testPortableBootstrap() }),
            ("fileLogWriteAndRotate", { $0.testFileLogWriteAndRotate() }),
            ("diagLogSinkToggle", { $0.testDiagLogSinkToggle() }),
            ("wave5Tokens", { $0.testWave5Tokens() }),
        ]
    }
}

/// 可变时钟盒(FileLog 按天分文件/轮转测试用)
private final class DateBox {
    var date: Date
    init(_ date: Date) { self.date = date }
}
