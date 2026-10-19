import AppKit

// MARK: - Tokens

/// Settings design tokens. Every color resolves per appearance, including Increase Contrast.
enum SettingsPalette {
    /// Grouped canvas behind cards: a cool off-white in light mode, near-black in dark mode.
    static let canvas = color(light: rgb(242, 242, 247), dark: rgb(30, 30, 32),
                              contrastLight: .white, contrastDark: .black)
    /// Card surface; the top stop is slightly lifted in dark mode so cards read as lit from above.
    static let cardTop = color(light: .white, dark: rgb(49, 49, 52))
    static let cardBottom = color(light: .white, dark: rgb(43, 43, 46))
    static let cardBorder = color(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08),
                                  contrastLight: NSColor(white: 0, alpha: 0.5), contrastDark: NSColor(white: 1, alpha: 0.55))
    /// Recessed wells: shortcut fields and list accessory bars.
    static let well = color(light: NSColor(white: 0, alpha: 0.04), dark: NSColor(white: 1, alpha: 0.06))
    static let wellHover = color(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.1))
    static let wellBorder = color(light: NSColor(white: 0, alpha: 0.1), dark: NSColor(white: 1, alpha: 0.1),
                                  contrastLight: NSColor(white: 0, alpha: 0.55), contrastDark: NSColor(white: 1, alpha: 0.6))
    /// Keycaps drawn inside shortcut fields.
    static let keycap = color(light: .white, dark: rgb(78, 78, 83))
    static let keycapEdge = color(light: NSColor(white: 0, alpha: 0.2), dark: NSColor(white: 0, alpha: 0.55))

    static let cornerRadius: CGFloat = 10
    static let rowInset: CGFloat = 14

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    private static func color(light: NSColor, dark: NSColor,
                              contrastLight: NSColor? = nil, contrastDark: NSColor? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                               .accessibilityHighContrastDarkAqua]) {
            case .darkAqua?: return dark
            case .accessibilityHighContrastDarkAqua?: return contrastDark ?? dark
            case .accessibilityHighContrastAqua?: return contrastLight ?? light
            default: return light
            }
        }
    }
}

extension NSAppearance {
    var isDarkMode: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSView {
    /// One physical pixel on the current display.
    var hairline: CGFloat { 1 / max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, 1) }
}

// MARK: - Motion

/// Short, interruptible entrance motion. Animations are presentation-only: model values never
/// change, so layout, hit testing and accessibility frames stay exact while anything moves.
enum SettingsMotion {
    private static let key = "settings.reveal"
    static let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

    static var isReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Staggered fade-and-rise of a page's blocks.
    static func reveal(_ views: [NSView]) {
        guard !isReduced else { return }
        let start = CACurrentMediaTime()
        for (index, view) in views.enumerated() {
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            layer.removeAnimation(forKey: key)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            // Layer y follows the superview: positive is downward in flipped containers.
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = view.superview?.isFlipped == true ? 10 : -10
            rise.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [fade, rise]
            group.duration = 0.34
            group.beginTime = start + Double(min(index, 5)) * 0.04
            group.fillMode = .backwards
            group.timingFunction = curve
            layer.add(group, forKey: key)
        }
    }

    static func cancel(_ views: [NSView]) {
        views.forEach { $0.layer?.removeAnimation(forKey: key) }
    }
}

// MARK: - Surfaces

/// The detail canvas; also used as the window background so floating sidebars sit on one tone.
final class SettingsCanvasView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = SettingsPalette.canvas.cgColor
        }
    }
}

final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Rounded, clipped card surface with a top-lit gradient and a hairline rim.
/// Drawn rather than built from CA gradient layers so offscreen fixtures match the window.
private final class SettingsSurfaceView: NSView {
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }
    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    override func layout() {
        super.layout()
        // Clip subviews (full-bleed lists, tinted subheaders) to the rounded corners.
        layer?.cornerRadius = SettingsPalette.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rim = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : hairline
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: rim / 2, dy: rim / 2),
                                 xRadius: SettingsPalette.cornerRadius, yRadius: SettingsPalette.cornerRadius)
        // Flipped view: angle 90 runs from the top edge to the bottom edge.
        NSGradient(starting: SettingsPalette.cardTop, ending: SettingsPalette.cardBottom)?.draw(in: shape, angle: 90)
        SettingsPalette.cardBorder.setStroke()
        shape.lineWidth = rim
        shape.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// An elevated grouped card. Content goes into `surface`, which clips to the rounded corners;
/// the outer layer only carries the soft drop shadow so clipping never cuts it off.
class SettingsGroupView: NSView {
    let surface: NSView = SettingsSurfaceView(frame: .zero)

    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    override func updateLayer() {
        guard let layer else { return }
        let dark = effectiveAppearance.isDarkMode
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = dark ? 0.32 : 0.07
        layer.shadowRadius = dark ? 2.5 : 3.5
        layer.shadowOffset = CGSize(width: 0, height: -1)
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: SettingsPalette.cornerRadius,
                                   cornerHeight: SettingsPalette.cornerRadius, transform: nil)
    }
}

/// A card that stacks form rows with inset hairlines between them.
final class SettingsFormCard: SettingsGroupView {
    private let rows = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            rows.topAnchor.constraint(equalTo: surface.topAnchor),
            rows.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    /// Rows span the card; `fullBleed` rows (lists) also drop the separator inset.
    func add(_ row: NSView, fullBleed: Bool = false) {
        if !rows.arrangedSubviews.isEmpty {
            let line = SettingsHairline(inset: fullBleed ? 0 : SettingsPalette.rowInset)
            rows.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }
}

/// A one-pixel separator drawn with the semantic separator color.
final class SettingsHairline: NSView {
    private let inset: CGFloat
    private let vertical: Bool

    init(inset: CGFloat, vertical: Bool = false, length: CGFloat? = nil) {
        self.inset = inset
        self.vertical = vertical
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        if vertical {
            widthAnchor.constraint(equalToConstant: 1).isActive = true
            if let length { heightAnchor.constraint(equalToConstant: length).isActive = true }
        } else {
            heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    override func draw(_ dirtyRect: NSRect) {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        (contrast ? NSColor.secondaryLabelColor : NSColor.separatorColor).setFill()
        if vertical {
            NSRect(x: 0, y: inset, width: hairline, height: max(0, bounds.height - inset * 2)).fill()
        } else {
            NSRect(x: inset, y: 0, width: max(0, bounds.width - inset * 2), height: hairline).fill()
        }
    }
}

/// A wrapping label that re-measures against its laid-out width, so stack views can size it.
final class SettingsWrappingLabel: NSTextField {
    convenience init(_ text: String, size: CGFloat = 11, color: NSColor = .secondaryLabelColor) {
        self.init(wrappingLabelWithString: text)
        font = .systemFont(ofSize: size)
        textColor = color
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    override func layout() {
        super.layout()
        if abs(preferredMaxLayoutWidth - bounds.width) > 0.5 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

// MARK: - Form rows

/// A grouped-form row: title and optional detail on the leading edge, accessory trailing.
final class SettingsFormRow: NSView {
    let titleLabel: NSTextField
    let accessory: NSView?

    init(title: String, detail: String? = nil, accessory: NSView? = nil, leading: NSView? = nil,
         titleWeight: NSFont.Weight = .regular) {
        self.accessory = accessory
        titleLabel = SettingsWrappingLabel(title, size: 13, color: .labelColor)
        titleLabel.font = .systemFont(ofSize: 13, weight: titleWeight)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let text = NSStackView(views: [titleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        if let detail, !detail.isEmpty {
            text.addArrangedSubview(SettingsWrappingLabel(detail))
        }
        text.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true }
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Explicit constraints: the text column takes every point the accessory leaves,
        // so long titles and details wrap instead of pushing controls off the trailing edge.
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        var textLeading = leadingAnchor
        var textInset = SettingsPalette.rowInset
        if let leading {
            leading.translatesAutoresizingMaskIntoConstraints = false
            addSubview(leading)
            NSLayoutConstraint.activate([
                leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsPalette.rowInset),
                leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            textLeading = leading.trailingAnchor
            textInset = 10
        }
        let hug = heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .init(1)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: textLeading, constant: textInset),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 9),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -9),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
            hug,
        ])
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            accessory.setContentHuggingPriority(.required, for: .horizontal)
            accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
            // Stack views size from their own hugging priority, not content hugging.
            (accessory as? NSStackView)?.setHuggingPriority(.required, for: .horizontal)
            addSubview(accessory)
            NSLayoutConstraint.activate([
                accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsPalette.rowInset),
                accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
                accessory.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 7),
                accessory.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -7),
                text.trailingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: -16),
            ])
        } else {
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsPalette.rowInset).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }
}

/// A tinted divider row that introduces a block of rows inside one card.
final class SettingsSubheaderRow: NSView {
    override var wantsUpdateLayer: Bool { true }

    init(title: String, accessory: NSView? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = NSStackView(views: [label, spacer] + (accessory.map { [$0] } ?? []))
        line.orientation = .horizontal
        line.alignment = .centerY
        line.distribution = .fill
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsPalette.rowInset),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsPalette.rowInset),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 34),
        ])
    }
    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = SettingsPalette.well.cgColor
        }
    }
}

/// Full-width padded content inside a card (explanations, button rows).
final class SettingsInsetRow: NSView {
    init(_ content: NSView, vertical: CGFloat = 10) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsPalette.rowInset),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -SettingsPalette.rowInset),
            content.topAnchor.constraint(equalTo: topAnchor, constant: vertical),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -vertical),
        ])
        if content is SettingsWrappingLabel {
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsPalette.rowInset).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }
}

// MARK: - Icon tiles

/// A System Settings–style tile: a softly graded color square with a white SF Symbol.
final class SettingsIconTile: NSView {
    private let tint: NSColor
    private let size: CGFloat
    private let elevated: Bool
    private let glyph = NSImageView()

    init(symbol: String, fallback: String? = nil, tint: NSColor, size: CGFloat, elevated: Bool = false) {
        self.tint = tint
        self.size = size
        self.elevated = elevated
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? fallback.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        glyph.image = image
        glyph.symbolConfiguration = .init(pointSize: size * 0.5, weight: .semibold)
        glyph.contentTintColor = .white
        glyph.imageScaling = .scaleProportionallyDown
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.setAccessibilityElement(false)
        addSubview(glyph)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.72),
            glyph.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.72),
        ])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    override var allowsVibrancy: Bool { false }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let radius = size * 0.24
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        let base = tint.usingColorSpace(.sRGB) ?? tint
        let top = base.blended(withFraction: 0.28, of: .white) ?? base
        let bottom = base.blended(withFraction: 0.08, of: .black) ?? base
        NSGradient(starting: top, ending: bottom)?.draw(in: shape, angle: 90)
        // A faint inner rim keeps the tile crisp on both light and dark sidebars.
        let rim = NSBezierPath(roundedRect: bounds.insetBy(dx: hairline / 2, dy: hairline / 2), xRadius: radius, yRadius: radius)
        rim.lineWidth = hairline
        NSColor(white: 1, alpha: 0.22).setStroke()
        rim.stroke()
    }

    override func layout() {
        super.layout()
        guard let layer else { return }
        let radius = size * 0.24
        layer.masksToBounds = false
        layer.shadowOpacity = elevated ? 0.35 : 0.14
        layer.shadowRadius = elevated ? size * 0.14 : 0.8
        layer.shadowOffset = CGSize(width: 0, height: elevated ? -size * 0.06 : -0.5)
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        updateShadowColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        updateShadowColor()
    }

    private func updateShadowColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.shadowColor = (elevated ? (tint.usingColorSpace(.sRGB) ?? tint) : NSColor.black).cgColor
        }
    }
}

// MARK: - Lists

/// A table set edge-to-edge in a card, with a native +/− accessory bar and an empty state.
final class SettingsListBox: NSView {
    let table: NSTableView
    private let placeholder: NSStackView

    init(table: NSTableView, height: CGFloat, buttons: [NSButton], trailing: [NSView] = [],
         emptySymbol: String, emptyMessage: String) {
        self.table = table
        let icon = NSImageView(image: NSImage(systemSymbolName: emptySymbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 22, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let message = NSTextField(labelWithString: emptyMessage)
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        placeholder = NSStackView(views: [icon, message])
        placeholder.orientation = .vertical
        placeholder.spacing = 6
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        table.backgroundColor = .clear
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 8, height: 0)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)

        let bar = SettingsAccessoryBar(buttons: buttons, trailing: trailing)
        addSubview(bar)
        let topOffset: CGFloat = table.headerView == nil ? 0 : 14
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.heightAnchor.constraint(equalToConstant: height),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: topOffset),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
        ])
        updatePlaceholder()
    }
    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    func updatePlaceholder() {
        placeholder.isHidden = table.numberOfRows > 0
    }

    /// Compact borderless bar button that shows its bezel on hover, as in Finder and Mail lists.
    static func barButton(symbol: String, label: String, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                              target: target, action: action)
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageOnly
        button.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }
}

/// Table cell that centers its text vertically; editing and `row(for:)` still reach the field.
final class SettingsTableCell: NSTableCellView {
    init(_ field: NSTextField) {
        super.init(frame: .zero)
        textField = field
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }
}

/// The recessed strip under a list holding add/remove buttons and status text.
private final class SettingsAccessoryBar: NSView {
    override var wantsUpdateLayer: Bool { true }

    init(buttons: [NSButton], trailing: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        let line = SettingsHairline(inset: 0)
        addSubview(line)
        var views: [NSView] = buttons
        if buttons.count > 1 {
            views.insert(SettingsHairline(inset: 0, vertical: true, length: 14), at: 1)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        views.append(spacer)
        views += trailing
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsPalette.rowInset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }
    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = SettingsPalette.well.cgColor
        }
    }
}
