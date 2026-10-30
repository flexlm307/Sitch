import AppKit
import SitchCore

enum CaptureMode: Sendable { case region, window, fullScreen }

struct CaptureResult {
    let image: CGImage
    let kind: CaptureMode
    /// Region captures only: the selected rect, for Recapture Last Region.
    let region: CGRect?
    /// Where on screen the capture came from (all modes) — opens the editor on that display.
    let sourceRect: CGRect?
    /// Pixels per point of the captured display (2 on Retina).
    let pointScale: CGFloat
}

struct DisplayInfo {
    let id: CGDirectDisplayID
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let isMain: Bool
}

/// Orchestrates interactive capture (Windows CaptureController parity): freezes every display
/// once, opens one overlay per display, and completes with a crop of the frozen frame. In
/// Region mode a plain click (no drag) captures the hovered window — one hotkey covers region
/// AND window, Skitch-style — or, with `snapToElements` and the Accessibility permission, the hovered
/// UI element; the scroll wheel steps out to its parents and back in. Arrow keys define/nudge a
/// selection, Return confirms. On a target, F3 pins it, S scrolls it, R records it; C copies the
/// magnifier's colour.
///
/// Coordinate rule: everything here is GLOBAL POINTS with a TOP-LEFT origin at the primary
/// display (Quartz display space — the same space as CGWindowList bounds and SCDisplay.frame).
/// A display's pixels are its points × its backing scale. AppKit's bottom-left space appears
/// only at the NSWindow/NSEvent boundary (ScreenSpace). Unlike Windows, a drag is confined to
/// the display it started on (as macOS's own ⇧⌘4 is), so a capture never mixes scales.
@MainActor
final class CaptureController {
    private(set) var isActive = false
    private(set) var mode: CaptureMode = .region

    private var overlays: [OverlayWindow] = []
    private var displays: [DisplayGeometry] = []
    private var frozen: [CGDirectDisplayID: CGImage] = [:]
    private var windows: [WindowEntry] = []
    private var completion: (@MainActor (CaptureResult) -> Void)?
    private var wasActive = false
    private var activationObserver: NSObjectProtocol?
    private var snapper: ElementSnapper?
    // Elements under the pointer, window first; snapLevel indexes the highlighted one.
    private var snapChain: [SnapTarget] = []
    private var snapLevel = 0
    private var levelsUp = 0 // wheel steps out from the innermost element, kept while the pointer stays inside

    // Selection state (global points)
    private(set) var dragging = false
    private(set) var hasKeyboardSelection = false
    private var dragStart = CGPoint.zero
    private var dragCurrent = CGPoint.zero
    private var selectionDisplay: DisplayGeometry?
    private(set) var pointer = CGPoint.zero
    private(set) var hoveredWindow: WindowEntry?

    var hasSelection: Bool { dragging || hasKeyboardSelection }

    /// Integral-point selection rect (like Windows' rounded physical pixels).
    var selectionRect: CGRect {
        let x1 = min(dragStart.x, dragCurrent.x).rounded(), y1 = min(dragStart.y, dragCurrent.y).rounded()
        let x2 = max(dragStart.x, dragCurrent.x).rounded(), y2 = max(dragStart.y, dragCurrent.y).rounded()
        return CGRect(x: x1, y: y1, width: max(1, x2 - x1), height: max(1, y2 - y1))
    }

    /// The snapped element below window level, or nil (then a click takes the whole window).
    var hoveredElement: SnapTarget? {
        snapLevel > 0 && snapLevel < snapChain.count ? snapChain[snapLevel] : nil
    }

    /// The highlighted thing's role for the size readout ("button", "窗口"), or "".
    var hoverKind: String {
        mode == .region && hasSelection ? "" : snapLevel < snapChain.count ? snapChain[snapLevel].kind : ""
    }

    /// What the overlays outline: the selection, else the snapped element, else the hovered window.
    var highlightRect: CGRect? {
        if mode == .region && hasSelection { return selectionRect }
        return hoveredElement?.frame ?? hoveredWindow?.frame
    }

    /// What a click (or Return) would capture now: the selection, the snapped element or the window.
    private var target: CGRect? {
        if hasSelection { return selectionRect }
        return hoveredElement?.frame ?? (mode != .fullScreen ? hoveredWindow?.frame : nil)
    }

    // MARK: - Interactive

    /// Freeze the screens, show the overlays, call `completion` once with the result.
    /// Cancelling (Esc / right-click) never calls it.
    func startInteractive(_ mode: CaptureMode, completion: @escaping @MainActor (CaptureResult) -> Void) {
        guard !isActive, ScreenRecordingPermission.ensureGranted() else { return }
        isActive = true
        self.mode = mode
        self.completion = completion
        resetSelection()
        wasActive = NSApp.isActive
        snapper = mode == .region && AppController.shared.settings.snapToElements && ElementSnapper.isTrusted
            ? ElementSnapper { [weak self] window, chain in self?.snapped(window, chain) } : nil

        displays = DisplayGeometry.all()
        // Window list is used by Window mode AND by Region mode's click-to-capture-window.
        windows = WindowList.topWindows()
        let targets = displays.map { (id: $0.id, pixelSize: CGSize(width: $0.frame.width * $0.scale,
                                                                   height: $0.frame.height * $0.scale)) }
        Task {
            do {
                let images = try await ScreenFreezer.captureDisplays(targets)
                self.showOverlays(images)
            } catch {
                self.cleanup()
                Self.report(error)
            }
        }
    }

    private func showOverlays(_ images: [CGDirectDisplayID: CGImage]) {
        guard isActive else { return }
        frozen = images
        pointer = ScreenSpace.toQuartz(NSEvent.mouseLocation)
        updateHover()
        NSApp.activate()
        for display in displays {
            let overlay = OverlayWindow(controller: self, display: display, frozen: images[display.id])
            overlays.append(overlay)
            overlay.orderFrontRegardless()
        }
        focusPointerOverlay()
        // Activation can land after this returns (macOS 14+ cooperative activation); without key
        // status Esc / arrows / Return would go to the previous app.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusPointerOverlay() }
        }
    }

    private func focusPointerOverlay() {
        let target = overlays.first { $0.display.frame.contains(pointer) } ?? overlays.first
        target?.makeKeyAndOrderFront(nil)
    }

    func beginDrag(_ p: CGPoint, on display: DisplayGeometry) {
        dragging = true
        hasKeyboardSelection = false
        selectionDisplay = display
        dragStart = clampToDisplay(p)
        dragCurrent = dragStart
        repaint()
    }

    func updatePointer(_ p: CGPoint) {
        pointer = p
        if dragging { dragCurrent = clampToDisplay(p) } else { updateHover() }
        repaint()
    }

    func endDrag(_ p: CGPoint) {
        if mode == .window {
            if let win = hoveredWindow { completeWindow(win) } else { cancel() }
            return
        }
        guard dragging else { return } // Esc already cancelled — the release must not reopen anything
        dragCurrent = clampToDisplay(p)
        let rect = selectionRect
        if rect.width < 4 || rect.height < 4 {
            dragging = false
            // A plain click captures the snapped element, else the window under the cursor (spec: one hotkey, all modes).
            if let element = hoveredElement { completeRegion(element.frame) }
            else if let win = hoveredWindow { completeWindow(win) } else { cancel() }
            return
        }
        completeRegion(rect)
    }

    /// Arrow-key capture: create/move (plain) or resize (Shift) the selection.
    func nudgeSelection(_ dx: CGFloat, _ dy: CGFloat, resize: Bool) {
        guard mode == .region, !dragging else { return }
        if !hasKeyboardSelection {
            // A starter selection centered on the pointer, on the pointer's display.
            selectionDisplay = DisplayGeometry.containing(pointer, in: displays)
            dragStart = clampToDisplay(CGPoint(x: pointer.x - 150, y: pointer.y - 100))
            dragCurrent = clampToDisplay(CGPoint(x: pointer.x + 150, y: pointer.y + 100))
            hasKeyboardSelection = true
        } else if resize {
            dragCurrent = clampToDisplay(CGPoint(x: dragCurrent.x + dx, y: dragCurrent.y + dy))
        } else if let bounds = selectionDisplay?.frame {
            // Move as a unit, stopping at the display edge instead of squashing the rect.
            let r = selectionRect
            let mx = clamp(dx, bounds.minX - r.minX, bounds.maxX - r.maxX)
            let my = clamp(dy, bounds.minY - r.minY, bounds.maxY - r.maxY)
            dragStart = CGPoint(x: dragStart.x + mx, y: dragStart.y + my)
            dragCurrent = CGPoint(x: dragCurrent.x + mx, y: dragCurrent.y + my)
        }
        repaint()
    }

    func confirmSelection() {
        guard mode == .region, hasSelection else { return }
        let rect = selectionRect
        if rect.width >= 4 && rect.height >= 4 { completeRegion(rect) }
    }

    func cancel() {
        closeOverlays()
        cleanup()
        returnFocus()
    }

    /// Hand focus back to whatever the user was in before the hotkey.
    private func returnFocus() {
        if !wasActive { NSApp.deactivate() }
    }

    /// Pixel size the result will have (for the overlay readout).
    func resultPixelSize(of rect: CGRect) -> (width: Int, height: Int)? {
        guard let d = DisplayGeometry.mostOverlapping(rect, in: displays) else { return nil }
        return (Int((rect.width * d.scale).rounded()), Int((rect.height * d.scale).rounded()))
    }

    // MARK: - Hand-offs (keys on a target)

    /// F3: what a click would capture is pinned in place instead.
    func pinTarget() {
        guard let (rect, display) = clippedTarget(), rect.width >= 4, rect.height >= 4,
              let frame = frozen[display.id], let image = ScreenFreezer.crop(frame, display: display.frame, to: rect) else { return }
        closeOverlays()
        cleanup()
        returnFocus()
        Pins.pin(image, pointScale: display.scale, at: rect)
    }

    /// S: a scrolling capture of what a click would take.
    func scrollTarget() { handOff { ScrollCaptureSession.start(rect: $0, display: $1) } }

    /// R: record what a click would take (format from Settings).
    func recordTarget() {
        handOff { RecordingSession.start(rect: $0, display: $1, format: AppController.shared.settings.recordFormat) }
    }

    /// Ends the capture and gives the target to a live session. The overlays go first so the session's
    /// first frame shows the screen, not the frozen copy.
    private func handOff(_ start: @escaping @MainActor (CGRect, DisplayGeometry) -> Void) {
        guard mode == .region, let (rect, display) = clippedTarget() else { return }
        // The app whose window holds the region goes to the front, or an open Sitch window (Settings, an
        // editor) would cover the area the user is about to scroll. That window, not the app that was
        // frontmost: the hotkey may have been pressed from anywhere.
        let owner = windows.first { $0.frame.contains(rect.center) }.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
        closeOverlays()
        cleanup()
        returnFocus()
        owner?.activate(options: [.activateAllWindows])
        start(rect, display)
    }

    private func clippedTarget() -> (CGRect, DisplayGeometry)? {
        guard let t = target else { return nil }
        guard let display = selectionDisplay ?? DisplayGeometry.containing(t.center, in: displays)
                ?? DisplayGeometry.mostOverlapping(t, in: displays) else { return nil }
        let r = t.intersection(display.frame)
        return r.isNull ? nil : (r, display)
    }

    /// Magnifier sample: the frozen pixels in a `grid`×`grid` square around the pointer (clamped inside
    /// the display), where the pointer's own pixel sits in it, and that pixel's colour.
    func magnifierSample(grid: Int) -> (image: CGImage, center: (x: Int, y: Int), color: (r: Int, g: Int, b: Int), pixel: (x: Int, y: Int))? {
        guard let display = displays.first(where: { $0.frame.contains(pointer) }), let frame = frozen[display.id] else { return nil }
        let sx = CGFloat(frame.width) / display.frame.width, sy = CGFloat(frame.height) / display.frame.height
        let px = Int(((pointer.x - display.frame.minX) * sx).rounded(.down)), py = Int(((pointer.y - display.frame.minY) * sy).rounded(.down))
        let x0 = max(0, min(px - grid / 2, frame.width - grid)), y0 = max(0, min(py - grid / 2, frame.height - grid))
        guard let crop = frame.cropping(to: CGRect(x: x0, y: y0, width: min(grid, frame.width), height: min(grid, frame.height))) else { return nil }
        // Read the pixel in the frame's own colour space: the values the display shows, like Digital Color Meter's native mode.
        let space = crop.colorSpace?.model == .rgb ? crop.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        var rgba = [UInt8](repeating: 0, count: 4)
        let cx = px - x0, cy = py - y0
        guard let ctx = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(crop, in: CGRect(x: -cx, y: cy - crop.height + 1, width: crop.width, height: crop.height))
        return (crop, (cx, cy), (Int(rgba[0]), Int(rgba[1]), Int(rgba[2])), (px, py))
    }

    /// C: the colour under the pointer goes to the clipboard and the capture ends (Shift: as RGB).
    func copyColor(asRGB: Bool) {
        guard mode == .region, AppController.shared.settings.showMagnifier, let c = magnifierSample(grid: 1)?.color else { return }
        let text = asRGB ? "\(c.r), \(c.g), \(c.b)" : String(format: "#%02X%02X%02X", c.r, c.g, c.b)
        cancel()
        let pb = NSPasteboard.general
        pb.clearContents()
        Toast.show(pb.setString(text, forType: .string) ? Loc.f("Copied {0}", text) : Loc.t("Clipboard is busy — try again."))
    }

    // MARK: - Completion

    private func completeRegion(_ rect: CGRect) {
        let done = completion
        let display = selectionDisplay ?? DisplayGeometry.mostOverlapping(rect, in: displays)
        let image = display.flatMap { d in frozen[d.id].flatMap { ScreenFreezer.crop($0, display: d.frame, to: rect) } }
        closeOverlays()
        cleanup()
        guard let image, let display else { return }
        done?(CaptureResult(image: image, kind: .region, region: rect, sourceRect: rect, pointScale: display.scale))
    }

    private func completeWindow(_ win: WindowEntry) {
        let done = completion
        let display = DisplayGeometry.mostOverlapping(win.frame, in: displays)
        // Fallback if the window can't be grabbed on its own: crop the frozen desktop.
        let fallback = display.flatMap { d in frozen[d.id].flatMap { ScreenFreezer.crop($0, display: d.frame, to: win.frame) } }
        closeOverlays()
        cleanup()
        Task {
            // The window's own composited content: clean even when partly occluded.
            let own = try? await ScreenFreezer.captureWindow(win.id)
            guard let image = own?.image ?? fallback else { return }
            done?(CaptureResult(image: image, kind: .window, region: nil, sourceRect: win.frame,
                                pointScale: own?.scale ?? display?.scale ?? 1))
        }
    }

    // MARK: - Non-interactive captures

    func captureDisplay(_ id: CGDirectDisplayID) async -> CaptureResult? {
        guard ScreenRecordingPermission.ensureGranted(),
              let display = DisplayGeometry.all().first(where: { $0.id == id }) else { return nil }
        do {
            let size = CGSize(width: display.frame.width * display.scale, height: display.frame.height * display.scale)
            guard let image = try await ScreenFreezer.captureDisplays([(id, size)])[id] else { return nil }
            return CaptureResult(image: image, kind: .fullScreen, region: nil, sourceRect: display.frame,
                                 pointScale: display.scale)
        } catch {
            Self.report(error)
            return nil
        }
    }

    /// Recapture Last Region: a fresh grab of the display under the rect's center, cropped.
    func captureRect(_ rect: CGRect) async -> CaptureResult? {
        guard ScreenRecordingPermission.ensureGranted() else { return nil }
        let all = DisplayGeometry.all()
        guard let display = all.first(where: { $0.frame.contains(rect.center) })
                ?? DisplayGeometry.mostOverlapping(rect, in: all) else { return nil }
        do {
            let size = CGSize(width: display.frame.width * display.scale, height: display.frame.height * display.scale)
            guard let full = try await ScreenFreezer.captureDisplays([(display.id, size)])[display.id],
                  let image = ScreenFreezer.crop(full, display: display.frame, to: rect) else { return nil }
            let clipped = rect.intersection(display.frame)
            return CaptureResult(image: image, kind: .region, region: clipped, sourceRect: clipped,
                                 pointScale: display.scale)
        } catch {
            Self.report(error)
            return nil
        }
    }

    static func displays() -> [DisplayInfo] {
        DisplayGeometry.all().map {
            DisplayInfo(id: $0.id, name: $0.name,
                        pixelWidth: Int(($0.frame.width * $0.scale).rounded()),
                        pixelHeight: Int(($0.frame.height * $0.scale).rounded()),
                        isMain: $0.id == CGMainDisplayID())
        }
    }

    // MARK: - Helpers

    private func updateHover() {
        let was = hoveredWindow?.id
        hoveredWindow = windows.first { $0.frame.contains(pointer) } // front-to-back: first hit is topmost
        guard let snapper else { return }
        if hoveredWindow?.id != was { resetSnap() }
        else if snapLevel < snapChain.count, !snapChain[snapLevel].frame.contains(pointer) { levelsUp = 0 }
        if let win = hoveredWindow { snapper.request(win, at: pointer) }
    }

    private func snapped(_ window: WindowEntry, _ chain: [SnapTarget]) {
        guard isActive, !dragging, window.id == hoveredWindow?.id else { return }
        snapChain = chain
        snapLevel = max(0, chain.count - 1 - levelsUp)
        repaint()
    }

    /// Scroll wheel: `outward` steps toward the window, otherwise back in.
    func stepSnap(outward: Bool) {
        guard snapper != nil, !dragging, !hasKeyboardSelection, !snapChain.isEmpty else { return }
        let level = clamp(snapLevel + (outward ? -1 : 1), 0, snapChain.count - 1)
        guard level != snapLevel else { return }
        snapLevel = level
        levelsUp = snapChain.count - 1 - level
        repaint()
    }

    private func resetSnap() {
        snapChain = []
        snapLevel = 0
        levelsUp = 0
    }

    private func clampToDisplay(_ p: CGPoint) -> CGPoint {
        guard let f = selectionDisplay?.frame else { return p }
        return CGPoint(x: clamp(p.x, f.minX, f.maxX), y: clamp(p.y, f.minY, f.maxY))
    }

    private func repaint() { overlays.forEach { $0.repaint() } }

    private func closeOverlays() {
        // orderOut is synchronous: the overlays are gone before any later capture can see them.
        for o in overlays { o.orderOut(nil); o.close() }
        overlays.removeAll()
    }

    private func resetSelection() {
        dragging = false
        hasKeyboardSelection = false
        hoveredWindow = nil
        selectionDisplay = nil
        resetSnap()
    }

    private func cleanup() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        frozen = [:]
        windows = []
        completion = nil
        snapper?.cancel()
        snapper = nil
        resetSelection()
        isActive = false
    }

    private static func report(_ error: Error) {
        if ScreenFreezer.isPermissionError(error) || !ScreenRecordingPermission.isGranted {
            ScreenRecordingPermission.showDeniedAlert()
        } else {
            let alert = NSAlert()
            alert.messageText = Loc.t("Couldn't capture the screen")
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }
    }
}
