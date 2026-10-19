import Foundation
import AppKit

// MARK: - SpecialPaste 变换回归(每个变换 ≥2 例,含中文/空串/多行)

final class SpecialPasteTests: XCTestCase {

    // MARK: 工具

    private func apply(_ t: SpecialPaste.Transform, _ text: String?) -> RawClip {
        SpecialPaste.apply(t, to: RawClip(text: text))
    }

    // MARK: 大小写系列

    func testUpperCase() {
        XCTAssertEqual(apply(.upperCase, "hello World").text, "HELLO WORLD")
        XCTAssertEqual(apply(.upperCase, "中文 abc").text, "中文 ABC")
    }

    func testLowerCase() {
        XCTAssertEqual(apply(.lowerCase, "Hello WORLD").text, "hello world")
        XCTAssertEqual(apply(.lowerCase, "").text, "")
    }

    func testCapitalizeCase() {
        XCTAssertEqual(apply(.capitalizeCase, "hello world").text, "Hello World")
        XCTAssertEqual(apply(.capitalizeCase, "HELLO").text, "Hello")
    }

    func testSentenceCase() {
        XCTAssertEqual(apply(.sentenceCase, "hello. world again! ok").text, "Hello. World again! Ok")
        XCTAssertEqual(apply(.sentenceCase, "中文 doesn't CHANGE").text, "中文 Doesn't change")
    }

    func testInvertCase() {
        XCTAssertEqual(apply(.invertCase, "Hello World").text, "hELLO wORLD")
        XCTAssertEqual(apply(.invertCase, "中文AbC123").text, "中文aBc123")
    }

    // MARK: 空白与换行

    func testTrimWhitespace() {
        XCTAssertEqual(apply(.trimWhitespace, "  x y \n").text, "x y")
        XCTAssertEqual(apply(.trimWhitespace, "   ").text, "")
    }

    func testRemoveLineFeeds() {
        // CRLF 是单个字素簇,必须整体移除
        XCTAssertEqual(apply(.removeLineFeeds, "a\r\nb\nc").text, "abc")
        XCTAssertEqual(apply(.removeLineFeeds, "中文\n行").text, "中文行")
    }

    func testAppendLineFeeds() {
        XCTAssertEqual(apply(.appendOneLineFeed, "x").text, "x\n")
        XCTAssertEqual(apply(.appendTwoLineFeeds, "x").text, "x\n\n")
        XCTAssertEqual(apply(.appendOneLineFeed, "").text, "")
    }

    func testAppendCurrentTime() {
        let out = apply(.appendCurrentTime, "事件")
        XCTAssertTrue(out.text?.hasPrefix("事件 ") == true, "应为 '前缀 + 空格 + 时间'")
        let time = String(out.text!.dropFirst(3))
        XCTAssertNotNil(DateFormatter.yyyyMMddHHmm.date(from: time), "时间格式应为 yyyy-MM-dd HH:mm")
    }

    // MARK: 路径与编码

    func testPosixify() {
        XCTAssertEqual(apply(.posixifyPaths, "C:\\a b\\c").text, "/c/a\\ b/c")
        XCTAssertEqual(apply(.posixifyPaths, "a\\b c").text, "a/b\\ c")
    }

    func testCamelCase() {
        XCTAssertEqual(apply(.camelCase, "hello world-foo_bar").text, "helloWorldFooBar")
        XCTAssertEqual(apply(.camelCase, "  x  y ").text, "xY")
    }

    func testAsciiTextOnly() {
        XCTAssertEqual(apply(.asciiTextOnly, "abc 中文 café ✅").text, "abc  caf ")
        XCTAssertEqual(apply(.asciiTextOnly, "").text, "")
    }

    // MARK: 文字游戏类

    func testTypoglycemia() {
        // 首尾字母保留、长度不变、中间乱序(多跑几次避免巧合)
        var scrambled = false
        for _ in 0..<20 {
            let out = apply(.typoglycemia, "keyboard").text!
            if out != "keyboard" { scrambled = true }
            XCTAssertEqual(out.count, 8)
            XCTAssertEqual(out.first, "k")
            XCTAssertEqual(out.last, "d")
            XCTAssertEqual(Set(out).sorted(), Set("keyboard").sorted())
        }
        XCTAssertTrue(scrambled)
        XCTAssertEqual(apply(.typoglycemia, "ab cd").text, "ab cd", "短词原样")
        XCTAssertEqual(apply(.typoglycemia, "").text, "")
    }

    func testSlugify() {
        XCTAssertEqual(apply(.slugify, "Hello World  Foo").text, "hello-world-foo")
        XCTAssertEqual(apply(.slugify, "  你好 World_café! ").text, "你好-world-café")
        XCTAssertEqual(apply(.slugify, "---").text, "")
        XCTAssertEqual(apply(.slugify, "A_B").text, "a-b")
    }

    func testNewGuid() {
        let out = apply(.newGuid, "任意源文本")
        let a = UUID(uuidString: out.text ?? "")
        let b = UUID(uuidString: apply(.newGuid, "x").text ?? "")
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertNotEqual(a, b, "每次生成新 GUID")
    }

    // MARK: 图片与纯文本

    func testPlainTextOnlyStripsRichRepresentations() {
        let payload = RawClip(text: "t", rtfData: Data([1]), htmlData: Data([2]), imageData: Data([3]))
        let out = SpecialPaste.apply(.plainTextOnly, to: payload)
        XCTAssertEqual(out.text, "t")
        XCTAssertNil(out.rtfData)
        XCTAssertNil(out.htmlData)
        XCTAssertNil(out.imageData)
    }

    func testPasteAsImageKeepsImageOnly() {
        let payload = RawClip(text: "t", imageData: Data([1, 2, 3]))
        let out = SpecialPaste.apply(.pasteAsImage, to: payload)
        XCTAssertNil(out.text)
        XCTAssertEqual(out.imageData, Data([1, 2, 3]))
        // 无图片:原样返回
        let textOnly = SpecialPaste.apply(.pasteAsImage, to: RawClip(text: "t"))
        XCTAssertEqual(textOnly.text, "t")
    }

    func testComposeImagesMergesMultiple() {
        func png(_ w: Int, _ h: Int, red: UInt8) -> Data {
            let img = NSImage(size: NSSize(width: w, height: h))
            img.lockFocus()
            NSColor(red: CGFloat(red) / 255, green: 0, blue: 0, alpha: 1).setFill()
            NSRect(origin: .zero, size: img.size).fill()
            img.unlockFocus()
            let tiff = img.tiffRepresentation!
            return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
        }
        let payloads = [RawClip(imageData: png(10, 20, red: 255)),
                        RawClip(imageData: png(10, 20, red: 100))]
        guard let out = SpecialPaste.composeImages(payloads, horizontal: true) else {
            XCTFail("合成失败"); return
        }
        // 用点尺寸断言(位图像素数随屏幕倍率变化)
        let composed = NSImage(data: out.imageData!)!
        XCTAssertEqual(composed.size.width, 24, "宽 = 10+10+间隙4")
        XCTAssertEqual(composed.size.height, 20)
        XCTAssertNil(SpecialPaste.composeImages([payloads[0]], horizontal: true), "单图不合成")
        let mixed = [payloads[0], RawClip(text: "x")]
        XCTAssertNil(SpecialPaste.composeImages(mixed, horizontal: true), "非全图片不合成")
    }

    static var registrations: [(String, (SpecialPasteTests) -> Void)] {
        [
            ("testUpperCase", { $0.testUpperCase() }),
            ("testLowerCase", { $0.testLowerCase() }),
            ("testCapitalizeCase", { $0.testCapitalizeCase() }),
            ("testSentenceCase", { $0.testSentenceCase() }),
            ("testInvertCase", { $0.testInvertCase() }),
            ("testTrimWhitespace", { $0.testTrimWhitespace() }),
            ("testRemoveLineFeeds", { $0.testRemoveLineFeeds() }),
            ("testAppendLineFeeds", { $0.testAppendLineFeeds() }),
            ("testAppendCurrentTime", { $0.testAppendCurrentTime() }),
            ("testPosixify", { $0.testPosixify() }),
            ("testCamelCase", { $0.testCamelCase() }),
            ("testAsciiTextOnly", { $0.testAsciiTextOnly() }),
            ("testTypoglycemia", { $0.testTypoglycemia() }),
            ("testSlugify", { $0.testSlugify() }),
            ("testNewGuid", { $0.testNewGuid() }),
            ("testPlainTextOnlyStripsRichRepresentations", { $0.testPlainTextOnlyStripsRichRepresentations() }),
            ("testPasteAsImageKeepsImageOnly", { $0.testPasteAsImageKeepsImageOnly() }),
            ("testComposeImagesMergesMultiple", { $0.testComposeImagesMergesMultiple() }),
        ]
    }
}

// MARK: - ClipDescription 回归(描述规则/色值/高亮/元数据行)

final class ClipDescriptionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        L10n.lang = .zh   // 文案断言固定中文
    }

    override func tearDown() {
        L10n.lang = .system
        super.tearDown()
    }

    private func item(text: String?) -> ClipItem {
        ClipItem(id: 1, kind: .text, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                 text: text, pinned: false, byteSize: 1, appName: "Test", contentHash: "h")
    }

    func testBuildFirstLineAndIndent() {
        XCTAssertEqual(ClipDescription.build(text: "第一行\n第二行"), "第一行")
        XCTAssertEqual(ClipDescription.build(text: "    缩进内容"), "» 缩进内容")
        XCTAssertEqual(ClipDescription.build(text: "\tx"), "  x")
    }

    func testBuildTruncatesAt500() {
        let long = String(repeating: "a", count: 600)
        let out = ClipDescription.build(text: long)
        XCTAssertEqual(out.count, 501)
        XCTAssertTrue(out.hasSuffix("…"))
    }

    func testColorHexDetection() {
        XCTAssertNotNil(ClipDescription.colorValue(in: "#FF0000"))
        XCTAssertNotNil(ClipDescription.colorValue(in: "#f00"))
        XCTAssertNil(ClipDescription.colorValue(in: "#GGGGGG"))
    }

    func testColorNamedDetection() {
        XCTAssertNotNil(ClipDescription.colorValue(in: "红色"))
        XCTAssertNotNil(ClipDescription.colorValue(in: "RED"))
        XCTAssertNil(ClipDescription.colorValue(in: "不存在的颜色名"))
    }

    func testHighlightMultiWordAndCaseInsensitive() {
        let attributed = NSMutableAttributedString(string: "Hello World hello")
        ClipDescription.highlight(attributed, matchesOf: "hello world", color: .systemRed)
        var redRanges = 0
        attributed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attributed.length)) { v, _, _ in
            if let color = v as? NSColor, color == .systemRed { redRanges += 1 }
        }
        XCTAssertEqual(redRanges, 3, "hello×2 + world×1(不区分大小写)")
    }

    func testHighlightEmptyQueryNoop() {
        let attributed = NSMutableAttributedString(string: "abc")
        ClipDescription.highlight(attributed, matchesOf: "", color: .systemRed)
        XCTAssertNil(attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil))
    }

    func testMetaLineSegments() {
        let line = ClipDescription.metaLine(item: item(text: "x"))
        XCTAssertTrue(line.contains("添加: "))
        XCTAssertTrue(line.contains("从未粘贴"))
    }

    static var registrations: [(String, (ClipDescriptionTests) -> Void)] {
        [
            ("testBuildFirstLineAndIndent", { $0.testBuildFirstLineAndIndent() }),
            ("testBuildTruncatesAt500", { $0.testBuildTruncatesAt500() }),
            ("testColorHexDetection", { $0.testColorHexDetection() }),
            ("testColorNamedDetection", { $0.testColorNamedDetection() }),
            ("testHighlightMultiWordAndCaseInsensitive", { $0.testHighlightMultiWordAndCaseInsensitive() }),
            ("testHighlightEmptyQueryNoop", { $0.testHighlightEmptyQueryNoop() }),
            ("testMetaLineSegments", { $0.testMetaLineSegments() }),
        ]
    }
}

extension DateFormatter {
    static let yyyyMMddHHmm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}


// MARK: - i18n 回归(语言切换/关键文案/时间格式)

final class L10nTests: XCTestCase {

    override func tearDown() {
        L10n.lang = .system
        super.tearDown()
    }

    func testLanguageSwitchChangesText() {
        L10n.lang = .zh
        XCTAssertTrue(L10n.isChinese)
        XCTAssertEqual(L10n.menuExit, "退出")
        XCTAssertEqual(L10n.emptyList, "没有匹配的条目")
        XCTAssertEqual(L10n.kindText, "纯文本")

        L10n.lang = .en
        XCTAssertFalse(L10n.isChinese)
        XCTAssertEqual(L10n.menuExit, "Exit")
        XCTAssertEqual(L10n.emptyList, "No matching clips")
        XCTAssertEqual(L10n.kindText, "Text")
    }

    func testRelativeTimeTokens() {
        // Fmt.relativeTime 逐字使用这些 L10n 词条;此处验证词条本身的中英文形态
        L10n.lang = .zh
        XCTAssertEqual(L10n.timeJustNow, "刚刚")
        XCTAssertEqual(L10n.timeMinutesAgo(2), "2 分钟前")
        L10n.lang = .en
        XCTAssertEqual(L10n.timeJustNow, "Just now")
        XCTAssertEqual(L10n.timeMinutesAgo(2), "2m ago")
        XCTAssertEqual(L10n.timeHoursAgo(3), "3h ago")
        XCTAssertEqual(L10n.timeYesterday, "Yesterday")
    }

    func testMetaLineLocalized() {
        let item = ClipItem(id: 1, kind: .text, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                            text: "x", pinned: true, byteSize: 1, appName: nil, contentHash: "h")
        L10n.lang = .zh
        XCTAssertTrue(ClipDescription.metaLine(item: item).contains("置顶"))
        L10n.lang = .en
        let en = ClipDescription.metaLine(item: item)
        XCTAssertTrue(en.contains("Sticky"))
        XCTAssertTrue(en.contains("Added: "))
        XCTAssertTrue(en.contains("Never pasted"))
    }

    func testPersistenceAcrossRead() {
        L10n.lang = .en
        XCTAssertEqual(UserDefaults.standard.string(forKey: L10n.languageKey), "en")
        L10n.lang = .zh
        XCTAssertEqual(UserDefaults.standard.string(forKey: L10n.languageKey), "zh")
    }

    func testCaptureSettingsTokens() {
        // 设置新增两节(捕获格式 / 排除规则)与属性窗口格式块的关键词条
        L10n.lang = .zh
        XCTAssertEqual(L10n.setSectionTypes, "捕获格式")
        XCTAssertEqual(L10n.setSectionExclude, "排除规则")
        XCTAssertEqual(L10n.setExcludeRegexCol, "正则")
        XCTAssertEqual(L10n.setExcludeProcessCol, "进程名")
        XCTAssertTrue(L10n.setTypesEmptyWarning.contains("不记录"))
        XCTAssertTrue(L10n.setExcludeRuleHint.contains(".*"))
        XCTAssertEqual(L10n.propsFormatsHeader, "格式")
        XCTAssertEqual(L10n.propsKeepOneFormat, "至少保留一种格式")

        L10n.lang = .en
        XCTAssertEqual(L10n.setSectionTypes, "Supported Types")
        XCTAssertEqual(L10n.setSectionExclude, "Exclude")
        XCTAssertEqual(L10n.setExcludeRegexCol, "Regex")
        XCTAssertEqual(L10n.setExcludeProcessCol, "Process")
        XCTAssertTrue(L10n.setTypesEmptyWarning.contains("nothing"))
        XCTAssertTrue(L10n.setExcludeRuleHint.contains(".*"))
        XCTAssertEqual(L10n.propsFormatsHeader, "Formats")
        XCTAssertEqual(L10n.propsKeepOneFormat, "At least one format must remain")
    }

    static var registrations: [(String, (L10nTests) -> Void)] {
        [
            ("testLanguageSwitchChangesText", { $0.testLanguageSwitchChangesText() }),
            ("testRelativeTimeTokens", { $0.testRelativeTimeTokens() }),
            ("testMetaLineLocalized", { $0.testMetaLineLocalized() }),
            ("testPersistenceAcrossRead", { $0.testPersistenceAcrossRead() }),
            ("testCaptureSettingsTokens", { $0.testCaptureSettingsTokens() }),
        ]
    }
}
