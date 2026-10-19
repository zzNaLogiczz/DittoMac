import AppKit
import Carbon.HIToolbox
import ServiceManagement
import DittoMacKit

extension Notification.Name {
    /// 设置变更(热键 / 清空历史等)。
    /// 设置窗口 post;AppDelegate 监听后重注册热键并刷新在屏面板。
    static let dittoSettingsChanged = Notification.Name("ditto.settingsChanged")

    /// 热键录入状态变更(userInfo["recording"]: Bool)。
    /// 录入期间 AppDelegate 临时注销全局热键,结束(提交/取消/失焦)后恢复。
    static let dittoHotKeyRecording = Notification.Name("ditto.hotKeyRecording")

    /// 暂停记录(原版 Connect To Clipboard)状态变化;面板据此把标题区变黄
    static let dittoPausedChanged = Notification.Name("ditto.pausedChanged")
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {

    var onClose: (() -> Void)?
    private let viewController: SettingsViewController

    init(store: ClipStoring, preview: Bool = false) {
        let content = SettingsViewController(store: store, preview: preview)
        self.viewController = content

        // 全尺寸内容 + 统一工具栏:侧边栏贯穿标题栏,页面标题进工具栏,滚动时系统自动给出边缘材质
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = L10n.settingsTitle
        window.minSize = NSSize(width: 800, height: 580)
        window.maxSize = NSSize(width: 1180, height: 1000)
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.backgroundColor = SettingsPalette.canvas
        if !preview { window.setFrameAutosaveName("DittoMac.NativeSettings") }
        window.contentViewController = content
        window.setContentSize(NSSize(width: 880, height: 650))
        window.isReleasedWhenClosed = false // 由 AppDelegate 持有并在关闭后释放
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "DittoMac.Settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.delegate = self
        content.updateWindowTitle()
        if preview || !window.setFrameUsingName("DittoMac.NativeSettings") { window.center() }
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func selectSection(_ section: SettingsSection, animated: Bool = true) {
        viewController.showSection(section, animated: animated)
    }

    // 工具栏只放侧边栏跟随分隔:标题落在详情区上方,与系统设置一致
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }
}

private final class SettingsViewController: NSSplitViewController {

    private let store: ClipStoring
    private let preview: Bool
    private var accessibilityStatusField: NSTextField!
    private var accessibilityStatusIcon: NSImageView!
    private var launchSwitch: NSSwitch?
    private var hotKeyRecorder: HotKeyRecorderView!
    private var observers: [NSObjectProtocol] = []

    // 捕获格式白名单 / 排除规则(模型随视图常驻;语言切换只重建视图不重读,保留未落盘状态)
    private var typesWhitelist: [String] = []
    private var excludeRules: [ExcludeRule] = []
    private var typesTable: NSTableView!
    private var typesRemoveButton: NSButton!
    private var typesEmptyWarning: NSTextField!
    private var rulesTable: NSTableView!
    private var ruleAddButton: NSButton!
    private var ruleRemoveButton: NSButton!
    private var rulesMaxHint: NSTextField!
    /// 打开中的添加格式 sheet(持有防释放,结束即清)
    private var addTypeSheetController: AddTypeSheetController?

    /// 原生分栏:侧边栏条目由系统提供材质/全高布局/新系统的浮动玻璃效果
    private let sidebarHost = NSView()
    private let detailHost = SettingsCanvasView(frame: .zero)
    private var selectedSection: SettingsSection = .general
    private var sidebar: SettingsSidebar?
    private var pages: [SettingsSection: NSScrollView] = [:]
    private var accessibilityObserver: NSObjectProtocol?
    private var themePopup: NSPopUpButton?
    private var transparencyPopup: NSPopUpButton?
    private var appearanceToggles: [String: NSSwitch] = [:]
    private var controlRefreshers: [() -> Void] = []
    private var listBoxes: [ObjectIdentifier: SettingsListBox] = [:]

    // 应用按键串(每应用替换默认 ⌘V/⌘C/⌘X)
    private var appKeyEntries: [AppKeyStringEntry] = []
    private var appKeysTable: NSTableView!
    private var appKeysAddButton: NSButton!
    private var appKeysRemoveButton: NSButton!

    /// 规则表两列 / 应用输入框的控件标识(controlTextDidEndEditing 分发用)
    private static let ruleRegexColumnID = NSUserInterfaceItemIdentifier("ruleRegex")
    private static let ruleProcessColumnID = NSUserInterfaceItemIdentifier("ruleProcess")
    private static let appIncludeFieldID = NSUserInterfaceItemIdentifier("appIncludeField")
    private static let appExcludeFieldID = NSUserInterfaceItemIdentifier("appExcludeField")

    /// 应用按键串表四列(单元格编辑结束按列分发)
    private static let appKeysPatternColumnID = NSUserInterfaceItemIdentifier("appKeysPattern")
    private static let appKeysPasteColumnID = NSUserInterfaceItemIdentifier("appKeysPaste")
    private static let appKeysCopyColumnID = NSUserInterfaceItemIdentifier("appKeysCopy")
    private static let appKeysCutColumnID = NSUserInterfaceItemIdentifier("appKeysCut")

    /// 复制缓冲清除按钮标识("cbclear.<index>.<action>" 解析回目标)
    private static let copyBufferClearIDPrefix = "cbclear."

    // 网络同步(原版 Friends / LAN CLIP SYNC)的控件标识与状态
    private static let netPortFieldID = NSUserInterfaceItemIdentifier("netPortField")
    private static let netPasswordFieldID = NSUserInterfaceItemIdentifier("netPasswordField")
    private static let netFriendNameColumnID = NSUserInterfaceItemIdentifier("netFriendName")
    private static let netFriendHostColumnID = NSUserInterfaceItemIdentifier("netFriendHost")
    private static let netFriendPortColumnID = NSUserInterfaceItemIdentifier("netFriendPort")
    private var netFriends: [NetSyncFriend] = []
    private var netFriendsTable: NSTableView!
    private var netFriendsAddButton: NSButton!
    private var netFriendsRemoveButton: NSButton!

    init(store: ClipStoring, preview: Bool) {
        self.store = store
        self.preview = preview
        super.init(nibName: nil, bundle: nil)
        // 侧边栏固定宽度且不可折叠:设置窗口只有八个分类,折叠没有收益
        let sidebarController = NSViewController()
        sidebarController.view = sidebarHost
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 214
        sidebarItem.maximumThickness = 214
        let detailController = NSViewController()
        detailController.view = detailHost
        let detailItem = NSSplitViewItem(viewController: detailController)
        detailItem.minimumThickness = 560
        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 白名单:UserDefaults 无键 → 默认白名单(不落盘,保持"默认"语义)
        typesWhitelist = DittoSettings.defaults
            .stringArray(forKey: DittoSettings.typesWhitelistKey)?
            .sorted() ?? DittoSettings.defaultTypesWhitelist.sorted()
        excludeRules = DittoSettings.loadExcludeRules()
        appKeyEntries = AppKeyStrings.load(defaults: DittoSettings.defaults)
        buildContent()
        // 辅助显示选项变化(减弱动态效果/增强对比度):立即终止动效并按新对比度重绘描边
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.pages.values.forEach { SettingsMotion.cancel(self.revealBlocks(of: $0)) }
            self.invalidateAppearance(in: self.view)
        }
        // 权限/自启状态随应用激活刷新(用户去系统设置授权后回来能看到)
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshDynamicStates()
        })
        // 语言切换 → 即时重建整个设置界面(全量文案 + 语言行选中态)
        observers.append(NotificationCenter.default.addObserver(
            forName: L10n.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.buildContent()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .dittoSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshAppearanceControls() })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, notification.object as? NSWindow === self.view.window else { return }
            self.refreshDynamicStates()
        })
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // 窗口首次出现:当前页逐块淡入上浮,与切换分类的动效一致
        if !preview, let page = pages[selectedSection] { SettingsMotion.reveal(revealBlocks(of: page)) }
    }

    deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - UI 构建

    private func buildContent() {
        // 先交出焦点:正在编辑的输入框提交,录制中的热键取消并恢复全局热键
        view.window?.makeFirstResponder(nil)
        sidebarHost.subviews.forEach { $0.removeFromSuperview() }
        detailHost.subviews.forEach { $0.removeFromSuperview() }
        pages.removeAll()
        appearanceToggles.removeAll()
        controlRefreshers.removeAll()
        listBoxes.removeAll()

        // 侧边栏:铺满分栏条目,材质与安全区由系统处理
        let navigation = SettingsSidebar(selected: selectedSection)
        sidebarHost.addSubview(navigation)
        pin(navigation, to: sidebarHost)
        sidebar = navigation

        // 八个分类页预先构建并常驻:切换时只改可见性,保留各页滚动位置与未提交状态
        for section in SettingsSection.allCases {
            let page = makePage(section)
            detailHost.addSubview(page)
            pin(page, to: detailHost)
            page.isHidden = section != selectedSection
            pages[section] = page
            navigation.searchIndex[section] = searchableLabels(in: page).joined(separator: " ")
        }
        navigation.onSelect = { [weak self] in self?.showSection($0) }
        refreshDynamicStates()
        updateWindowTitle()
    }

    private func pin(_ child: NSView, to parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    /// 工具栏标题跟随当前分类(系统设置的做法);窗口菜单与调度中心同步显示
    fileprivate func updateWindowTitle() {
        view.window?.title = selectedSection.title
    }

    fileprivate func showSection(_ section: SettingsSection, animated: Bool = true) {
        guard section != selectedSection, let page = pages[section] else { return }
        // 切页前提交编辑:录制中的热键会被取消并恢复全局热键;焦点拒绝转移则留在原页
        guard sidebar?.focusSelection() != false else {
            sidebar?.select(selectedSection)
            return
        }
        // 打断进行中的入场动效,保证快速连点时只有目标页可见
        pages.values.forEach { SettingsMotion.cancel(revealBlocks(of: $0)); $0.isHidden = true }
        selectedSection = section
        sidebar?.select(section)
        page.isHidden = false
        if animated { SettingsMotion.reveal(revealBlocks(of: page)) }
        updateWindowTitle()
        refreshDynamicStates()
        view.window?.recalculateKeyViewLoop()
    }

    /// 页面的顶层块(标题卡 + 各分组),入场动效按此顺序错峰
    private func revealBlocks(of page: NSScrollView) -> [NSView] {
        (page.documentView?.subviews.first as? NSStackView)?.arrangedSubviews ?? []
    }

    private func makePage(_ section: SettingsSection) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.identifier = .init("settings.page.\(section.rawValue)")
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.setAccessibilityLabel(section.title)
        let document = SettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        // 内容列居中并限宽:宽窗口下行不会被拉得过长,窄窗口时两侧各留 28pt
        let fill = stack.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -56)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 660),
            fill,
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -32),
        ])
        addFullWidth(makeHero(section), to: stack)

        switch section {
        case .general: buildGeneralPage(stack)
        case .clipboard: buildClipboardPage(stack)
        case .appearance: buildAppearancePage(stack)
        case .shortcuts: buildShortcutsPage(stack)
        case .filters: buildFiltersPage(stack)
        case .automation: buildAutomationPage(stack)
        case .network: buildNetworkPage(stack)
        case .advanced: buildAdvancedPage(stack)
        }
        return scroll
    }

    /// 页首标题卡:分类图标 + 标题 + 一句话说明(系统设置各面板的页首样式)
    private func makeHero(_ section: SettingsSection) -> NSView {
        let card = SettingsGroupView(frame: .zero)
        let title = NSTextField(labelWithString: section.title)
        title.font = .systemFont(ofSize: 17, weight: .bold)
        title.alignment = .center
        title.setAccessibilityRole(.staticText)
        let subtitle = SettingsWrappingLabel(section.subtitle, size: 12)
        subtitle.alignment = .center
        let stack = NSStackView(views: [section.tile(size: 48, elevated: true), title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(12, after: stack.arrangedSubviews[0])
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.surface.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.surface.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.surface.bottomAnchor, constant: -20),
            stack.centerXAnchor.constraint(equalTo: card.surface.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: card.surface.leadingAnchor, constant: 24),
            subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        return card
    }

    // MARK: - 分类页

    private func buildGeneralPage(_ stack: NSStackView) {
        addGroup(L10n.t("日常使用", "Everyday Use"), to: stack) { card in
            card.add(makeRow(L10n.setLanguage, makeLanguagePopup()))
            // 便携模式不写系统登录项,因此不提供该开关
            if !PortableMode.isPortable {
                let launch = switchRow(L10n.setLaunchAtLogin, isOn: false, action: #selector(launchToggleChanged(_:)))
                launchSwitch = launch.accessory as? NSSwitch
                card.add(launch)
            }
            card.add(switchRow(L10n.quickPromptDelete, isOn: DittoSettings.promptDelete(),
                               action: #selector(promptDeleteToggle(_:)), refresh: { DittoSettings.promptDelete() }))
            card.add(switchRow(L10n.quickPromptGroupName, isOn: DittoSettings.promptForGroupName(),
                               action: #selector(promptGroupNameToggle(_:)), refresh: { DittoSettings.promptForGroupName() }))
            card.add(switchRow(L10n.quickFindAsYouType, isOn: DittoSettings.findAsYouType(),
                               action: #selector(findAsYouTypeToggle(_:)), refresh: { DittoSettings.findAsYouType() }))
        }
        addGroup(L10n.setAccessibility, to: stack) { card in
            card.add(makeAccessibilityRow())
        }
    }

    private func buildClipboardPage(_ stack: NSStackView) {
        addGroup(L10n.setSectionRecording, to: stack) { card in
            card.add(makeRow(L10n.setKeepCount, makePopup(titles: ["100", "500", "1000", "5000"], values: [100, 500, 1000, 5000], current: intSetting(DittoSettings.maxItemsKey, default: DittoSettings.defaultMaxItems), action: #selector(maxItemsChanged(_:)))))
            card.add(makeRow(L10n.setKeepDays, makePopup(titles: [7, 30, 90, 365].map { "\($0) \(L10n.setDaysUnit)" }, values: [7, 30, 90, 365], current: intSetting(DittoSettings.maxAgeDaysKey, default: DittoSettings.defaultMaxAgeDays), action: #selector(maxAgeDaysChanged(_:)))))
            card.add(makeRow(L10n.setSizeLimit, makePopup(titles: ["5 MB", "20 MB", "50 MB"], values: [5, 20, 50].map { $0 * 1024 * 1024 }, current: intSetting(DittoSettings.maxDataBytesKey, default: DittoSettings.defaultMaxDataBytes), action: #selector(maxDataBytesChanged(_:)), customTitle: { "\($0 / 1024 / 1024) MB" })))
        }
        addGroup(L10n.setSectionTypes, footer: L10n.setTypesCaption, to: stack) { buildTypesSection(in: $0) }
    }

    private func buildAppearancePage(_ stack: NSStackView) {
        addGroup(L10n.t("快速粘贴窗口", "Quick Paste Window"), to: stack) { card in
            card.add(makeRow(L10n.setLinesPerRow, makePopup(titles: (1...5).map { "\($0) \(L10n.setLinesUnit)" }, values: Array(1...5), current: intSetting(DittoSettings.linesPerRowKey, default: DittoSettings.defaultLinesPerRow), action: #selector(linesPerRowChanged(_:)))))
            card.add(makeRow(L10n.setPosition, makePositionPopup()))
            card.add(makeRow(L10n.menuSortOrder, makeSortOrderPopup()))
            card.add(switchRow(L10n.quickShowGroupClips, isOn: DittoSettings.includeGroupClips(),
                               action: #selector(includeGroupClipsToggle(_:)), refresh: { DittoSettings.includeGroupClips() }))
        }
        addGroup(L10n.t("主题与显示", "Theme & Display"), to: stack) { card in
            card.add(makeRow(L10n.menuTheme, makeThemePopup()))
            let transparency = makePopup(titles: stride(from: 0, through: 40, by: 5).map { "\($0)%" }, values: Array(stride(from: 0, through: 40, by: 5)), current: DittoSettings.defaults.integer(forKey: DittoSettings.transparencyPercentKey), action: #selector(transparencyChanged(_:)))
            transparencyPopup = transparency
            card.add(makeRow(L10n.menuTransparency, transparency))
            card.add(appearanceSwitchRow(L10n.menuAlwaysShowDescription, key: DittoSettings.alwaysShowDescriptionKey))
            card.add(appearanceSwitchRow(L10n.menuDrawRtfText, key: DittoSettings.drawRtfTextKey))
            card.add(appearanceSwitchRow(L10n.menuAutoRollUp, key: DittoSettings.autoRollUpKey))
            let chooseFont = NSButton(title: L10n.menuFont, target: self, action: #selector(chooseFont))
            chooseFont.bezelStyle = .push
            let resetFont = NSButton(title: L10n.menuResetFont, target: self, action: #selector(resetFont))
            resetFont.bezelStyle = .push
            let fonts = NSStackView(views: [resetFont, chooseFont])
            fonts.spacing = 8
            card.add(SettingsFormRow(title: L10n.t("列表字体", "List Font"), accessory: fonts))
        }
    }

    private func buildShortcutsPage(_ stack: NSStackView) {
        addGroup(L10n.setSectionShortcuts, footer: L10n.t("在任意应用中按下即可呼出快速粘贴窗口。", "Opens Quick Paste from any app."), to: stack) { card in
            card.add(SettingsFormRow(title: L10n.setGlobalHotkey, accessory: makeHotKeyRow()))
        }
        addGroup(L10n.setSectionWindowKeys, footer: L10n.t("这些快捷键在快速粘贴窗口内生效。点击快捷键可重新录制，清除后停用该命令。", "These shortcuts work inside Quick Paste. Click a shortcut to record a new one, or clear it to disable the command."), to: stack) {
            buildWindowKeysSection(in: $0)
        }
    }

    private func buildFiltersPage(_ stack: NSStackView) {
        addGroup(L10n.t("应用范围", "App Scope"), footer: L10n.setExcludeAppsHint, to: stack) { card in
            card.add(makeAppFieldRow(id: Self.appIncludeFieldID, title: L10n.setExcludeIncludeApps, value: DittoSettings.appInclude()))
            card.add(makeAppFieldRow(id: Self.appExcludeFieldID, title: L10n.setExcludeExcludeApps, value: DittoSettings.appExclude()))
        }
        addGroup(L10n.setSectionExclude, footer: L10n.setExcludeRuleHint, to: stack) { buildExcludeSection(in: $0) }
    }

    private func buildAutomationPage(_ stack: NSStackView) {
        addGroup(L10n.setSectionCopyBuffers, footer: L10n.t("将内容分别保存在三个复制缓冲中。复制到缓冲后，原剪贴板内容会恢复。", "Keep clips in three separate copy buffers. Your original clipboard is restored after copying to a buffer."), to: stack) {
            buildCopyBuffersSection(in: $0)
        }
        addGroup(L10n.setSectionAppKeys, footer: L10n.setAppKeysHint, to: stack) { buildAppKeysSection(in: $0) }
    }

    private func buildNetworkPage(_ stack: NSStackView) {
        addGroup(L10n.t("连接", "Connection"), footer: L10n.setNetPasswordHint, to: stack) { buildNetConnectionSection(in: $0) }
        addGroup(L10n.t("发送目标", "Send Targets"), footer: L10n.setNetFriendsCaption, to: stack) { buildNetFriendsSection(in: $0) }
    }

    private func buildAdvancedPage(_ stack: NSStackView) {
        addGroup(L10n.t("诊断", "Diagnostics"), to: stack) { card in
            let stats = NSButton(title: L10n.setStatsButton, target: self, action: #selector(openStats))
            stats.bezelStyle = .push
            card.add(makeRow(L10n.setStatsRowLabel, stats))
            card.add(switchRow(L10n.setWriteDebugLog, detail: L10n.setWriteDebugLogHint,
                               isOn: DittoSettings.writeDebugLogFile(), action: #selector(writeDebugLogToggle(_:))))
        }
        addGroup(L10n.t("历史数据", "History Data"), to: stack) { card in
            let clear = NSButton(title: L10n.t("清理…", "Clear…"), target: self, action: #selector(clearHistory))
            clear.bezelStyle = .push
            clear.hasDestructiveAction = true
            card.add(makeRow(L10n.t("清理历史记录", "Clear History"), clear,
                             detail: L10n.t("清理前会再次确认。置顶和标记为永不删除的条目会保留。", "You'll be asked to confirm. Pinned and protected clips are kept.")))
        }
    }

    // MARK: - 分组与行

    /// 分组:粗体组标题 + 卡片 + 卡片下方的说明文字(系统设置分组表单的结构)
    private func addGroup(_ title: String, footer: String? = nil,
                          to page: NSStackView, build: (SettingsFormCard) -> Void) {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 8
        // 组标题与卡片内行文字左对齐
        addFullWidth(SettingsInsetRow(makeGroupTitle(title), vertical: 0), to: group)
        let card = SettingsFormCard(frame: .zero)
        build(card)
        addFullWidth(card, to: group)
        if let footer, !footer.isEmpty {
            group.setCustomSpacing(7, after: card)
            let note = SettingsInsetRow(SettingsWrappingLabel(footer), vertical: 0)
            addFullWidth(note, to: group)
        }
        addFullWidth(group, to: page)
    }

    private func makeGroupTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    /// 标签 + 右侧控件;控件继承行标题作为 VoiceOver 标签
    private func makeRow(_ title: String, _ control: NSView, detail: String? = nil) -> SettingsFormRow {
        if !(control is NSStackView) { control.setAccessibilityLabel(title) }
        return SettingsFormRow(title: title, detail: detail, accessory: control)
    }

    /// 布尔设置使用开关(HIG:分组表单中的开关);refresh 用于与快速选项菜单双向同步
    private func switchRow(_ title: String, detail: String? = nil, isOn: Bool, action: Selector,
                           refresh: (() -> Bool)? = nil) -> SettingsFormRow {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = action
        if let refresh {
            controlRefreshers.append { [weak toggle] in toggle?.state = refresh() ? .on : .off }
        }
        return makeRow(title, toggle, detail: detail)
    }

    private func appearanceSwitchRow(_ title: String, key: String) -> SettingsFormRow {
        let row = switchRow(title, isOn: DittoSettings.defaults.bool(forKey: key), action: #selector(appearanceToggle(_:)))
        if let toggle = row.accessory as? NSSwitch {
            toggle.identifier = .init(key)
            appearanceToggles[key] = toggle
        }
        return row
    }

    /// 辅助功能权限行:状态图标 + 状态文字 + 说明 + 跳转系统设置
    private func makeAccessibilityRow() -> SettingsFormRow {
        let icon = NSImageView()
        icon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        accessibilityStatusIcon = icon
        let button = NSButton(title: L10n.btnOpenSettings + "…", target: self, action: #selector(openAccessibilitySettings))
        button.bezelStyle = .push
        let row = SettingsFormRow(title: "", detail: L10n.t("允许 DittoMac 将选中的内容粘贴回你正在使用的应用。", "Allow DittoMac to paste selected clips into the app you're using."),
                                  accessory: button, leading: icon)
        row.titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        accessibilityStatusField = row.titleLabel
        return row
    }

    /// 清除快捷键:行内小图标按钮(避免整列重复的文字按钮)
    private func makeClearButton(action: Selector, identifier: String) -> NSButton {
        let label = L10n.propsGroupHotkeyClear
        let button = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: label) ?? NSImage(),
                              target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        button.contentTintColor = .tertiaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }

    /// 录制控件 + 清除按钮(窗口快捷键与复制缓冲共用)
    private func recorderAccessory(_ recorder: HotKeyRecorderView, clear: NSButton) -> NSStackView {
        let controls = NSStackView(views: [recorder, clear])
        controls.orientation = .horizontal
        controls.spacing = 6
        controls.alignment = .centerY
        return controls
    }

    /// 列表卡片内容:表格 + 底部 +/− 工具条;空表时居中显示引导
    private func addListBox(_ table: NSTableView, to card: SettingsFormCard, height: CGFloat,
                            buttons: [NSButton], trailing: [NSView] = [],
                            emptySymbol: String, emptyMessage: String) {
        table.rowHeight = 26
        let box = SettingsListBox(table: table, height: height, buttons: buttons, trailing: trailing,
                                  emptySymbol: emptySymbol, emptyMessage: emptyMessage)
        listBoxes[ObjectIdentifier(table)] = box
        card.add(box, fullBleed: true)
    }

    private func makeThemePopup() -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.target = self
        popup.action = #selector(themeChanged(_:))
        themePopup = popup
        populateThemePopup(popup)
        return popup
    }

    private func populateThemePopup(_ popup: NSPopUpButton) {
        let current = DittoSettings.defaults.string(forKey: DittoSettings.themeFileKey) ?? ""
        var entries = [(L10n.setFollowSystem, "")]
        entries += ThemeRegistry.bundledThemeNames().map { ($0, "builtin:" + $0) }
        if !preview {
            entries += ThemeRegistry.userThemeNames().compactMap { name in
                ThemeRegistry.userThemeURL(name: name).map { (name + L10n.t("（已导入）", " (Imported)"), $0.path) }
            }
        }
        if popup.itemArray.compactMap({ $0.representedObject as? String }) != entries.map({ $0.1 }) {
            popup.removeAllItems()
            for (name, value) in entries {
                popup.addItem(withTitle: name)
                popup.lastItem?.representedObject = value
            }
        }
        popup.selectItem(at: entries.firstIndex(where: { $0.1 == current }) ?? 0)
    }

    private func refreshAppearanceControls() {
        controlRefreshers.forEach { $0() }
        if let themePopup { populateThemePopup(themePopup) }
        let transparency = DittoSettings.defaults.integer(forKey: DittoSettings.transparencyPercentKey)
        if let item = transparencyPopup?.itemArray.first(where: { ($0.representedObject as? Int) == transparency }) {
            transparencyPopup?.select(item)
        }
        for (key, toggle) in appearanceToggles {
            toggle.state = DittoSettings.defaults.bool(forKey: key) ? .on : .off
        }
    }

    private func searchableLabels(in root: NSView) -> [String] {
        var labels: [String] = []
        if let text = root as? NSTextField, !text.isEditable { labels.append(text.stringValue) }
        if let button = root as? NSButton { labels.append(button.title) }
        for child in root.subviews { labels += searchableLabels(in: child) }
        return labels
    }

    private func invalidateAppearance(in root: NSView) {
        root.needsDisplay = true
        root.needsLayout = true
        root.subviews.forEach { invalidateAppearance(in: $0) }
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String else { return }
        DittoSettings.defaults.set(value, forKey: DittoSettings.themeFileKey)
        notifyChanged()
    }
    @objc private func transparencyChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? Int else { return }
        DittoSettings.defaults.set(value, forKey: DittoSettings.transparencyPercentKey)
        notifyChanged()
    }
    @objc private func appearanceToggle(_ sender: NSSwitch) {
        guard let key = sender.identifier?.rawValue else { return }
        DittoSettings.defaults.set(sender.state == .on, forKey: key)
        notifyChanged()
    }
    @objc private func chooseFont() { FontPanelManager.shared.openFontPanel() }
    @objc private func resetFont() {
        DittoSettings.defaults.removeObject(forKey: DittoSettings.fontNameKey)
        DittoSettings.defaults.removeObject(forKey: DittoSettings.fontSizeKey)
        notifyChanged()
    }

    private func makePopup(titles: [String],
                           values: [Int],
                           current: Int,
                           action: Selector,
                           customTitle: ((Int) -> String)? = nil) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = action
        for (title, value) in zip(titles, values) {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = value
        }
        if let index = values.firstIndex(of: current) {
            popup.selectItem(at: index)
        } else {
            popup.insertItem(withTitle: customTitle?(current) ?? "自定义", at: 0)
            popup.selectItem(at: 0)
        }
        popup.setContentHuggingPriority(.required, for: .horizontal)
        let keys: [Selector: String] = [
            #selector(maxItemsChanged(_:)): DittoSettings.maxItemsKey,
            #selector(maxAgeDaysChanged(_:)): DittoSettings.maxAgeDaysKey,
            #selector(maxDataBytesChanged(_:)): DittoSettings.maxDataBytesKey,
            #selector(linesPerRowChanged(_:)): DittoSettings.linesPerRowKey,
            #selector(transparencyChanged(_:)): DittoSettings.transparencyPercentKey,
        ]
        if let key = keys[action] {
            controlRefreshers.append { [weak popup] in
                let value = (DittoSettings.defaults.object(forKey: key) as? NSNumber)?.intValue ?? current
                if let item = popup?.itemArray.first(where: { ($0.representedObject as? Int) == value }) {
                    popup?.select(item)
                }
            }
        }
        return popup
    }

    /// 热键行:录入控件 + 恢复默认按钮
    private func makeHotKeyRow() -> NSView {
        let recorder = HotKeyRecorderView()
        let d = DittoSettings.defaults
        let code = (d.object(forKey: DittoSettings.hotKeyCodeKey) as? NSNumber)?.uint32Value
            ?? DittoSettings.defaultHotKeyCode
        let mods = (d.object(forKey: DittoSettings.hotKeyModsKey) as? NSNumber)?.uintValue
            ?? DittoSettings.defaultHotKeyMods
        recorder.display(code: code, mods: mods)
        recorder.setAccessibilityLabel(L10n.setGlobalHotkey)
        recorder.onCommit = { [weak self, weak recorder] code, mods in
            guard let self else { return }
            DittoSettings.defaults.set(code, forKey: DittoSettings.hotKeyCodeKey)
            DittoSettings.defaults.set(mods, forKey: DittoSettings.hotKeyModsKey)
            recorder?.display(code: code, mods: mods)
            self.notifyChanged()
        }
        hotKeyRecorder = recorder

        let reset = NSButton(title: L10n.setResetHotkey, target: self, action: #selector(resetHotKey(_:)))
        reset.bezelStyle = .push
        reset.controlSize = .small

        let row = NSStackView(views: [recorder, reset])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    /// 语言:跟随系统 / 中文 / English(切换即时生效,广播 L10n.changedNotification)
    private func makeLanguagePopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(languageChanged(_:))
        for lang in L10n.Lang.allCases {
            popup.addItem(withTitle: lang.displayName)
            popup.lastItem?.representedObject = lang.rawValue
        }
        popup.selectItem(at: L10n.Lang.allCases.firstIndex(of: L10n.lang) ?? 0)
        return popup
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let lang = L10n.Lang(rawValue: raw) else { return }
        L10n.lang = lang   // setter 写 UserDefaults 并广播 → 设置界面即时重建
    }

    /// 出现位置(原版 Positioning At Caret/At Cursor/At Previous;macOS 等价映射)
    private func makePositionPopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(positionModeChanged(_:))
        let options = [("atCursor", L10n.menuAtCursor), ("atPrevious", L10n.menuAtPrevious)]
        for (value, title) in options {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = value
        }
        let mode = DittoSettings.defaults.string(forKey: DittoSettings.positionModeKey)
            ?? DittoSettings.defaultPositionMode
        popup.selectItem(at: options.firstIndex(where: { $0.0 == mode }) ?? 0)
        controlRefreshers.append { [weak popup] in
            let value = DittoSettings.defaults.string(forKey: DittoSettings.positionModeKey) ?? DittoSettings.defaultPositionMode
            if let item = popup?.itemArray.first(where: { ($0.representedObject as? String) == value }) { popup?.select(item) }
        }
        return popup
    }

    /// 排序方向:最新在上/最新在下(原版 2.8.1;影响非置顶条目排序)
    private func makeSortOrderPopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(sortOrderChanged(_:))
        let options = [(true, L10n.menuSortLatestOnTop), (false, L10n.menuSortLatestOnBottom)]
        for (value, title) in options {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = value
        }
        popup.selectItem(at: options.firstIndex(where: { $0.0 == DittoSettings.orderLatestOnTop() }) ?? 0)
        popup.setContentHuggingPriority(.required, for: .horizontal)
        controlRefreshers.append { [weak popup] in
            if let item = popup?.itemArray.first(where: { ($0.representedObject as? Bool) == DittoSettings.orderLatestOnTop() }) { popup?.select(item) }
        }
        return popup
    }

    // MARK: - 捕获格式白名单(原版 Supported Types)

    /// 全宽子视图:先入栈再拉等宽约束(同分隔线,无共同祖先时 activate 会抛)
    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func buildTypesSection(in card: SettingsFormCard) {
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue: "type"))
        column.width = 280
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.autoresizingMask = [.width]   // 跟随滚动视图宽度铺满
        typesTable = table

        let add = SettingsListBox.barButton(symbol: "plus", label: L10n.setTypesAdd, target: self, action: #selector(addTypeClicked(_:)))
        let remove = SettingsListBox.barButton(symbol: "minus", label: L10n.setTypesRemove, target: self, action: #selector(removeTypeClicked(_:)))
        typesRemoveButton = remove
        // 空表警示:列表清空 = 什么都不记录(原版空 Types 表行为)
        let warning = NSTextField(labelWithString: L10n.setTypesEmptyWarning)
        warning.font = .systemFont(ofSize: 11, weight: .medium)
        warning.textColor = .systemRed
        warning.lineBreakMode = .byTruncatingTail
        warning.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        typesEmptyWarning = warning
        addListBox(table, to: card, height: 168, buttons: [add, remove], trailing: [warning],
                   emptySymbol: "doc.badge.plus",
                   emptyMessage: L10n.t("添加要记录的剪贴板格式", "Add the clipboard formats you want to capture"))
        updateTypesAuxState()
    }

    /// 白名单立即落盘(监控每轮现读 provider,无需额外通知)
    private func persistTypesWhitelist() {
        typesWhitelist.sort()
        DittoSettings.defaults.set(typesWhitelist, forKey: DittoSettings.typesWhitelistKey)
        typesTable.reloadData()
        updateTypesAuxState()
    }

    private func updateTypesAuxState() {
        let empty = typesWhitelist.isEmpty
        typesEmptyWarning.isHidden = !empty
        typesRemoveButton.isEnabled = !typesTable.selectedRowIndexes.isEmpty && !empty
        updateTablePlaceholder(typesTable)
    }

    // MARK: - 排除规则(原版 RegEx Filter + 应用包含/排除)

    private func buildExcludeSection(in card: SettingsFormCard) {
        // 规则表:正则 / 进程名 两列可编辑(单元格 NSTextField,再次单击或双击进入编辑)
        let table = NSTableView()
        let regexColumn = NSTableColumn(identifier: Self.ruleRegexColumnID)
        regexColumn.headerCell.stringValue = L10n.setExcludeRegexCol
        regexColumn.width = 220
        regexColumn.minWidth = 100
        let processColumn = NSTableColumn(identifier: Self.ruleProcessColumnID)
        processColumn.headerCell.stringValue = L10n.setExcludeProcessCol
        processColumn.width = 140
        processColumn.minWidth = 80
        table.addTableColumn(regexColumn)
        table.addTableColumn(processColumn)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.autoresizingMask = [.width]   // 跟随滚动视图宽度铺满
        rulesTable = table

        let add = SettingsListBox.barButton(symbol: "plus", label: L10n.t("添加规则", "Add Rule"), target: self, action: #selector(addRuleClicked(_:)))
        ruleAddButton = add
        let remove = SettingsListBox.barButton(symbol: "minus", label: L10n.t("移除所选", "Remove Selected"), target: self, action: #selector(removeRuleClicked(_:)))
        ruleRemoveButton = remove
        let maxHint = NSTextField(labelWithString: L10n.setExcludeMaxRules)
        maxHint.font = .systemFont(ofSize: 11)
        maxHint.textColor = .secondaryLabelColor
        rulesMaxHint = maxHint
        addListBox(table, to: card, height: 176, buttons: [add, remove], trailing: [maxHint],
                   emptySymbol: "line.3.horizontal.decrease.circle",
                   emptyMessage: L10n.t("使用 + 添加排除规则", "Use + to add an exclusion rule"))
        updateRulesAuxState()
    }

    /// 应用包含/排除输入行:标签 + 圆角输入框(分号分隔多个应用,支持通配)
    private func makeAppFieldRow(id: NSUserInterfaceItemIdentifier, title: String, value: String) -> SettingsFormRow {
        let field = NSTextField()
        field.identifier = id
        field.stringValue = value
        field.placeholderString = L10n.setExcludeAppsPlaceholder
        field.delegate = self
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 12)
        field.cell?.truncatesLastVisibleLine = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        return makeRow(title, field)
    }

    // MARK: - 复制缓冲(原版 Copy Buffers 页:每缓冲 粘贴/复制/剪切 热键 + 提示音)

    /// 录入控件引用("index.action" → recorder;清除/恢复默认后回显用)
    private var copyBufferRecorders: [String: HotKeyRecorderView] = [:]

    private func copyBufferActionTitle(_ action: CopyBufferAction) -> String {
        switch action {
        case .paste: return L10n.setCopyBufferPaste
        case .copy: return L10n.setCopyBufferCopy
        case .cut: return L10n.setCopyBufferCut
        }
    }

    private func buildCopyBuffersSection(in card: SettingsFormCard) {
        copyBufferRecorders = [:]
        for index in 1...DittoSettings.copyBufferCount {
            // 小节头:缓冲 N + 恢复默认(整组热键回到默认绑定)
            let reset = NSButton(title: L10n.setResetHotkey, target: self, action: #selector(copyBufferReset(_:)))
            reset.bezelStyle = .push
            reset.controlSize = .small
            reset.tag = index
            card.add(SettingsSubheaderRow(title: L10n.setCopyBufferName(index), accessory: reset), fullBleed: true)

            // 三行:粘贴/复制/剪切 热键录入 + 清除
            for action in CopyBufferAction.allCases {
                let recorder = HotKeyRecorderView()
                if let key = DittoSettings.copyBufferKey(index: index, action: action) {
                    recorder.display(code: key.code, mods: key.mods)
                } else {
                    recorder.clear()
                }
                recorder.setAccessibilityLabel("\(L10n.setCopyBufferName(index)) \(copyBufferActionTitle(action))")
                copyBufferRecorders["\(index).\(action.rawValue)"] = recorder
                recorder.onCommit = { [weak self, weak recorder] code, mods in
                    DittoSettings.setCopyBufferKey(index: index, action: action,
                                                   code: code, mods: mods)
                    recorder?.display(code: code, mods: mods)
                    self?.notifyChanged()   // AppDelegate 重注册热键
                }
                let clear = makeClearButton(action: #selector(copyBufferCleared(_:)),
                                            identifier: "\(Self.copyBufferClearIDPrefix)\(index).\(action.rawValue)")
                card.add(SettingsFormRow(title: copyBufferActionTitle(action),
                                         accessory: recorderAccessory(recorder, clear: clear)))
            }

            // 复制到缓冲时的提示音(每个缓冲独立)
            let sound = switchRow(L10n.setCopyBufferPlaySound, isOn: DittoSettings.copyBufferPlaySound(index: index),
                                  action: #selector(copyBufferSoundToggled(_:)))
            (sound.accessory as? NSSwitch)?.tag = index
            card.add(sound)
        }
    }

    /// 按 "index.action" 键回显该录入控件当前的生效绑定
    private func refreshCopyBufferRecorder(index: Int, action: CopyBufferAction) {
        guard let recorder = copyBufferRecorders["\(index).\(action.rawValue)"] else { return }
        if let key = DittoSettings.copyBufferKey(index: index, action: action) {
            recorder.display(code: key.code, mods: key.mods)
        } else {
            recorder.clear()
        }
    }

    @objc private func copyBufferSoundToggled(_ sender: NSSwitch) {
        DittoSettings.setCopyBufferPlaySound(index: sender.tag, sender.state == .on)
    }

    /// 该缓冲全部热键恢复默认(默认即未绑定的项回到"点击设置")
    @objc private func copyBufferReset(_ sender: NSButton) {
        let index = sender.tag
        DittoSettings.resetCopyBufferKeys(index: index)
        for action in CopyBufferAction.allCases {
            refreshCopyBufferRecorder(index: index, action: action)
        }
        notifyChanged()
    }

    /// 清除 = 显式解绑(默认键也一并停用;再录一次即恢复)
    @objc private func copyBufferCleared(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              id.hasPrefix(Self.copyBufferClearIDPrefix) else { return }
        let parts = id.dropFirst(Self.copyBufferClearIDPrefix.count).split(separator: ".")
        guard parts.count == 2, let index = Int(parts[0]),
              let action = CopyBufferAction(rawValue: String(parts[1])) else { return }
        DittoSettings.setCopyBufferKey(index: index, action: action, code: nil)
        refreshCopyBufferRecorder(index: index, action: action)
        notifyChanged()
    }

    // MARK: - 应用按键串(原版 Custom Key Strokes:按应用替换默认 ⌘V/⌘C/⌘X)

    private func buildAppKeysSection(in card: SettingsFormCard) {
        let table = NSTableView()
        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)] = [
            (Self.appKeysPatternColumnID, L10n.setAppKeysPatternCol, 120),
            (Self.appKeysPasteColumnID, L10n.setAppKeysPasteCol, 96),
            (Self.appKeysCopyColumnID, L10n.setAppKeysCopyCol, 96),
            (Self.appKeysCutColumnID, L10n.setAppKeysCutCol, 96),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.headerCell.stringValue = title
            column.width = width
            column.minWidth = 56
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.autoresizingMask = [.width]   // 跟随滚动视图宽度铺满
        appKeysTable = table

        let add = SettingsListBox.barButton(symbol: "plus", label: L10n.t("添加应用", "Add App"), target: self, action: #selector(appKeysAddClicked(_:)))
        appKeysAddButton = add
        let remove = SettingsListBox.barButton(symbol: "minus", label: L10n.t("移除所选", "Remove Selected"), target: self, action: #selector(appKeysRemoveClicked(_:)))
        appKeysRemoveButton = remove
        addListBox(table, to: card, height: 150, buttons: [add, remove],
                   emptySymbol: "keyboard",
                   emptyMessage: L10n.t("使用 + 添加应用专属按键", "Use + to add app-specific keystrokes"))
        updateAppKeysAuxState()
    }

    @objc private func appKeysAddClicked(_ sender: NSButton) {
        guard appKeyEntries.count < AppKeyStrings.maxEntries else { return }
        appKeyEntries.append(AppKeyStringEntry())
        AppKeyStrings.save(appKeyEntries, defaults: DittoSettings.defaults)
        appKeysTable.reloadData()
        appKeysTable.scrollRowToVisible(appKeyEntries.count - 1)
        updateAppKeysAuxState()
    }

    @objc private func appKeysRemoveClicked(_ sender: NSButton) {
        let rows = appKeysTable.selectedRowIndexes
        guard !rows.isEmpty else { return }
        for row in rows.reversed() where row < appKeyEntries.count {
            appKeyEntries.remove(at: row)
        }
        AppKeyStrings.save(appKeyEntries, defaults: DittoSettings.defaults)
        appKeysTable.reloadData()
        updateAppKeysAuxState()
    }

    private func updateAppKeysAuxState() {
        updateTablePlaceholder(appKeysTable)
        appKeysAddButton.isEnabled = appKeyEntries.count < AppKeyStrings.maxEntries
        appKeysRemoveButton.isEnabled = !appKeysTable.selectedRowIndexes.isEmpty
    }

    // MARK: - 窗口快捷键(原版 Quick Paste Keyboard:命令重绑定)

    /// 录入控件引用(命令 → recorder;清除后回显用)
    private var accelRecorders: [PanelCommand: HotKeyRecorderView] = [:]

    private func buildWindowKeysSection(in card: SettingsFormCard) {
        accelRecorders = [:]
        for command in PanelCommand.allCases {
            let recorder = HotKeyRecorderView()
            if let first = PanelAccels.bindings(for: command).first {
                recorder.display(code: UInt32(first.keyCode), mods: first.carbonModifiers)
            } else {
                recorder.clear()
            }
            recorder.setAccessibilityLabel(command.displayName)
            accelRecorders[command] = recorder
            recorder.onCommit = { [weak recorder] code, mods in
                // 面板按键路径每次现读注册表,保存即生效,无需通知
                PanelAccels.setBinding(KeyCombo(keyCode: UInt16(code), carbonModifiers: mods),
                                       for: command)
                recorder?.display(code: code, mods: mods)
            }

            let clear = makeClearButton(action: #selector(accelCleared(_:)), identifier: command.rawValue)
            // 粘贴所选是面板的核心命令,不允许解绑
            if command == .pasteSelected {
                clear.isEnabled = false
                clear.toolTip = L10n.t("粘贴所选条目需要保留一个快捷键", "Keep a shortcut for Paste Selected")
            }
            card.add(SettingsFormRow(title: command.displayName, accessory: recorderAccessory(recorder, clear: clear)))
        }
    }

    /// 清除 = 禁用该命令(pasteSelected 有守卫,解绑被拒时回显默认)
    @objc private func accelCleared(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let command = PanelCommand(rawValue: raw),
              let recorder = accelRecorders[command] else { return }
        PanelAccels.setBinding(nil, for: command)
        if let first = PanelAccels.bindings(for: command).first {
            recorder.display(code: UInt32(first.keyCode), mods: first.carbonModifiers)
        } else {
            recorder.clear()
        }
    }

    // MARK: - 网络同步(原版 Friends 页:接收开关/端口/共享密码/好友表)

    private func buildNetConnectionSection(in card: SettingsFormCard) {
        // 接收开关(默认关:隐私优先;上游 DisableRecieve 的反向开关)
        card.add(switchRow(L10n.setNetReceiveEnabled, isOn: DittoSettings.netReceiveEnabled(),
                           action: #selector(netReceiveToggle(_:))))

        // 端口行(上游 SendRecvPort,默认 23443,Options.cpp:1475)
        let portField = NSTextField()
        portField.identifier = Self.netPortFieldID
        portField.stringValue = String(DittoSettings.netPort())
        portField.bezelStyle = .roundedBezel
        portField.alignment = .right
        portField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        portField.delegate = self
        portField.cell?.truncatesLastVisibleLine = true
        portField.cell?.wraps = false
        portField.translatesAutoresizingMaskIntoConstraints = false
        portField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        card.add(makeRow(L10n.setNetPort, portField))

        // 共享密码行(secure;只落 Keychain,绝不进 UserDefaults)
        let passwordField = NSSecureTextField()
        passwordField.identifier = Self.netPasswordFieldID
        passwordField.stringValue = preview ? "" : (NetSyncKeychain.loadPassword() ?? "")
        passwordField.placeholderString = L10n.t("未设置", "Not set")
        passwordField.bezelStyle = .roundedBezel
        passwordField.font = .systemFont(ofSize: 12)
        passwordField.delegate = self
        passwordField.cell?.truncatesLastVisibleLine = true
        passwordField.cell?.wraps = false
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        passwordField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        card.add(makeRow(L10n.setNetPassword, passwordField))
    }

    private func buildNetFriendsSection(in card: SettingsFormCard) {
        // 好友表(上游 "send clients":名称/主机/端口 三列可编辑)
        netFriends = DittoSettings.loadNetFriends()
        let table = NSTableView()
        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)] = [
            (Self.netFriendNameColumnID, L10n.setNetFriendNameCol, 140),
            (Self.netFriendHostColumnID, L10n.setNetFriendHostCol, 180),
            (Self.netFriendPortColumnID, L10n.setNetFriendPortCol, 70),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.headerCell.stringValue = title
            column.width = width
            column.minWidth = 48
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.autoresizingMask = [.width]
        netFriendsTable = table

        let add = SettingsListBox.barButton(symbol: "plus", label: L10n.t("添加设备", "Add Device"), target: self, action: #selector(netFriendAddClicked(_:)))
        netFriendsAddButton = add
        let remove = SettingsListBox.barButton(symbol: "minus", label: L10n.t("移除所选", "Remove Selected"), target: self, action: #selector(netFriendRemoveClicked(_:)))
        netFriendsRemoveButton = remove
        addListBox(table, to: card, height: 150, buttons: [add, remove],
                   emptySymbol: "desktopcomputer",
                   emptyMessage: L10n.t("使用 + 添加要发送到的设备", "Use + to add a device to send clips to"))
        updateNetFriendsAuxState()
    }

    /// 好友表按钮态:− 需有选中行
    private func updateNetFriendsAuxState() {
        updateTablePlaceholder(netFriendsTable)
        netFriendsRemoveButton.isEnabled = !(netFriendsTable?.selectedRowIndexes.isEmpty ?? true)
    }

    /// 接收开关:通知 AppDelegate 起/停监听
    @objc private func netReceiveToggle(_ sender: NSSwitch) {
        DittoSettings.setNetReceiveEnabled(sender.state == .on)
        notifyChanged()
    }

    @objc private func netFriendAddClicked(_ sender: NSButton) {
        netFriends.append(NetSyncFriend(name: L10n.setNetFriendDefaultName,
                                        host: "192.168.1.2", port: DittoSettings.defaultNetPort))
        DittoSettings.saveNetFriends(netFriends)
        netFriendsTable.reloadData()
        netFriendsTable.scrollRowToVisible(netFriends.count - 1)
        updateNetFriendsAuxState()
    }

    @objc private func netFriendRemoveClicked(_ sender: NSButton) {
        let rows = netFriendsTable.selectedRowIndexes
        guard !rows.isEmpty else { return }
        for row in rows.reversed() where row < netFriends.count {
            netFriends.remove(at: row)
        }
        DittoSettings.saveNetFriends(netFriends)
        netFriendsTable.reloadData()
        updateNetFriendsAuxState()
    }

    // MARK: - 动作

    @objc private func maxItemsChanged(_ sender: NSPopUpButton) {
        if let value = sender.selectedItem?.representedObject as? Int {
            DittoSettings.defaults.set(value, forKey: DittoSettings.maxItemsKey)
            notifyChanged()
        }
    }

    @objc private func maxAgeDaysChanged(_ sender: NSPopUpButton) {
        if let value = sender.selectedItem?.representedObject as? Int {
            DittoSettings.defaults.set(value, forKey: DittoSettings.maxAgeDaysKey)
            notifyChanged()
        }
    }

    @objc private func maxDataBytesChanged(_ sender: NSPopUpButton) {
        if let value = sender.selectedItem?.representedObject as? Int {
            DittoSettings.defaults.set(value, forKey: DittoSettings.maxDataBytesKey)
            notifyChanged()
        }
    }

    @objc private func linesPerRowChanged(_ sender: NSPopUpButton) {
        if let value = sender.selectedItem?.representedObject as? Int {
            DittoSettings.defaults.set(value, forKey: DittoSettings.linesPerRowKey)
            notifyChanged()
        }
    }

    @objc private func positionModeChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String else { return }
        DittoSettings.defaults.set(value, forKey: DittoSettings.positionModeKey)
    }

    /// 组行为开关:主列表显示组内条目(通知面板重查)
    @objc private func includeGroupClipsToggle(_ sender: NSSwitch) {
        DittoSettings.defaults.set(sender.state == .on, forKey: DittoSettings.includeGroupClipsKey)
        notifyChanged()
    }

    /// 组行为开关:新建组时提示输入名称
    @objc private func promptGroupNameToggle(_ sender: NSSwitch) {
        DittoSettings.defaults.set(sender.state == .on, forKey: DittoSettings.promptForGroupNameKey)
    }

    /// 行为开关:删除条目前确认(原版 Prompt to Delete Clip)
    @objc private func promptDeleteToggle(_ sender: NSSwitch) {
        DittoSettings.defaults.set(sender.state == .on, forKey: DittoSettings.promptDeleteKey)
    }

    /// 行为开关:即输即搜(原版 Find As You Type)
    @objc private func findAsYouTypeToggle(_ sender: NSSwitch) {
        DittoSettings.defaults.set(sender.state == .on, forKey: DittoSettings.findAsYouTypeKey)
    }

    /// 行为:排序方向(切换后通知面板重排)
    @objc private func sortOrderChanged(_ sender: NSPopUpButton) {
        guard let latestOnTop = sender.selectedItem?.representedObject as? Bool else { return }
        DittoSettings.defaults.set(latestOnTop, forKey: DittoSettings.orderLatestOnTopKey)
        notifyChanged()
    }

    @objc private func resetHotKey(_ sender: NSButton) {
        DittoSettings.defaults.set(DittoSettings.defaultHotKeyCode, forKey: DittoSettings.hotKeyCodeKey)
        DittoSettings.defaults.set(DittoSettings.defaultHotKeyMods, forKey: DittoSettings.hotKeyModsKey)
        hotKeyRecorder?.display(code: DittoSettings.defaultHotKeyCode,
                                mods: DittoSettings.defaultHotKeyMods)
        notifyChanged()
    }

    @objc private func launchToggleChanged(_ sender: NSSwitch) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // 注册失败(未打包/受限环境):静默回退为实际状态
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    @objc private func openAccessibilitySettings() {
        Permissions.openAccessibilitySettings()
    }

    /// 打开统计窗口(设置「统计…」按钮)
    @objc private func openStats() {
        AppDelegate.shared?.showStats()
    }

    /// 「写调试日志到文件」开关(原版 Write debug to file):即时装配/卸载 FileLog
    @objc private func writeDebugLogToggle(_ sender: NSSwitch) {
        let on = sender.state == .on
        DittoSettings.setWriteDebugLogFile(on)
        FileLog.setEnabled(on, directory: PortableMode.currentLogsDirectory)
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.dlgClearTitle
        alert.informativeText = L10n.dlgClearBody
        alert.addButton(withTitle: L10n.dlgClear)
        alert.addButton(withTitle: L10n.dlgCancel)
        alert.buttons.first?.hasDestructiveAction = true
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.clear(keepingPinned: true)
            self?.notifyChanged()
        }
    }

    // MARK: - 捕获格式 / 排除规则动作

    /// 添加格式:弹出 sheet 枚举当前剪贴板上的格式供勾选,亦可手动输入 UTI
    @objc private func addTypeClicked(_ sender: NSButton) {
        guard let parent = view.window else { return }
        let sheet = AddTypeSheetController()
        addTypeSheetController = sheet
        sheet.onAdd = { [weak self] entries in
            guard let self else { return }
            var changed = false
            for entry in entries where !entry.isEmpty && !self.typesWhitelist.contains(entry) {
                self.typesWhitelist.append(entry)
                changed = true
            }
            if changed { self.persistTypesWhitelist() }
        }
        sheet.onDismiss = { [weak self] in self?.addTypeSheetController = nil }
        sheet.begin(on: parent)
    }

    @objc private func removeTypeClicked(_ sender: NSButton) {
        let rows = typesTable.selectedRowIndexes
        guard !rows.isEmpty else { return }
        let selected = Set(rows.compactMap { $0 < typesWhitelist.count ? typesWhitelist[$0] : nil })
        typesWhitelist.removeAll { selected.contains($0) }
        persistTypesWhitelist()   // 删到空 = 显式记录"什么都不捕获"
    }

    @objc private func addRuleClicked(_ sender: NSButton) {
        guard excludeRules.count < CaptureFilter.maxRules else { return }
        excludeRules.append(ExcludeRule(regex: "", processName: ""))
        DittoSettings.saveExcludeRules(excludeRules)
        rulesTable.reloadData()
        rulesTable.scrollRowToVisible(excludeRules.count - 1)
        updateRulesAuxState()
    }

    @objc private func removeRuleClicked(_ sender: NSButton) {
        let rows = rulesTable.selectedRowIndexes
        guard !rows.isEmpty else { return }
        for row in rows.reversed() where row < excludeRules.count {
            excludeRules.remove(at: row)
        }
        DittoSettings.saveExcludeRules(excludeRules)
        rulesTable.reloadData()
        updateRulesAuxState()
    }

    /// 规则表按钮态:＋到达上限(原版固定 15 槽)置灰并提示;−需有选中行
    private func updateRulesAuxState() {
        updateTablePlaceholder(rulesTable)
        let atCap = excludeRules.count >= CaptureFilter.maxRules
        ruleAddButton.isEnabled = !atCap
        rulesMaxHint.isHidden = !atCap
        ruleRemoveButton.isEnabled = !rulesTable.selectedRowIndexes.isEmpty
    }

    // MARK: - 状态

    private func updateTablePlaceholder(_ table: NSTableView?) {
        guard let table else { return }
        listBoxes[ObjectIdentifier(table)]?.updatePlaceholder()
    }

    private func refreshDynamicStates() {
        refreshAppearanceControls()
        // 辅助功能权限:图标 + 文案同时表达状态,不只依赖颜色
        let granted = preview || Permissions.isAccessibilityGranted
        accessibilityStatusField?.stringValue = granted ? L10n.setGranted : L10n.setNotGranted
        accessibilityStatusIcon?.image = NSImage(systemSymbolName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                                 accessibilityDescription: nil)
        accessibilityStatusIcon?.contentTintColor = granted ? .systemGreen : .systemOrange
        // 便携模式无"登录时启动"行(launchSwitch 未建)
        if let launchSwitch {
            launchSwitch.state = !preview && SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
    }

    private func intSetting(_ key: String, default defaultValue: Int) -> Int {
        (DittoSettings.defaults.object(forKey: key) as? NSNumber)?.intValue ?? defaultValue
    }
}

// MARK: - 白名单 / 排除规则表的数据源与委托(按表格身份分发)

extension SettingsViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === typesTable { return typesWhitelist.count }
        if tableView === appKeysTable { return appKeyEntries.count }
        if tableView === netFriendsTable { return netFriends.count }
        return excludeRules.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // 白名单表:等宽只读 UTI;规则/应用按键串/好友表:可编辑单元格(编辑结束走 controlTextDidEndEditing)
        if tableView === typesTable {
            guard row >= 0, row < typesWhitelist.count else { return nil }
            let label = NSTextField(labelWithString: typesWhitelist[row])
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.lineBreakMode = .byTruncatingTail
            return SettingsTableCell(label)
        }
        if tableView === appKeysTable {
            guard row >= 0, row < appKeyEntries.count, let column = tableColumn else { return nil }
            let field = NSTextField()
            field.isBordered = false
            field.drawsBackground = false
            field.font = .systemFont(ofSize: 12)
            field.identifier = column.identifier
            field.cell?.isScrollable = true
            field.cell?.truncatesLastVisibleLine = true
            field.cell?.wraps = false
            field.delegate = self
            let entry = appKeyEntries[row]
            switch column.identifier {
            case Self.appKeysPatternColumnID: field.stringValue = entry.appPattern
            case Self.appKeysPasteColumnID: field.stringValue = entry.pasteString
            case Self.appKeysCopyColumnID: field.stringValue = entry.copyString
            case Self.appKeysCutColumnID: field.stringValue = entry.cutString
            default: break
            }
            return SettingsTableCell(field)
        }
        if tableView === netFriendsTable {
            guard row >= 0, row < netFriends.count, let column = tableColumn else { return nil }
            let field = NSTextField()
            field.isBordered = false
            field.drawsBackground = false
            field.font = .systemFont(ofSize: 12)
            field.identifier = column.identifier
            field.cell?.isScrollable = true
            field.cell?.truncatesLastVisibleLine = true
            field.cell?.wraps = false
            field.delegate = self
            let friend = netFriends[row]
            switch column.identifier {
            case Self.netFriendNameColumnID: field.stringValue = friend.name
            case Self.netFriendHostColumnID: field.stringValue = friend.host
            case Self.netFriendPortColumnID: field.stringValue = String(friend.port)
            default: break
            }
            return SettingsTableCell(field)
        }
        guard row >= 0, row < excludeRules.count, let column = tableColumn else { return nil }
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 12)
        field.identifier = column.identifier
        field.cell?.isScrollable = true
        field.cell?.truncatesLastVisibleLine = true
        field.cell?.wraps = false
        field.delegate = self
        field.stringValue = (column.identifier == Self.ruleRegexColumnID)
            ? excludeRules[row].regex : excludeRules[row].processName
        return SettingsTableCell(field)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === typesTable {
            typesRemoveButton.isEnabled = !table.selectedRowIndexes.isEmpty && !typesWhitelist.isEmpty
        } else if table === rulesTable {
            ruleRemoveButton.isEnabled = !table.selectedRowIndexes.isEmpty
        } else if table === appKeysTable {
            appKeysRemoveButton.isEnabled = !table.selectedRowIndexes.isEmpty
        } else if table === netFriendsTable {
            netFriendsRemoveButton.isEnabled = !table.selectedRowIndexes.isEmpty
        }
    }
}

// MARK: - 输入框编辑结束(应用列表 / 规则单元格共用)

extension SettingsViewController: NSTextFieldDelegate {

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        switch field.identifier {
        case Self.appIncludeFieldID:
            DittoSettings.setAppInclude(field.stringValue)
        case Self.appExcludeFieldID:
            DittoSettings.setAppExclude(field.stringValue)
        case Self.netPortFieldID:
            // 端口:非法/越界回落当前生效值(1...65535)
            let port = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? -1
            guard (1...65535).contains(port) else {
                field.stringValue = String(DittoSettings.netPort())
                return
            }
            DittoSettings.setNetPort(port)
            field.stringValue = String(DittoSettings.netPort())
            notifyChanged()   // AppDelegate 重启监听
        case Self.netPasswordFieldID:
            // 密码:空 = 清除(回明文);非空 = 落 Keychain(绝不进 UserDefaults)
            let value = field.stringValue
            if value.isEmpty {
                NetSyncKeychain.deletePassword()
            } else {
                NetSyncKeychain.savePassword(value)
            }
            notifyChanged()   // 监听端解密密钥随密码变更
        case Self.netFriendNameColumnID, Self.netFriendHostColumnID, Self.netFriendPortColumnID:
            let row = netFriendsTable.row(for: field)
            guard row >= 0, row < netFriends.count else { return }
            switch field.identifier {
            case Self.netFriendNameColumnID:
                netFriends[row].name = field.stringValue
            case Self.netFriendHostColumnID:
                netFriends[row].host = field.stringValue.trimmingCharacters(in: .whitespaces)
            case Self.netFriendPortColumnID:
                let port = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? -1
                if (1...65535).contains(port) {
                    netFriends[row].port = port
                } else {
                    field.stringValue = String(netFriends[row].port)   // 非法回落
                }
            default: break
            }
            DittoSettings.saveNetFriends(netFriends)
        case Self.appKeysPatternColumnID, Self.appKeysPasteColumnID,
             Self.appKeysCopyColumnID, Self.appKeysCutColumnID:
            let row = appKeysTable.row(for: field)
            guard row >= 0, row < appKeyEntries.count else { return }
            switch field.identifier {
            case Self.appKeysPatternColumnID: appKeyEntries[row].appPattern = field.stringValue
            case Self.appKeysPasteColumnID: appKeyEntries[row].pasteString = field.stringValue
            case Self.appKeysCopyColumnID: appKeyEntries[row].copyString = field.stringValue
            case Self.appKeysCutColumnID: appKeyEntries[row].cutString = field.stringValue
            default: break
            }
            AppKeyStrings.save(appKeyEntries, defaults: DittoSettings.defaults)   // 粘贴/复制/剪切路径每次现读,保存即生效
        case Self.ruleRegexColumnID, Self.ruleProcessColumnID:
            let row = rulesTable.row(for: field)
            guard row >= 0, row < excludeRules.count else { return }
            if field.identifier == Self.ruleRegexColumnID {
                excludeRules[row].regex = field.stringValue
            } else {
                excludeRules[row].processName = field.stringValue
            }
            DittoSettings.saveExcludeRules(excludeRules)
        default:
            break
        }
    }
}
