import AppKit
import AVFoundation
import SitchCore

/// Screen recording of one region to MP4 or GIF (windows/Sitch/Shell/RecordingSession.cs parity). A
/// RegionStream delivers frames, pointer included, with their own timestamps; AVAssetWriter encodes
/// them as they come, so a still screen (no new frames) costs nothing and the clip keeps real time.
/// MP4 is H.264 straight from the system encoder — no FFmpeg needed. GIF is first recorded as a
/// high-bitrate temporary MP4, then converted by FFmpeg in two passes — palettegen over the whole clip,
/// then paletteuse — for far better colours than one fixed palette.
@MainActor
final class RecordingSession {
    private static var current: RecordingSession?
    static var isActive: Bool { current != nil }

    private static let gifFps = 12, mp4Fps = 30
    private static let gifLimit: TimeInterval = 60, mp4Limit: TimeInterval = 30 * 60

    private let gif: Bool
    private let output: URL
    private let temp: URL
    private let writer: FrameWriter
    private var stream: RegionStream?
    private var chrome: RegionChrome?
    private let time = RegionChrome.label("00:00", bold: true)
    private var ticker: Timer?
    private let started = Date()

    /// `rect`: global Quartz points inside `display`; `format`: "gif" or "mp4".
    static func start(rect: CGRect, display: DisplayGeometry, format: String) {
        guard current == nil, !ScrollCaptureSession.isActive else { return }
        let gif = format != "mp4"
        guard rect.width * display.scale >= 16, rect.height * display.scale >= 16 else { return }
        if gif && ExternalTools.ffmpeg == nil {
            Toast.show(Loc.t("Recording a GIF needs FFmpeg (brew install ffmpeg). MP4 works without it."))
            return
        }
        do { current = try RecordingSession(rect: rect, display: display, gif: gif) } catch {
            current = nil
            Toast.show(Loc.t("Recording failed.") + "\n\(error.localizedDescription)")
        }
    }

    private init(rect: CGRect, display: DisplayGeometry, gif: Bool) throws {
        self.gif = gif
        let ext = gif ? "gif" : "mp4"
        output = Exporters.uniqueURL(in: Exporters.saveFolder(), baseName: "Sitch \(Exporters.timestamp(Date()))", ext: ext)
        temp = TempFiles.directory.appendingPathComponent("rec-\(UUID().uuidString).mp4")
        try FileManager.default.createDirectory(at: TempFiles.directory, withIntermediateDirectories: true)

        let fps = gif ? Self.gifFps : Self.mp4Fps
        var w = Int((rect.width * display.scale).rounded()) & ~1, h = Int((rect.height * display.scale).rounded()) & ~1
        w = max(2, w); h = max(2, h)
        // Near-lossless source for the GIF conversion; a sensible bitrate for a video meant to be shared.
        let bitsPerPixel: Double = gif ? 1.2 : 0.12
        writer = try FrameWriter(url: gif ? temp : output, width: w, height: h,
                                 bitrate: Int(Double(w * h * fps) * bitsPerPixel), fps: fps,
                                 colorSpace: CGDisplayCopyColorSpace(display.id))

        let dot = RegionChrome.label("●", color: NSColor(srgbRed: 1, green: 0x3B / 255.0, blue: 0x30 / 255.0, alpha: 1))
        let size = RegionChrome.label("\(w)×\(h) · \(ext.uppercased())", color: NSColor(srgbRed: 0xB0 / 255.0, green: 0xB0 / 255.0, blue: 0xB8 / 255.0, alpha: 1))
        let stop = RegionChrome.button(Loc.t("Stop"), primary: true) { [weak self] in self?.stop(keep: true) }
        let cancel = RegionChrome.button(Loc.t("Cancel"), primary: false) { [weak self] in self?.stop(keep: false) }
        chrome = RegionChrome(rect: rect, display: display, items: [dot, time, size, stop, cancel])
        chrome?.frameColor = .systemRed

        let writer = self.writer
        stream = RegionStream(rect: rect, display: display, fps: fps, showsCursor: AppController.shared.settings.recordPointer,
                              even: true,
                              onFrame: { buffer in writer.append(buffer) },
                              onError: { error in
                                  Task { @MainActor in
                                      Toast.show(Loc.t("Recording failed.") + "\n\(error.localizedDescription)")
                                      RecordingSession.current?.stop(keep: false)
                                  }
                              })
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let t = Date().timeIntervalSince(started)
        time.stringValue = String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
        if t >= (gif ? Self.gifLimit : Self.mp4Limit) { stop(keep: true) }
    }

    private func stop(keep: Bool) {
        guard Self.current === self else { return }
        Self.current = nil
        ticker?.invalidate()
        chrome?.close()
        chrome = nil
        let stream = self.stream
        self.stream = nil
        Task { @MainActor in
            await stream?.stop()
            guard keep else {
                writer.cancel()
                try? FileManager.default.removeItem(at: temp)
                try? FileManager.default.removeItem(at: output)
                return
            }
            Toast.show(Loc.t(gif ? "Making the GIF…" : "Saving the video…"))
            do {
                try await writer.finish()
                if gif { try await makeGif() }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([output as NSURL])
                Toast.show(Loc.f("Saved {0} — the file is on the clipboard", output.lastPathComponent))
            } catch {
                Toast.show(Loc.t("Recording failed.") + "\n\(error.localizedDescription)")
                try? FileManager.default.removeItem(at: output)
            }
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private func makeGif() async throws {
        guard let ffmpeg = ExternalTools.ffmpeg else { throw ExternalTools.Failure(message: "FFmpeg was not found") }
        let palette = temp.deletingPathExtension().appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: palette) }
        let base = ["-hide_banner", "-loglevel", "error", "-y"]
        // fps= resamples the variable-rate source to a steady GIF rate. diff mode: the palette favours
        // what moves; rectangle: each frame only redraws what changed.
        let fps = "fps=\(Self.gifFps)"
        var out = try await ExternalTools.run(ffmpeg, base + ["-i", temp.path, "-vf", "\(fps),palettegen=stats_mode=diff", palette.path], timeout: 300)
        guard out.status == 0 else { throw ExternalTools.Failure(message: ExternalTools.tail(out.stderr)) }
        out = try await ExternalTools.run(ffmpeg, base + ["-i", temp.path, "-i", palette.path, "-lavfi",
                                                          "\(fps)[v];[v][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle",
                                                          "-loop", "0", output.path], timeout: 600)
        guard out.status == 0 else { throw ExternalTools.Failure(message: ExternalTools.tail(out.stderr)) }
    }
}

/// AVAssetWriter fed from the stream's queue. The session starts at the first frame; the last frame
/// is held until stop, so a recording that ends on a still screen keeps its full length.
final class FrameWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let lock = NSLock()
    private var startTime: CMTime?
    private var lastTime = CMTime.zero
    private var closed = false

    init(url: URL, width: Int, height: Int, bitrate: Int, fps: Int, colorSpace: CGColorSpace) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // Tag the colours the display uses, so players show the clip as it looked on screen.
        let p3 = colorSpace.name.map { String($0).contains("P3") } ?? false
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: p3 ? AVVideoColorPrimaries_P3_D65 : AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ExternalTools.Failure(message: "AVAssetWriter did not start") }
    }

    func append(_ buffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        let t = buffer.presentationTimeStamp
        if startTime == nil {
            startTime = t
            writer.startSession(atSourceTime: t)
        }
        guard input.isReadyForMoreMediaData, t > lastTime || lastTime == .zero else { return } // a busy encoder drops, never blocks capture
        if input.append(buffer) { lastTime = t }
    }

    func finish() async throws {
        let end: CMTime? = lock.withLock {
            closed = true
            return startTime.map { _ in CMClockGetTime(CMClockGetHostTimeClock()) }
        }
        guard let end else {
            writer.cancelWriting()
            throw ExternalTools.Failure(message: Loc.nothingRecorded)
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: max(end, lastTime))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? ExternalTools.Failure(message: "AVAssetWriter failed") }
    }

    func cancel() {
        lock.withLock { closed = true }
        writer.cancelWriting()
    }
}

extension Loc {
    nonisolated static let nothingRecorded = "No frames were recorded."
}
