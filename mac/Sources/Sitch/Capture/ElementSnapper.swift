import AppKit
import ApplicationServices

/// One element under the pointer: its visible rect (global Quartz points, clipped to its ancestors so
/// scrolled-away content doesn't count) and its role in the system's words ("button", "按钮").
struct SnapTarget: Equatable {
    let frame: CGRect
    let kind: String
}

/// Region capture's hover snapping (windows/Sitch/Capture/ElementSnapper.cs parity): the chain of
/// accessibility elements under the pointer, outermost (the window) first. Hit-tests inside the hovered
/// window's own app — never system-wide, which would hit our overlay — on a worker queue, because
/// cross-process AX calls can take tens of milliseconds. Only the newest request matters: queued points
/// collapse and stale answers are dropped. Needs the Accessibility permission; without it, plain window
/// snapping.
@MainActor
final class ElementSnapper {
    private let onResult: (WindowEntry, [SnapTarget]) -> Void
    private let queue = DispatchQueue(label: "Sitch.ElementSnapper", qos: .userInteractive)
    private var generation = 0
    private var busy = false
    private var pending: (WindowEntry, CGPoint)?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security > Accessibility.
    static func requestTrust() {
        let key = "AXTrustedCheckOptionPrompt" // kAXTrustedCheckOptionPrompt, a non-Sendable global in Swift 6
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    init(onResult: @escaping (WindowEntry, [SnapTarget]) -> Void) {
        self.onResult = onResult
    }

    func request(_ window: WindowEntry, at point: CGPoint) {
        pending = (window, point)
        if !busy { next() }
    }

    func cancel() {
        generation += 1
        pending = nil
    }

    private func next() {
        guard let (window, point) = pending else { busy = false; return }
        pending = nil
        busy = true
        let gen = generation
        queue.async {
            let chain = Self.walk(window, point)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // A newer point is queued: its answer replaces this one, so skip the flicker.
                    if gen == self.generation && self.pending == nil { self.onResult(window, chain) }
                    self.next()
                }
            }
        }
    }

    private nonisolated static func walk(_ window: WindowEntry, _ p: CGPoint) -> [SnapTarget] {
        var chain = [SnapTarget(frame: window.frame, kind: "")]
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit) == .success, let hit else { return chain }

        // Climb to the window, collecting each element's frame (innermost first).
        var path: [(CGRect, String)] = []
        var element: AXUIElement? = hit
        var reachedWindow = false
        for _ in 0..<40 {
            guard let e = element else { break }
            let role = string(e, kAXRoleAttribute) ?? ""
            if role == kAXWindowRole as String {
                // Another window of the same app answered (two windows overlap): window snapping only.
                if let f = frame(e), !close(f, window.frame) { return chain }
                chain[0] = SnapTarget(frame: window.frame, kind: string(e, kAXRoleDescriptionAttribute) ?? "")
                reachedWindow = true
                break
            }
            if let f = frame(e), f.width >= 2, f.height >= 2 {
                path.append((f, string(e, kAXRoleDescriptionAttribute) ?? role))
            }
            element = parent(e)
        }
        guard reachedWindow else { return chain }

        var clip = window.frame
        for (f, kind) in path.reversed() {
            let r = f.intersection(clip)
            guard !r.isNull, r.contains(p) else { break }
            clip = r
            let rounded = CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded())
            // Wrappers the same size as their parent add a wheel step that shows nothing new; the
            // window keeps its own name, deeper levels take the innermost one.
            if close(rounded, chain[chain.count - 1].frame) {
                if chain.count > 1 { chain[chain.count - 1] = SnapTarget(frame: chain[chain.count - 1].frame, kind: kind) }
            } else {
                chain.append(SnapTarget(frame: rounded, kind: kind))
            }
        }
        return chain
    }

    private nonisolated static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    private nonisolated static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private nonisolated static func parent(_ e: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// AX positions are global points with a top-left origin — the capture's own space.
    private nonisolated static func frame(_ e: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
}
