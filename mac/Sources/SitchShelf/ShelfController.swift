import AppKit
import Carbon
import Combine
import ImageIO
import SwiftUI

/// The screenshot line (formerly the standalone Snapline app): revealing and tucking away the
/// line, its shortcut, the folders it watches, and captures flying to it. Sitch owns the menu
/// bar item, capture and the editor; it creates one of these while the line is on and wires
/// the hooks below. This target stays in the Swift 5 language mode Snapline was written in.
@MainActor
public final class ShelfController: NSObject, NSMenuDelegate {
    /// Opens a photo in Sitch's editor, saving back into the file.
    public var onEdit: @MainActor (URL) -> Void = { _ in }
    /// Starts a Sitch capture.
    public var onNewCapture: @MainActor () -> Void = {}
    public var onSitchSettings: @MainActor () -> Void = {}
    public var onQuit: @MainActor () -> Void = {}
    /// A photo's "Pin to screen" (Sitch's pins float it above every window).
    public var onPin: @MainActor (URL) -> Void = { _ in }
    /// A photo's "Restore as Markdown"; shown only while `canRestoreMarkdown` says MinerU is there.
    public var onRestoreMarkdown: @MainActor (URL) -> Void = { _ in }
    public var canRestoreMarkdown: @MainActor () -> Bool = { false }
    /// "Copy text": Sitch's OCR (its engine setting); nil = the line's own Vision reader.
    public var readText: (@MainActor (URL) async -> String?)?
    /// "zh" makes the line Chinese when its own language setting is "auto" (Sitch's Language).
    nonisolated(unsafe) public static var hostLanguage: String? {
        didSet { Localization.refresh() }
    }

    private let line = Line()
    private var panel: LinePanel!
    private let menu = NSMenu()
    private var watcher: ScreenshotWatcher!
    /// In inbox mode, a second watcher on the Desktop. If a macOS version
    /// ignores the screenshot settings (macOS 27 renamed one), captures keep
    /// landing on the Desktop, and they still hang on the line.
    private var safetyWatcher: ScreenshotWatcher?
    /// Captures that only reach the clipboard (Cmd+Ctrl+Shift+4).
    private var clipboard: ClipboardWatcher!
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Whether the line has slid down into view.
    public private(set) var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    /// After a click in the menu bar the line stays up there hidden until the
    /// pointer leaves the menu bar, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var awaySince: Date?
    /// Whether the line should be up, if nothing prevents it. A full screen
    /// app on that screen does: the line waits until you leave full screen.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false
    private var lastLiveCount = 0
    /// The screen a new capture was taken on: the line goes there.
    private var pendingScreen: NSScreen?

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    public override init() {
        super.init()
        start()
    }

    /// Whether the standalone Snapline app is running: two lines would fight over the top edge.
    public static var snaplineRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "app.snapline.Snapline").isEmpty
    }

    private func start() {
        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        panel.placeOnScreen()
        updateCapacity()

        // A snapshot left by a run that never quit cleanly goes back first.
        Inbox.recoverIfNeeded()
        Originals.sweep(hanging: line.items.map(\.url))
        if Inbox.isEnabled { Inbox.apply() }
        restoreSettingsOnTermination()
        startWatcher()
        startClipboardWatcher()

        hotKey = HotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in
            self?.toggle()
        }

        menu.delegate = self
        watchMenuBarClicks()
        applyAppearance()

        Markup.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        line.onEdit = { [weak self] url in self?.onEdit(url) }
        line.onPin = { [weak self] url in self?.onPin(url) }
        line.onRestoreMarkdown = { [weak self] url in self?.onRestoreMarkdown(url) }
        line.canRestoreMarkdown = { [weak self] in self?.canRestoreMarkdown() ?? false }
        line.readText = { [weak self] url in
            if let read = self?.readText { return await read(url) }
            return await Ocr.read(url)
        }
        line.onFall = { [weak self] item in self?.fall(item) }

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observe(workspace, name) { [weak self] _ in
                self?.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
            }
        }

        let center = NotificationCenter.default
        observe(center, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
            self?.panel.placeOnScreen()
            self?.updateCapacity()
        }
        // The paper tag on the line, or a right-click on the rope: the menu.
        observe(center, .snaplineMenuRequested) { [weak self] _ in self?.popMenu() }
        observe(center, .lineNewCapture) { [weak self] _ in self?.onNewCapture() }
        observe(center, .snaplineSettingsChanged) { [weak self] _ in self?.settingsChanged() }
        observe(center, .snaplineInboxToggle) { [weak self] note in
            self?.setInbox(note.object as? Bool ?? !Inbox.isEnabled)
        }

        if !Inbox.wasOffered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerInbox() }
        }

        if !Settings.current.welcomed {
            Settings.current.welcomed = true
            Settings.save()
            keepOpen = true
            wanted = true
            refresh()
            reveal(pinned: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.line.liveCount == 0 else { return }
                self.keepOpen = false
                self.wanted = false
                self.refresh()
            }
        } else if line.liveCount > 0 {
            // Photos restored from last time: the line is there, tucked away.
            wanted = true
            lastLiveCount = line.liveCount
            refresh()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { handler(note) }
        }
        observers.append((center, token))
    }

    /// Sitch is quitting, or the line was turned off: put the screenshot settings back and
    /// take everything off the screen. The photos stay remembered for next time.
    public func stop() {
        if Inbox.isEnabled { Inbox.restore() }
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        for monitor in clickMonitors { NSEvent.removeMonitor(monitor) }
        clickMonitors.removeAll()
        watcher?.stop()
        safetyWatcher?.stop()
        clipboard?.stop()
        hotKey = nil
        stopMouseTracking()
        panel?.orderOut(nil)
        Settings.save()
    }

    // MARK: Sitch

    /// A Sitch capture: written to the line's folder and hung at once, lifting off from where
    /// it was taken (`sourceRect`, global coordinates with the origin at the top left).
    /// `pointScale` (2 for a Retina capture) is written as the PNG's DPI, so the file keeps its on-screen
    /// size when it is pinned or opened in Sitch's editor later.
    public func hang(image: CGImage, sourceRect: CGRect?, pointScale: CGFloat = 1) {
        let url = Inbox.newCapturePath()
        do {
            try FileManager.default.createDirectory(at: Inbox.folder, withIntermediateDirectories: true)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
            let dpi = 72 * max(1, pointScale)
            CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            log.error("Could not save a capture for the line: \(error.localizedDescription, privacy: .public)")
            return
        }
        var from: CGRect?
        if let r = sourceRect, r.width > 2, r.height > 2, let main = NSScreen.screens.first {
            from = CGRect(x: r.minX, y: main.frame.maxY - r.maxY, width: r.width, height: r.height)
        }
        hangCapture(url, from: from)
    }

    /// Sitch's editor wrote back into a file: the card shows the new version.
    public func fileSaved(_ url: URL) {
        let path = url.standardizedFileURL.path
        if let item = line.items.first(where: { !$0.falling && $0.url.standardizedFileURL.path == path }) {
            line.reloadThumbnail(for: item.url)
        }
    }

    public var lineToggleKey: String { "⌃⌥T" }

    public static var noteColors: [String] { Notes.colors }
    public static func noteName(_ key: String) -> String { L(Notes.name(key)) }

    public func newNote(color: String) {
        showLine()
        line.newNote(color: color)
    }

    public func showSettings() { SettingsWindow.show() }

    public func toggleLine() { toggle() }

    // MARK: Settings

    private func settingsChanged() {
        applyAppearance()
        clipboard.enabled = Settings.current.catchClipboard
        panel.placeOnScreen(panel.screen)
        line.look += 1
    }

    /// Only the line's own windows follow its Appearance setting; Sitch has its own theme.
    private func applyAppearance() {
        let appearance: NSAppearance? = switch Settings.current.appearance {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
        panel?.appearance = appearance
        menu.appearance = appearance
    }

    // MARK: Inbox mode

    private func startWatcher() {
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        watcher = ScreenshotWatcher(
            onNew: { [weak self] url in self?.hangCapture(url) },
            onChange: { [weak self] in self?.line.prune() })
        watcher.start()
        if Inbox.isEnabled, watcher.folder.standardizedFileURL != ScreenshotWatcher.desktop.standardizedFileURL {
            let safety = ScreenshotWatcher(
                folder: ScreenshotWatcher.desktop,
                onNew: { [weak self] url in
                    log.notice("Screenshot landed on the Desktop despite inbox mode: \(url.lastPathComponent, privacy: .public)")
                    self?.hangCapture(url)
                },
                onChange: { [weak self] in self?.line.prune() })
            safety.start()
            safetyWatcher = safety
        }
    }

    private func startClipboardWatcher() {
        clipboard = ClipboardWatcher(
            onCapture: { [weak self] url, _ in self?.hangCapture(url) },
            recentlyHungFromFile: { [weak self] size in
                guard let self else { return false }
                return self.line.items.contains { item in
                    !item.falling && Date().timeIntervalSince(item.hungAt) < 5 && pixelSize(item.url) == size
                }
            })
        clipboard.enabled = Settings.current.catchClipboard
        clipboard.start()
    }

    private func setInbox(_ on: Bool) {
        Inbox.isEnabled = on
        if on { Inbox.apply() } else { Inbox.restore() }
        startWatcher()
    }

    /// Asked once. Changing system settings is the user's call, never ours.
    private func offerInbox() {
        Inbox.wasOffered = true
        let alert = NSAlert()
        alert.messageText = L("Let Sitch handle your screenshots?")
        alert.informativeText = L(
            "Screenshots will hang on the line the instant you take them, without the floating thumbnail, and will not pile up on your Desktop. Drag one to a folder to keep it, or discard it with the cross. You can turn this off from the line's menu, and your settings come back when Sitch quits.")
        alert.addButton(withTitle: L("Turn on"))
        alert.addButton(withTitle: L("Not now"))
        if let icon = NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
    }

    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                if Inbox.isEnabled { Inbox.restore() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    private func itemsChanged() {
        let live = line.liveCount
        if live > lastLiveCount {
            panel.placeOnScreen(pendingScreen)
            pendingScreen = nil
            updateCapacity()
            wanted = true
            refresh()
            reveal(peekFor: 2.5)
        } else if live == 0 && !keepOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.line.liveCount == 0, !self.keepOpen else { return }
                self.wanted = false
                self.refresh()
            }
        }
        lastLiveCount = live
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    private func hangCapture(_ url: URL) { hangCapture(url, from: captureRect(of: url)) }

    private func hangCapture(_ url: URL, from: CGRect?) {
        if let from {
            let center = CGPoint(x: from.midX, y: from.midY)
            pendingScreen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
        }
        guard let id = line.hang(url, flying: from != nil), let from else { return }
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: from)
        }
    }

    private func fly(_ id: UUID, from: CGRect) {
        guard isPresent, isRevealed, let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(3000, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    private func fall(_ item: Pegged) {
        guard isPresent, isRevealed, !item.flying, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), on: screen)
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let item = line.item(id) else { return nil }
        let width = panel.frame.width
        guard let x = Layout.positions(for: line, width: width)[id] else { return nil }
        let viewTop = Layout.ropeY(x: x, width: width) - Layout.pinAbove
        let cardTop = viewTop + PeggedView.cardOffsetBelowTop
        let size = PeggedView.cardSize(for: item.thumb.size)
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Decides whether the panel is ordered in at all: something to show,
    /// and no full screen app on that screen.
    private func refresh() {
        let blocked = panel.screen.map(FullScreen.isActive(on:))
            ?? LinePanel.screenUnderPointer().map(FullScreen.isActive(on:)) ?? false
        if wanted && !blocked {
            present()
        } else {
            dismiss()
        }
        // The cursor is watched while there is a line, even tucked away,
        // to notice it pushing against the top edge.
        if wanted { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel.orderOut(nil)
        }
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        line.revealed = on
        if !on {
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
        }
    }

    @objc private func toggle() {
        if isRevealed {
            setRevealed(false)
            if line.liveCount == 0 {
                keepOpen = false
                wanted = false
                refresh()
            }
        } else {
            showLine()
        }
    }

    private func showLine() {
        keepOpen = true
        wanted = true
        panel.placeOnScreen()
        updateCapacity()
        refresh()
        reveal(pinned: true)
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
    }

    /// How long the cursor rests against the top edge before the line comes
    /// down. Short enough to feel instant, long enough that a quick trip to
    /// the menu bar does not trigger it.
    private static let revealDelay: TimeInterval = 0.25

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts the line away.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.line.menuOpen else { return }
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { NSMouseInRect(p, Self.menuBarBand(of: $0), false) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if self.isRevealed {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { NSMouseInRect(mouse, Self.menuBarBand(of: $0), false) } ?? false
        if !inMenuBar { menuBarSuppressed = false }

        guard isRevealed else {
            // Resting in the menu bar brings the line down on that screen.
            // Pushing against the top edge is part of it, and it also works
            // when another display sits above and the pointer never stops.
            if let screen = screenUnderPointer, inMenuBar, !menuBarSuppressed,
               !FullScreen.isActive(on: screen) {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    if panel.screen != screen {
                        panel.placeOnScreen()
                        updateCapacity()
                    }
                    refresh()
                    reveal()
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside && pinned { pinned = false }

        // With "stay down until used", the line waits while something fresh hangs on it.
        let waiting = Settings.current.stayDownWhileUnused && line.hasUnused
        let busy = pinned || waiting || line.menuOpen || GrabView.isDragging || line.pressedID != nil || now < peekUntil
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo, the paper tag or the hint.
    /// Everywhere else, clicks go to whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging, !line.menuOpen else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        let overSomething = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
            || line.extraHitRects.contains { $0.contains(flipped) }
        if panel.ignoresMouseEvents == overSomething {
            panel.ignoresMouseEvents = !overSomething
        }
    }

    private func updateCapacity() {
        let usable = panel.frame.width - 200
        line.maxItems = max(3, min(12, Int(usable / Layout.spacing)))
    }

    // MARK: Menu

    /// The line's menu, popped up at the pointer when the paper tag on the
    /// line is clicked or the rope is right-clicked.
    private func popMenu() {
        menuNeedsUpdate(menu)
        line.menuOpen = true
        panel.ignoresMouseEvents = false
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        line.menuOpen = false
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(ClosureMenuItem(L("New capture")) { [weak self] in
            self?.onNewCapture()
        })

        let notes = NSMenu()
        for key in Notes.colors {
            let item = ClosureMenuItem(L(Notes.name(key))) { [weak self] in
                guard let self else { return }
                self.showLine()
                self.line.newNote(color: key)
            }
            item.image = Notes.swatch(key)
            notes.addItem(item)
        }
        let noteItem = NSMenuItem(title: L("New note"), action: nil, keyEquivalent: "")
        noteItem.submenu = notes
        menu.addItem(noteItem)

        menu.addItem(.separator())

        let toggleItem = ClosureMenuItem(isRevealed ? L("Hide line") : L("Show line")) { [weak self] in
            self?.toggle()
        }
        toggleItem.keyEquivalent = "t"
        toggleItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(toggleItem)

        let clearItem = ClosureMenuItem(L("Take everything down")) { [weak self] in
            self?.line.clear()
        }
        clearItem.isEnabled = line.liveCount > 0
        menu.addItem(clearItem)

        menu.addItem(.separator())

        let inbox = ClosureMenuItem(L("Handle screenshots")) { [weak self] in
            self?.setInbox(!Inbox.isEnabled)
        }
        inbox.state = Inbox.isEnabled ? .on : .off
        inbox.toolTip = L("Screenshots hang instantly and skip the Desktop")
        menu.addItem(inbox)

        let clip = ClosureMenuItem(L("Catch clipboard captures")) { [weak self] in
            Settings.current.catchClipboard.toggle()
            Settings.save()
            self?.clipboard.enabled = Settings.current.catchClipboard
        }
        clip.state = Settings.current.catchClipboard ? .on : .off
        clip.toolTip = L("Cmd+Ctrl+Shift+4 copies instead of saving; those hang too")
        menu.addItem(clip)

        let stay = ClosureMenuItem(L("Stay down until each capture is used")) {
            Settings.current.stayDownWhileUnused.toggle()
            Settings.save()
        }
        stay.state = Settings.current.stayDownWhileUnused ? .on : .off
        menu.addItem(stay)

        let takeDown = ClosureMenuItem(L("Take down after dragging into an app")) {
            Settings.current.takeDownAfterDrag.toggle()
            Settings.save()
        }
        takeDown.state = Settings.current.takeDownAfterDrag ? .on : .off
        menu.addItem(takeDown)

        menu.addItem(ClosureMenuItem(L("Open screenshots folder")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.watcher.folder)
        })

        menu.addItem(.separator())

        let sound = ClosureMenuItem(L("Sounds")) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)

        menu.addItem(ClosureMenuItem(L("Line settings…")) {
            SettingsWindow.show()
        })
        menu.addItem(ClosureMenuItem(L("Sitch settings…")) { [weak self] in
            self?.onSitchSettings()
        })

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit Sitch")) { [weak self] in
            self?.onQuit()
        })
    }
}
