import AppKit
import SitchCore
import SitchShelf

/// Menu-bar presence: the Mac counterpart of windows/Sitch/Shell/TrayController.cs. Same menu;
/// clicking opens it (macOS convention — the Windows tray icon captured on left-click).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let captureItem = NSMenuItem(title: "Capture Region", action: #selector(AppDelegate.captureRegion(_:)), keyEquivalent: "")
    private let recaptureItem = NSMenuItem(title: "Recapture Last Region", action: #selector(AppDelegate.recaptureLast(_:)), keyEquivalent: "")
    private let quickCopyItem = NSMenuItem(title: "Quick Capture → Clipboard", action: #selector(AppDelegate.quickCaptureToClipboard(_:)), keyEquivalent: "")
    private let fullScreen = NSMenuItem(title: "Capture Full Screen", action: nil, keyEquivalent: "")
    private let scrollItem = NSMenuItem(title: "Scrolling Capture", action: #selector(scrollCapture), keyEquivalent: "")
    private let recordItem = NSMenuItem(title: "Record GIF", action: #selector(record), keyEquivalent: "")
    private let recordOtherItem = NSMenuItem(title: "Record Video (MP4)", action: #selector(recordOther), keyEquivalent: "")
    private let pinItem = NSMenuItem(title: "Pin Clipboard Image", action: #selector(pinClipboard), keyEquivalent: "")
    private let unpinAllItem = NSMenuItem(title: "Close All Pins", action: #selector(closeAllPins), keyEquivalent: "")
    // The screenshot line (merged from Snapline): shown only while it runs.
    private let lineItem = NSMenuItem(title: "Show Screenshot Line", action: #selector(toggleLine), keyEquivalent: "")
    private let noteItem = NSMenuItem(title: "New Note", action: nil, keyEquivalent: "")
    private let lineSettingsItem = NSMenuItem(title: "Line Settings…", action: #selector(showLineSettings), keyEquivalent: "")
    private let lineSeparator = NSMenuItem.separator()

    override init() {
        super.init()
        item.button?.image = Self.glyph
        item.button?.toolTip = Loc.t("Sitch — Capture. Annotate. Share.")

        let menu = NSMenu()
        menu.addItem(captureItem)
        menu.addItem(withTitle: "Capture Window", action: #selector(AppDelegate.captureWindow(_:)), keyEquivalent: "")
        fullScreen.submenu = NSMenu()
        fullScreen.submenu?.delegate = self
        menu.addItem(fullScreen)
        menu.addItem(scrollItem)
        menu.addItem(recordItem)
        menu.addItem(recordOtherItem)
        menu.addItem(recaptureItem)
        menu.addItem(.separator())
        menu.addItem(quickCopyItem)
        menu.addItem(withTitle: "Quick Capture → File", action: #selector(AppDelegate.quickCaptureToFile(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Image…", action: #selector(AppDelegate.openImage(_:)), keyEquivalent: "")
        menu.addItem(pinItem)
        menu.addItem(unpinAllItem)
        menu.addItem(.separator())
        noteItem.submenu = NSMenu()
        for entry in [lineItem, noteItem, lineSettingsItem, lineSeparator] { menu.addItem(entry) }
        menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "About Sitch", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sitch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        for entry in menu.items where entry.action != nil && entry.action != #selector(NSApplication.terminate(_:)) {
            entry.target = NSApp.delegate
        }
        for entry in [lineItem, lineSettingsItem, scrollItem, recordItem, recordOtherItem, pinItem, unpinAllItem] { entry.target = self }
        for entry in menu.items { entry.title = Loc.t(entry.title) }
        menu.delegate = self
        item.menu = menu
        refreshShortcuts()
    }

    /// Hotkeys are rebindable in Settings — show the current ones next to their items.
    func refreshShortcuts() {
        Self.show(AppController.shared.settings.captureHotkey, on: captureItem)
        Self.show(AppController.shared.settings.recaptureHotkey, on: recaptureItem)
        Self.show(AppController.shared.settings.quickCopyHotkey, on: quickCopyItem)
        Self.show(AppController.shared.settings.scrollHotkey, on: scrollItem)
        Self.show(AppController.shared.settings.recordHotkey, on: recordItem)
        Self.show(AppController.shared.settings.pinHotkey, on: pinItem)
    }

    // Displays come and go — rebuild the submenu each time it opens. The main menu refreshes
    // the screenshot line's items.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === item.menu {
            updateLineItems()
            let mp4 = AppController.shared.settings.recordFormat == "mp4"
            recordItem.title = Loc.t(mp4 ? "Record Video (MP4)" : "Record GIF")
            recordOtherItem.title = Loc.t(mp4 ? "Record GIF" : "Record Video (MP4)")
            unpinAllItem.isHidden = Pins.count == 0
            return
        }
        menu.removeAllItems()
        for (i, d) in CaptureController.displays().enumerated() {
            let entry = NSMenuItem(
                title: Loc.f("Display {0} — {1} ({2}×{3})", i + 1, d.name, d.pixelWidth, d.pixelHeight) + (d.isMain ? Loc.t(" — main") : ""),
                action: #selector(AppDelegate.captureFullScreen(_:)), keyEquivalent: "")
            entry.target = NSApp.delegate
            entry.representedObject = d.id
            menu.addItem(entry)
        }
        if menu.items.isEmpty { menu.addItem(withTitle: Loc.t("No displays"), action: nil, keyEquivalent: "") }
    }

    private func updateLineItems() {
        let shelf = AppController.shared.shelf
        for entry in [lineItem, noteItem, lineSettingsItem, lineSeparator] { entry.isHidden = shelf == nil }
        guard let shelf else { return }
        lineItem.title = Loc.t(shelf.isRevealed ? "Hide Screenshot Line" : "Show Screenshot Line")
        lineItem.keyEquivalent = "t"
        lineItem.keyEquivalentModifierMask = [.control, .option]
        noteItem.submenu?.removeAllItems()
        for color in ShelfController.noteColors {
            let entry = NSMenuItem(title: ShelfController.noteName(color), action: #selector(newNote(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = color
            noteItem.submenu?.addItem(entry)
        }
    }

    @objc private func scrollCapture() { AppController.shared.scrollCapture() }
    @objc private func record() { AppController.shared.record() }
    @objc private func recordOther() {
        AppController.shared.record(format: AppController.shared.settings.recordFormat == "mp4" ? "gif" : "mp4")
    }
    @objc private func pinClipboard() { Pins.pinClipboard() }
    @objc private func closeAllPins() { Pins.closeAll() }

    @objc private func toggleLine() { AppController.shared.shelf?.toggleLine() }
    @objc private func showLineSettings() { AppController.shared.shelf?.showSettings() }
    @objc private func newNote(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? String else { return }
        AppController.shared.shelf?.newNote(color: color)
    }

    private static func show(_ hotkey: String, on item: NSMenuItem) {
        guard let chord = HotkeyChord.parse(hotkey), let key = keyEquivalent(for: chord.key) else {
            item.keyEquivalent = ""
            return
        }
        item.keyEquivalent = key
        var mods: NSEvent.ModifierFlags = []
        if chord.modifiers.contains(.command) { mods.insert(.command) }
        if chord.modifiers.contains(.option) { mods.insert(.option) }
        if chord.modifiers.contains(.control) { mods.insert(.control) }
        if chord.modifiers.contains(.shift) { mods.insert(.shift) }
        item.keyEquivalentModifierMask = mods
    }

    /// Display-only key equivalent (the global hotkey does the work; this just shows it).
    private static func keyEquivalent(for key: String) -> String? {
        if key.count == 1 { return key.lowercased() }
        if key.hasPrefix("F"), let n = Int(key.dropFirst()), (1...20).contains(n),
           let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
            return String(Character(scalar))
        }
        return key == "Space" ? " " : nil
    }

    /// The app icon's tapered arrow as a template image, so the menu bar tints it for light/dark.
    private static let glyph: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            // Outline from the icon's 256-px design (see scripts/make-icon.swift), fitted to 18 pt.
            let points: [(CGFloat, CGFloat)] =
                [(188, 73), (171, 161), (144, 134), (96, 213), (49, 165), (127, 117), (101, 90)]
            let scale: CGFloat = 16 / 140, cx: CGFloat = 118.5, cy: CGFloat = 143
            let path = NSBezierPath()
            for (i, (x, y)) in points.enumerated() {
                let p = NSPoint(x: 9 + (x - cx) * scale, y: 9 + (y - cy) * scale)
                if i == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            path.close()
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
