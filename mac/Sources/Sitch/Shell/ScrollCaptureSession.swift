import AppKit
import CoreMedia
import SitchCore

/// Scrolling capture (windows/Sitch/Shell/ScrollCaptureSession.cs parity): the user scrolls a chosen
/// region (trackpad, wheel, keys, scrollbar — anything) while a RegionStream samples it and the
/// ScrollStitcher joins the frames. RegionChrome marks the region and holds the height with Done /
/// Cancel. Done routes the long image like any capture.
@MainActor
final class ScrollCaptureSession {
    private static var current: ScrollCaptureSession?
    static var isActive: Bool { current != nil }

    private let rect: CGRect
    private let display: DisplayGeometry
    private var stream: RegionStream?
    private var chrome: RegionChrome?
    private let status = RegionChrome.label(Loc.t("Scroll the area slowly…"))
    private let height = RegionChrome.label(color: NSColor(srgbRed: 1, green: 0x8F / 255.0, blue: 0xAB / 255.0, alpha: 1), bold: true)
    private var timer: Timer?
    private var warnUntil = Date.distantPast

    // Touched on the stitch queue only; the main actor reads the counters it posts back.
    private nonisolated(unsafe) var stitcher: ScrollStitcher?
    private nonisolated(unsafe) var latest: CMSampleBufferBox?
    private let stitchQueue = DispatchQueue(label: "Sitch.ScrollStitch", qos: .userInitiated)
    private let latestLock = NSLock()
    private var stitching = false
    // Debugging aid: `defaults write io.github.phalladar.Sitch ScrollFrameDump <folder>` saves every sampled
    // frame there as raw BGRA (`NNNN_<width>x<height>.bgra`), for replaying a real capture through the stitcher.
    private nonisolated let dumpFolder = UserDefaults.standard.string(forKey: "ScrollFrameDump")
    private nonisolated(unsafe) var dumped = 0

    /// `rect`: global Quartz points inside `display`.
    static func start(rect: CGRect, display: DisplayGeometry) {
        guard current == nil, !RecordingSession.isActive else { return }
        guard rect.width * display.scale >= 60, rect.height * display.scale >= 80 else {
            Toast.show(Loc.t("Choose a larger area to scroll."))
            return
        }
        current = ScrollCaptureSession(rect: rect, display: display)
    }

    private init(rect: CGRect, display: DisplayGeometry) {
        self.rect = rect
        self.display = display
        let done = RegionChrome.button(Loc.t("Done"), primary: true) { [weak self] in self?.finish(keep: true) }
        let cancel = RegionChrome.button(Loc.t("Cancel"), primary: false) { [weak self] in self?.finish(keep: false) }
        chrome = RegionChrome(rect: rect, display: display, items: [status, height, done, cancel])
        updateLabels(height: Int((rect.height * display.scale).rounded()), frames: 1)
        stream = RegionStream(rect: rect, display: display, fps: 15, showsCursor: false, even: false,
                              onFrame: { [weak self] buffer in self?.keep(buffer) },
                              onError: { error in
                                  Task { @MainActor in
                                      Toast.show(Loc.t("Scrolling capture failed.") + "\n\(error.localizedDescription)")
                                      ScrollCaptureSession.current?.finish(keep: false)
                                  }
                              })
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    private nonisolated func keep(_ buffer: CMSampleBuffer) {
        latestLock.withLock { latest = CMSampleBufferBox(buffer) }
    }

    /// Every 80 ms: the newest frame goes to the stitcher (off the main thread; a busy stitcher skips a tick).
    private func sample() {
        guard !stitching, let box = latestLock.withLock({ () -> CMSampleBufferBox? in
            defer { latest = nil }
            return latest
        }) else { return }
        stitching = true
        stitchQueue.async { [weak self] in
            guard let self else { return }
            guard let frame = RegionStream.bgra(box.buffer) else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.stitching = false } }
                return
            }
            if let dumpFolder {
                let url = URL(fileURLWithPath: dumpFolder).appendingPathComponent(String(format: "%04d_%dx%d.bgra", dumped, frame.width, frame.height))
                try? FileManager.default.createDirectory(atPath: dumpFolder, withIntermediateDirectories: true)
                try? Data(frame.bytes).write(to: url)
                dumped += 1
            }
            let step: StitchStep
            if let stitcher {
                step = stitcher.add(frame.bytes)
            } else {
                stitcher = ScrollStitcher(firstFrame: frame.bytes, width: frame.width, height: frame.height)
                step = .unchanged
            }
            let h = stitcher?.imageHeight ?? 0, n = stitcher?.frames ?? 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.stitching = false
                    self.show(step, height: h, frames: n)
                }
            }
        }
    }

    private func show(_ step: StitchStep, height h: Int, frames: Int) {
        switch step {
        case .noMatch:
            warnUntil = Date().addingTimeInterval(1.5)
            status.stringValue = Loc.t("Lost track — scroll back a little, then slower")
        case .full:
            status.stringValue = Loc.t("Maximum height reached")
        default:
            if Date() > warnUntil { status.stringValue = Loc.t("Scroll the area slowly…") }
        }
        updateLabels(height: h, frames: frames)
    }

    private func updateLabels(height h: Int, frames: Int) {
        height.stringValue = Loc.f("{0} px · {1} frames", h, frames)
        chrome?.layout()
    }

    private func finish(keep: Bool) {
        guard Self.current === self else { return }
        Self.current = nil
        timer?.invalidate()
        chrome?.close()
        chrome = nil
        let stream = self.stream
        self.stream = nil
        Task { await stream?.stop() }
        guard keep else { return }
        // Wait for a stitch in flight, then build the image on the same queue. Strong self: nothing else
        // holds the session once `current` is cleared.
        let rect = rect, scale = display.scale
        let space = CGDisplayCopyColorSpace(display.id)
        stitchQueue.async {
            guard let stitcher = self.stitcher else { return }
            let frames = stitcher.frames
            let image = stitcher.image(colorSpace: space)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if frames < 2 { Toast.show(Loc.t("Nothing scrolled — keeping a normal capture.")) }
                    guard let image else { return }
                    AppController.shared.finishScrollCapture(image, sourceRect: rect, pointScale: scale)
                }
            }
        }
    }
}

/// Carries a CMSampleBuffer (immutable once delivered) across queues.
final class CMSampleBufferBox: @unchecked Sendable {
    let buffer: CMSampleBuffer
    init(_ buffer: CMSampleBuffer) { self.buffer = buffer }
}
