import AppKit
import SitchCore

/// One borderless overlay per display showing that display's slice of the frozen desktop
/// (Windows OverlayWindow parity). It draws in local top-left points but reports every pointer
/// position to the controller in global Quartz points, so selection math lives in one space.
@MainActor
final class OverlayWindow: NSWindow {
    let display: DisplayGeometry

    init(controller: CaptureController, display: DisplayGeometry, frozen: CGImage?) {
        self.display = display
        super.init(contentRect: ScreenSpace.toAppKit(display.frame), styleMask: .borderless,
                   backing: .buffered, defer: false)
        // Above the menu bar and Dock, on every Space, over full-screen apps.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        contentView = OverlayView(controller: controller, display: display, frozen: frozen)
        setFrame(ScreenSpace.toAppKit(display.frame), display: false)
    }

    // Borderless windows refuse key status by default; the one under the cursor needs Esc/arrows.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func repaint() { contentView?.needsDisplay = true }
}

@MainActor
private final class OverlayView: NSView {
    private unowned let controller: CaptureController
    private let display: DisplayGeometry
    private let frozen: CGImage?

    init(controller: CaptureController, display: DisplayGeometry, frozen: CGImage?) {
        self.controller = controller
        self.display = display
        self.frozen = frozen
        super.init(frame: NSRect(origin: .zero, size: display.frame.size))
        // activeAlways: overlays that aren't key (other displays) still track the pointer.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var cursor: NSCursor { controller.mode == .region ? .crosshair : .arrow }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    /// The pointer in global Quartz points (event locations are per-window; this is not).
    private var pointer: CGPoint { ScreenSpace.toQuartz(NSEvent.mouseLocation) }

    // MARK: - Input

    override func mouseMoved(with event: NSEvent) {
        cursor.set()
        controller.updatePointer(pointer)
    }

    override func mouseDown(with event: NSEvent) {
        if controller.mode == .region { controller.beginDrag(pointer, on: display) }
    }

    override func mouseDragged(with event: NSEvent) { controller.updatePointer(pointer) }
    override func mouseUp(with event: NSEvent) { controller.endDrag(pointer) }
    override func rightMouseDown(with event: NSEvent) { controller.cancel() }

    override func scrollWheel(with event: NSEvent) {
        // One step per gesture, not per momentum tick: a trackpad flick would race to the window.
        guard event.momentumPhase.isEmpty, abs(event.scrollingDeltaY) > 0.5 else { return }
        if event.phase == .changed || event.phase == [] {
            let now = event.timestamp
            if now - lastWheelStep < 0.12 { return }
            lastWheelStep = now
        }
        // Natural scrolling flips the sign; "up" (content moving down) means outward, as on Windows.
        let up = (event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY) > 0
        controller.stepSnap(outward: up)
    }

    private var lastWheelStep: TimeInterval = 0

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        // ⌥ for 10-pt steps: Ctrl+arrows belong to Mission Control / Spaces.
        let step: CGFloat = event.modifierFlags.contains(.option) ? 10 : 1
        switch event.keyCode {
        case 53: controller.cancel()                                 // Esc abandons the whole capture
        case 36, 76: controller.confirmSelection()                   // Return / Enter
        case 123: controller.nudgeSelection(-step, 0, resize: shift)  // ←
        case 124: controller.nudgeSelection(step, 0, resize: shift)   // →
        case 126: controller.nudgeSelection(0, -step, resize: shift)  // ↑
        case 125: controller.nudgeSelection(0, step, resize: shift)   // ↓
        case 99: controller.pinTarget()                              // F3
        default:
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            guard mods.isEmpty else { super.keyDown(with: event); return }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "s" where !shift: controller.scrollTarget()
            case "r" where !shift: controller.recordTarget()
            case "c": controller.copyColor(asRGB: shift)
            default: super.keyDown(with: event)
            }
        }
    }

    // MARK: - Painting

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let full = bounds
        if let frozen {
            ctx.interpolationQuality = .none // 1:1 with the display's own pixels
            Draw.image(frozen, in: full, ctx)
        } else {
            ctx.setFillColor(.black)
            ctx.fill(full)
        }

        let dim = CGColor(gray: 0, alpha: 0x73 / 255.0)
        guard let selGlobal = controller.highlightRect else {
            ctx.setFillColor(dim)
            ctx.fill(full)
            if controller.mode == .region { drawCrosshair(ctx) }
            drawMagnifier(ctx, full: full)
            return
        }

        let sel = local(selGlobal)
        ctx.saveGState()
        ctx.addRect(full)
        ctx.addRect(sel)
        ctx.setFillColor(dim)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        ctx.setStrokeColor(RGBAColor.pink.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(sel)

        // Only annotate the readout on overlays the selection actually touches.
        if sel.intersects(full), let size = controller.resultPixelSize(of: selGlobal) {
            let kind = controller.hoverKind
            drawReadout(ctx, full: full, sel: sel, text: kind.isEmpty ? "\(size.width) × \(size.height)" : "\(kind)  \(size.width) × \(size.height)")
        }
        if controller.mode == .region && !controller.hasSelection { drawCrosshair(ctx) }
        drawMagnifier(ctx, full: full)
    }

    // Magnifier: a 15×15 pixel sample, 8 pt per pixel.
    private static let grid = 15, cell: CGFloat = 8, pad: CGFloat = 8

    /// Zoomed view of the frozen frame around the pointer plus that pixel's colour (C copies HEX,
    /// ⇧C RGB). Samples display pixels, so the centre cell is exactly the pixel under the pointer at
    /// any backing scale. Only the display holding the pointer draws it.
    private func drawMagnifier(_ ctx: CGContext, full: CGRect) {
        guard controller.mode == .region, AppController.shared.settings.showMagnifier,
              display.frame.contains(controller.pointer),
              let s = controller.magnifierSample(grid: Self.grid) else { return }
        let p = controller.pointer
        let local = CGPoint(x: p.x - display.frame.minX, y: p.y - display.frame.minY)
        let c = s.color
        let hex = String(format: "#%02X%02X%02X", c.r, c.g, c.b)
        let dim = RGBAColor(0xD2, 0xD2, 0xD2, 0xFF)
        let lines = [
            TextLayout.string("(\(s.pixel.x), \(s.pixel.y))", font: .systemFont(ofSize: 12), color: dim),
            TextLayout.string("RGB \(c.r), \(c.g), \(c.b)", font: .systemFont(ofSize: 12), color: dim),
            TextLayout.string(hex, font: .systemFont(ofSize: 12, weight: .semibold), color: RGBAColor(0xFF, 0xFF, 0xFF, 0xFF)),
            TextLayout.string(Loc.t("C: copy HEX · ⇧C: RGB"), font: .systemFont(ofSize: 10.5), color: dim),
        ]
        let sizes = lines.map { TextLayout.size($0) }
        let zoom = CGFloat(Self.grid) * Self.cell
        let widest: CGFloat = sizes.map { $0.width }.max() ?? 0
        let textHeight: CGFloat = sizes.reduce(0) { $0 + $1.height + 1 }
        let width = max(zoom, widest + 17) + Self.pad * 2
        let height = Self.pad + zoom + 6 + textHeight + Self.pad

        // Down-right of the pointer, flipped to whichever side has room.
        var x = local.x + 20, y = local.y + 20
        if x + width > full.width { x = local.x - 20 - width }
        if y + height > full.height { y = local.y - 20 - height }

        let bg = CGRect(x: x, y: y, width: width, height: height)
        ctx.addPath(CGPath(roundedRect: bg, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.setFillColor(RGBAColor(0x1E, 0x1E, 0x20, 0xD9).cgColor)
        ctx.fillPath()
        let zoomRect = CGRect(x: x + Self.pad, y: y + Self.pad, width: CGFloat(s.image.width) * Self.cell, height: CGFloat(s.image.height) * Self.cell)
        ctx.saveGState()
        ctx.interpolationQuality = .none
        Draw.image(s.image, in: zoomRect, ctx)
        ctx.restoreGState()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0x24 / 255.0))
        ctx.setLineWidth(1)
        var segments: [CGPoint] = []
        for i in 0...s.image.width {
            let gx = zoomRect.minX + CGFloat(i) * Self.cell
            segments += [CGPoint(x: gx, y: zoomRect.minY), CGPoint(x: gx, y: zoomRect.maxY)]
        }
        for i in 0...s.image.height {
            let gy = zoomRect.minY + CGFloat(i) * Self.cell
            segments += [CGPoint(x: zoomRect.minX, y: gy), CGPoint(x: zoomRect.maxX, y: gy)]
        }
        ctx.strokeLineSegments(between: segments)

        // Centre cell outlined in a colour that contrasts with the pixel itself.
        let light = Double(c.r) * 0.299 + Double(c.g) * 0.587 + Double(c.b) * 0.114 > 128
        ctx.setStrokeColor(light ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(2)
        ctx.stroke(CGRect(x: zoomRect.minX + CGFloat(s.center.x) * Self.cell, y: zoomRect.minY + CGFloat(s.center.y) * Self.cell,
                          width: Self.cell, height: Self.cell))

        var ty = y + Self.pad + zoom + 6
        for (i, line) in lines.enumerated() {
            var tx = x + Self.pad
            if i == 2 {
                let swatch = CGRect(x: tx, y: ty + 2, width: 11, height: 11)
                ctx.setFillColor(CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1))
                ctx.fill(swatch)
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
                ctx.setLineWidth(1)
                ctx.stroke(swatch)
                tx += 17
            }
            TextLayout.draw(line, at: CGPoint(x: tx, y: ty), in: ctx)
            ty += sizes[i].height + 1
        }
    }

    private func drawCrosshair(_ ctx: CGContext) {
        // Shared controller pointer: only the display actually containing it draws a crosshair.
        let p = controller.pointer
        guard display.frame.contains(p) else { return }
        let x = (p.x - display.frame.minX).rounded() + 0.5, y = (p.y - display.frame.minY).rounded() + 0.5
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0x80 / 255.0))
        ctx.setLineWidth(1)
        ctx.strokeLineSegments(between: [CGPoint(x: x, y: 0), CGPoint(x: x, y: bounds.height),
                                         CGPoint(x: 0, y: y), CGPoint(x: bounds.width, y: y)])
    }

    private func drawReadout(_ ctx: CGContext, full: CGRect, sel: CGRect, text: String) {
        let label = TextLayout.string(text, font: .systemFont(ofSize: 13, weight: .semibold), color: .white)
        let size = TextLayout.size(label)
        let pad: CGFloat = 5
        var x = min(sel.maxX + 8, full.width - size.width - pad * 2 - 4)
        var y = min(sel.maxY + 8, full.height - size.height - pad * 2 - 4)
        x = max(x, 4); y = max(y, 4)
        let bg = CGRect(x: x, y: y, width: size.width + pad * 2, height: size.height + pad * 2)
        ctx.addPath(CGPath(roundedRect: bg, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.setFillColor(RGBAColor(0x1E, 0x1E, 0x20, 0xD9).cgColor)
        ctx.fillPath()
        TextLayout.draw(label, at: CGPoint(x: x + pad, y: y + pad), in: ctx)
    }
}
