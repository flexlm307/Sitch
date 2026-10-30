import AppKit
import CoreMedia
import ScreenCaptureKit

/// A live ScreenCaptureKit stream of one rect of one display, for scrolling capture and recording (the
/// Mac counterpart of the Windows FrameGrabber's repeated BitBlts). Sitch's own windows — the session's
/// frame and bar, toasts, pins — are left out of every frame. Frames arrive on a private queue as BGRA
/// sample buffers; ScreenCaptureKit sends a new one only when the screen changed.
final class RegionStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    private let onFrame: @Sendable (CMSampleBuffer) -> Void
    private let onError: @Sendable (Error) -> Void
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "Sitch.RegionStream", qos: .userInteractive)

    /// `rect`: global Quartz points inside `display`. `even`: round the pixel size down to even numbers
    /// (H.264 in 4:2:0 needs them; a pixel off the edge is never missed).
    @MainActor
    init(rect: CGRect, display: DisplayGeometry, fps: Int, showsCursor: Bool, even: Bool,
         onFrame: @escaping @Sendable (CMSampleBuffer) -> Void, onError: @escaping @Sendable (Error) -> Void) {
        var w = Int((rect.width * display.scale).rounded()), h = Int((rect.height * display.scale).rounded())
        if even { w &= ~1; h &= ~1 }
        pixelWidth = max(2, w)
        pixelHeight = max(2, h)
        self.onFrame = onFrame
        self.onError = onError
        super.init()
        let local = CGRect(x: rect.minX - display.frame.minX, y: rect.minY - display.frame.minY,
                           width: CGFloat(pixelWidth) / display.scale, height: CGFloat(pixelHeight) / display.scale)
        let displayID = display.id
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = pixelWidth
        config.height = pixelHeight
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = showsCursor
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 5
        config.capturesAudio = false
        Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                    throw ScreenFreezer.Failure.displayNotFound
                }
                let pid = ProcessInfo.processInfo.processIdentifier
                let own = content.applications.filter { $0.processID == pid }
                let filter = SCContentFilter(display: scDisplay, excludingApplications: own, exceptingWindows: [])
                guard let self else { return }
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                self.stream = stream
            } catch {
                self?.onError(error)
            }
        }
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isComplete(sampleBuffer) else { return }
        onFrame(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onError(error) }

    /// Idle and blank frames carry no new image.
    private static func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    /// A frame's pixels as tightly packed BGRA rows (the stitcher's input).
    static func bgra(_ buffer: CMSampleBuffer) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let pb = buffer.imageBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { dst in
            for y in 0..<h {
                memcpy(dst.baseAddress! + y * w * 4, base + y * stride, w * 4)
            }
        }
        return (out, w, h)
    }
}
