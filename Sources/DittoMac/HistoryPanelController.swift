import AppKit
import Carbon.HIToolbox
import DittoMacKit

// MARK: - 主题色(macOS 原生语义色,自动适配深浅色;主题应用时被上游 XML 值覆盖)

enum DittoTheme {
    static var borderColor = NSColor.separatorColor
    static var listBackground = NSColor.windowBackgroundColor
    static var captionBackground = NSColor.windowBackgroundColor
    static var captionText = NSColor.secondaryLabelColor
    static var textColor = NSColor.labelColor
    static var pastedBar = NSColor.controlAccentColor      // 已粘贴指示(原版可随系统强调色)
    static var searchHighlight = NSColor.systemRed
    static var topTenNumber = NSColor.tertiaryLabelColor
    static var timeText = NSColor.secondaryLabelColor

    // ---- 主题扩展字段(上游 Theme.xml 的对应项;跟随系统时保持语义色/等价默认)----
    /// 主窗口底色(主区工具行一带;上游 MainWindowBG)
    static var windowBackground = NSColor.windowBackgroundColor
    /// 偶数行底色/文字(上游 ListBoxEvenRows*;非主题时系统交替行绘制,不使用)
    static var listBackgroundEven = NSColor.windowBackgroundColor
    static var textColorEven = NSColor.labelColor
    /// 选中态(有焦点/无焦点;上游 ListBoxSelected* / ListBoxSelectedNoFocus*)
    static var selectedBackground = NSColor.controlAccentColor
    static var selectedText = NSColor.alternateSelectedControlTextColor
    static var selectedNoFocusBackground = NSColor.unemphasizedSelectedContentBackgroundColor
    static var selectedNoFocusText = NSColor.unemphasizedSelectedTextColor
    /// 标题栏渐变两端与变体(上游 CaptionLeft/Right + TopMost/NotConnected;
    /// nil = 平涂 captionBackground —— 跟随系统时的形态)
    static var captionGradient: (NSColor, NSColor)?
    static var captionGradientTopMost: (NSColor, NSColor)?
    static var captionGradientNotConnected: (NSColor, NSColor)?
    /// 标题栏变体底色(平涂;非主题时断开 = 原版黄,置顶 = 同 captionBackground)
    static var captionBackgroundTopMost = NSColor.windowBackgroundColor
    static var captionBackgroundNotConnected = NSColor(red: 1, green: 1, blue: 0, alpha: 0.9)
    /// 边框变体(上游 BorderTopMost / BorderNotConnected)
    static var borderTopMost = NSColor.separatorColor
    static var borderNotConnected = NSColor.separatorColor
    /// 组树(上游 GroupTree*)
    static var groupTreeBackground = NSColor.windowBackgroundColor
    static var groupTreeText = NSColor.labelColor
    /// 悬停浮窗(上游 DescriptionWindow*)
    static var hoverTipBackground = NSColor.windowBackgroundColor
    static var hoverTipText = NSColor.labelColor
    /// 标题栏厚度/标题字号(上游 CaptionSize / CaptionFontSize;单位 pt)
    static var captionWidth: CGFloat = 25
    static var captionFontSize: CGFloat = 19
    /// 是否处于主题应用态(行背景/选中改为自绘)
    static var isThemed = false

    /// 语义色本身随外观动态解析,无需按明暗切换(保留入口以兼容调用点)
    static func adjusted() {}

    /// 应用主题(仅覆盖出现的字段;未含字段保持跟随系统值 —— 上游 LoadDefaults+覆盖语义)
    static func apply(_ theme: DittoThemeFile) {
        isThemed = true
        func color(_ rgb: ThemeRGB) -> NSColor {
            NSColor(srgbRed: CGFloat(rgb.red) / 255,
                    green: CGFloat(rgb.green) / 255,
                    blue: CGFloat(rgb.blue) / 255, alpha: 1)
        }
        if let v = theme.border { borderColor = color(v) }
        if let v = theme.borderTopMost { borderTopMost = color(v) }
        if let v = theme.borderNotConnected { borderNotConnected = color(v) }
        if let v = theme.mainWindowBG { windowBackground = color(v) }
        if let v = theme.listBoxOddRowsBG { listBackground = color(v) }
        if let v = theme.listBoxEvenRowsBG { listBackgroundEven = color(v) }
        if let v = theme.listBoxOddRowsText { textColor = color(v) }
        if let v = theme.listBoxEvenRowsText { textColorEven = color(v) }
        if let v = theme.listBoxSelectedBG { selectedBackground = color(v) }
        if let v = theme.listBoxSelectedText { selectedText = color(v) }
        if let v = theme.listBoxSelectedNoFocusBG { selectedNoFocusBackground = color(v) }
        if let v = theme.listBoxSelectedNoFocusText { selectedNoFocusText = color(v) }
        if let l = theme.captionLeft, let r = theme.captionRight {
            captionGradient = (color(l), color(r))
            captionBackground = color(l)
        } else if let l = theme.captionLeft {
            captionBackground = color(l)
        }
        if let l = theme.captionLeftTopMost, let r = theme.captionRightTopMost {
            captionGradientTopMost = (color(l), color(r))
            captionBackgroundTopMost = color(l)
        }
        if let l = theme.captionLeftNotConnected, let r = theme.captionRightNotConnected {
            captionGradientNotConnected = (color(l), color(r))
            captionBackgroundNotConnected = color(l)
        }
        if let v = theme.captionTextColor { captionText = color(v) }
        if let v = theme.groupTreeBG { groupTreeBackground = color(v) }
        if let v = theme.groupTreeText { groupTreeText = color(v) }
        if let v = theme.descriptionWindowBG { hoverTipBackground = color(v) }
        if let v = theme.descriptionWindowText { hoverTipText = color(v) }
        if let v = theme.captionSize { captionWidth = CGFloat(min(max(v, 16), 60)) }
        if let v = theme.captionFontSize { captionFontSize = CGFloat(min(max(v, 9), 40)) }
    }

    /// 恢复跟随系统(全部字段回到默认;与初始值一一对应)
    static func resetToSystem() {
        borderColor = .separatorColor
        listBackground = .windowBackgroundColor
        captionBackground = .windowBackgroundColor
        captionText = .secondaryLabelColor
        textColor = .labelColor
        pastedBar = .controlAccentColor
        searchHighlight = .systemRed
        topTenNumber = .tertiaryLabelColor
        timeText = .secondaryLabelColor
        windowBackground = .windowBackgroundColor
        listBackgroundEven = .windowBackgroundColor
        textColorEven = .labelColor
        selectedBackground = .controlAccentColor
        selectedText = .alternateSelectedControlTextColor
        selectedNoFocusBackground = .unemphasizedSelectedContentBackgroundColor
        selectedNoFocusText = .unemphasizedSelectedTextColor
        captionGradient = nil
        captionGradientTopMost = nil
        captionGradientNotConnected = nil
        captionBackgroundTopMost = .windowBackgroundColor
        captionBackgroundNotConnected = NSColor(red: 1, green: 1, blue: 0, alpha: 0.9)
        borderTopMost = .separatorColor
        borderNotConnected = .separatorColor
        groupTreeBackground = .windowBackgroundColor
        groupTreeText = .labelColor
        hoverTipBackground = .windowBackgroundColor
        hoverTipText = .labelColor
        captionWidth = 25
        captionFontSize = 19
        isThemed = false
    }

    /// ThemeRGB 三元组 → sRGB 颜色(应用层便捷入口)
    static func color(from rgb: ThemeRGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red) / 255,
                green: CGFloat(rgb.green) / 255,
                blue: CGFloat(rgb.blue) / 255, alpha: 1)
    }
}

// MARK: - 标题栏(原版 caption:25px、竖排文字 + 四按钮;支持 上/右/下/左 四向,
// 上游 DittoWindow.cpp:38-167 按 CAPTION_TOP/RIGHT/BOTTOM/LEFT 分支绘制)

final class CaptionView: NSView {
    var onClose: (() -> Void)?
    var onRoll: (() -> Void)?
    var onMaximize: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    /// 标题动态后缀(原版 §7:"ditto-mac [置顶] ... - 选中/总数")
    var titleText = "ditto-mac" { didSet { needsDisplay = true } }
    /// 剪贴板断开(=暂停记录)时标题区变黄(原版 Disconnected 态;主题化后用主题断变色)
    var disconnected = false { didSet { needsDisplay = true; superview?.needsDisplay = true } }
    /// 常驻置顶(原版 TopMost 变体:标题栏/边框用 *TopMost 颜色)
    var isTopMost = false { didSet { needsDisplay = true; superview?.needsDisplay = true } }
    /// 标题栏停靠边(默认右 = 既有布局;切换由 PanelRootView 驱动)
    var position: CaptionPosition = .right { didSet { needsDisplay = true } }

    private var captionWidth: CGFloat { DittoTheme.captionWidth }
    private let buttonSize: CGFloat = 16
    private var rollUp = false
    /// 按钮区总长(4 钮:4/28/60/92,16px)——标题文字锚在其后
    private static let buttonAreaLength: CGFloat = 112

    /// 停靠边是否竖排(左右 = 竖排,上下 = 横排;对齐原版 VertFont/HorFont)
    private var isVertical: Bool { position == .left || position == .right }

    override var isFlipped: Bool { true }   // 全视图统一"自顶向下"坐标系,绘制与命中共用

    func setRolled(_ rolled: Bool) {
        rollUp = rolled
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        _ = DittoTheme.adjusted()
        bounds.fill()   // 先铺底,避免渐变缺字段时透出主区

        // ---- 背景:主题 = CaptionLeft→CaptionRight 渐变(含 TopMost/NotConnected
        // 变体);跟随系统 = 平涂语义色(断开 = 原版黄)----
        if DittoTheme.isThemed {
            var gradient: (NSColor, NSColor)?
            var flat: NSColor?
            if disconnected {
                gradient = DittoTheme.captionGradientNotConnected
                flat = DittoTheme.captionBackgroundNotConnected
            } else if isTopMost {
                gradient = DittoTheme.captionGradientTopMost
                flat = DittoTheme.captionBackgroundTopMost
            } else {
                gradient = DittoTheme.captionGradient
                flat = DittoTheme.captionBackground
            }
            let angle: CGFloat = isVertical ? 0 : 90   // 左右停靠:横向渐变;上下:纵向
            if let (a, b) = gradient, let g = NSGradient(starting: a, ending: b) {
                g.draw(in: bounds, angle: angle)
            } else if let flat {
                flat.setFill()
                bounds.fill()
            }
        } else {
            let fill: NSColor = disconnected
                ? DittoTheme.captionBackgroundNotConnected   // 未主题化 = 原版黄
                : DittoTheme.captionBackground
            fill.setFill()
            bounds.fill()
        }

        // ---- 与主区之间的发丝分隔线(位置随停靠边)----
        DittoTheme.borderColor.setFill()
        separatorRect().fill()

        // ---- 四枚 16px 按钮:关闭/折叠/最大化/最小化(间距 24/32/32,原版
        // DittoWindow.cpp:269-318;竖排自顶向下,横排自左向右)----
        drawButton(kind: .close, offset: 4)
        drawButton(kind: .roll, offset: 28)
        drawButton(kind: .max, offset: 60)
        drawButton(kind: .min, offset: 92)

        // ---- 标题:锚在按钮区之后(竖排旋转 90°/270°,横排水平)----
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let text = NSAttributedString(string: titleText, attributes: [
            .font: NSFont.systemFont(ofSize: DittoTheme.captionFontSize),
            .foregroundColor: DittoTheme.captionText,
        ])
        let size = text.size()
        if isVertical {
            ctx.saveGState()
            if position == .right {
                ctx.translateBy(x: bounds.width - captionWidth / 2, y: Self.buttonAreaLength + 10)
                ctx.rotate(by: .pi / 2)   // 自上而下读
                text.draw(at: NSPoint(x: 0, y: -size.height / 2 + 4))
            } else {
                ctx.translateBy(x: captionWidth / 2, y: bounds.height - 10)
                ctx.rotate(by: -.pi / 2)  // 自下而上读
                text.draw(at: NSPoint(x: 0, y: -size.height / 2 + 4))
            }
            ctx.restoreGState()
        } else {
            let y = position == .top
                ? (bounds.height - captionWidth + captionWidth / 2 - size.height / 2)
                : (captionWidth / 2 - size.height / 2)
            text.draw(at: NSPoint(x: Self.buttonAreaLength + 12, y: max(2, y)))
        }
    }

    /// 分隔线矩形(停靠边内侧 1px)
    private func separatorRect() -> NSRect {
        switch position {
        case .right: return NSRect(x: bounds.width - captionWidth, y: 0, width: 1, height: bounds.height)
        case .left: return NSRect(x: captionWidth - 1, y: 0, width: 1, height: bounds.height)
        case .top: return NSRect(x: 0, y: bounds.height - captionWidth, width: bounds.width, height: 1)
        case .bottom: return NSRect(x: 0, y: captionWidth - 1, width: bounds.width, height: 1)
        }
    }

    private enum CaptionButton { case close, roll, max, min }

    /// 按钮矩形(offset 沿按钮排布轴:竖排 = 距顶,横排 = 距左)
    private func buttonRect(offset: CGFloat) -> NSRect {
        if isVertical {
            return NSRect(x: (captionWidth - buttonSize) / 2 + (position == .right ? bounds.width - captionWidth : 0),
                          y: offset, width: buttonSize, height: buttonSize)
        }
        let y = position == .top ? bounds.height - captionWidth + (captionWidth - buttonSize) / 2
                                 : (captionWidth - buttonSize) / 2
        return NSRect(x: offset, y: y, width: buttonSize, height: buttonSize)
    }

    private func drawButton(kind: CaptionButton, offset: CGFloat) {
        let rect = buttonRect(offset: offset)
        let p = NSBezierPath()
        p.lineWidth = 1.2
        DittoTheme.captionText.setStroke()
        switch kind {
        case .close:
            p.move(to: NSPoint(x: rect.minX + 4, y: rect.minY + 4))
            p.line(to: NSPoint(x: rect.maxX - 4, y: rect.maxY - 4))
            p.move(to: NSPoint(x: rect.maxX - 4, y: rect.minY + 4))
            p.line(to: NSPoint(x: rect.minX + 4, y: rect.maxY - 4))
        case .roll:
            let midX = rect.midX
            if rollUp {
                p.move(to: NSPoint(x: midX - 5, y: rect.midY + 2))
                p.line(to: NSPoint(x: midX, y: rect.midY - 3))
                p.line(to: NSPoint(x: midX + 5, y: rect.midY + 2))
            } else {
                p.move(to: NSPoint(x: midX - 5, y: rect.midY - 2))
                p.line(to: NSPoint(x: midX, y: rect.midY + 3))
                p.line(to: NSPoint(x: midX + 5, y: rect.midY - 2))
            }
        case .max:
            p.append(NSBezierPath(rect: rect.insetBy(dx: 4, dy: 4)))
        case .min:
            p.move(to: NSPoint(x: rect.minX + 4, y: rect.midY))
            p.line(to: NSPoint(x: rect.maxX - 4, y: rect.midY))
        }
        p.stroke()
    }

    /// 点是否在标题栏条内
    private func inCaption(_ point: NSPoint) -> Bool {
        switch position {
        case .right: return point.x >= bounds.width - captionWidth
        case .left: return point.x <= captionWidth
        case .top: return point.y >= bounds.height - captionWidth
        case .bottom: return point.y <= captionWidth
        }
    }

    /// 点沿按钮轴的坐标(竖排 = y,横排 = x)
    private var buttonAxis: (NSPoint) -> CGFloat {
        isVertical ? { $0.y } : { $0.x }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard inCaption(point) else { return }
        let along = buttonAxis(point)
        if rollUp {
            // 折叠态:整条 caption 点击=展开(必须有 UI 出口,原版点击标题条恢复)
            if event.clickCount == 2 || along <= 24 { onRoll?() }
            return
        }
        switch along {
        case ..<24: onClose?()
        case ..<48: onRoll?()
        case ..<80: onMaximize?()
        case ..<112: onMinimize?()
        default:
            if event.clickCount == 2 { onDoubleClick?() }   // 双击空白标题区=折叠
        }
    }

    override func mouseDragged(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - 面板(无边框、方形发丝边框,原版 WS_POPUP + Draw3dRect)

final class DittoPanel: NSPanel {
    /// 窗口级按键拦截(Esc);返回 true 表示已消费
    var escapeHandler: (() -> Void)?
    var forceHideHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        escapeHandler?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // 关窗/强关走命令注册表(默认 closeWindow=Esc / forceClose=⇧Esc,与原实现一致;
        // 用户重绑后此处跟随注册表)
        if event.type == .keyDown,
           let command = PanelAccels.command(
               forKeyCode: event.keyCode,
               carbonModifiers: DittoSettings.carbonMask(from: event.modifierFlags)) {
            switch command {
            case .closeWindow:
                escapeHandler?()
                return true
            case .forceClose:
                forceHideHandler?()
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 主区背景(工具行一带底色 = 上游 MainWindowBG;列表区由表格覆盖)
final class PanelMainAreaView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        DittoTheme.windowBackground.setFill()
        bounds.fill()
    }
}

/// 面板根视图:画 1px 边框 + 布局 主区/标题栏(上/右/下/左四向,约束驱动)
/// + 边缘拖拽缩放(无边框窗需自实现)
final class PanelRootView: NSView {
    let caption = CaptionView()
    let mainArea = PanelMainAreaView()
    private static let edge: CGFloat = 5
    /// 标题栏位置(变化时约束整体重建;对齐原版 View Caption Bar On *)
    var captionPosition: CaptionPosition = .right {
        didSet {
            guard captionPosition != oldValue else { return }
            relayout()
        }
    }
    private var layoutConstraints: [NSLayoutConstraint] = []
    /// 标题栏厚度约束(主题 CaptionSize 变化时改常量,无需重建)
    private var captionThicknessConstraint: NSLayoutConstraint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        caption.translatesAutoresizingMaskIntoConstraints = false
        mainArea.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainArea)
        addSubview(caption)
        relayout()
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    /// 按停靠边重建主区/标题栏约束(1px 边框内衬保持不变)
    func relayout() {
        NSLayoutConstraint.deactivate(layoutConstraints)
        layoutConstraints.removeAll()
        if let thicknessConstraint = captionThicknessConstraint {
            NSLayoutConstraint.deactivate([thicknessConstraint])
        }

        var cs: [NSLayoutConstraint] = []
        let thickness: NSLayoutConstraint
        switch captionPosition {
        case .right:
            cs = [
                mainArea.topAnchor.constraint(equalTo: topAnchor, constant: 1),
                mainArea.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
                mainArea.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
                mainArea.trailingAnchor.constraint(equalTo: caption.leadingAnchor),
                caption.topAnchor.constraint(equalTo: topAnchor, constant: 1),
                caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
                caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            ]
            thickness = caption.widthAnchor.constraint(equalToConstant: DittoTheme.captionWidth)
        case .left:
            cs = [
                mainArea.topAnchor.constraint(equalTo: topAnchor, constant: 1),
                mainArea.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
                mainArea.leadingAnchor.constraint(equalTo: caption.trailingAnchor),
                mainArea.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
                caption.topAnchor.constraint(equalTo: topAnchor, constant: 1),
                caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
                caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            ]
            thickness = caption.widthAnchor.constraint(equalToConstant: DittoTheme.captionWidth)
        case .top:
            cs = [
                mainArea.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
                mainArea.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
                mainArea.topAnchor.constraint(equalTo: caption.bottomAnchor),
                mainArea.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
                caption.topAnchor.constraint(equalTo: topAnchor, constant: 1),
                caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
                caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            ]
            thickness = caption.heightAnchor.constraint(equalToConstant: DittoTheme.captionWidth)
        case .bottom:
            cs = [
                mainArea.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
                mainArea.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
                mainArea.topAnchor.constraint(equalTo: topAnchor, constant: 1),
                mainArea.bottomAnchor.constraint(equalTo: caption.topAnchor),
                caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
                caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
                caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            ]
            thickness = caption.heightAnchor.constraint(equalToConstant: DittoTheme.captionWidth)
        }
        cs.append(thickness)
        captionThicknessConstraint = thickness
        layoutConstraints = cs
        NSLayoutConstraint.activate(cs)
        caption.position = captionPosition
        needsLayout = true
        needsDisplay = true
    }

    /// 主题 CaptionSize 变化:只改厚度常量
    func refreshCaptionThickness() {
        captionThicknessConstraint?.constant = DittoTheme.captionWidth
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveBorderColor.setFill()
        bounds.fill()
    }

    /// 边框色:主题化时随 置顶/断开 变体(上游 BorderTopMost/BorderNotConnected)
    private var effectiveBorderColor: NSColor {
        guard DittoTheme.isThemed else { return DittoTheme.borderColor }
        if caption.disconnected { return DittoTheme.borderNotConnected }
        if caption.isTopMost { return DittoTheme.borderTopMost }
        return DittoTheme.borderColor
    }

    // MARK: 边缘缩放(原版无边框窗四周可拖)

    private enum Zone { case none, l, r, t, b, tl, tr, bl, br }

    private func zone(at point: NSPoint) -> Zone {
        let e = Self.edge
        let left = point.x <= e, right = point.x >= bounds.width - e
        let top = point.y >= bounds.height - e, bottom = point.y <= e
        switch (left, right, top, bottom) {
        case (true, false, false, false): return .l
        case (false, true, false, false): return .r
        case (false, false, true, false): return .t
        case (false, false, false, true): return .b
        case (true, false, true, false): return .tl
        case (false, true, true, false): return .tr
        case (true, false, false, true): return .bl
        case (false, true, false, true): return .br
        default: return .none
        }
    }

    override func resetCursorRects() {
        switch zone(at: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)) {
        case .l, .r: addCursorRect(bounds, cursor: .resizeLeftRight)
        case .t, .b: addCursorRect(bounds, cursor: .resizeUpDown)
        default: break
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        let z = zone(at: point)
        guard z != .none else { super.mouseDown(with: event); return }
        let startFrame = window.frame
        let start = NSEvent.mouseLocation
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            guard e.type == .leftMouseDragged else { break }
            let now = NSEvent.mouseLocation
            var f = startFrame
            let dx = now.x - start.x, dy = now.y - start.y
            if z == .l || z == .tl || z == .bl {
                f.origin.x = startFrame.minX + dx
                f.size.width = startFrame.width - dx
            }
            if z == .r || z == .tr || z == .br {
                f.size.width = startFrame.width + dx
            }
            if z == .b || z == .bl || z == .br {
                f.origin.y = startFrame.minY + dy
                f.size.height = startFrame.height - dy
            }
            if z == .t || z == .tl || z == .tr {
                f.size.height = startFrame.height + dy
            }
            if f.width >= window.minSize.width {
                window.setFrame(f, display: true)
            } else {
                var fixed = f
                fixed.size.width = window.minSize.width
                window.setFrame(fixed, display: true)
            }
        }
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
    }
}

// MARK: - 面板控制器

final class HistoryPanelController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {

    private static let frameKey = "panelFrame"

    let store: ClipStoring
    let listViewController: ClipListViewController
    private let rootView = PanelRootView()
    private let searchField = PanelSearchField()
    private var rolledFrame: NSRect?
    private var normalFrame: NSRect?
    private var isRolled = false
    private var isPersistent = false   // 常驻置顶(原版 ShowPersistent / Ctrl+Space)
    private var pendingAutoHide: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    /// 描述浮窗(F3 / 查看完整描述,原版 tooltip 等价)
    private var descTooltip: NSPanel?
    /// 临时关闭失焦隐藏(选菜单/拖窗口期间)
    private var suspendAutoHide = false
    /// 当前所在组(-1 = 顶层;仅会话内有效,关面板即回顶层 —— 原版隐藏窗口
    /// 时 m_GroupID 复位,下次打开回到主列表)
    private(set) var currentParentID: Int64 = -1
    /// 组树覆盖层(⌃G):NSOutlineView 停靠在主区左缘
    private var groupTreeContainer: NSView?
    private var groupTreeOutline: NSOutlineView?
    private var treeHeader: NSTextField?
    /// 组树节点(每次展开重建,轻量)
    private final class GroupNode {
        let id: Int64
        let title: String
        var children: [GroupNode]
        init(id: Int64, title: String, children: [GroupNode]) {
            self.id = id
            self.title = title
            self.children = children
        }
    }
    private var groupTreeRoots: [GroupNode] = []

    var isOnScreen: Bool { window?.isVisible == true }
    var isPersistentMode: Bool { isPersistent }
    var isGroupTreeVisible: Bool { groupTreeContainer?.isHidden == false }

    init(store: ClipStoring) {
        self.store = store
        let list = ClipListViewController(store: store)
        self.listViewController = list

        let panel = DittoPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),   // 原版默认 300×300
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false)
        super.init(window: panel)

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = NSSize(width: 160, height: 120)
        panel.delegate = self

        buildContent(in: rootView)
        panel.contentView = rootView
        panel.escapeHandler = { [weak self] in self?.escapePressed() }
        panel.forceHideHandler = { [weak self] in self?.hide() }
        rootView.caption.onClose = { [weak self] in self?.hide() }
        rootView.caption.onMinimize = { [weak self] in self?.hide() }
        rootView.caption.onRoll = { [weak self] in self?.toggleRollUp() }
        rootView.caption.onMaximize = { [weak self] in self?.toggleMaximize() }
        rootView.caption.onDoubleClick = { [weak self] in self?.toggleRollUp() }

        restoreFrame()

        // 列表 → 粘贴流程
        list.onPaste = { [weak self] items in self?.paste(items: items, mode: .normal) }
        list.onPastePlainText = { [weak self] items in self?.paste(items: items, mode: .plainText) }
        list.onPasteDontReorder = { [weak self] items in self?.paste(items: items, mode: .dontReorder) }
        list.onTransformedPaste = { [weak self] item, t in self?.paste(items: [item], mode: .transform(t)) }
        list.onComposeImagesPaste = { [weak self] items, horizontal in
            guard let self else { return }
            let payloads = items.compactMap { self.store.payload(id: $0.id) }
            if let composed = SpecialPaste.composeImages(payloads, horizontal: horizontal) {
                self.hide()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    if Permissions.isAccessibilityGranted {
                        _ = PasteBack.paste(composed, monitor: ClipboardMonitor.shared)
                    } else {
                        PasteBack.write(composed, monitor: ClipboardMonitor.shared)
                        AppDelegate.shared?.promptAccessibilityForPaste()
                    }
                }
            }
        }
        list.onShowProperties = { [weak self] item in self?.showProperties(item: item) }
        list.onSelectionChange = { [weak self] in self?.updateCaptionSuffix() }
        list.onTypeAhead = { [weak self] ch in self?.typeAhead(char: ch) }
        list.onHoverRow = { [weak self] item, rowScreenRect in
            self?.handleHover(item: item, rowScreenRect: rowScreenRect)
        }
        // 组导航/组树(原版 Enter 进组、Backspace 回上级、⌃G 组树)
        list.onEnterGroup = { [weak self] id in self?.enterGroup(id: id) }
        list.onGoToParent = { [weak self] in self?.goToParent() }
        list.onToggleGroupTree = { [weak self] in self?.toggleGroupTree() }
        // 窗口级命令(命令注册表绑定:关窗/强关/折叠/最大化)
        list.onWindowCommand = { [weak self] command in
            self?.handleWindowCommand(command) ?? false
        }
        // 编辑条目 / 对比条目(原版 Edit Clip 2.7.8 / Compare 2.7.14)
        list.onEditClip = { [weak self] item in
            guard let self else { return }
            self.suspendAutoHide = true
            let controller = AppDelegate.shared?.showClipEditor(clip: item)
            self.observeAuxWindowClose(controller?.window)
        }
        list.onCompareClips = { [weak self] left, right in
            guard let self else { return }
            self.suspendAutoHide = true
            let controller = AppDelegate.shared?.showCompareClips(left, right)
            self.observeAuxWindowClose(controller?.window)
        }

        // 应用失活 → 延迟复核隐藏(原版 OnActivate WA_INACTIVE)
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleAutoHideCheck()
        })
        // 暂停记录(原版"断开剪贴板")→ 标题区变黄
        observers.append(NotificationCenter.default.addObserver(
            forName: .dittoPausedChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.rootView.caption.disconnected = DittoSettings.defaults.bool(forKey: DittoSettings.pausedKey)
        })
        // 外观类设置(主题/标题栏位置/透明度/字体/行高/描述行)→ 即时重应用
        observers.append(NotificationCenter.default.addObserver(
            forName: .dittoSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyAppearanceSettings()
        })

        // 启动时应用外观(主题/标题栏位置/透明度)
        applyAppearanceSettings()
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - 布局(原版 §1:列表 + 底部 33px 工具行)

    private func buildContent(in root: PanelRootView) {
        updateSearchPlaceholder()   // 占位提示含搜索方式/范围状态前缀
        searchField.delegate = self

        // 底部工具行:左 = 搜索历史按钮(原版文件夹钮位置,映射 ⌘↓ 历史),
        // 中 = 搜索框 @(34, 高 25),右 = 系统菜单钮 @(cx-30)
        let historyButton = NSButton(image: NSImage(systemSymbolName: "clock",
                                                     accessibilityDescription: "搜索历史")!,
                                     target: self, action: #selector(showSearchHistory))
        historyButton.bezelStyle = .regularSquare
        historyButton.isBordered = false
        let systemButton = NSButton(image: NSImage(systemSymbolName: "line.3.horizontal",
                                                   accessibilityDescription: "系统菜单")!,
                                    target: self, action: #selector(showSystemMenu))
        systemButton.bezelStyle = .regularSquare
        systemButton.isBordered = false

        let listView = listViewController.view
        for v in [listView, searchField, historyButton, systemButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.mainArea.addSubview(v)
        }
        rootView.caption.disconnected = DittoSettings.defaults.bool(forKey: DittoSettings.pausedKey)

        NSLayoutConstraint.activate([
            listView.topAnchor.constraint(equalTo: root.mainArea.topAnchor),
            listView.leadingAnchor.constraint(equalTo: root.mainArea.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: root.mainArea.trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: root.mainArea.bottomAnchor, constant: -33),

            searchField.centerYAnchor.constraint(equalTo: historyButton.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: root.mainArea.leadingAnchor, constant: 34),
            searchField.trailingAnchor.constraint(equalTo: root.mainArea.trailingAnchor, constant: -36),
            searchField.heightAnchor.constraint(equalToConstant: 25),

            historyButton.leadingAnchor.constraint(equalTo: root.mainArea.leadingAnchor, constant: 4),
            historyButton.bottomAnchor.constraint(equalTo: root.mainArea.bottomAnchor, constant: -4),
            historyButton.widthAnchor.constraint(equalToConstant: 24),
            historyButton.heightAnchor.constraint(equalToConstant: 24),

            systemButton.trailingAnchor.constraint(equalTo: root.mainArea.trailingAnchor, constant: -6),
            systemButton.centerYAnchor.constraint(equalTo: historyButton.centerYAnchor),
            systemButton.widthAnchor.constraint(equalToConstant: 24),
            systemButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        // 搜索框行为接线(原版 CSymbolEdit)
        searchField.onArrow = { [weak self] down in
            guard let self else { return false }
            if down { self.listViewController.moveSelection(+1); return true }
            return self.listViewController.moveSelection(-1)
        }
        searchField.onSubmit = { [weak self] in
            guard let self else { return }
            self.recordSearchHistory(self.searchField.stringValue)
            // 即输即搜关闭:回车先应用查询;再按回车才粘贴(原版 Find As You Type=off 行为)
            if !DittoSettings.findAsYouType(),
               self.searchField.stringValue != self.lastAppliedQuery {
                self.lastAppliedQuery = self.searchField.stringValue
                self.listViewController.reload(query: self.searchField.stringValue)
                return
            }
            self.listViewController.pasteSelection()
        }
        searchField.onDeleteAtEnd = { [weak self] in
            self?.listViewController.deleteSelection() ?? false
        }
        searchField.onCopyItem = { [weak self] in
            self?.listViewController.copySelection() ?? false
        }
        searchField.onHistory = { [weak self] in self?.showSearchHistory() }
    }

    // MARK: - 外观设置(主题 / 标题栏位置 / 透明度;原版 Quick Options 的显示项)

    /// 读取设置并应用到面板(启动时 + 设置变更时调用)
    func applyAppearanceSettings() {
        // 主题:存储值解析失败(文件被删/损坏)→ 回落跟随系统
        let stored = DittoSettings.defaults.string(forKey: DittoSettings.themeFileKey) ?? ""
        if let theme = ThemeRegistry.load(storedValue: stored) {
            DittoTheme.apply(theme)
        } else {
            DittoTheme.resetToSystem()
        }
        rootView.captionPosition = DittoSettings.captionPosition()
        rootView.refreshCaptionThickness()
        applyTransparency()
        updateSearchPlaceholder()
        // 列表配色/行高/字体(主题化时行背景与选中态改为自绘)
        listViewController.applyAppearance()
        // 在屏的组树覆盖层同步配色
        if let container = groupTreeContainer {
            container.layer?.backgroundColor = DittoTheme.groupTreeBackground.cgColor
            treeHeader?.textColor = DittoTheme.groupTreeText
            groupTreeOutline?.reloadData()
        }
    }

    /// 透明度(原版 Transparency:alpha = 1 - pct/100;窗口级,折叠态同样生效)
    func applyTransparency() {
        let pct = DittoSettings.clampedTransparencyPercent(
            DittoSettings.defaults.integer(forKey: DittoSettings.transparencyPercentKey))
        window?.alphaValue = CGFloat(DittoSettings.transparencyAlpha(percent: pct))
    }

    /// 搜索框占位提示:非"包含"方式时前缀方式名(原版搜索状态可见性)
    func updateSearchPlaceholder() {
        let method = DittoSettings.searchMethod()
        let scope = DittoSettings.searchScope()
        var prefix = ""
        if method != .contains {
            prefix = (method == .regex ? L10n.searchMethodRegex : L10n.searchMethodWildcard) + " · "
        }
        if scope == .descriptionOnly {
            prefix += L10n.searchScopeDescription + " · "
        }
        searchField.placeholderAttributedString = NSAttributedString(
            string: prefix + L10n.searchPlaceholder,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(srgbRed: 127 / 255, green: 127 / 255, blue: 127 / 255, alpha: 1),
                .obliqueness: 0.25,   // 灰斜体
            ])
    }

    // MARK: - NSSearchFieldDelegate:FindAsYouType 250ms 防抖(原版默认;
    // 设置"即输即搜"关闭时,输入不触发查询,仅回车执行)

    private var searchDebounce: DispatchWorkItem?
    /// 列表当前已应用的查询(即输即搜关闭时,区分"回车=查询"与"回车=粘贴")
    private var lastAppliedQuery = ""

    func controlTextDidChange(_ obj: Notification) {
        guard DittoSettings.findAsYouType() else { return }   // 关闭:输入不查询
        searchDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastAppliedQuery = self.searchField.stringValue
            self.listViewController.reload(query: self.searchField.stringValue)
        }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: - 组导航(原版 EnterGroupID / 返回上级;仅会话内)

    /// 统一的列表刷新入口:先把当前组同步给列表再查询
    private func reloadList() {
        listViewController.parentID = currentParentID
        lastAppliedQuery = searchField.stringValue
        listViewController.reload(query: searchField.stringValue)
    }

    /// 进入组(原版 theApp.EnterGroupID):清过滤,列表切到该组
    func enterGroup(id: Int64) {
        guard store.item(id: id)?.isGroup == true else { return }
        currentParentID = id
        if !searchField.stringValue.isEmpty { searchField.stringValue = "" }
        reloadList()
        updateCaptionSuffix()
    }

    /// 返回父组(Backspace;原版返回上级直到主列表)
    func goToParent() {
        guard currentParentID != -1 else { return }
        currentParentID = store.item(id: currentParentID)?.parentID ?? -1
        reloadList()
        updateCaptionSuffix()
    }

    /// 组热键单击:打开面板并定位到该组
    func show(atGroup groupID: Int64) {
        currentParentID = store.item(id: groupID)?.isGroup == true ? groupID : -1
        show()
    }

    // MARK: - 显示 / 隐藏(原版 ShowQPasteWindow / HideQPasteWindow)

    func show() {
        guard let panel = window else { return }
        cancelPendingAutoHide()
        reloadList()
        positionWindow(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(listViewController.firstResponderTarget)
        updateCaptionSuffix()
        // 面板在屏 = 非全局组热键开始生效(注册式实现)
        AppDelegate.shared?.panelVisibilityChanged()
    }

    /// 原版三种出现位置;macOS 等价:光标处(默认)/ 插入符处(原版 At Caret,
    /// 经辅助功能取焦点元素选区位置,失败回落光标)/ 上次位置(出屏夹取)。
    /// 面板放到参考点所在的屏幕(多屏跟随),再按该屏可视区夹取
    private func positionWindow(_ panel: NSWindow) {
        let mode = DittoSettings.defaults.string(forKey: DittoSettings.positionModeKey)
            ?? DittoSettings.defaultPositionMode
        guard mode != "atPrevious" else { return }
        let caret = mode == "atCaret" ? CaretLocator.caretScreenPoint() : nil
        let reference = CaretLocator.referencePoint(caret: caret, mouse: NSEvent.mouseLocation)
        // 多屏:参考点所在屏(未落在任何屏内 → 主屏兜底)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(reference) }) ?? NSScreen.main else {
            return
        }
        var origin = reference
        origin.x += 2; origin.y -= 2   // At Cursor +2px 偏移
        var frame = panel.frame
        frame.origin = origin
        let visible = screen.visibleFrame
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        panel.setFrameOrigin(frame.origin)
    }

    func toggle() {
        if isOnScreen { hide() } else { show() }
    }

    func hide() {
        cancelPendingAutoHide()
        saveFrame()
        closeDescTooltip()
        closeHoverTip()
        setGroupTreeVisible(false)
        // 原版隐藏时清空搜索文本(QPasteWnd.cpp:923-929),并回到主列表(组状态复位)
        currentParentID = -1
        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            listViewController.reload(query: "")
        }
        window?.orderOut(nil)
        onHidden?()
        // 面板离屏 = 非全局组热键停用
        AppDelegate.shared?.panelVisibilityChanged()
    }

    var onHidden: (() -> Void)?

    func refreshList() {
        listViewController.refreshKeepingSelection()
    }

    /// Alt+C / 菜单:清空过滤
    func clearFilter() {
        searchField.stringValue = ""
        reloadList()
    }

    /// 菜单"以此条过滤列表":把搜索词设为该条描述
    func setFilter(_ q: String) {
        searchField.stringValue = q
        reloadList()
    }

    // MARK: - 折叠 / 最大化 / 常驻(原版 Roll-up / Maximize / ShowPersistent)

    /// 折叠窗口(标题栏按钮 / 命令注册表绑定)。向标题栏一侧收成"仅标题栏"的
    /// 细条(上游 MinMaxWindow,DittoWindow.cpp:772-868:右停靠 = 宽收到
    /// caption 宽、右缘不动;左/上/下同理各锚自身边缘;展开向对侧恢复,
    /// 且以折叠条当前停靠边缘为锚 —— 折叠条可拖动后再展开)
    func toggleRollUp() {
        guard let panel = window else { return }
        let thickness = DittoTheme.captionWidth + 2   // 标题栏 + 双侧 1px 边框
        let side = rootView.captionPosition
        if isRolled {
            if let full = rolledFrame {
                var frame = panel.frame
                switch side {
                case .right: frame.origin.x = panel.frame.maxX - full.width
                case .left: break                       // 左缘即锚,origin 不动
                case .top: frame.origin.y = panel.frame.maxY - full.height
                case .bottom: frame.origin.y = panel.frame.minY - full.height
                }
                frame.size = full.size
                panel.setFrame(frame, display: true, animate: false)
            }
            isRolled = false
        } else {
            rolledFrame = panel.frame
            var f = panel.frame
            switch side {
            case .right:
                f.origin.x = panel.frame.maxX - thickness
                f.size.width = thickness
            case .left:
                f.size.width = thickness
            case .top:
                f.origin.y = panel.frame.maxY - thickness
                f.size.height = thickness
            case .bottom:
                f.size.height = thickness
            }
            panel.setFrame(f, display: true, animate: false)
            isRolled = true
        }
        rootView.caption.setRolled(isRolled)
    }

    /// 最大化/还原(标题栏按钮 / 命令注册表绑定);折叠态下先展开(点击
    /// 最大化/标题栏即恢复,原版折叠态的外出路径)
    func toggleMaximize() {
        if isRolled {
            toggleRollUp()
            return
        }
        guard let panel = window, let screen = NSScreen.main else { return }
        if let normal = normalFrame {
            panel.setFrame(normal, display: true, animate: false)
            normalFrame = nil
        } else {
            normalFrame = panel.frame
            var f = screen.visibleFrame
            f = f.insetBy(dx: 40, dy: 40)
            panel.setFrame(f, display: true, animate: false)
        }
    }

    /// Ctrl+Space / 系统菜单:常驻置顶(不因失焦隐藏);主题化时标题栏/边框
    /// 切 *TopMost 变体(上游 CaptionLeftTopMost/BorderTopMost)
    func togglePersistent() {
        isPersistent.toggle()
        window?.level = isPersistent ? .statusBar : .floating
        rootView.caption.isTopMost = isPersistent
        updateCaptionSuffix()
    }

    private func updateCaptionSuffix() {
        guard isOnScreen else { return }
        var title = "ditto-mac"
        if isPersistent { title += " [\(L10n.tagPinned)]" }
        if DittoSettings.defaults.bool(forKey: DittoSettings.pausedKey) { title += " [\(L10n.tagDisconnected)]" }
        // 组内显示组名(原版组内标题区显示组文本)
        if currentParentID != -1, let name = store.item(id: currentParentID)?.text, !name.isEmpty {
            title += " - \(name)"
        }
        let (sel, total) = listViewController.selectionCounts()
        if total > 0 { title += " - \(sel)/\(total)" }
        rootView.caption.titleText = title
    }

    // MARK: - 搜索历史(原版:10 条,Ctrl+↓ 弹出,含 Clear List)

    private static let historyKey = "ditto.searchHistory"

    private var searchHistory: [String] {
        DittoSettings.defaults.stringArray(forKey: Self.historyKey) ?? []
    }

    private func recordSearchHistory(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var h = searchHistory.filter { $0 != trimmed }
        h.insert(trimmed, at: 0)
        if h.count > 10 { h = Array(h.prefix(10)) }
        DittoSettings.defaults.set(h, forKey: Self.historyKey)
    }

    @objc private func showSearchHistory() {
        let menu = NSMenu()
        for q in searchHistory {
            let item = NSMenuItem(title: q, action: #selector(historyPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = q
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear List", action: #selector(clearSearchHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        let btn = searchField.superview
        let popRect = btn.map { $0.convert(searchField.frame, from: searchField.superview) } ?? NSRect.zero
        menu.popUp(positioning: nil, at: NSPoint(x: popRect.minX + 34, y: popRect.minY), in: btn)
    }

    @objc private func historyPicked(_ sender: NSMenuItem) {
        searchField.stringValue = sender.representedObject as? String ?? ""
        reloadList()
    }

    @objc private func clearSearchHistory() {
        DittoSettings.defaults.removeObject(forKey: Self.historyKey)
    }

    // MARK: - 系统菜单(原版 IDR_QUICK_PASTE_SYSTEM_MENU 的 macOS 映射)

    @objc private func showSystemMenu() {
        let menu = AppDelegate.shared?.buildSystemMenu() ?? NSMenu()
        let origin = NSPoint(x: rootView.mainArea.frame.width - 30, y: 8)
        menu.popUp(positioning: nil, at: origin, in: rootView.mainArea)
    }

    // MARK: - Esc 四级退出(原版:关组树 → 关 tooltip → 清过滤 → 隐藏窗)

    private func escapePressed() {
        if isGroupTreeVisible {
            setGroupTreeVisible(false)
        } else if descTooltip != nil {
            closeDescTooltip()
        } else if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            listViewController.reload(query: "")
        } else {
            hide()
        }
    }

    /// 窗口级命令(命令注册表绑定命中时列表转发来;返回 false = 非窗口级命令)
    func handleWindowCommand(_ command: PanelCommand) -> Bool {
        switch command {
        case .closeWindow: escapePressed(); return true
        case .forceClose: hide(); return true
        case .rollUp: toggleRollUp(); return true
        case .maximize: toggleMaximize(); return true
        default: return false
        }
    }

    // MARK: - 组树覆盖层(⌃G;原版 GroupTree 的轻量等价:停靠主区左缘)

    func toggleGroupTree() {
        setGroupTreeVisible(!isGroupTreeVisible)
    }

    func setGroupTreeVisible(_ visible: Bool) {
        guard let mainArea = window?.contentView as? PanelRootView else {
            // 窗口未建(contentView 未换)时静默忽略
            return
        }
        if visible {
            if groupTreeContainer == nil {
                buildGroupTreeOverlay(in: mainArea)
            }
            rebuildGroupTreeData()
            groupTreeContainer?.isHidden = false
        } else {
            groupTreeContainer?.isHidden = true
        }
    }

    /// 组树:左侧 180px 覆盖层(浮在列表上方),含 NSOutlineView
    private func buildGroupTreeOverlay(in root: PanelRootView) {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = DittoTheme.groupTreeBackground.cgColor
        container.layer?.borderColor = DittoTheme.borderColor.cgColor
        container.layer?.borderWidth = 1
        container.translatesAutoresizingMaskIntoConstraints = false
        root.mainArea.addSubview(container)

        treeHeader = NSTextField(labelWithString: L10n.menuMoveToGroup)
        treeHeader?.font = .systemFont(ofSize: 11, weight: .semibold)
        treeHeader?.textColor = DittoTheme.groupTreeText
        treeHeader?.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(treeHeader!)

        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue: "group"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 22
        outline.style = .sourceList
        outline.dataSource = self
        outline.delegate = self
        outline.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: root.mainArea.leadingAnchor),
            container.topAnchor.constraint(equalTo: root.mainArea.topAnchor),
            container.bottomAnchor.constraint(equalTo: root.mainArea.bottomAnchor, constant: -33),
            container.widthAnchor.constraint(equalToConstant: 180),

            treeHeader!.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            treeHeader!.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),

            scroll.topAnchor.constraint(equalTo: treeHeader!.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        groupTreeContainer = container
        groupTreeOutline = outline
    }

    /// 每次展开重建(组结构在菜单操作后可能已变);无组时标题给占位提示
    private func rebuildGroupTreeData() {
        func buildChildren(of parent: Int64) -> [GroupNode] {
            store.childGroups(of: parent).map { group in
                GroupNode(id: group.id, title: group.text ?? "", children: buildChildren(of: group.id))
            }
        }
        groupTreeRoots = buildChildren(of: -1)
        treeHeader?.stringValue = groupTreeRoots.isEmpty ? L10n.groupTreePlaceholder : L10n.menuMoveToGroup
        groupTreeOutline?.reloadData()
        groupTreeOutline?.expandItem(nil, expandChildren: true)
    }

    // MARK: - 列表打字转发 / 焦点(原版:列表打字直接进搜索框)

    private func typeAhead(char: Character) {
        window?.makeFirstResponder(searchField)
        searchField.stringValue.append(char)
        listViewController.reload(query: searchField.stringValue)
    }

    // MARK: - 粘贴流程(原版 DoPaste:写板 → 激活目标 → 隐藏;标记 lastPasteDate)

    private enum PasteMode: Equatable {
        case normal
        case plainText
        case dontReorder
        case transform(SpecialPaste.Transform)
    }

    private func paste(items: [ClipItem], mode: PasteMode) {
        guard !items.isEmpty else { return }
        hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            let payloads = items.compactMap { self.store.payload(id: $0.id) }
            guard !payloads.isEmpty else { return }
            var payload = payloads[0]
            if payloads.count > 1 {
                // 多选:全部为文本时按顺序拼接(原版多选聚合粘贴,分隔 \r\n)
                if payloads.allSatisfy({ $0.imageData == nil && ($0.filePaths ?? []).isEmpty }) {
                    let joined = payloads.compactMap(\.text).joined(separator: "\r\n")
                    payload = RawClip(text: joined)
                }
            }
            switch mode {
            case .normal: break
            case .plainText:
                payload = SpecialPaste.apply(.plainTextOnly, to: payload)
            case .transform(let t):
                payload = SpecialPaste.apply(t, to: payload)
            case .dontReorder: break
            }
            if !Permissions.isAccessibilityGranted {
                // 未授权:内容仍在剪贴板可手动 ⌘V,同时明确引导授权(不再静默)
                PasteBack.write(payload, monitor: ClipboardMonitor.shared)
                AppDelegate.shared?.promptAccessibilityForPaste()
            } else {
                _ = PasteBack.paste(payload, monitor: ClipboardMonitor.shared)
            }
            if mode != .dontReorder {
                let now = Date()
                // 粘贴计数(原版 TotalPasteCount):每次 markPasted 累加
                for item in items {
                    self.store.markPasted(id: item.id, at: now)
                    UsageStats.shared.notePaste()
                }
            }
        }
    }

    // MARK: - 属性(原版 Alt+Enter / Properties 菜单)

    /// 辅窗(属性/编辑器/对比)关闭后恢复失焦自动隐藏
    private func observeAuxWindowClose(_ window: NSWindow?) {
        guard let window else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.suspendAutoHide = false
        })
    }

    private func showProperties(item: ClipItem) {
        suspendAutoHide = true
        let payload = store.payload(id: item.id)
        let controller = PropertiesWindowController(item: item, payload: payload, store: store)
        controller.noteSelfWrite = { ClipboardMonitor.shared.noteExternalWrite() }
        observeAuxWindowClose(controller.window)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.center()
    }

    // MARK: - 悬停浮窗(鼠标移到条目上时,在面板左侧展示完整内容;对齐原版 tooltip)

    private var hoverTip: NSPanel?
    private var hoverDebounce: DispatchWorkItem?
    private var hoverItemID: Int64?

    private func handleHover(item: ClipItem?, rowScreenRect: NSRect) {
        hoverDebounce?.cancel()
        guard let item else {
            closeHoverTip()
            return
        }
        if hoverItemID == item.id, hoverTip?.isVisible == true { return }
        let work = DispatchWorkItem { [weak self] in
            self?.showHoverTip(item: item, rowScreenRect: rowScreenRect)
        }
        hoverDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func showHoverTip(item: ClipItem, rowScreenRect: NSRect) {
        guard isOnScreen, let panel = window else { return }
        let payload = store.payload(id: item.id)

        // ---- 单文本流内容:元数据 + 图片附件 + 全文,精确测量高度,永不裁切 ----
        let tipWidth: CGFloat = 380
        let hPadding: CGFloat = 12, vPadding: CGFloat = 10
        let contentWidth = tipWidth - hPadding * 2

        let ts = NSMutableAttributedString()
        let meta = ClipDescription.metaLine(item: item,
                                            lastUsedAt: item.lastPasteAt,
                                            neverAutoDelete: item.noDelete)
        ts.append(NSAttributedString(string: meta + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        if let imageData = payload?.imageData, let image = NSImage(data: imageData) {
            let attach = NSTextAttachment()
            let maxW = contentWidth, maxH: CGFloat = 180
            let ratio = min(maxW / max(image.size.width, 1), maxH / max(image.size.height, 1), 1)
            attach.image = image
            attach.bounds = CGRect(x: 0, y: 0,
                                   width: image.size.width * ratio,
                                   height: image.size.height * ratio)
            ts.append(NSAttributedString(attachment: attach))
            ts.append(NSAttributedString(string: "\n"))
        }
        var fullText = payload?.text ?? item.text ?? "(无文本内容)"
        if fullText.isEmpty { fullText = "(空白内容)" }
        if fullText.utf8.count > 64 * 1024 {
            fullText = String(fullText.prefix(64 * 1024)) + "\n…(已截断)"
        }
        ts.append(NSAttributedString(string: fullText, attributes: [
            .font: ClipListViewController.rowFont,   // 跟随用户选择的列表字体
            .foregroundColor: DittoTheme.hoverTipText,
        ]))

        // 测量:按 contentWidth 排版后的实际高度
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 0))
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        text.textStorage?.setAttributedString(ts)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let usedHeight = text.layoutManager!.usedRect(for: text.textContainer!).height

        let viewHeight = min(max(usedHeight + vPadding * 2, 48), 400)

        // ---- 容器:圆角窗口背景 + 滚动视图(超高时内部滚动,不再裁切)----
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: hPadding, height: vPadding)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.frame = NSRect(x: 0, y: 0, width: contentWidth, height: usedHeight + vPadding * 2)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: tipWidth, height: viewHeight))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay

        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.layer?.backgroundColor = DittoTheme.hoverTipBackground.cgColor
        wrap.layer?.cornerRadius = 8
        wrap.layer?.borderColor = DittoTheme.borderColor.cgColor
        wrap.layer?.borderWidth = 1
        wrap.layer?.masksToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: wrap.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            wrap.widthAnchor.constraint(equalToConstant: tipWidth),
            wrap.heightAnchor.constraint(equalToConstant: viewHeight),
        ])

        if hoverTip == nil {
            let tip = NSPanel(contentRect: NSRect(x: 0, y: 0, width: tipWidth, height: viewHeight),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
            tip.isOpaque = false
            tip.backgroundColor = .clear
            tip.hasShadow = true
            tip.hidesOnDeactivate = false
            tip.level = .floating + 1
            tip.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            hoverTip = tip
        }
        guard let tip = hoverTip else { return }
        tip.contentView = wrap

        // 定位:面板左侧,与悬停行垂直居中;左侧放不下换右侧;上下夹取到屏内
        let vf = panel.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: panel.frame.minX - tipWidth - 8,
                             y: rowScreenRect.midY - viewHeight / 2)
        if origin.x < vf.minX + 8 {
            origin.x = panel.frame.maxX + 8
        }
        origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - viewHeight - 8)
        tip.setFrameOrigin(origin)
        tip.orderFront(nil)
        hoverItemID = item.id
    }

    private func closeHoverTip() {
        hoverDebounce?.cancel()
        hoverTip?.orderOut(nil)
        hoverTip = nil
        hoverItemID = nil
    }

    func hoverTipForTesting() -> NSPanel? { hoverTip }

    /// 自测钩子:程序化显示第一条(或 DITTO_HOVER_LONG_TEXT=1 时临时插入的长文本)的悬停浮窗
    var hoverTestCleanup: (() -> Void)?

    func showHoverTipForTesting() {
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { PerfLog.event("HOVER_DBG", "self nil"); return }
            let longTextMode = ProcessInfo.processInfo.environment["DITTO_HOVER_LONG_TEXT"] == "1"
            if longTextMode {
                let body = (1...24).map { "第\($0)行:悬停浮窗长文本裁切验证 Hello world \($0) clipboard 测试内容行,中文与 English 混排。" }
                    .joined(separator: "\n")
                if let item = self.store.insert(RawClip(text: body, appName: "hover-test"),
                                                maxDataBytes: 20 << 20) {
                    self.hoverTestCleanup = { [weak self] in self?.store.delete(id: item.id) }
                    self.listViewController.reload(query: "")   // 刷新列表使新行排在首位并被选中
                }
            }
            guard let item = self.listViewController.selectedItems().first else {
                PerfLog.event("HOVER_DBG", "no selected item")
                return
            }
            guard let window = self.window else { PerfLog.event("HOVER_DBG", "no window"); return }
            let rect = self.listViewController.screenRectOfSelectedRow(in: window) ?? .zero
            PerfLog.event("HOVER_DBG", "show item=\(item.id)")
            self.showHoverTip(item: item, rowScreenRect: rect)
            PerfLog.event("HOVER_DBG", "tip=\(self.hoverTip != nil)")
        }
    }

    // MARK: - 描述浮窗(F3,原版 View Full Description tooltip 等价)

    func toggleDescTooltip() {
        if descTooltip != nil {
            closeDescTooltip()
            return
        }
        guard let item = listViewController.selectedItems().first,
              let window = window else { return }
        let full = store.payload(id: item.id)?.text ?? item.text ?? L10n.noTextPlaceholder
        let meta = ClipDescription.metaLine(item: item, lastUsedAt: item.lastPasteAt, neverAutoDelete: item.noDelete)
        let text = NSAttributedString(string: "\(meta)\n\n\(full)", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ])
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        tv.isEditable = false
        tv.drawsBackground = true
        tv.backgroundColor = .windowBackgroundColor
        tv.textStorage?.setAttributedString(text)
        let sv = NSScrollView(frame: tv.frame)
        sv.documentView = tv
        sv.hasVerticalScroller = true
        let tip = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        tip.title = L10n.descWindowTitle
        tip.contentView = sv
        tip.setFrameAutosaveName("descTooltip")
        // 出现在选中行附近
        if let rowRect = listViewController.screenRectOfSelectedRow(in: window) {
            var origin = NSPoint(x: rowRect.minX + 20, y: rowRect.minY - 20)
            origin.x = min(origin.x, window.screen?.visibleFrame.maxX ?? 1600) - 500
            origin.y = max(origin.y, (window.screen?.visibleFrame.minY ?? 0))
            tip.setFrameOrigin(origin)
        } else {
            tip.center()
        }
        tip.orderFront(nil)
        descTooltip = tip
    }

    private func closeDescTooltip() {
        descTooltip?.orderOut(nil)
        descTooltip = nil
    }

    // MARK: - 失焦自动隐藏 / 自动折叠(原版 OnActivate WA_INACTIVE +
    // Auto Roll-up;常驻模式与折叠态豁免见 focusLossBehavior)

    private func cancelPendingAutoHide() {
        pendingAutoHide?.cancel()
        pendingAutoHide = nil
    }

    private func scheduleAutoHideCheck() {
        guard !isPersistent, !suspendAutoHide else { return }
        pendingAutoHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.window else { return }
            guard panel.isVisible, NSApp.keyWindow !== panel, !NSApp.isActive else { return }
            // 原版 Auto Roll-up:开启 → 失焦折叠(保持可见);关闭 → 隐藏
            switch DittoSettings.focusLossBehavior(
                autoRollUp: DittoSettings.defaults.bool(forKey: DittoSettings.autoRollUpKey),
                persistent: self.isPersistent,
                rolled: self.isRolled) {
            case .hide:
                self.hide()
            case .rollUp:
                self.toggleRollUp()
            case .none:
                break
            }
        }
        pendingAutoHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: - 位置记忆

    /// 按主屏分辨率分键(原版按分辨率记忆)
    private var frameKeyForScreen: String {
        if let screen = window?.screen ?? NSScreen.main {
            let w = Int(screen.frame.width), h = Int(screen.frame.height)
            if "\(w)x\(h)" != "0x0" { return "\(Self.frameKey)-\(w)x\(h)" }
        }
        return Self.frameKey
    }

    private func restoreFrame() {
        guard let panel = window else { return }
        if let saved = DittoSettings.defaults.string(forKey: frameKeyForScreen) {
            let frame = NSRectFromString(saved)
            let visible = NSScreen.screens.contains { $0.frame.intersects(frame) }
            if frame.width >= panel.minSize.width, frame.height >= panel.minSize.height, visible {
                panel.setFrame(frame, display: false)
                return
            }
        }
        panel.center()
    }

    private func saveFrame() {
        guard let panel = window, panel.isVisible, !isRolled else { return }
        DittoSettings.defaults.set(NSStringFromRect(panel.frame), forKey: frameKeyForScreen)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        scheduleAutoHideCheck()
        listViewController.refreshSelectionColors()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        listViewController.refreshSelectionColors()
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveFrame()
    }
}

// MARK: - 组树数据源/委托(点击或回车导航;树保持展开供连续浏览)

extension HistoryPanelController: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? GroupNode)?.children[index] ?? groupTreeRoots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? GroupNode)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? GroupNode)?.children.count ?? groupTreeRoots.count
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? GroupNode else { return nil }
        let cell = NSTableCellView()
        let textField = NSTextField(labelWithString: node.title)
        textField.font = .systemFont(ofSize: 12)
        textField.textColor = DittoTheme.groupTreeText
        cell.textField = textField
        cell.addSubview(textField)
        textField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if node.id == currentParentID {
            textField.font = .systemFont(ofSize: 12, weight: .semibold)
        }
        return cell
    }

    /// 选中(单击/方向键+回车)→ 进入该组;树保持可见
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outline = notification.object as? NSOutlineView,
              outline === groupTreeOutline,
              let node = outline.item(atRow: outline.selectedRow) as? GroupNode else { return }
        enterGroup(id: node.id)
    }
}

// MARK: - 搜索框(原版 CSymbolEdit 行为)

final class PanelSearchField: NSSearchField {
    var onArrow: ((Bool /*down*/) -> Bool)?          // ↑↓/PgUp/PgDn/End 转发列表
    var onSubmit: (() -> Void)?                       // 回车 = 粘贴选中(FindAsYouType)
    var onDeleteAtEnd: (() -> Bool)?                  // 光标在末尾按 Delete → 删条目
    var onCopyItem: (() -> Bool)?                     // Ctrl+C 无字段选中 → 复制条目
    var onHistory: (() -> Void)?                      // ⌘↓ 历史

    override init(frame: NSRect) {
        super.init(frame: frame)
        target = self
        action = #selector(submit)
        sendsWholeSearchString = true
        (cell as? NSSearchFieldCell)?.searchButtonCell = nil
        centersPlaceholder = false
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    private func cursorAtEnd() -> Bool {
        guard let editor = currentEditor() as? NSTextView else { return false }
        let len = (editor.string as NSString).length
        let sel = editor.selectedRange
        return sel.location + sel.length >= len
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let responder = window?.firstResponder,
           responder === self || responder === currentEditor(),
           PanelAccels.command(forKeyCode: event.keyCode,
                               carbonModifiers: DittoSettings.carbonMask(from: event.modifierFlags)) == .pasteSelected {
            onSubmit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command), event.keyCode == 125 { onHistory?(); return }   // ⌘↓ 历史(先于 ↓ 判断)
        // 回车粘贴走命令注册表(默认 = 原下方 36/76 分支;重绑后此处跟随)
        if PanelAccels.command(forKeyCode: event.keyCode,
                               carbonModifiers: DittoSettings.carbonMask(from: event.modifierFlags)) == .pasteSelected {
            onSubmit?()
            return
        }
        switch event.keyCode {
        case 125: if onArrow?(true) == true { return }          // ↓
        case 126: if onArrow?(false) == true { return }         // ↑
        case 36, 76: onSubmit?(); return                        // 回车 = 粘贴选中
        case 117:                                               // Forward Delete @末尾 → 删条目
            if cursorAtEnd(), onDeleteAtEnd?() == true { return }
        case 115, 119, 116, 121:                                // Home/End/PgUp/PgDn 转发列表
            if onArrow?(event.keyCode == 119 || event.keyCode == 121) == true { return }
        default: break
        }
        if mods.contains(.command), event.charactersIgnoringModifiers == "c",
           (currentEditor() as? NSTextView)?.selectedRange.length == 0, onCopyItem?() == true { return }
        super.keyDown(with: event)
    }

    @objc private func submit() { onSubmit?() }
}
