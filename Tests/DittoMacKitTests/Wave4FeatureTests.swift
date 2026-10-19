import AppKit
import Foundation

/// Wave4 快速选项特性:主题解析 / 透明度 / 字体行高 / 插入符坐标 / 失焦策略 / 搜索选项
final class Wave4FeatureTests: XCTestCase {
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
        let d = UserDefaults.standard
        d.removeObject(forKey: DittoSettings.fontNameKey)
        d.removeObject(forKey: DittoSettings.fontSizeKey)
        super.tearDown()
    }

    // MARK: - 主题解析(上游 Theme.cpp:136-203 的 <Ditto_Theme_File> 格式)

    /// 全字段解析(含 RGB 内空格、整数、根属性)
    func testThemeParseFullFields() {
        let xml = #"""
        <Ditto_Theme_File Version = "3" Author = "tester" Notes = "note here">
          <CaptionLeft>RGB( 10 , 20 , 30 )</CaptionLeft>
          <CaptionRight>RGB(40,50,60)</CaptionRight>
          <CaptionTextColor>RGB(1,2,3)</CaptionTextColor>
          <ListBoxOddRowsBG>RGB(5,6,7)</ListBoxOddRowsBG>
          <ListBoxEvenRowsBG>RGB(8,9,10)</ListBoxEvenRowsBG>
          <ListBoxSelectedBG>RGB(11,12,13)</ListBoxSelectedBG>
          <ListBoxSelectedText>RGB(14,15,16)</ListBoxSelectedText>
          <Border>RGB(17,18,19)</Border>
          <GroupTreeBG>RGB(20,21,22)</GroupTreeBG>
          <DescriptionWindowBG>RGB(23,24,25)</DescriptionWindowBG>
          <MainWindowBG>rgb(26, 27, 28)</MainWindowBG>
          <CaptionSize>18</CaptionSize>
          <CaptionFontSize>15</CaptionFontSize>
        </Ditto_Theme_File>
        """#
        let theme = DittoThemeFile.parse(xml)
        XCTAssertEqual(theme.captionLeft, ThemeRGB(red: 10, green: 20, blue: 30), "RGB 允许可选空格")
        XCTAssertEqual(theme.captionRight, ThemeRGB(red: 40, green: 50, blue: 60))
        XCTAssertEqual(theme.captionTextColor, ThemeRGB(red: 1, green: 2, blue: 3))
        XCTAssertEqual(theme.mainWindowBG, ThemeRGB(red: 26, green: 27, blue: 28), "rgb 前缀大小写不敏感")
        XCTAssertEqual(theme.captionSize, 18)
        XCTAssertEqual(theme.captionFontSize, 15)
        XCTAssertEqual(theme.author, "tester")
        XCTAssertEqual(theme.version, 3)
    }

    /// 坏值跳过 / 未知标签忽略 / 越界 RGB 拒绝
    func testThemeParseMalformedSkips() {
        let xml = #"""
        <Ditto_Theme_File Version = "3">
          <CaptionLeft>RGB(300, 20, 30)</CaptionLeft>
          <CaptionRight>not a color</CaptionRight>
          <CaptionTextColor>RGB(1,2)</CaptionTextColor>
          <Border>RGB(1,2,3)</Border>
          <CaptionSize>abc</CaptionSize>
          <CaptionFontSize>20</CaptionFontSize>
          <UnknownTag>whatever</UnknownTag>
          <SearchTextBoxFocusBG>RGB(9,9,9)</SearchTextBoxFocusBG>
        </Ditto_Theme_File>
        """#
        let theme = DittoThemeFile.parse(xml)
        XCTAssertNil(theme.captionLeft, "RGB 分量越界(>255)应跳过")
        XCTAssertNil(theme.captionRight, "非 RGB() 形式应跳过")
        XCTAssertNil(theme.captionTextColor, "RGB 分量不足应跳过")
        XCTAssertEqual(theme.border, ThemeRGB(red: 1, green: 2, blue: 3), "好值不受坏值影响")
        XCTAssertNil(theme.captionSize, "非整数应跳过")
        XCTAssertEqual(theme.captionFontSize, 20)
        // 未知/未支持标签被忽略(不崩溃、不误配)
        XCTAssertNil(theme.listBoxEvenRowsBG)
    }

    /// 上游 Nord.xml 全文夹具(逐字段校验关键项)
    func testThemeParseNordFixture() {
        let nord = #"""
        <Ditto_Theme_File Version = "3" Author = "Yaroslav Kargin" Notes = "www.nordtheme.com">

        	<CaptionLeft>RGB(46, 52, 64)</CaptionLeft>
        	<CaptionRight>RGB(46, 52, 64)</CaptionRight>

        	<CaptionLeftTopMost>RGB(46, 52, 64)</CaptionLeftTopMost>
        	<CaptionRightTopMost>RGB(46, 52, 64)</CaptionRightTopMost>

        	<CaptionLeftNotConnected>RGB(49, 55, 66)</CaptionLeftNotConnected>
        	<CaptionRightNotConnected>RGB(49, 55, 66)</CaptionRightNotConnected>

        	<CaptionTextColor>RGB(160, 197, 146)</CaptionTextColor>

        	<ListBoxOddRowsBG>RGB(49, 55, 66)</ListBoxOddRowsBG>
        	<ListBoxEvenRowsBG>RGB(49, 55, 66)</ListBoxEvenRowsBG>

        	<ListBoxOddRowsText>RGB(124, 167, 170)</ListBoxOddRowsText>
        	<ListBoxEvenRowsText>RGB(124, 167, 170)</ListBoxEvenRowsText>

        	<ListBoxSelectedBG>RGB(59, 66, 81)</ListBoxSelectedBG>
        	<ListBoxSelectedNoFocusBG>RGB(61, 71, 89)</ListBoxSelectedNoFocusBG>

        	<ListBoxSelectedText>RGB(214, 221, 232)</ListBoxSelectedText>
        	<ListBoxSelectedNoFocusText>RGB(214, 220, 231)</ListBoxSelectedNoFocusText>

        	<Border>RGB(49, 55, 66)</Border>
        	<BorderTopMost>RGB(49, 55, 66)</BorderTopMost>
        	<BorderNotConnected>RGB(49, 55, 66)</BorderNotConnected>

        	<GroupTreeBG>RGB(49, 55, 66)</GroupTreeBG>
        	<GroupTreeText>RGB(214, 221, 232)</GroupTreeText>

        	<CaptionSize>18</CaptionSize>
        	<CaptionFontSize>15</CaptionFontSize>

        	<DescriptionWindowBG>RGB(46, 52, 64)</DescriptionWindowBG>
        	<DescriptionWindowText>RGB(214, 221, 232)</DescriptionWindowText>

        	<MainWindowBG>RGB(49, 55, 66)</MainWindowBG>

        	<SearchTextBoxFocusBG>RGB(46, 52, 64)</SearchTextBoxFocusBG>
        	<SearchTextBoxFocusText>RGB(214, 221, 232)</SearchTextBoxFocusText>

        </Ditto_Theme_File>
        """#
        let theme = DittoThemeFile.parse(nord)
        XCTAssertEqual(theme.captionLeft, ThemeRGB(red: 46, green: 52, blue: 64))
        XCTAssertEqual(theme.captionLeftTopMost, ThemeRGB(red: 46, green: 52, blue: 64))
        XCTAssertEqual(theme.captionLeftNotConnected, ThemeRGB(red: 49, green: 55, blue: 66))
        XCTAssertEqual(theme.captionTextColor, ThemeRGB(red: 160, green: 197, blue: 146))
        XCTAssertEqual(theme.listBoxOddRowsText, ThemeRGB(red: 124, green: 167, blue: 170))
        XCTAssertEqual(theme.listBoxSelectedBG, ThemeRGB(red: 59, green: 66, blue: 81))
        XCTAssertEqual(theme.listBoxSelectedNoFocusText, ThemeRGB(red: 214, green: 220, blue: 231))
        XCTAssertEqual(theme.border, ThemeRGB(red: 49, green: 55, blue: 66))
        XCTAssertEqual(theme.borderTopMost, ThemeRGB(red: 49, green: 55, blue: 66))
        XCTAssertEqual(theme.groupTreeText, ThemeRGB(red: 214, green: 221, blue: 232))
        XCTAssertEqual(theme.captionSize, 18)
        XCTAssertEqual(theme.captionFontSize, 15)
        XCTAssertEqual(theme.descriptionWindowBG, ThemeRGB(red: 46, green: 52, blue: 64))
        XCTAssertEqual(theme.mainWindowBG, ThemeRGB(red: 49, green: 55, blue: 66))
        XCTAssertEqual(theme.author, "Yaroslav Kargin")
    }

    /// 内置主题目录:12 个上游 XML 可枚举且可加载(直连编译走 #filePath 回退)
    func testBundledThemesAvailable() {
        let names = ThemeRegistry.bundledThemeNames()
        XCTAssertEqual(names.count, 12, "上游 Debug/Themes 全部 12 个主题")
        XCTAssertTrue(names.contains("Nord"))
        XCTAssertTrue(names.contains("Classic"))
        let nord = ThemeRegistry.load(storedValue: ThemeRegistry.builtinPrefix + "Nord")
        XCTAssertNotNil(nord)
        XCTAssertEqual(nord?.captionSize, 18)
        // 路径穿越名拒绝;空值 = 跟随系统(nil)
        XCTAssertNil(ThemeRegistry.load(storedValue: ""))
        XCTAssertNil(ThemeRegistry.bundledThemeURL(name: "../Package"))
        // 不存在的主题 → nil(面板回落跟随系统)
        XCTAssertNil(ThemeRegistry.load(storedValue: ThemeRegistry.builtinPrefix + "不存在"))
    }

    /// 导入:拷贝到用户目录(重名加序号),存储值(绝对路径)可加载
    func testThemeImportRoundTrip() {
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("wave4-theme-\(UUID().uuidString).xml")
        try? #"<Ditto_Theme_File><Border>RGB(1,2,3)</Border></Ditto_Theme_File>"#
            .write(to: src, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: src) }
        guard let dest = ThemeRegistry.importTheme(from: src) else {
            XCTFail("导入应成功"); return
        }
        defer { try? FileManager.default.removeItem(at: dest) }
        XCTAssertTrue(dest.path.contains("DittoMac/Themes"))
        // 二次导入重名 → 加序号新文件
        guard let dest2 = ThemeRegistry.importTheme(from: src) else {
            XCTFail("重名导入应成功"); return
        }
        defer { try? FileManager.default.removeItem(at: dest2) }
        XCTAssertNotEqual(dest.path, dest2.path)
        let loaded = ThemeRegistry.load(storedValue: dest.path)
        XCTAssertEqual(loaded?.border, ThemeRGB(red: 1, green: 2, blue: 3))
    }

    // MARK: - 透明度(上游 Options.cpp:867-873 夹取;alpha = 1 - pct/100)

    func testTransparencyClampAndAlpha() {
        XCTAssertEqual(DittoSettings.clampedTransparencyPercent(-5), 0)
        XCTAssertEqual(DittoSettings.clampedTransparencyPercent(0), 0)
        XCTAssertEqual(DittoSettings.clampedTransparencyPercent(40), 40)
        XCTAssertEqual(DittoSettings.clampedTransparencyPercent(120), 90, "上限 90,保 alpha>0")
        XCTAssertEqual(DittoSettings.transparencyAlpha(percent: 0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(DittoSettings.transparencyAlpha(percent: 25), 0.75, accuracy: 1e-9)
        XCTAssertEqual(DittoSettings.transparencyAlpha(percent: 40), 0.6, accuracy: 1e-9)
        XCTAssertEqual(DittoSettings.transparencyAlpha(percent: 150), 0.1, accuracy: 1e-9, "越界经夹取")
    }

    // MARK: - 字体持久化 + 行高(原版行高 = 行数 × 字体行高 + 4)

    func testFontPersistenceKeys() {
        UserDefaults.standard.set("Courier", forKey: DittoSettings.fontNameKey)
        UserDefaults.standard.set(15.0, forKey: DittoSettings.fontSizeKey)
        XCTAssertEqual(UserDefaults.standard.string(forKey: DittoSettings.fontNameKey), "Courier")
        XCTAssertEqual(UserDefaults.standard.double(forKey: DittoSettings.fontSizeKey), 15.0, accuracy: 1e-9)
        // 默认字号常量(重置字体 = 回系统 13pt)
        XCTAssertEqual(DittoSettings.defaultFontSize, 13)
    }

    func testRowHeightMath() {
        // 2 行 × 16 + 4 = 36
        XCTAssertEqual(DittoSettings.rowHeight(lineHeight: 16, linesPerRow: 2, alwaysShowDescription: false), 36,
                       accuracy: 0.001)
        // 始终显示描述:+1 行 → 52
        XCTAssertEqual(DittoSettings.rowHeight(lineHeight: 16, linesPerRow: 2, alwaysShowDescription: true), 52,
                       accuracy: 0.001)
        // 行数至少 1
        XCTAssertEqual(DittoSettings.rowHeight(lineHeight: 20, linesPerRow: 0, alwaysShowDescription: false), 24,
                       accuracy: 0.001)
        // 小数行高(自定义字体)不受取整影响
        XCTAssertEqual(DittoSettings.rowHeight(lineHeight: 18.4, linesPerRow: 3, alwaysShowDescription: true),
                       18.4 * 4 + 4, accuracy: 0.001)
    }

    // MARK: - 插入符坐标(AX 左上原点 → AppKit 左下原点;回落与屏幕命中)

    func testCaretCoordinateFlip() {
        // 主屏高 900:AX y=20(自顶向下)→ AppKit y=880(自底向上)
        let flipped = CaretLocator.flipToAppKit(NSPoint(x: 100, y: 20), primaryHeight: 900)
        XCTAssertEqual(flipped.x, 100, accuracy: 1e-9)
        XCTAssertEqual(flipped.y, 880, accuracy: 1e-9)
        // 边界:y=0(主屏顶)→ 900;y=900(主屏底)→ 0
        XCTAssertEqual(CaretLocator.flipToAppKit(NSPoint(x: 0, y: 0), primaryHeight: 900).y, 900, accuracy: 1e-9)
        XCTAssertEqual(CaretLocator.flipToAppKit(NSPoint(x: 0, y: 900), primaryHeight: 900).y, 0, accuracy: 1e-9)
    }

    func testCaretFallbackToMouse() {
        XCTAssertEqual(CaretLocator.referencePoint(caret: nil, mouse: NSPoint(x: 10, y: 20)),
                       NSPoint(x: 10, y: 20), "取不到插入符 → 鼠标位置")
        XCTAssertEqual(CaretLocator.referencePoint(caret: NSPoint(x: 5, y: 6), mouse: NSPoint(x: 10, y: 20)),
                       NSPoint(x: 5, y: 6), "插入符优先")
    }

    func testScreenContainingPoint() {
        let frames = [NSRect(x: 0, y: 0, width: 1440, height: 900),
                      NSRect(x: 1440, y: 0, width: 1000, height: 900)]
        XCTAssertEqual(CaretLocator.screenFrame(containing: NSPoint(x: 100, y: 450), frames: frames),
                       frames[0])
        XCTAssertEqual(CaretLocator.screenFrame(containing: NSPoint(x: 1500, y: 400), frames: frames),
                       frames[1], "副屏上的点命中副屏")
        XCTAssertEqual(CaretLocator.screenFrame(containing: NSPoint(x: 1440, y: 0), frames: frames),
                       frames[1], "主屏 maxX 边界点按半开区间属副屏(CGRect 含 minX 不含 maxX)")
        XCTAssertNil(CaretLocator.screenFrame(containing: NSPoint(x: -50, y: 450), frames: frames),
                     "屏外点 → nil(调用方回落主屏)")
        XCTAssertNil(CaretLocator.screenFrame(containing: NSPoint(x: 10, y: 10), frames: []))
    }

    // MARK: - 失焦行为(原版 Auto Roll-up;常驻/已折叠豁免)

    func testFocusLossBehavior() {
        XCTAssertEqual(DittoSettings.focusLossBehavior(autoRollUp: false, persistent: false, rolled: false), .hide)
        XCTAssertEqual(DittoSettings.focusLossBehavior(autoRollUp: false, persistent: false, rolled: true), .hide)
        XCTAssertEqual(DittoSettings.focusLossBehavior(autoRollUp: true, persistent: false, rolled: false), .rollUp,
                       "开启自动折叠:失焦 → 折叠")
        XCTAssertEqual(DittoSettings.focusLossBehavior(autoRollUp: true, persistent: false, rolled: true),
                       FocusLossBehavior.none, "已折叠:保持")
        XCTAssertEqual(DittoSettings.focusLossBehavior(autoRollUp: true, persistent: true, rolled: false),
                       FocusLossBehavior.none, "常驻置顶豁免")
        XCTAssertEqual(DittoSettings.focusLossBehavior(autoRollUp: false, persistent: true, rolled: false),
                       FocusLossBehavior.none)
    }

    // MARK: - 搜索范围 × 方式(原版 Search Options;组合全覆盖)

    private func seedSearchItems() {
        _ = store.insert(RawClip(text: "alpha first line\nbeta second line"), maxDataBytes: 20 << 20)
        _ = store.insert(RawClip(text: "gamma content"), maxDataBytes: 20 << 20)
        if let c = store.insert(RawClip(text: "delta text"), maxDataBytes: 20 << 20) {
            store.setTitle(c.id, "特殊标题")
        }
    }

    func testSearchCombosFullText() {
        seedSearchItems()
        // contains 全文 = 既有行为(text+title 任一列)
        XCTAssertEqual(store.search("second line", limit: 10, scope: .fullText, method: .contains).count, 1)
        XCTAssertEqual(store.search("delta", limit: 10, scope: .fullText, method: .contains).count, 1)
        XCTAssertEqual(store.search("特殊", limit: 10, scope: .fullText, method: .contains).count, 1, "全文命中标题")
        // wildcard 全文(既有 LIKE 路径,* 通配)
        XCTAssertEqual(store.search("g*a", limit: 10, scope: .fullText, method: .wildcard).count, 1)
        XCTAssertEqual(store.search("alpha*line", limit: 10, scope: .fullText, method: .wildcard).count, 1)
        // regex 全文(内存;大小写不敏感;子串语义)
        XCTAssertEqual(store.search("sec.+line", limit: 10, scope: .fullText, method: .regex).count, 1)
        XCTAssertEqual(store.search("ALPHA", limit: 10, scope: .fullText, method: .regex).count, 1)
        XCTAssertEqual(store.search("^gamma$", limit: 10, scope: .fullText, method: .regex).count, 0,
                       "正则按子串查找,^$ 锚整串")
        XCTAssertEqual(store.search("(", limit: 10, scope: .fullText, method: .regex).count, 0,
                       "非法正则 → 无结果不崩溃")
    }

    func testSearchCombosDescriptionOnly() {
        seedSearchItems()
        // 派生描述 = 标题 ?? 首行:A="alpha first line" B="gamma content" C="特殊标题"
        XCTAssertEqual(store.search("second", limit: 10, scope: .descriptionOnly, method: .contains).count, 0,
                       "第二行不在描述内")
        XCTAssertEqual(store.search("alpha", limit: 10, scope: .descriptionOnly, method: .contains).count, 1)
        XCTAssertEqual(store.search("gamma", limit: 10, scope: .descriptionOnly, method: .contains).count, 1)
        XCTAssertEqual(store.search("delta", limit: 10, scope: .descriptionOnly, method: .contains).count, 0,
                       "仅描述不搜全文(标题已覆盖 delta 的行)")
        XCTAssertEqual(store.search("特殊", limit: 10, scope: .descriptionOnly, method: .contains).count, 1)
        // wildcard 仅描述
        XCTAssertEqual(store.search("alpha*line", limit: 10, scope: .descriptionOnly, method: .wildcard).count, 1)
        XCTAssertEqual(store.search("beta*", limit: 10, scope: .descriptionOnly, method: .wildcard).count, 0)
        // regex 仅描述
        XCTAssertEqual(store.search("^alpha", limit: 10, scope: .descriptionOnly, method: .regex).count, 1)
        XCTAssertEqual(store.search("beta", limit: 10, scope: .descriptionOnly, method: .regex).count, 0)
        // 内存路径保留分词语义(AND / NOT)
        XCTAssertEqual(store.search("alpha NOT first", limit: 10, scope: .descriptionOnly, method: .contains).count, 0)
        XCTAssertEqual(store.search("alpha OR gamma", limit: 10, scope: .descriptionOnly, method: .contains).count, 2)
    }

    func testSearchListScopeCombos() {
        seedSearchItems()
        // list() 组感知口径同样支持范围/方式(面板主入口)
        XCTAssertEqual(store.list(parentID: -1, includeGroupClips: false, query: "beta",
                                  limit: 10, scope: .fullText, method: .contains).count, 1)
        XCTAssertEqual(store.list(parentID: -1, includeGroupClips: false, query: "beta",
                                  limit: 10, scope: .descriptionOnly, method: .contains).count, 0)
        XCTAssertEqual(store.list(parentID: -1, includeGroupClips: false, query: "gam*a",
                                  limit: 10, scope: .fullText, method: .wildcard).count, 1)
        XCTAssertEqual(store.list(parentID: -1, includeGroupClips: false, query: "co.tent",
                                  limit: 10, scope: .descriptionOnly, method: .regex).count, 1)
        // 空查询:内存路径不做过滤(与 SQL 路径一致)
        XCTAssertEqual(store.list(parentID: -1, includeGroupClips: false, query: "",
                                  limit: 10, scope: .descriptionOnly, method: .regex).count, 3)
        // limit 截断(命中补齐到 limit 即止)
        XCTAssertEqual(store.list(parentID: -1, includeGroupClips: false, query: "e",
                                  limit: 2, scope: .fullText, method: .regex).count, 2)
    }

    func testDerivedDescription() {
        let base = ClipItem(id: 1, kind: .text, createdAt: Date(), text: nil,
                            pinned: false, byteSize: 0, appName: nil, contentHash: "h")
        XCTAssertEqual(ClipStore.derivedDescription(of: base), "")
        let titled = ClipItem(id: 2, kind: .text, createdAt: Date(), text: "全文第一行\n第二行",
                              pinned: false, byteSize: 0, appName: nil, contentHash: "h", title: "自定义标题")
        XCTAssertEqual(ClipStore.derivedDescription(of: titled), "自定义标题", "标题优先")
        let untitled = ClipItem(id: 3, kind: .text, createdAt: Date(), text: "全文第一行\n第二行",
                                pinned: false, byteSize: 0, appName: nil, contentHash: "h")
        XCTAssertEqual(ClipStore.derivedDescription(of: untitled), "全文第一行", "无标题取首行")
    }

    // MARK: - 新增词条(双语)

    func testNewQuickOptionTokens() {
        L10n.lang = .zh
        XCTAssertEqual(L10n.menuTransparency, "透明度")
        XCTAssertEqual(L10n.menuAutoRollUp, "失焦自动折叠")
        XCTAssertEqual(L10n.themeFollowSystem, "跟随系统")
        XCTAssertEqual(L10n.menuAtCaret, "插入符处")
        XCTAssertEqual(L10n.searchMethodRegex, "正则")
        L10n.lang = .en
        XCTAssertEqual(L10n.menuTransparency, "Transparency")
        XCTAssertEqual(L10n.menuAutoRollUp, "Auto Roll-up")
        XCTAssertEqual(L10n.themeFollowSystem, "Follow System")
        XCTAssertEqual(L10n.menuAtCaret, "At Caret")
        XCTAssertEqual(L10n.searchMethodRegex, "Regex")
        L10n.lang = .system
    }

    static var registrations: [(String, (Wave4FeatureTests) -> Void)] {
        [
            ("themeParseFullFields", { $0.testThemeParseFullFields() }),
            ("themeParseMalformedSkips", { $0.testThemeParseMalformedSkips() }),
            ("themeParseNordFixture", { $0.testThemeParseNordFixture() }),
            ("bundledThemesAvailable", { $0.testBundledThemesAvailable() }),
            ("themeImportRoundTrip", { $0.testThemeImportRoundTrip() }),
            ("transparencyClampAndAlpha", { $0.testTransparencyClampAndAlpha() }),
            ("fontPersistenceKeys", { $0.testFontPersistenceKeys() }),
            ("rowHeightMath", { $0.testRowHeightMath() }),
            ("caretCoordinateFlip", { $0.testCaretCoordinateFlip() }),
            ("caretFallbackToMouse", { $0.testCaretFallbackToMouse() }),
            ("screenContainingPoint", { $0.testScreenContainingPoint() }),
            ("focusLossBehavior", { $0.testFocusLossBehavior() }),
            ("searchCombosFullText", { $0.testSearchCombosFullText() }),
            ("searchCombosDescriptionOnly", { $0.testSearchCombosDescriptionOnly() }),
            ("searchListScopeCombos", { $0.testSearchListScopeCombos() }),
            ("derivedDescription", { $0.testDerivedDescription() }),
            ("newQuickOptionTokens", { $0.testNewQuickOptionTokens() }),
        ]
    }
}
