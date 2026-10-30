import AppKit
import SitchCore

/// The on-screen furniture of a live capture of one region (scrolling capture, recording) —
/// windows/Sitch/Shell/RegionChrome.cs parity: a click-through frame just outside the region, so it
/// never lands in a sample, and a non-activating bar beside it holding the session's controls, so focus
/// stays in the app being captured. Neither shows in the session's frames (RegionStream leaves Sitch out).
@MainActor
final class RegionChrome {
    private let rect: CGRect
    private let display: DisplayGeometry
    private let frame: NSWindow
    private let frameView = FrameView()
    private let bar: NSPanel
    private let row: NSStackView

    /// `rect`: global Quartz points.
    init(rect: CGRect, display: DisplayGeometry, items: [NSView]) {
        self.rect = rect
        self.display = display
        let pad: CGFloat = 3
        frame = NSWindow(contentRect: ScreenSpace.toAppKit(rect.insetBy(dx: -pad, dy: -pad)), styleMask: .borderless,
                         backing: .buffered, defer: false)
        frame.isOpaque = false
        frame.backgroundColor = .clear
        frame.hasShadow = false
        frame.ignoresMouseEvents = true
        frame.level = .floating
        frame.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        frame.isReleasedWhenClosed = false
        frame.contentView = frameView

        row = NSStackView(views: items)
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 7, left: 14, bottom: 7, right: 8)
        let host = NSView()
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(srgbRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x22 / 255.0, alpha: 0.94).cgColor
        host.layer?.cornerRadius = 10
        host.layer?.borderWidth = 1
        host.layer?.borderColor = NSColor(white: 1, alpha: 0.25).cgColor
        row.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor),
            row.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        bar = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        bar.isOpaque = false
        bar.backgroundColor = .clear
        bar.hasShadow = true
        bar.level = .floating
        bar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        bar.isReleasedWhenClosed = false
        bar.hidesOnDeactivate = false
        bar.appearance = NSAppearance(named: .darkAqua)
        bar.contentView = host

        frame.orderFrontRegardless()
        placeBar()
        bar.orderFrontRegardless()
    }

    /// The frame's colour, e.g. red while recording.
    var frameColor: NSColor {
        get { frameView.color }
        set { frameView.color = newValue; frameView.needsDisplay = true }
    }

    func close() {
        frame.orderOut(nil)
        bar.orderOut(nil)
        frame.close()
        bar.close()
    }

    /// Labels change width as they count: keep the bar sized and in place.
    func layout() { placeBar() }

    /// Below the region, else above it, else inside its bottom edge; kept on the region's display.
    private func placeBar() {
        let size = bar.contentView?.fittingSize ?? .zero
        let screen = NSScreen.screens.first { $0.displayID == display.id }
        let work = screen?.visibleFrame ?? ScreenSpace.toAppKit(display.frame)
        let region = ScreenSpace.toAppKit(rect)
        let gap: CGFloat = 11
        let x = clamp(region.midX - size.width / 2, work.minX + 8, max(work.minX + 8, work.maxX - size.width - 8))
        var y = region.minY - gap - size.height
        if y < work.minY + 8 { y = region.maxY + gap }
        if y + size.height > work.maxY - 8 { y = region.minY + gap } // no room outside: over the bottom edge
        bar.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    static func label(_ text: String = "", color: NSColor = .white, bold: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = color
        l.font = bold ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 13)
        return l
    }

    static func button(_ title: String, primary: Bool, _ action: @escaping @MainActor () -> Void) -> NSButton {
        let target = ActionTarget(action)
        let b = NSButton(title: title, target: target, action: #selector(ActionTarget.fire(_:)))
        b.bezelStyle = .rounded
        b.controlSize = .regular
        if primary { b.bezelColor = RGBAColor.pink.nsColor }
        objc_setAssociatedObject(b, &targetKey, target, .OBJC_ASSOCIATION_RETAIN)
        return b
    }

    private nonisolated(unsafe) static var targetKey: UInt8 = 0
}

/// A 2-pt border drawn inside the frame window, which sits 3 pt outside the region.
private final class FrameView: NSView {
    var color = RGBAColor.pink.nsColor

    override func draw(_ dirtyRect: NSRect) {
        color.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }
}
