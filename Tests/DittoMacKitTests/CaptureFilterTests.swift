import Foundation

/// 捕获排除规则回归(原版 RegExFilterHelper + ClipboardViewer 应用包含/排除列表;纯逻辑,不碰剪贴板)
final class CaptureFilterTests: XCTestCase {

    private func exclude(_ text: String?, app: String? = nil,
                         rules: [ExcludeRule] = [],
                         include: String = "", excludeApps: String = "") -> Bool {
        CaptureFilter.shouldExclude(text: text, appName: app,
                                    rules: rules, appInclude: include, appExclude: excludeApps)
    }

    // MARK: 正则语义(原版 std::regex_match = 整串匹配)

    func testFullMatchRegexSemantics() {
        let rule = ExcludeRule(regex: "test", processName: "")
        XCTAssertFalse(exclude("this is a test", rules: [rule]),
                       "\"test\" 是整串匹配,不得命中句子中间的 test")
        XCTAssertTrue(exclude("test", rules: [rule]))
        XCTAssertTrue(exclude("TEST", rules: [ExcludeRule(regex: "TEST", processName: "")]))
        let loose = ExcludeRule(regex: ".*test.*", processName: "")
        XCTAssertTrue(exclude("this is a test", rules: [loose]), ".*test.* 应命中")
        // 空文本不跑正则(原版空描述跳过);空正则永不命中
        XCTAssertFalse(exclude("", rules: [rule]))
        XCTAssertFalse(exclude("anything", rules: [ExcludeRule(regex: "", processName: "")]))
        XCTAssertFalse(exclude(nil, rules: [rule]))
    }

    func testInvalidRegexIgnoredNoCrash() {
        let bad = ExcludeRule(regex: "([unclosed", processName: "")
        XCTAssertFalse(exclude("([unclosed", rules: [bad]), "非法正则应忽略该条,不得崩溃")
        let mixed = [bad, ExcludeRule(regex: "ok", processName: "")]
        XCTAssertTrue(exclude("ok", rules: mixed), "非法条不影响后续规则")
    }

    // MARK: 进程过滤(原版 MatchesProcessFilters)

    func testProcessFilterMatching() {
        let rule = ExcludeRule(regex: "secret", processName: "Safari;Chrome")
        XCTAssertTrue(exclude("secret", app: "chrome", rules: [rule]), "命中列表(大小写不敏感)")
        XCTAssertFalse(exclude("secret", app: "Firefox", rules: [rule]), "不在列表 → 规则不适用")
        // 空列表 = 所有进程;"*" 同义
        XCTAssertTrue(exclude("secret", app: "Anything", rules: [ExcludeRule(regex: "secret", processName: "")]))
        XCTAssertTrue(exclude("secret", app: "Anything", rules: [ExcludeRule(regex: "secret", processName: "*")]))
        // 来源应用为空串 = 命中(原版 activeApp == "" 返回 true)
        XCTAssertTrue(exclude("secret", app: "", rules: [rule]))
        XCTAssertTrue(exclude("secret", app: nil, rules: [rule]))
        // 通配 * 与 ?
        XCTAssertTrue(exclude("secret", app: "Safari",
                              rules: [ExcludeRule(regex: "secret", processName: "saf*")]))
        XCTAssertTrue(exclude("secret", app: "chrome",
                              rules: [ExcludeRule(regex: "secret", processName: "ch?ome")]))
        XCTAssertFalse(exclude("secret", app: "chooome",
                               rules: [ExcludeRule(regex: "secret", processName: "ch?ome")]))
        // 分号分词 + 空白片段忽略
        XCTAssertTrue(exclude("secret", app: "Notes",
                              rules: [ExcludeRule(regex: "secret", processName: " ;; Notes ; ")]))
    }

    // MARK: 应用包含/排除列表(原版 ValidActiveWnd)

    func testAppIncludeList() {
        // 包含列表非空:未命中 → 排除
        XCTAssertTrue(exclude("x", app: "Chrome", include: "Safari;Notes"), "不在包含列表 → 不入库")
        // 命中(大小写不敏感 + 通配)→ 放行
        XCTAssertFalse(exclude("x", app: "safari", include: "Safari"))
        XCTAssertFalse(exclude("x", app: "Safari Technology Preview", include: "safari*"))
        // 列表为空(或仅空白)→ 不限制
        XCTAssertFalse(exclude("x", app: "Chrome", include: ""))
        XCTAssertFalse(exclude("x", app: "Chrome", include: "  ;  "))
    }

    func testAppExcludeList() {
        XCTAssertTrue(exclude("x", app: "Chrome", excludeApps: "chrome"), "命中排除列表 → 不入库")
        XCTAssertTrue(exclude("x", app: "1Password", excludeApps: "safari;*password*"), "通配 + 多模式")
        XCTAssertFalse(exclude("x", app: "Safari", excludeApps: "chrome"))
        // 排除优先:即便包含列表命中,排除仍生效(原版先 include 后 exclude)
        XCTAssertTrue(exclude("x", app: "Safari", include: "safari", excludeApps: "saf*"))
    }

    // MARK: 15 条上限(原版 MAX_REGEX_FILTERS)

    func testRuleCapAtFifteen() {
        // 前 15 条不命中的前提下,第 16 条即使命中也不生效
        var rules = (0..<15).map { ExcludeRule(regex: "no-hit-\($0)", processName: "") }
        rules.append(ExcludeRule(regex: "victim", processName: ""))
        XCTAssertFalse(exclude("victim", app: "Safari", rules: rules), "第 16 条规则应被忽略")
        // 第 15 条命中 → 生效
        rules[14] = ExcludeRule(regex: "victim", processName: "")
        XCTAssertTrue(exclude("victim", app: "Safari", rules: rules))
    }

    static var registrations: [(String, (CaptureFilterTests) -> Void)] {
        [
            ("testFullMatchRegexSemantics", { $0.testFullMatchRegexSemantics() }),
            ("testInvalidRegexIgnoredNoCrash", { $0.testInvalidRegexIgnoredNoCrash() }),
            ("testProcessFilterMatching", { $0.testProcessFilterMatching() }),
            ("testAppIncludeList", { $0.testAppIncludeList() }),
            ("testAppExcludeList", { $0.testAppExcludeList() }),
            ("testRuleCapAtFifteen", { $0.testRuleCapAtFifteen() }),
        ]
    }
}
