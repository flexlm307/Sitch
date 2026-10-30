import CoreGraphics
import Foundation

/// What one frame did to the long image.
public enum StitchStep: Sendable { case unchanged, appended, noMatch, full }

/// Joins frames of a region the user scrolls into one tall image (windows/Sitch/Capture/ScrollStitcher.cs
/// parity; approach after evan's ScrollStitcher, MIT). Frames are tightly packed 4-byte rows (BGRA or
/// RGBA — only the first three channels are compared) of the same width and height.
///
/// Each new frame is matched against the previous one: rows that stay put at the top (a sticky header)
/// are found first and left out, the scrolling middle is matched coarsely on per-row signatures, then
/// confirmed on full pixels. With the offset known, every row of the frame is classified against the
/// previous frame: did it stay put (a fixed overlay — a footer, or a floating, translucent input box with
/// content still scrolling beneath it) or move with the content, and if it moved, did it arrive intact
/// (clean) or changed (under a fade mask or a blur)? Only each frame's clean band is painted onto the
/// canvas, so content that enters dimmed at the bottom is painted again once it has scrolled up into the
/// clear; the last frame's lower part closes the image, so an overlay appears once, at the end. When only
/// part of the region scrolls — a window with a fixed side panel — the first match finds the columns that
/// moved, and from then on only that span is compared and kept: the long image is the part that scrolls,
/// and a toolbar across its top is an ordinary fixed header. Only downward scrolling extends the image.
public final class ScrollStitcher {
    public static let maxHeight = 30000

    private static let sigColumns = 64       // per-row signature: average luminance of 64 column bands
    private static let staticRow = 0.5       // mean |Δ| per pixel channel under which a row "didn't move"
    private static let stillFrame = 2.0      // whole-frame mean |Δ| under which nothing scrolled
    private static let matchLimit = 10.0     // full-pixel mean |Δ| a confirmed overlap must stay under
    private static let candidates = 12       // signature-best offsets compared on full pixels
    private static let changedRow = 8.0      // a row changed in place by more than this has content going by
    private static let intactRow = 1.0       // a moved row differing more than this (or 3× the median) didn't arrive intact

    private let width: Int, height: Int, stride: Int
    // Columns compared: inside the kept span, minus a margin at each side (scrollbars and window shadows move).
    private var colLo: Int, colHi: Int
    // Columns kept in the long image: the whole width until a fixed side panel is found.
    private var cropLo = 0, cropHi: Int
    private var columnsDecided = false
    private var canvas: [UInt8]
    private var frameTop = 0          // canvas row of the current frame's row 0
    private var last: [UInt8]
    private var lastSig: [Int]
    private var lastCleanBottom: Int  // the previous frame's clean band ends here: rows below stay out of the match

    public private(set) var frames = 1

    /// The long image's height so far (the last frame's bottom included).
    public var imageHeight: Int { frameTop + height }

    public init(firstFrame: [UInt8], width: Int, height: Int) {
        self.width = width
        self.height = height
        stride = width * 4
        let margin = Self.margin(width)
        colLo = margin
        colHi = width - margin
        cropHi = width
        canvas = firstFrame
        last = firstFrame
        lastSig = []
        lastCleanBottom = height
        lastSig = signatures(firstFrame)
    }

    public func add(_ frame: [UInt8]) -> StitchStep {
        if imageHeight >= Self.maxHeight { return .full }
        var sig = signatures(frame)
        if meanRowDiff(lastSig, 0, sig, 0, height) < Self.stillFrame { return .unchanged }

        // Static bands: rows identical in both frames, counted inward from each edge. Compared on full
        // pixels: on signatures, lines of similar text one line apart look "unmoved", the bands swallow
        // the scrolling area and the offset search runs out of room. The bottom also stops at the last
        // frame's clean band, which keeps a known overlay out of the match.
        var header = staticHeader(frame)
        var footer = height - lastCleanBottom
        while footer < height / 4 && rowPixelDiff(last, height - 1 - footer, frame, 0, height - 1 - footer) < Self.staticRow { footer += 1 }
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

        // Columns are judged once, on a step small enough to leave rows to compare in the frame's middle half.
        if !columnsDecided, best <= height / 2 - 20 {
            columnsDecided = true
            if let span = scrollingColumns(frame, offset: best) {
                cropLo = span.lowerBound
                cropHi = span.upperBound
                let margin = Self.margin(span.count)
                colLo = cropLo + margin
                colHi = cropHi - margin
                lastSig = signatures(last)
                sig = signatures(frame)
                header = staticHeader(frame)
            }
        }
        let (cleanTop, cleanBottom) = cleanBand(frame, offset: best, header: header)

        // The clean bands of consecutive frames must overlap, or a stretch of content was never seen intact.
        guard best < cleanBottom - cleanTop else { return .noMatch }

        let newTop = min(frameTop + best, Self.maxHeight - height)
        let needed = (newTop + height) * stride
        if canvas.count < needed { canvas.append(contentsOf: repeatElement(0, count: needed - canvas.count)) }
        paint(frame, rows: cleanTop..<cleanBottom, at: newTop)
        frameTop = newTop
        frames += 1
        last = frame
        lastSig = sig
        lastCleanBottom = cleanBottom
        return .appended
    }

    /// The long image's pixels (rows top-down, the kept columns only) and its size: the canvas, closed by
    /// the last frame's lower part (an overlay at the bottom appears once, here).
    public func pixels() -> (bytes: [UInt8], width: Int, height: Int) {
        var full = Array(canvas.prefix(imageHeight * stride))
        if full.count < imageHeight * stride { full.append(contentsOf: repeatElement(0, count: imageHeight * stride - full.count)) }
        let from = lastCleanBottom * stride
        full.replaceSubrange((frameTop * stride + from)..<(imageHeight * stride), with: last[from...])
        guard cropLo > 0 || cropHi < width else { return (full, width, imageHeight) }
        let outStride = (cropHi - cropLo) * 4
        var out = [UInt8]()
        out.reserveCapacity(imageHeight * outStride)
        for y in 0..<imageHeight {
            let row = y * stride + cropLo * 4
            out.append(contentsOf: full[row..<(row + outStride)])
        }
        return (out, cropHi - cropLo, imageHeight)
    }

    /// The long image as a CGImage in the frames' byte order (BGRA by default, as ScreenCaptureKit delivers).
    public func image(bgra: Bool = true, colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage? {
        let (bytes, outWidth, total) = pixels()
        let info: CGBitmapInfo = bgra
            ? [CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue), .byteOrder32Little]
            : CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: outWidth, height: total, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: outWidth * 4,
                       space: colorSpace, bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The rows of `frame` that show content as it really is. Each row is weighed against the previous
    /// frame, the offset known: it arrived intact (matches where that content was, though it changed in
    /// place — clean), it didn't (it stayed put while the content moved, or arrived changed: a header or
    /// footer, a translucent bar showing blurred content through, an overlay, a fade), or it can't tell (a
    /// blank row matches either way). The band runs from below the last bad row above the first stretch of
    /// clean rows to above the first bad row below the last such stretch, so blank rows inside a translucent
    /// bar can't end it early and the bar's rows never reach the canvas, where they would cover content
    /// already painted.
    private func cleanBand(_ frame: [UInt8], offset d: Int, header: Int) -> (Int, Int) {
        // moved[y]: frame row y against where that content was in the last frame (row y+d).
        var moved = [Double](repeating: .greatestFiniteMagnitude, count: height)
        for y in 0..<(height - d) { moved[y] = rowPixelDiff(last, y + d, frame, 0, y) }
        let middle = moved[header..<(height - d)].sorted()
        let median = middle.isEmpty ? 0 : middle[middle.count / 2]
        let ok = max(Self.intactRow, median * 3)

        enum Kind { case clean, bad, unknown }
        func kind(_ y: Int) -> Kind {
            if moved[y] > ok { return .bad }
            // Clean takes a real change in place (text going by), not the drift of blurred content seen
            // through a translucent bar, which also matches itself shifted.
            return rowPixelDiff(last, y, frame, 0, y) > max(Self.changedRow, ok * 4) ? .clean : .unknown
        }
        // Content shifted within a translucent bar matches itself (the bar tints every row alike), so a
        // few clean rows prove nothing there: the band needs a stretch of clean rows — counted across blank
        // ones, reset by a bad one — before it trusts that it has left a bar.
        let run = max(3, height / 20)

        var top = header
        var cleanRun = 0
        for y in header..<(height / 2) {
            switch kind(y) {
            case .bad: top = y + 1; cleanRun = 0
            case .clean: cleanRun += 1
            case .unknown: break
            }
            if cleanRun == run { break }
        }
        var bottom = height
        cleanRun = 0
        for y in Swift.stride(from: height - 1, through: max(top + 1, height / 2), by: -1) {
            switch kind(y) {
            case .bad: bottom = y; cleanRun = 0
            case .clean: cleanRun += 1
            case .unknown: break
            }
            if cleanRun == run { break }
        }
        return (top, max(bottom, top + 1))
    }

    private static func margin(_ width: Int) -> Int { min(max(width / 20, 4), 24) }

    /// Rows identical in both frames, counted down from the top: a toolbar or a sticky header.
    private func staticHeader(_ frame: [UInt8]) -> Int {
        var header = 0
        while header < height / 4 && rowPixelDiff(last, header, frame, 0, header) < Self.staticRow { header += 1 }
        return header
    }

    /// With the offset known, the columns that moved with the content, or nil when the whole width did.
    /// Judged on the middle half of the frame (headers, footers and floating boxes sit at the edges), per
    /// column, by evidence: a pixel that changed in place but matches the shifted content says "scrolls", one
    /// that stayed put while the content moved says "stays". The columns that scroll form the core; it
    /// widens over columns without evidence (page margins) until it meets a fixed column or a vertical edge
    /// running down nearly the whole frame — the border or background change at a side panel — so a blank
    /// strip of a fixed sidebar isn't kept.
    private func scrollingColumns(_ frame: [UInt8], offset d: Int) -> Range<Int>? {
        // Both ends of each comparison stay in the middle half: an overlay in the last frame would say "stays".
        let rows = Swift.stride(from: height / 4, to: height * 3 / 4 - d, by: 2).map { $0 }
        guard rows.count >= 10 else { return nil }
        var scrolls = [Int](repeating: 0, count: width), fixed = [Bool](repeating: false, count: width)
        let minEvidence = max(3, rows.count / 20)
        last.withUnsafeBufferPointer { a in
            frame.withUnsafeBufferPointer { b in
                for x in 0..<width {
                    var stays = 0, moves = 0
                    for y in rows {
                        let i = y * stride + x * 4, j = (y + d) * stride + x * 4
                        var s = 0, m = 0
                        for c in 0..<3 {
                            s += abs(Int(a[i + c]) - Int(b[i + c]))
                            m += abs(Int(a[j + c]) - Int(b[i + c]))
                        }
                        if s < 6 && m > 30 { stays += 1 } else if m < 6 && s > 30 { moves += 1 }
                    }
                    scrolls[x] = moves
                    fixed[x] = stays >= max(minEvidence, rows.count / 8) && moves * 4 <= stays
                }
            }
        }
        // A vertical edge between x-1 and x: the two columns differ on nearly every row of the frame.
        func edge(_ x: Int) -> Bool {
            var differ = 0, total = 0
            frame.withUnsafeBufferPointer { b in
                for y in Swift.stride(from: 0, to: height, by: 2) {
                    let i = y * stride + x * 4
                    var diff = 0
                    for c in 0..<3 { diff += abs(Int(b[i + c]) - Int(b[i - 4 + c])) }
                    if diff > 9 { differ += 1 }
                    total += 1
                }
            }
            return differ * 10 >= total * 9
        }
        let moving = (0..<width).filter { scrolls[$0] >= minEvidence && !fixed[$0] }
        guard let first = moving.first, let lastMoving = moving.last else { return nil }
        // The core is the widest run of columns between fixed ones that holds moving columns.
        var lo = first, hi = lastMoving + 1
        if let cut = (first..<hi).first(where: { fixed[$0] }) {
            // A fixed column inside the moving range: keep the side with more scrolling columns.
            let left = moving.filter { $0 < cut }.count, right = moving.count - left
            if left >= right { hi = cut } else { lo = (cut..<hi).first { !fixed[$0] && scrolls[$0] >= minEvidence } ?? cut + 1 }
            hi = min(hi, (moving.last { $0 < hi } ?? hi - 1) + 1)
        }
        while lo > 0, !fixed[lo - 1], !edge(lo) { lo -= 1 }
        while hi < width, !fixed[hi], !edge(hi) { hi += 1 }
        let best = lo..<hi
        // A sliver of fixed columns (a window edge) isn't a side panel; and a span too narrow to read is a fluke.
        guard width - best.count > width / 20, best.count >= 60 else { return nil }
        return best
    }

    private func paint(_ frame: [UInt8], rows: Range<Int>, at top: Int) {
        let start = (top + rows.lowerBound) * stride
        canvas.replaceSubrange(start..<(start + rows.count * stride), with: frame[(rows.lowerBound * stride)..<(rows.upperBound * stride)])
    }

    private func signatures(_ frame: [UInt8]) -> [Int] {
        let cols = Self.sigColumns
        var sig = [Int](repeating: 0, count: height * cols)
        let usable = colHi - colLo
        frame.withUnsafeBufferPointer { f in
            for y in 0..<height {
                let row = y * stride
                for c in 0..<cols {
                    let x0 = colLo + usable * c / cols, x1 = max(x0 + 1, colLo + usable * (c + 1) / cols)
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

    /// Mean |Δ| per channel between row `rowA` of `a` and row `rowB` of `b` (offsets in rows).
    private func rowPixelDiff(_ a: [UInt8], _ rowA: Int, _ b: [UInt8], _ offsetB: Int, _ rowB: Int) -> Double {
        let sa = rowA * stride, sb = (offsetB + rowB) * stride
        var sum = 0
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                for x in colLo..<colHi {
                    let i = x * 4
                    sum += abs(Int(a[sa + i]) - Int(b[sb + i])) + abs(Int(a[sa + i + 1]) - Int(b[sb + i + 1]))
                        + abs(Int(a[sa + i + 2]) - Int(b[sb + i + 2]))
                }
            }
        }
        return Double(sum) / Double(3 * (colHi - colLo))
    }

    /// Mean |Δ| per channel over the best-matching 60% of the rows, each row itself scored on its
    /// best-matching 60% of 16 column blocks (every other row and column sampled): an overlay, a fade or a
    /// fixed side panel covering up to 40% of the band either way can't veto the right offset, while a
    /// wrong offset still differs almost everywhere.
    private func pixelDiff(_ a: [UInt8], _ firstA: Int, _ b: [UInt8], _ firstB: Int, _ rows: Int) -> Double {
        let blocks = 16
        let span = colHi - colLo
        guard span >= blocks else { return .greatestFiniteMagnitude }
        var perRow: [Double] = []
        perRow.reserveCapacity(rows / 2 + 1)
        var blockDiff = [Double](repeating: 0, count: blocks)
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                for r in Swift.stride(from: 0, to: rows, by: 2) {
                    let ia = (firstA + r) * stride, ib = (firstB + r) * stride
                    for k in 0..<blocks {
                        let x0 = colLo + span * k / blocks, x1 = colLo + span * (k + 1) / blocks
                        var sum = 0, count = 0
                        for x in Swift.stride(from: x0, to: x1, by: 2) {
                            let i = x * 4
                            sum += abs(Int(a[ia + i]) - Int(b[ib + i])) + abs(Int(a[ia + i + 1]) - Int(b[ib + i + 1]))
                                + abs(Int(a[ia + i + 2]) - Int(b[ib + i + 2]))
                            count += 3
                        }
                        blockDiff[k] = count == 0 ? 0 : Double(sum) / Double(count)
                    }
                    blockDiff.sort()
                    let keptBlocks = blocks * 6 / 10
                    perRow.append(blockDiff.prefix(keptBlocks).reduce(0, +) / Double(keptBlocks))
                }
            }
        }
        guard !perRow.isEmpty else { return .greatestFiniteMagnitude }
        perRow.sort()
        let kept = perRow.prefix(max(1, perRow.count * 6 / 10))
        return kept.reduce(0, +) / Double(kept.count)
    }
}
