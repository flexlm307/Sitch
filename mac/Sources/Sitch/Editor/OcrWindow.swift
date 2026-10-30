import AppKit

/// "Extract text" result: the recognised rows in an editable box (OCR is rarely perfect, so fix it here
/// before copying), with Copy and Close (windows/Sitch/Editor/OcrWindow.cs parity). One per owner
/// window; a new run replaces its text.
@MainActor
final class OcrWindow: NSWindowController, NSWindowDelegate {
    private static var open: [ObjectIdentifier: OcrWindow] = [:]
    private let key: ObjectIdentifier
    private let textView = NSTextView()

    /// Reads `image` and shows the text beside `owner` (an editor or a pin); progress and errors go to toasts.
    static func extract(from image: CGImage, near owner: NSWindow?) {
        Toast.show(Loc.t("Reading text…"))
        Task { @MainActor in
            let text: String
            do { text = try await Ocr.read(image) } catch {
                Toast.show(Loc.t("Could not read text.") + "\n\(error.localizedDescription)")
                return
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Toast.show(Loc.t("No text found."))
                return
            }
            let id = ObjectIdentifier(owner ?? NSApp)
            let window = open[id] ?? OcrWindow(key: id, near: owner)
            open[id] = window
            window.show(text)
        }
    }

    private init(key: ObjectIdentifier, near owner: NSWindow?) {
        self.key = key
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = Loc.t("Extracted text")
        window.minSize = NSSize(width: 300, height: 200)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        if let owner {
            let o = owner.frame
            window.setFrameOrigin(NSPoint(x: o.midX - 230, y: o.midY - 190))
        } else {
            window.center()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        guard let content = window?.contentView else { return }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView

        let close = NSButton(title: Loc.t("Close"), target: self, action: #selector(closeClicked))
        close.keyEquivalent = "\u{1b}"
        let copy = NSButton(title: Loc.t("Copy"), target: self, action: #selector(copyClicked))
        copy.keyEquivalent = "\r"
        let buttons = NSStackView(views: [close, copy])
        buttons.spacing = 8

        for v in [scroll, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private func show(_ text: String) {
        textView.string = text
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        textView.selectAll(nil)
    }

    @objc private func closeClicked() { close() }

    @objc private func copyClicked() {
        let range = textView.selectedRange()
        let text = range.length > 0 ? (textView.string as NSString).substring(with: range) : textView.string
        let pb = NSPasteboard.general
        pb.clearContents()
        Toast.show(pb.setString(text, forType: .string) ? Loc.t("Text copied") : Loc.t("Clipboard is busy — try again."))
    }

    func windowWillClose(_ notification: Notification) { Self.open[key] = nil }
}
