import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// 波次 3:按键串解析 / 命令行动词 / 窗口命令注册表 / 复制缓冲表 / 每应用按键串匹配
final class Wave3FeatureTests: XCTestCase {
    var store: ClipStore!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dittomac-wave3-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ClipStore(path: dir.appendingPathComponent("t.sqlite").path)
    }

    override func tearDown() {
        store = nil
        // 清理 UserDefaults 覆盖(注册表/复制缓冲/应用按键串),防跨用例污染
        PanelAccels.resetAll()
        UserDefaults.standard.removeObject(forKey: AppKeyStrings.storageKey)
        for index in 1...DittoSettings.copyBufferCount {
            DittoSettings.resetCopyBufferKeys(index: index)
            UserDefaults.standard.removeObject(forKey: DittoSettings.copyBufferPlaySoundKey(index))
        }
        super.tearDown()
    }

    private func key(_ code: CGKeyCode,
                     _ mods: KeyStrokeString.Modifiers = []) -> KeyStrokeString.Event {
        .key(code: code, modifiers: mods, unicode: nil)
    }

    // MARK: 按键串解析(上游 SendKeys 语法;只测 parse,不发事件)

    func testModifierPrefixes() {
        XCTAssertEqual(KeyStrokeString.parse("^c"), [key(8, [.ctrl])], "Ctrl 前缀")
        XCTAssertEqual(KeyStrokeString.parse("%a"), [key(0, [.alt])], "Alt 前缀")
        XCTAssertEqual(KeyStrokeString.parse("+s"), [key(1, [.shift])], "Shift 前缀")
        XCTAssertEqual(KeyStrokeString.parse("@v"), [key(9, [.cmd])], "@ = Win → ⌘ 映射")
        XCTAssertEqual(KeyStrokeString.parse("^+c"), [key(8, [.ctrl, .shift])], "多修饰叠加")
        XCTAssertEqual(KeyStrokeString.parse("%^+@x"),
                       [key(7, [.alt, .ctrl, .shift, .cmd])], "四修饰全开")
    }

    func testModifiersResetAfterKey() {
        XCTAssertEqual(KeyStrokeString.parse("^ab"),
                       [key(0, [.ctrl]), key(11)], "修饰只作用于下一个键(上游 PopUpShiftKeys)")
    }

    func testPlainChars() {
        XCTAssertEqual(KeyStrokeString.parse("ab"), [key(0), key(11)])
        XCTAssertEqual(KeyStrokeString.parse("A"), [key(0, [.shift])], "大写自动 ⇧")
        XCTAssertEqual(KeyStrokeString.parse("1"), [key(18)])
        XCTAssertEqual(KeyStrokeString.parse("0"), [key(29)])
        XCTAssertEqual(KeyStrokeString.parse("!"), [key(18, [.shift])], "符号自动 ⇧")
        XCTAssertEqual(KeyStrokeString.parse("-"), [key(27)])
        XCTAssertEqual(KeyStrokeString.parse(" "), [key(49)], "空格")
    }

    func testTildeIsEnter() {
        XCTAssertEqual(KeyStrokeString.parse("a~b"), [key(0), key(36), key(11)], "~ = 回车")
    }

    func testSpecialTokens() {
        XCTAssertEqual(KeyStrokeString.parse("{ENTER}"), [key(36)])
        XCTAssertEqual(KeyStrokeString.parse("{RETURN}"), [key(36)])
        XCTAssertEqual(KeyStrokeString.parse("{TAB}"), [key(48)])
        XCTAssertEqual(KeyStrokeString.parse("{ESC}"), [key(53)])
        XCTAssertEqual(KeyStrokeString.parse("{ESCAPE}"), [key(53)])
        XCTAssertEqual(KeyStrokeString.parse("{BACKSPACE}"), [key(51)])
        XCTAssertEqual(KeyStrokeString.parse("{BS}"), [key(51)])
        XCTAssertEqual(KeyStrokeString.parse("{DELETE}"), [key(117)], "前向删除(上游 VK_DELETE)")
        XCTAssertEqual(KeyStrokeString.parse("{DEL}"), [key(117)])
        XCTAssertEqual(KeyStrokeString.parse("{HOME}"), [key(115)])
        XCTAssertEqual(KeyStrokeString.parse("{END}"), [key(119)])
        XCTAssertEqual(KeyStrokeString.parse("{PGUP}"), [key(116)])
        XCTAssertEqual(KeyStrokeString.parse("{PGDN}"), [key(121)])
        XCTAssertEqual(KeyStrokeString.parse("{UP}"), [key(126)])
        XCTAssertEqual(KeyStrokeString.parse("{DOWN}"), [key(125)])
        XCTAssertEqual(KeyStrokeString.parse("{LEFT}"), [key(123)])
        XCTAssertEqual(KeyStrokeString.parse("{RIGHT}"), [key(124)])
        XCTAssertEqual(KeyStrokeString.parse("{HELP}"), [key(114)])
        XCTAssertEqual(KeyStrokeString.parse("{CAPSLOCK}"), [key(57)])
        XCTAssertEqual(KeyStrokeString.parse("{F1}"), [key(122)])
        XCTAssertEqual(KeyStrokeString.parse("{F16}"), [key(106)])
        // 平台映射(macOS 无对应物理键,取最近等价;见 KeyStrokeString 头注释)
        XCTAssertEqual(KeyStrokeString.parse("{INSERT}"), [key(114)], "INSERT → Help")
        XCTAssertEqual(KeyStrokeString.parse("{NUMLOCK}"), [key(71)], "NUMLOCK → 小键盘 Clear")
        XCTAssertEqual(KeyStrokeString.parse("{SCROLLLOCK}"), [key(107)], "SCROLLLOCK → F14")
        XCTAssertEqual(KeyStrokeString.parse("{PRTSC}"), [key(105)], "PRTSC → F13")
        XCTAssertEqual(KeyStrokeString.parse("{APPS}"), [key(106)], "APPS → F16")
        // 小键盘
        XCTAssertEqual(KeyStrokeString.parse("{ADD}"), [key(69)])
        XCTAssertEqual(KeyStrokeString.parse("{SUBTRACT}"), [key(78)])
        XCTAssertEqual(KeyStrokeString.parse("{MULTIPLY}"), [key(67)])
        XCTAssertEqual(KeyStrokeString.parse("{DIVIDE}"), [key(75)])
        // 修饰键 token 叠在前缀上
        XCTAssertEqual(KeyStrokeString.parse("^{F5}"), [key(96, [.ctrl])])
    }

    func testEscapedLiteralTokens() {
        XCTAssertEqual(KeyStrokeString.parse("{PLUS}"), [key(24, [.shift])])
        XCTAssertEqual(KeyStrokeString.parse("{AT}"), [key(19, [.shift])])
        XCTAssertEqual(KeyStrokeString.parse("{CARET}"), [key(22, [.shift])])
        XCTAssertEqual(KeyStrokeString.parse("{TILDE}"), [key(50, [.shift])], "TILDE = 字面 ~ 而非回车")
        XCTAssertEqual(KeyStrokeString.parse("{LEFTBRACE}"), [key(33, [.shift])])
        XCTAssertEqual(KeyStrokeString.parse("{RIGHTBRACE}"), [key(30, [.shift])])
        XCTAssertEqual(KeyStrokeString.parse("{LEFTPAREN}"), [key(25, [.shift])])
        XCTAssertEqual(KeyStrokeString.parse("{RIGHTPAREN}"), [key(29, [.shift])])
        XCTAssertEqual(KeyStrokeString.parse("{PERCENT}"), [key(23, [.shift])])
        XCTAssertEqual(KeyStrokeString.parse("{RIGHT 3}"),
                       [key(124), key(124), key(124)], "次数后缀重复 3 次(上游 {TOKEN n})")
    }

    func testVkeyDelayBeep() {
        XCTAssertEqual(KeyStrokeString.parse("{VKEY 9}"), [key(9)], "VKEY 直用 macOS 键码")
        XCTAssertEqual(KeyStrokeString.parse("{DELAY 100}"), [.delay(ms: 100)], "立即延迟")
        XCTAssertEqual(KeyStrokeString.parse("{DELAY =50}"), [.setPerKeyDelay(ms: 50)], "每键延迟")
        XCTAssertEqual(KeyStrokeString.parse("{BEEP 1000 500}"), [.beep(frequency: 1000, durationMs: 500)])
    }

    func testWinTokensBecomeCommandModifier() {
        XCTAssertEqual(KeyStrokeString.parse("{LWIN}c"), [key(8, [.cmd])], "LWIN → 后续键带 ⌘")
        XCTAssertEqual(KeyStrokeString.parse("{RWIN}v"), [key(9, [.cmd])])
        XCTAssertEqual(KeyStrokeString.parse("{WIN}"), [], "单独 Win 键不产生事件")
    }

    func testUnicodeChar() {
        let parsed = KeyStrokeString.parse("你")
        XCTAssertEqual(parsed?.count, 1)
        if case .key(_, let mods, let unicode)? = parsed?.first {
            XCTAssertEqual(unicode, "你", "非 ASCII 字符走 Unicode 注入")
            XCTAssertEqual(mods, [])
        } else {
            XCTFail("应是 key 事件")
        }
    }

    func testInvalidSpecs() {
        XCTAssertNil(KeyStrokeString.parse("{UNCLOSED"), "未闭合 {")
        XCTAssertNil(KeyStrokeString.parse("{NOTATOKEN}"), "未知 token")
        XCTAssertNil(KeyStrokeString.parse("{ENTER x}"), "坏次数")
        XCTAssertNil(KeyStrokeString.parse("{VKEY abc}"), "坏键码")
        XCTAssertEqual(KeyStrokeString.parse(""), [], "空串 = 空事件表")
    }

    // MARK: 命令行动词(上游 Command Line Options)

    func testSlashVerbs() {
        XCTAssertEqual(CommandLineParser.parse(["/path/DittoMac", "/Open"]), .open)
        XCTAssertEqual(CommandLineParser.parse(["/path/DittoMac", "/Close"]), .close)
        XCTAssertEqual(CommandLineParser.parse(["/path/DittoMac", "/Connect"]), .connect)
        XCTAssertEqual(CommandLineParser.parse(["/path/DittoMac", "/Disconnect"]), .disconnect)
        XCTAssertEqual(CommandLineParser.parse(["/path/DittoMac", "/PlainTextPaste"]), .plainTextPaste)
        XCTAssertEqual(CommandLineParser.parse(["/path/DittoMac", "/Exit"]), .exitApp)
    }

    func testDashAndDoubleDashForms() {
        XCTAssertEqual(CommandLineParser.parse(["x", "-open"]), .open, "- 前缀")
        XCTAssertEqual(CommandLineParser.parse(["x", "--open"]), .open, "-- 前缀")
        XCTAssertEqual(CommandLineParser.parse(["x", "--PASTE:123"]), .paste(clipID: 123))
        XCTAssertEqual(CommandLineParser.parse(["x", "-Edit:12"]), .edit(clipID: 12))
        XCTAssertEqual(CommandLineParser.parse(["x", "/paste:456"]), .paste(clipID: 456), "大小写不敏感")
    }

    func testPasteEditRequireID() {
        XCTAssertNil(CommandLineParser.parse(["x", "/paste"]), "paste 无 :id 不生效(上游同)")
        XCTAssertNil(CommandLineParser.parse(["x", "/edit"]), "edit 无 :id 不生效")
    }

    func testUnknownArgsIgnored() {
        XCTAssertNil(CommandLineParser.parse(["x"]))
        XCTAssertNil(CommandLineParser.parse(["x", "-ApplePersistenceIgnoreState", "foo", "--bar:1"]))
        XCTAssertEqual(CommandLineParser.parse(["x", "junk", "/Close"]), .close, "首个动词胜出")
    }

    func testVerbRoundTrip() {
        // 转发用的原始名 + id 还原(分布式通知 userInfo 往返)
        for verb in [DittoVerb.open, .close, .connect, .disconnect, .plainTextPaste, .exitApp,
                     .paste(clipID: 77), .edit(clipID: 9)] {
            XCTAssertEqual(DittoVerb.from(rawName: verb.rawName, clipID: verb.clipID), verb)
        }
        XCTAssertNil(DittoVerb.from(rawName: "paste", clipID: nil))
    }

    // MARK: 窗口命令注册表(默认值 = 现有按键行为的零回归基线)

    private func cmd(_ code: UInt16, _ mods: UInt) -> PanelCommand? {
        PanelAccels.command(forKeyCode: code, carbonModifiers: mods)
    }

    func testDefaultResolution() {
        XCTAssertEqual(cmd(36, 0), .pasteSelected, "回车粘贴")
        XCTAssertEqual(cmd(76, 0), .pasteSelected, "小键盘回车")
        XCTAssertEqual(cmd(36, UInt(shiftKey)), .pastePlain, "⇧回车纯文本")
        XCTAssertEqual(cmd(36, UInt(optionKey)), .properties, "⌥回车属性")
        XCTAssertEqual(cmd(99, 0), .fullDescription, "F3")
        XCTAssertEqual(cmd(117, 0), .deleteSelected, "Delete")
        XCTAssertEqual(cmd(51, 0), .deleteSelected, "Backspace")
        XCTAssertEqual(cmd(1, UInt(cmdKey)), .selectAll, "⌘A")
        XCTAssertEqual(cmd(8, UInt(cmdKey)), .copySelection, "⌘C 复制选中")
        XCTAssertEqual(cmd(96, 0), .refresh, "F5")
        XCTAssertEqual(cmd(8, UInt(optionKey)), .clearFilter, "⌥C 清过滤")
        XCTAssertEqual(cmd(49, UInt(controlKey)), .toggleAlwaysOnTop, "⌃Space")
        XCTAssertEqual(cmd(5, UInt(controlKey)), .showGroupTree, "⌃G")
        XCTAssertEqual(cmd(98, UInt(controlKey)), .newGroup, "⌃F7")
        XCTAssertEqual(cmd(98, 0), .newGroupFromSelection, "F7")
        XCTAssertEqual(cmd(7, UInt(controlKey)), .cutClips, "⌃X 组间剪切")
        XCTAssertEqual(cmd(8, UInt(controlKey)), .copyClips, "⌃C 组间复制")
        XCTAssertEqual(cmd(9, UInt(controlKey)), .pasteClips, "⌃V 组间粘贴")
        XCTAssertEqual(cmd(53, 0), .closeWindow, "Esc 关窗")
        XCTAssertEqual(cmd(53, UInt(shiftKey)), .forceClose, "⇧Esc 强关")
    }

    func testDefaultPastePositions() {
        // ⌘1..⌘9,⌘0(键码 18,19,20,21,23,22,25,28,26,29 —— 与原 ctrlDigitIndex 表一致)
        let expected: [(UInt16, PanelCommand)] = [
            (18, .pastePosition1), (19, .pastePosition2), (20, .pastePosition3),
            (21, .pastePosition4), (23, .pastePosition5), (22, .pastePosition6),
            (26, .pastePosition7), (28, .pastePosition8), (25, .pastePosition9),   // 26='7'键、25='9'键(ANSI 键码排序不规则)
            (29, .pastePosition10),
        ]
        for (code, command) in expected {
            XCTAssertEqual(cmd(code, UInt(cmdKey)), command)
        }
        XCTAssertEqual(cmd(18, 0), nil, "无 ⌘ 的数字键不命中(打字搜索路径)")
    }

    func testDefaultUnboundCommands() {
        // 今日只有菜单入口、无按键的命令:默认未绑定 = 禁用
        for command in [PanelCommand.moveClipUp, .moveClipDown, .moveClipTop, .moveClipLast,
                        .makeTopSticky, .makeLastSticky, .replaceTopSticky, .removeSticky,
                        .toggleOrder, .toggleSearchMethod, .rollUp, .maximize, .pasteDontReorder] {
            XCTAssertTrue(PanelAccels.isUnbound(command), "\(command) 默认应未绑定")
            XCTAssertEqual(PanelAccels.defaults[command] ?? [], [])
        }
        XCTAssertEqual(cmd(0, 0), nil, "普通字符 'a' 不命中任何命令")
    }

    func testCustomOverrideAndUnbind() {
        // 重绑 pastePlain:默认 ⇧Enter 不再命中,新键生效
        PanelAccels.setBinding(KeyCombo(keyCode: 45, carbonModifiers: UInt(cmdKey)), for: .pastePlain)
        XCTAssertEqual(cmd(36, UInt(shiftKey)), nil, "旧绑定失效")
        XCTAssertEqual(cmd(45, UInt(cmdKey)), .pastePlain, "新绑定生效")
        XCTAssertEqual(PanelAccels.bindings(for: .pastePlain),
                       [KeyCombo(keyCode: 45, carbonModifiers: UInt(cmdKey))])

        // 解绑 copySelection → ⌘C 不再命中(命令禁用)
        PanelAccels.setBinding(nil, for: .copySelection)
        XCTAssertTrue(PanelAccels.isUnbound(.copySelection))
        XCTAssertEqual(cmd(8, UInt(cmdKey)), nil)

        // 恢复默认
        PanelAccels.resetToDefault(.pastePlain)
        XCTAssertEqual(cmd(36, UInt(shiftKey)), .pastePlain)
    }

    func testPasteSelectedGuard() {
        // 粘贴选中必须永远有绑定:解绑被拒,回落默认
        PanelAccels.setBinding(nil, for: .pasteSelected)
        XCTAssertFalse(PanelAccels.isUnbound(.pasteSelected))
        XCTAssertEqual(cmd(36, 0), .pasteSelected)
    }

    func testEveryCommandResolvableTable() {
        // 默认表内每个绑定都能反解回所属命令(注册表自洽)
        for (command, combos) in PanelAccels.defaults {
            XCTAssertTrue(!combos.isEmpty)
            for combo in combos {
                XCTAssertEqual(PanelAccels.command(forKeyCode: combo.keyCode,
                                                   carbonModifiers: combo.carbonModifiers),
                               command, "\(command) 的默认绑定应反解回自身")
            }
        }
    }

    // MARK: 复制缓冲表(copy_buffers CRUD + 条目删除后视为空)

    func testCopyBufferCRUD() {
        let a = store.insert(RawClip(text: "A"), maxDataBytes: 20 << 20)!
        let b = store.insert(RawClip(text: "B"), maxDataBytes: 20 << 20)!

        XCTAssertNil(store.copyBufferClipID(index: 1), "初始为空")
        store.setCopyBuffer(index: 1, clipID: a.id)
        XCTAssertEqual(store.copyBufferClipID(index: 1), a.id)

        // 覆盖关联(上游 UPDATE CopyBuffers)
        store.setCopyBuffer(index: 1, clipID: b.id)
        XCTAssertEqual(store.copyBufferClipID(index: 1), b.id)

        // 各缓冲互不影响
        store.setCopyBuffer(index: 2, clipID: a.id)
        store.setCopyBuffer(index: 3, clipID: b.id)
        XCTAssertEqual(store.copyBufferClipID(index: 2), a.id)
        XCTAssertEqual(store.copyBufferClipID(index: 3), b.id)

        // 清除关联
        store.setCopyBuffer(index: 2, clipID: nil)
        XCTAssertNil(store.copyBufferClipID(index: 2))
    }

    func testCopyBufferEmptyWhenClipDeleted() {
        let a = store.insert(RawClip(text: "A"), maxDataBytes: 20 << 20)!
        store.setCopyBuffer(index: 1, clipID: a.id)
        XCTAssertEqual(store.copyBufferClipID(index: 1), a.id)

        // 条目被单删 → JOIN 视为空
        store.delete(id: a.id)
        XCTAssertNil(store.copyBufferClipID(index: 1), "条目删除后缓冲视为空")

        // 批量删除同样清理(deleteClips 的孤儿回收)
        let b = store.insert(RawClip(text: "B"), maxDataBytes: 20 << 20)!
        store.setCopyBuffer(index: 2, clipID: b.id)
        _ = store.deleteClips(ids: [b.id])
        XCTAssertNil(store.copyBufferClipID(index: 2))

        // 清空历史(保留置顶 = 全删)也清缓冲
        let c = store.insert(RawClip(text: "C"), maxDataBytes: 20 << 20)!
        store.setCopyBuffer(index: 3, clipID: c.id)
        store.clear(keepingPinned: true)
        XCTAssertNil(store.copyBufferClipID(index: 3))
    }

    // MARK: 复制缓冲热键设置(UserDefaults 读写 + 默认 + 解绑)

    func testNewestClipIgnoresStickyOrdering() {
        // 复制缓冲引擎的"新内容已入库"判定依赖 created_at 最新的条目;
        // 置顶条目占据 recent 首位但未必最新 —— newestClip 必须绕开列表序
        let a = store.insert(RawClip(text: "A"), maxDataBytes: 20 << 20)!
        sleep(1)
        let b = store.insert(RawClip(text: "B"), maxDataBytes: 20 << 20)!
        store.setSticky(a.id, true)
        XCTAssertEqual(store.recent(limit: 1).first?.id, a.id, "置顶条目在列表首位")
        XCTAssertEqual(store.newestClip()?.id, b.id, "最新入库的是 B 而非置顶的 A")
    }

    func testCopyBufferKeySettings() {
        // 默认:缓冲1 粘贴 ⌃= / 复制 ⌃⇧=;缓冲2 粘贴 ⌃- / 复制 ⌃⇧-;缓冲3 与全部 cut 未绑
        XCTAssertEqual(DittoSettings.copyBufferKey(index: 1, action: .paste)?.code, 24)
        XCTAssertEqual(DittoSettings.copyBufferKey(index: 1, action: .paste)?.mods, UInt(controlKey))
        XCTAssertEqual(DittoSettings.copyBufferKey(index: 1, action: .copy)?.mods,
                       UInt(controlKey | shiftKey))
        XCTAssertEqual(DittoSettings.copyBufferKey(index: 2, action: .paste)?.code, 27)
        XCTAssertNil(DittoSettings.copyBufferKey(index: 1, action: .cut))
        XCTAssertNil(DittoSettings.copyBufferKey(index: 3, action: .paste))
        XCTAssertNil(DittoSettings.copyBufferKey(index: 3, action: .copy))

        // 显式绑定
        DittoSettings.setCopyBufferKey(index: 3, action: .cut, code: 11, mods: UInt(cmdKey))
        let bound = DittoSettings.copyBufferKey(index: 3, action: .cut)
        XCTAssertEqual(bound?.code, 11)
        XCTAssertEqual(bound?.mods, UInt(cmdKey))

        // 解绑(有默认 → 显式解绑;无默认 → 移除)
        DittoSettings.setCopyBufferKey(index: 1, action: .paste, code: nil)
        XCTAssertNil(DittoSettings.copyBufferKey(index: 1, action: .paste), "清除默认键 = 解绑")
        DittoSettings.setCopyBufferKey(index: 3, action: .cut, code: nil)
        XCTAssertNil(DittoSettings.copyBufferKey(index: 3, action: .cut))

        // 恢复默认
        DittoSettings.resetCopyBufferKeys(index: 1)
        XCTAssertEqual(DittoSettings.copyBufferKey(index: 1, action: .paste)?.code, 24)
    }

    // MARK: 每应用按键串匹配(通配/分号/BundleID/空串回落)

    func testAppKeyStringMatchByName() {
        let entries = [AppKeyStringEntry(appPattern: "Terminal",
                                         pasteString: "@v", copyString: "^c", cutString: "")]
        XCTAssertEqual(AppKeyStrings.matchedString(kind: .paste, appName: "Terminal",
                                                   bundleID: nil, entries: entries), "@v")
        XCTAssertEqual(AppKeyStrings.matchedString(kind: .copy, appName: "terminal",
                                                   bundleID: nil, entries: entries), "^c",
                       "应用名大小写不敏感")
        XCTAssertEqual(AppKeyStrings.matchedString(kind: .cut, appName: "Terminal",
                                                   bundleID: nil, entries: entries), nil,
                       "命中但该串为空 → 回落默认 ⌘X")
    }

    func testAppKeyStringWildcardAndSemicolon() {
        let entries = [AppKeyStringEntry(appPattern: "Code; *Edit*",
                                         pasteString: "@v", copyString: "", cutString: "")]
        XCTAssertEqual(AppKeyStrings.matchedString(kind: .paste, appName: "Visual Studio Code",
                                                   bundleID: nil, entries: entries), nil,
                       "无通配的模式是整名匹配(非子串),与捕获过滤同一语义")
        XCTAssertEqual(AppKeyStrings.matchedString(kind: .paste, appName: "Xcode Editor",
                                                   bundleID: nil, entries: entries), "@v",
                       "; 分隔的任一模式命中(*Edit*)")
        XCTAssertEqual(AppKeyStrings.matchedString(kind: .paste, appName: "Code",
                                                   bundleID: nil, entries: entries), "@v",
                       "整名精确命中(Code)")
        XCTAssertNil(AppKeyStrings.matchedString(kind: .paste, appName: "Safari",
                                                 bundleID: nil, entries: entries))
    }

    func testAppKeyStringBundleIDMatch() {
        let entries = [AppKeyStringEntry(appPattern: "com.apple.Terminal",
                                         pasteString: "^v", copyString: "", cutString: "")]
        XCTAssertEqual(AppKeyStrings.matchedString(kind: .paste, appName: "其他名字",
                                                   bundleID: "com.apple.Terminal",
                                                   entries: entries), "^v",
                       "Bundle ID 也参与匹配")
    }

    func testAppKeyStringEmptyFallsThroughToNextEntry() {
        // 第一条命中但串为空 → 继续找第二条(上游:空 → 默认串;这里默认串由后续条目或系统 ⌘V 提供)
        let entries = [
            AppKeyStringEntry(appPattern: "Terminal", pasteString: "", copyString: "", cutString: ""),
            AppKeyStringEntry(appPattern: "*", pasteString: "{F13}", copyString: "", cutString: ""),
        ]
        XCTAssertEqual(AppKeyStrings.matchedString(kind: .paste, appName: "Terminal",
                                                   bundleID: nil, entries: entries), "{F13}")
        XCTAssertNil(AppKeyStrings.matchedString(kind: .paste, appName: "Safari",
                                                 bundleID: nil, entries: []), "无条目 → 默认")
        XCTAssertNil(AppKeyStrings.matchedString(kind: .paste, appName: "Safari",
                                                 bundleID: nil,
                                                 entries: [AppKeyStringEntry(appPattern: " ; ",
                                                                            pasteString: "@v",
                                                                            copyString: "",
                                                                            cutString: "")]),
                     "纯空白模式 = 不匹配任何应用")
    }

    func testAppKeyStringPersistenceRoundTrip() {
        var entries: [AppKeyStringEntry] = []
        for i in 0..<AppKeyStrings.maxEntries {
            entries.append(AppKeyStringEntry(appPattern: "app\(i)",
                                             pasteString: "@v\(i)", copyString: "^c", cutString: "x"))
        }
        entries.append(AppKeyStringEntry(appPattern: "overflow",
                                         pasteString: "nope", copyString: "", cutString: ""))
        AppKeyStrings.save(entries)
        let loaded = AppKeyStrings.load()
        XCTAssertEqual(loaded.count, AppKeyStrings.maxEntries, "条目封顶保存")
        XCTAssertEqual(loaded.first?.appPattern, "app0")
        XCTAssertEqual(loaded.first?.pasteString, "@v0")

        UserDefaults.standard.set(Data([0xFF, 0xFE]), forKey: AppKeyStrings.storageKey)
        XCTAssertEqual(AppKeyStrings.load(), [], "解析失败安全退化为空")
    }

    static var registrations: [(String, (Wave3FeatureTests) -> Void)] {
        var regs: [(String, (Wave3FeatureTests) -> Void)] = []
        regs.append(("modifierPrefixes", { $0.testModifierPrefixes() }))
        regs.append(("modifiersResetAfterKey", { $0.testModifiersResetAfterKey() }))
        regs.append(("plainChars", { $0.testPlainChars() }))
        regs.append(("tildeIsEnter", { $0.testTildeIsEnter() }))
        regs.append(("specialTokens", { $0.testSpecialTokens() }))
        regs.append(("escapedLiteralTokens", { $0.testEscapedLiteralTokens() }))
        regs.append(("vkeyDelayBeep", { $0.testVkeyDelayBeep() }))
        regs.append(("winTokensBecomeCommandModifier", { $0.testWinTokensBecomeCommandModifier() }))
        regs.append(("unicodeChar", { $0.testUnicodeChar() }))
        regs.append(("invalidSpecs", { $0.testInvalidSpecs() }))
        regs.append(("slashVerbs", { $0.testSlashVerbs() }))
        regs.append(("dashAndDoubleDashForms", { $0.testDashAndDoubleDashForms() }))
        regs.append(("pasteEditRequireID", { $0.testPasteEditRequireID() }))
        regs.append(("unknownArgsIgnored", { $0.testUnknownArgsIgnored() }))
        regs.append(("verbRoundTrip", { $0.testVerbRoundTrip() }))
        regs.append(("defaultResolution", { $0.testDefaultResolution() }))
        regs.append(("defaultPastePositions", { $0.testDefaultPastePositions() }))
        regs.append(("defaultUnboundCommands", { $0.testDefaultUnboundCommands() }))
        regs.append(("customOverrideAndUnbind", { $0.testCustomOverrideAndUnbind() }))
        regs.append(("pasteSelectedGuard", { $0.testPasteSelectedGuard() }))
        regs.append(("everyCommandResolvableTable", { $0.testEveryCommandResolvableTable() }))
        regs.append(("copyBufferCRUD", { $0.testCopyBufferCRUD() }))
        regs.append(("copyBufferEmptyWhenClipDeleted", { $0.testCopyBufferEmptyWhenClipDeleted() }))
        regs.append(("copyBufferKeySettings", { $0.testCopyBufferKeySettings() }))
        regs.append(("newestClipIgnoresStickyOrdering", { $0.testNewestClipIgnoresStickyOrdering() }))
        regs.append(("appKeyStringMatchByName", { $0.testAppKeyStringMatchByName() }))
        regs.append(("appKeyStringWildcardAndSemicolon", { $0.testAppKeyStringWildcardAndSemicolon() }))
        regs.append(("appKeyStringBundleIDMatch", { $0.testAppKeyStringBundleIDMatch() }))
        regs.append(("appKeyStringEmptyFallsThroughToNextEntry", { $0.testAppKeyStringEmptyFallsThroughToNextEntry() }))
        regs.append(("appKeyStringPersistenceRoundTrip", { $0.testAppKeyStringPersistenceRoundTrip() }))
        return regs
    }
}
