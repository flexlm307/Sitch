import AppKit
import SitchCore

/// Opens and tracks pins: captures floating above every window (windows/Sitch/Shell/PinWindow.cs parity).
@MainActor
enum Pins {
    private static var open: [PinWindow] = []

    static var count: Int { open.count }

    /// `at`: the global Quartz rect (points) the image came from — the pin lands exactly over it.
    /// Nil centres it on the pointer.
    static func pin(_ image: CGImage, pointScale: CGFloat, at: CGRect? = nil) {
        let size = CGSize(width: CGFloat(image.width) / pointScale, height: CGFloat(image.height) / pointScale)
        let place = at ?? {
            let p = ScreenSpace.toQuartz(NSEvent.mouseLocation)
            return CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height)
        }()
        let pin = PinWindow(image: image, pointScale: pointScale, place: place)
        open.append(pin)
        pin.onClose = { [weak pin] in open.removeAll { $0 === pin } }
        pin.makeKeyAndOrderFront(nil)
    }

    static func pinClipboard() {
        guard let (image, scale) = ClipboardImage.read() else {
            Toast.show(Loc.t("No image on the clipboard to pin."))
            return
        }
        pin(image, pointScale: scale)
    }

    static func pinFile(_ url: URL) {
        guard let (image, scale) = AppController.loadImage(url) else {
            Toast.show(Loc.f("Couldn't open {0}", url.lastPathComponent))
            return
        }
        pin(image, pointScale: scale)
    }

    static func closeAll() {
        for pin in open { pin.close() }
    }
}

/// The image on the general pasteboard (pixels and their point scale), or the first image file copied
/// in Finder.
enum ClipboardImage {
    @MainActor static func read() -> (CGImage, CGFloat)? {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let first = urls.first, let loaded = AppController.loadImage(first) {
            return loaded
        }
        guard let image = NSImage(pasteboard: pb),
              let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init),
              let cg = rep.cgImage else { return nil }
        let scale = image.size.width > 0 ? max(1, (CGFloat(cg.width) / image.size.width).rounded()) : 1
        return (cg, scale)
    }
}

/// One pin: a borderless floating panel showing a capture at its on-screen size with the system
/// shadow. Drag to move, scroll to zoom, ⌘-scroll for opacity, double-click or Esc to close,
/// right-click for the rest. Non-activating, so pinning never pulls focus from the app in front.
@MainActor
final class PinWindow: NSPanel {
    private static let minZoom: CGFloat = 0.1, maxZoom: CGFloat = 5

    private let image: CGImage
    private let pointScale: CGFloat
    private let imageView: PinImageView
    private var zoom: CGFloat = 1
    var onClose: (() -> Void)?

    init(image: CGImage, pointScale: CGFloat, place: CGRect) {
        self.image = image
        self.pointScale = pointScale
        imageView = PinImageView(image: image)
        super.init(contentRect: ScreenSpace.toAppKit(place), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = Loc.t("Pinned capture")
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        imageView.owner = self
        contentView = imageView
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }

    private var naturalSize: CGSize {
        CGSize(width: CGFloat(image.width) / pointScale, height: CGFloat(image.height) / pointScale)
    }

    func setZoom(_ z: CGFloat) {
        zoom = clamp(z, Self.minZoom, Self.maxZoom)
        // Zoom about the top-left corner, as the Windows pin grows from its origin.
        let size = CGSize(width: naturalSize.width * zoom, height: naturalSize.height * zoom)
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
        Toast.show("\(Int((zoom * 100).rounded()))%")
    }

    func scrolled(_ event: NSEvent) {
        let up = event.scrollingDeltaY > 0
        if event.modifierFlags.contains(.command) {
            alphaValue = clamp(alphaValue + (up ? 0.1 : -0.1), 0.2, 1)
        } else if event.scrollingDeltaY != 0 {
            setZoom(zoom * (up ? 1.1 : 1 / 1.1))
        }
    }

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        switch (event.keyCode, cmd) {
        case (53, _): close()                     // Esc
        case (8, true): copyImage()               // ⌘C
        case (1, true): saveAs()                  // ⌘S
        case (29, true): setZoom(1)               // ⌘0
        default: super.keyDown(with: event)
        }
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionMenuItem(title: Loc.t("Copy") + "\t⌘C") { [weak self] in self?.copyImage() })
        menu.addItem(ActionMenuItem(title: Loc.t("Save As…") + "\t⌘S") { [weak self] in self?.saveAs() })
        menu.addItem(ActionMenuItem(title: Loc.t("Open in editor")) { [weak self] in
            guard let self else { return }
            AppController.shared.openEditor(image: image, title: Loc.t("Untitled"), pointScale: pointScale)
            close()
        })
        menu.addItem(ActionMenuItem(title: Loc.t("Extract text")) { [weak self] in
            guard let self else { return }
            OcrWindow.extract(from: image, near: self)
        })
        if MinerU.configured {
            menu.addItem(ActionMenuItem(title: Loc.t("Restore as Markdown (MinerU)")) { [weak self] in
                guard let self else { return }
                MinerU.restore(image, pointScale: pointScale)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(title: Loc.t("Actual size") + "\t⌘0") { [weak self] in self?.setZoom(1) })
        let opacity = NSMenuItem(title: Loc.t("Opacity"), action: nil, keyEquivalent: "")
        opacity.submenu = NSMenu()
        for pct in [100, 80, 60, 40] {
            let item = ActionMenuItem(title: "\(pct)%") { [weak self] in self?.alphaValue = CGFloat(pct) / 100 }
            item.state = abs(alphaValue * 100 - CGFloat(pct)) < 5 ? .on : .off
            opacity.submenu?.addItem(item)
        }
        menu.addItem(opacity)
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(title: Loc.t("Close") + "\tEsc") { [weak self] in self?.close() })
        if Pins.count > 1 { menu.addItem(ActionMenuItem(title: Loc.t("Close all pins")) { Pins.closeAll() }) }
        return menu
    }

    private func copyImage() {
        Toast.show(ClipboardHelper.copy(image, pointScale: pointScale) ? Loc.t("Copied to clipboard.") : Loc.t("Clipboard is busy — try again."))
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Sitch \(Exporters.timestamp(Date())).png"
        panel.allowedContentTypes = Exporters.formats.compactMap(EditorWindowController.contentType)
        let folder = AppController.shared.settings.defaultSaveFolder
        if !folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true) }
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Exporters.save(image, to: url, pointScale: pointScale)
            Toast.show(Loc.f("Saved {0}", url.lastPathComponent))
            MediaMini.compressLater(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = Loc.t("Save failed.")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

/// The pin's content: the image scaled to the window, a hairline border that turns pink on hover.
@MainActor
private final class PinImageView: NSView {
    weak var owner: PinWindow?
    private let image: CGImage
    private var hovering = false

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        Draw.image(image, in: bounds, ctx)
        let border = hovering ? RGBAColor.pink.nsColor : NSColor(white: 0.5, alpha: 0.4)
        border.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { owner?.close(); return }
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) { owner?.scrolled(event) }

    override func menu(for event: NSEvent) -> NSMenu? { owner?.menu() }
}
