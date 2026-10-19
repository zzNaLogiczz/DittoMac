import AppKit
@testable import DittoMacKit

// Render our own view hierarchy offscreen. Never launches AppDelegate, registers
// hotkeys, monitors the system clipboard, opens the user database or reads Keychain.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let repository = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
app.applicationIconImage = NSImage(contentsOf: repository.appendingPathComponent("Resources/AppIcon.icns"))
let suiteName = "dittomac-settings-preview-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
DittoSettings.defaults = defaults
defer { defaults.removePersistentDomain(forName: suiteName) }
let store = ClipStore(path: ":memory:")

func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
}

/// Capture the whole window frame view so the unified toolbar title is part of the fixture.
/// Offscreen caching omits window-server effects (materials, vibrancy, layer shadows).
func snapshot(_ window: NSWindow, to url: URL) throws -> NSSize {
    let frameView = window.contentView!.superview ?? window.contentView!
    frameView.layoutSubtreeIfNeeded()
    guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
        fatalError("Unable to create bitmap")
    }
    frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    return frameView.bounds.size
}

func smokeCheck(_ controller: SettingsWindowController) {
    let window = controller.window!
    let views = descendants(window.contentView!)
    let search = views.compactMap { $0 as? NSSearchField }.first!
    let sidebarTable = views.compactMap { $0 as? NSTableView }.first {
        $0.accessibilityLabel() == L10n.t("设置分类", "Settings categories")
    }!
    let cases: [(String, SettingsSection)] = [(L10n.menuTransparency, .appearance),
        (L10n.setKeepCount, .clipboard), (L10n.menuAlwaysShowDescription, .appearance)]
    for (query, expected) in cases {
        search.stringValue = query
        search.sendAction(search.action, to: search.target)
        precondition(sidebarTable.numberOfRows == 1, "Search does not find \(query)")
        sidebarTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let visible = views.filter { $0.identifier?.rawValue.hasPrefix("settings.page.") == true && !$0.isHidden }
        precondition(visible.count == 1 && visible[0].identifier?.rawValue == "settings.page.\(expected.rawValue)")
    }
    search.stringValue = ""
    search.sendAction(search.action, to: search.target)
    precondition(sidebarTable.numberOfRows == SettingsSection.allCases.count)

    defaults.set(20, forKey: DittoSettings.transparencyPercentKey)
    defaults.set(true, forKey: DittoSettings.alwaysShowDescriptionKey)
    NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
    let popup = views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == L10n.menuTransparency }!
    precondition((popup.selectedItem?.representedObject as? Int) == 20, "Quick Options change was not reflected")
    let toggle = views.compactMap { $0 as? NSSwitch }.first { $0.accessibilityLabel() == L10n.menuAlwaysShowDescription }!
    precondition(toggle.state == .on)
    defaults.removeObject(forKey: DittoSettings.transparencyPercentKey)
    defaults.removeObject(forKey: DittoSettings.alwaysShowDescriptionKey)
    NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)

    controller.selectSection(.shortcuts, animated: false)
    let recorder = views.compactMap { $0 as? HotKeyRecorderView }.first!
    var states: [Bool] = []
    let observer = NotificationCenter.default.addObserver(forName: .dittoHotKeyRecording, object: nil, queue: nil) {
        states.append($0.userInfo?["recording"] as? Bool ?? false)
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    precondition(recorder.accessibilityPerformPress())
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)!
    precondition(recorder.performKeyEquivalent(with: event), "Recorder did not consume menu shortcut")
    precondition(recorder.currentValue?.code == 12 && states.suffix(2) == [true, false])
    precondition(recorder.accessibilityPerformPress())
    controller.selectSection(.general, animated: false)
    precondition(states.last == false, "Changing pages left hotkey recording active")
    defaults.removeObject(forKey: DittoSettings.hotKeyCodeKey)
    defaults.removeObject(forKey: DittoSettings.hotKeyModsKey)
    print("PASS: setting-label search, category navigation, Quick Options state sync, command-key recording and cancellation")
}

func verifyPanelCommandPriority() {
    let panel = DittoPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    defer { panel.close(); PanelAccels.resetToDefault(.pasteSelected) }
    let table = DittoTableView()
    table.addTableColumn(NSTableColumn(identifier: .init("fixture")))
    panel.contentView = table
    precondition(panel.makeFirstResponder(table))
    var received: [UInt16] = []
    table.onKeyDown = { received.append($0.keyCode) }
    for (code, character) in [(UInt16(12), "q"), (UInt16(4), "h"), (UInt16(43), ",")] {
        PanelAccels.setBinding(KeyCombo(keyCode: code, carbonModifiers: DittoSettings.carbonMask(from: .command)), for: .pasteSelected)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
        precondition(panel.performKeyEquivalent(with: event), "Panel command lost to app menu")
    }
    precondition(received == [12, 4, 43])
    let field = PanelSearchField(frame: NSRect(x: 0, y: 0, width: 250, height: 28))
    panel.contentView = field
    precondition(panel.makeFirstResponder(field))
    var submitted = false
    field.onSubmit = { submitted = true }
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: panel.windowNumber, context: nil,
        characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43)!
    precondition(panel.performKeyEquivalent(with: event) && submitted, "Search submit binding lost to app menu")
    print("PASS: custom panel Cmd-Q / Cmd-H / Cmd-comma bindings retain priority over native menus")
}

verifyPanelCommandPriority()

for language in ["zh", "en"] {
    defaults.set(language, forKey: L10n.languageKey)
    for mode in ["light", "dark"] {
        app.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
        let controller = SettingsWindowController(store: store, preview: true)
        let window = controller.window!
        window.setContentSize(NSSize(width: 880, height: 650))
        window.appearance = app.appearance
        for section in SettingsSection.allCases {
            controller.selectSection(section, animated: false)
            let content = window.contentView!
            content.layoutSubtreeIfNeeded()
            precondition(content.bounds.width == 880, "Settings width grew beyond the requested size")
            let filename = "\(language)-\(mode)-\(section.rawValue).png"
            let size = try snapshot(window, to: output.appendingPathComponent(filename))
            print("Rendered \(filename) \(Int(size.width))×\(Int(size.height))")
        }
        // Minimum supported window width must also keep controls in the content area.
        window.setContentSize(NSSize(width: 800, height: 580))
        controller.selectSection(.shortcuts, animated: false)
        let content = window.contentView!
        content.layoutSubtreeIfNeeded()
        precondition(content.bounds.width == 800, "Minimum settings width is not respected")
        _ = try snapshot(window, to: output.appendingPathComponent("\(language)-\(mode)-minimum.png"))
        smokeCheck(controller)
        window.close()
    }
}
print("Settings preview completed without desktop interaction.")
