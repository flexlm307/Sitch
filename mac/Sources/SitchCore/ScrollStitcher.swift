import CoreGraphics
import Foundation

/// What one frame did to the long image.
public enum StitchStep: Sendable { case unchanged, appended, noMatch, full }

/// Joins frames of a region the user scrolls into one tall image (windows/Sitch/Capture/ScrollStitcher.cs
/// parity; approach after evan's ScrollStitcher, MIT). Frames are tightly packed 4-byte rows (BGRA or
/// RGBA — only the first three channels are compared) of the same width and height. Each new frame is
/// matched against the previous one: rows that stay put at the top (a sticky header) or bottom (a
/// footer, a status bar) are found first and left out of the match, so they appear once instead of in
/// every slice; the scrolling middle is matched coarsely on per-row signatures, then confirmed on full
/// pixels. Only downward scrolling extends the image.
public final class ScrollStitcher {
    public static let maxHeight = 30000

    private static let sigColumns = 64       // per-row signature: average luminance of 64 column bands
    private static let staticRow = 0.5       // mean |Δ| per pixel channel under which a row "didn't move"
    private static let stillFrame = 2.0      // whole-frame mean |Δ| under which nothing scrolled
    private static let matchLimit = 10.0     // full-pixel mean |Δ| a confirmed overlap must stay under
    private static let candidates = 12       // signature-best offsets compared on full pixels

    private let width: Int, height: Int, stride: Int
    private let margin: Int // columns ignored at each side: scrollbars and window shadows move
    private var slices: [[UInt8]] = []
    private var last: [UInt8]
    private var lastSig: [Int]
    // Rows at the bottom that didn't scroll (a footer, or a blank stretch that only looked still): they
    // stay out of the slices and the last frame's copy closes the image, so nothing real is lost.
    private var footerRows = -1

    public private(set) var imageHeight: Int
    public private(set) var frames = 1

    public init(firstFrame: [UInt8], width: Int, height: Int) {
        self.width = width
        self.height = height
        stride = width * 4
        margin = min(max(width / 20, 4), 24)
        last = firstFrame
        lastSig = []
        imageHeight = height
        lastSig = signatures(firstFrame)
        slices.append(firstFrame)
    }

    public func add(_ frame: [UInt8]) -> StitchStep {
        if imageHeight >= Self.maxHeight { return .full }
        let sig = signatures(frame)
        if meanRowDiff(lastSig, 0, sig, 0, height) < Self.stillFrame { return .unchanged }

        // Static bands: rows identical in both frames, counted inward from each edge. Compared on full
        // pixels: on signatures, lines of similar text one line apart look "unmoved", the bands swallow
        // the scrolling area and the offset search runs out of room.
        var header = 0
        while header < height / 4 && rowPixelDiff(last, frame, header) < Self.staticRow { header += 1 }
        var footer = 0
        while footer < height / 4 && rowPixelDiff(last, frame, height - 1 - footer) < Self.staticRow { footer += 1 }
        let band = height - header - footer
        if band < 40 { return .noMatch }

        // Content moved up by d: previous rows [header+d, header+band) == current rows [header, header+band-d).
        // Signatures shortlist the offsets (local minima only, so one wrong offset and its neighbours can't
        // crowd out the right one); full pixels pick among them.
        let minOverlap = max(20, band / 8)
        let maxD = band - minOverlap
        if maxD < 1 { return .noMatch }
        var scores = [Double](repeating: 0, count: maxD + 1)
        for d in 1...maxD { scores[d] = meanRowDiff(lastSig, header + d, sig, header, band - d) }
        let shortlist = (1...maxD)
            .filter { d in (max(1, d - 2)...min(maxD, d + 2)).allSatisfy { scores[d] <= scores[$0] } }
            .sorted { scores[$0] < scores[$1] }
            .prefix(Self.candidates)
        var best = -1
        var bestPixels = Self.matchLimit
        for d in shortlist {
            let pixels = pixelDiff(last, header + d, frame, header, band - d)
            if pixels < bestPixels { bestPixels = pixels; best = d }
        }
        if best < 0 { return .noMatch }

        // Fixed on the first scroll: the footer leaves the first slice and is added once at the end.
        if footerRows < 0 {
            footerRows = footer
            if footer > 0 {
                slices[0] = rows(slices[0], 0, height - footer)
                imageHeight -= footer
            }
        }

        let newRows = min(best, Self.maxHeight - imageHeight)
        let from = height - max(0, footerRows) - best
        if from < 0 { return .noMatch }
        slices.append(rows(frame, from, newRows))
        imageHeight += newRows
        frames += 1
        last = frame
        lastSig = sig
        return .appended
    }

    /// The long image's pixels (rows top-down) and its full height, footer included.
    public func pixels() -> (bytes: [UInt8], height: Int) {
        let footer = max(0, footerRows)
        var out = [UInt8]()
        out.reserveCapacity((imageHeight + footer) * stride)
        for slice in slices { out.append(contentsOf: slice) }
        if footer > 0 { out.append(contentsOf: last[((height - footer) * stride)...]) }
        return (out, imageHeight + footer)
    }

    /// The long image as a CGImage in the frames' byte order (BGRA by default, as ScreenCaptureKit delivers).
    public func image(bgra: Bool = true, colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage? {
        let (bytes, total) = pixels()
        let info: CGBitmapInfo = bgra
            ? [CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue), .byteOrder32Little]
            : CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: total, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: colorSpace, bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    private func rows(_ frame: [UInt8], _ first: Int, _ count: Int) -> [UInt8] {
        Array(frame[(first * stride)..<((first + count) * stride)])
    }

    private func signatures(_ frame: [UInt8]) -> [Int] {
        let cols = Self.sigColumns
        var sig = [Int](repeating: 0, count: height * cols)
        let usable = width - 2 * margin
        frame.withUnsafeBufferPointer { f in
            for y in 0..<height {
                let row = y * stride
                for c in 0..<cols {
                    let x0 = margin + usable * c / cols, x1 = max(x0 + 1, margin + usable * (c + 1) / cols)
                    var sum = 0
                    for x in x0..<x1 {
                        let i = row + x * 4
                        sum += Int(f[i]) + 2 * Int(f[i + 1]) + Int(f[i + 2]) // cheap luminance, ×4
                    }
                    sig[y * cols + c] = sum / (x1 - x0)
                }
            }
        }
        return sig
    }

    private func meanRowDiff(_ a: [Int], _ firstA: Int, _ b: [Int], _ firstB: Int, _ rows: Int) -> Double {
        let cols = Self.sigColumns
        var sum = 0
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                for r in 0..<rows {
                    let ia = (firstA + r) * cols, ib = (firstB + r) * cols
                    for c in 0..<cols { sum += abs(a[ia + c] - b[ib + c]) }
                }
            }
        }
        return Double(sum) / (4.0 * Double(cols)) / Double(rows)
    }

    private func rowPixelDiff(_ a: [UInt8], _ b: [UInt8], _ row: Int) -> Double {
        let start = row * stride
        var sum = 0
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                for x in margin..<(width - margin) {
                    let i = start + x * 4
                    sum += abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
                }
            }
        }
        return Double(sum) / Double(3 * (width - 2 * margin))
    }

    private func pixelDiff(_ a: [UInt8], _ firstA: Int, _ b: [UInt8], _ firstB: Int, _ rows: Int) -> Double {
        var sum = 0, count = 0
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                for r in Swift.stride(from: 0, to: rows, by: 2) {
                    let ia = (firstA + r) * stride, ib = (firstB + r) * stride
                    for x in Swift.stride(from: margin, to: width - margin, by: 2) {
                        let i = x * 4
                        sum += abs(Int(a[ia + i]) - Int(b[ib + i])) + abs(Int(a[ia + i + 1]) - Int(b[ib + i + 1]))
                            + abs(Int(a[ia + i + 2]) - Int(b[ib + i + 2]))
                        count += 3
                    }
                }
            }
        }
        return count == 0 ? .greatestFiniteMagnitude : Double(sum) / Double(count)
    }
}
