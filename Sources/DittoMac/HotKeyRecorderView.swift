import AppKit
import Carbon.HIToolbox
import DittoMacKit

/// A keyboard-accessible shortcut recorder. Bindings render as keycaps in a recessed well;
/// recording tints the well with the accent color and gently pulses its glow.
final class HotKeyRecorderView: NSView {
    var onCommit: ((UInt32, UInt) -> Void)?

    /// The active binding; kept in sync by display, commit and clear.
    private(set) var currentValue: (code: UInt32, mods: UInt)?

    private let label = NSTextField(labelWithString: "")
    private var isRecording = false
    private var needsModifier = false
    private var isHovered = false
    private var currentText = ""
    /// Keycap legends in HIG modifier order (⌃⌥⇧⌘) followed by the key.
    private var caps: [String] = []
    private static let pulseKey = "recorder.pulse"

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    private static let functionKeyCodes: Set<UInt16> = [
        96, 97, 98, 99, 100, 101, 103, 109, 111, 118, 120, 122,
    ]

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 156, height: 26))
        wantsLayer = true
        focusRingType = .exterior
        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            widthAnchor.constraint(equalToConstant: 156),
            heightAnchor.constraint(equalToConstant: 26),
        ])
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        refreshUI()
    }

    required init?(coder: NSCoder) { fatalError("不支持 XIB 创建") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if isRecording {
            NotificationCenter.default.post(name: .dittoHotKeyRecording, object: nil,
                                            userInfo: ["recording": false])
        }
    }

    func display(code: UInt32, mods: UInt) {
        currentValue = (code, mods)
        currentText = Fmt.hotKeyString(code: code, mods: mods)
        caps = Fmt.modifierSymbols(mods) + [Fmt.keyName(code)]
        setRecording(false)
        refreshUI()
    }

    func clear() {
        currentValue = nil
        currentText = ""
        caps = []
        setRecording(false)
        refreshUI()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        noteFocusRingMaskChanged()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard window?.makeFirstResponder(self) == true else { return }
        setRecording(!isRecording)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            // Standard keyboard activation after Tab focus; do not capture the activation key.
            if [UInt16(36), 49, 76].contains(event.keyCode),
               DittoSettings.carbonMask(from: event.modifierFlags) == 0 {
                setRecording(true)
            } else {
                super.keyDown(with: event)
            }
            return
        }
        if event.keyCode == 53 {
            setRecording(false)
            return
        }
        if Self.modifierKeyCodes.contains(event.keyCode) { return }

        let mods = DittoSettings.carbonMask(from: event.modifierFlags)
        if mods == 0 && !Self.functionKeyCodes.contains(event.keyCode) {
            needsModifier = true
            refreshUI()
            return
        }
        let code = UInt32(event.keyCode)
        // Update the visible value even when the caller only persists the binding.
        display(code: code, mods: mods)
        onCommit?(code, mods)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        setRecording(false)
        needsDisplay = true
        noteFocusRingMaskChanged()
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { setRecording(false) }
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification,
                                                      object: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                                                   name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { setRecording(false) }
        super.viewWillMove(toSuperview: newSuperview)
    }

    @objc private func windowResignedKey() { setRecording(false) }
    @objc private func accessibilityDisplayOptionsChanged() {
        needsDisplay = true
        updatePulse()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        if isRecording { updatePulse() }
    }

    private func setRecording(_ on: Bool) {
        guard isRecording != on else { return }
        isRecording = on
        needsModifier = false
        refreshUI()
        updatePulse()
        NotificationCenter.default.post(name: .dittoHotKeyRecording, object: nil,
                                        userInfo: ["recording": on])
    }

    /// Soft accent glow that breathes while listening; static when Reduce Motion is on.
    private func updatePulse() {
        guard let layer else { return }
        layer.removeAnimation(forKey: Self.pulseKey)
        layer.masksToBounds = false
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 7, cornerHeight: 7, transform: nil)
        layer.shadowOffset = .zero
        layer.shadowRadius = 5
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.shadowColor = NSColor.controlAccentColor.cgColor
        }
        layer.shadowOpacity = isRecording ? 0.45 : 0
        guard isRecording, !SettingsMotion.isReduced else { return }
        let pulse = CABasicAnimation(keyPath: "shadowOpacity")
        pulse.fromValue = 0.15
        pulse.toValue = 0.6
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: Self.pulseKey)
    }

    private func refreshUI() {
        if isRecording {
            label.isHidden = false
            label.textColor = needsModifier ? .systemRed : .controlAccentColor
            label.stringValue = needsModifier
                ? L10n.t("请加修饰键或按 F 键", "Use modifiers or an F-key")
                : L10n.t("按下快捷键…", "Type shortcut…")
            toolTip = needsModifier ? L10n.recNeedModifier : L10n.recPressKeys
        } else {
            // A binding draws as keycaps; the label only carries the empty-state prompt.
            label.isHidden = !caps.isEmpty
            label.textColor = .tertiaryLabelColor
            label.stringValue = L10n.t("录制快捷键", "Record Shortcut")
            toolTip = L10n.recClickToSet
        }
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 7, cornerHeight: 7, transform: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let well = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        (isHovered && !isRecording ? SettingsPalette.wellHover : SettingsPalette.well).setFill()
        well.fill()
        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
            well.fill()
        }
        let border: NSColor = isRecording ? .controlAccentColor : SettingsPalette.wellBorder
        border.setStroke()
        well.lineWidth = isRecording ? 1.5 : 1
        well.stroke()
        if !isRecording && !caps.isEmpty { drawKeycaps() }
    }

    /// Small raised keys centered in the well: a face, a darker lip below it and a hairline rim.
    private func drawKeycaps() {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let height: CGFloat = 17, gap: CGFloat = 3
        let widths = caps.map { max(height, ceil(($0 as NSString).size(withAttributes: attributes).width) + 9) }
        let total = widths.reduce(0, +) + gap * CGFloat(caps.count - 1)
        var x = floor((bounds.width - total) / 2)
        let y = floor((bounds.height - height) / 2) + 0.5
        for (legend, width) in zip(caps, widths) {
            let face = NSRect(x: x, y: y, width: width, height: height)
            let lip = NSBezierPath(roundedRect: face.offsetBy(dx: 0, dy: -1), xRadius: 4, yRadius: 4)
            SettingsPalette.keycapEdge.setFill()
            lip.fill()
            let key = NSBezierPath(roundedRect: face, xRadius: 4, yRadius: 4)
            SettingsPalette.keycap.setFill()
            key.fill()
            SettingsPalette.wellBorder.setStroke()
            key.lineWidth = 0.5
            key.stroke()
            let size = (legend as NSString).size(withAttributes: attributes)
            (legend as NSString).draw(at: NSPoint(x: face.midX - size.width / 2, y: face.midY - size.height / 2 + 0.5),
                                      withAttributes: attributes)
            x += width + gap
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? {
        super.accessibilityLabel() ?? L10n.t("录制快捷键", "Record Shortcut")
    }
    override func accessibilityValue() -> Any? {
        if isRecording { return needsModifier ? L10n.recNeedModifier : L10n.recPressKeys }
        return currentText.isEmpty ? L10n.t("未设置", "Not set") : currentText
    }
    override func accessibilityHelp() -> String? {
        L10n.t("按空格键或回车开始录制，按 Escape 取消。", "Press Space or Return to record; Escape cancels.")
    }
    override func accessibilityPerformPress() -> Bool {
        guard window?.makeFirstResponder(self) == true else { return false }
        setRecording(!isRecording)
        return true
    }
}
