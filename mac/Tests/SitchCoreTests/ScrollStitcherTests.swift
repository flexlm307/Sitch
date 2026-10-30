import Foundation
import Testing
@testable import SitchCore

/// A page of "text lines": each 18-row line has a pseudo-random pattern of dark glyph blocks on white,
/// so neighbouring lines look alike but differ — the case that fools signature-only matching.
private func page(width: Int, height: Int) -> [UInt8] {
    var px = [UInt8](repeating: 255, count: width * height * 4)
    var seed: UInt64 = 42
    func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
    for line in 0..<(height / 18) {
        var x = 30
        while x < width - 30 {
            let w = 4 + Int(next() % 9)
            if next() % 5 != 0 {
                for y in (line * 18 + 4)..<(line * 18 + 14) {
                    for xx in x..<min(x + w, width - 30) {
                        let i = (y * width + xx) * 4
                        px[i] = 30; px[i + 1] = 30; px[i + 2] = 30
                    }
                }
            }
            x += w + 2 + Int(next() % 3)
        }
    }
    return px
}

/// The visible region at scroll offset `top`, with a fixed header (`header` rows of grey) painted over it.
private func frame(_ page: [UInt8], width: Int, top: Int, height: Int, header: Int) -> [UInt8] {
    var f = Array(page[(top * width * 4)..<((top + height) * width * 4)])
    for i in 0..<(header * width * 4) where i % 4 != 3 { f[i] = 200 }
    return f
}

@Test func stitcherRebuildsAScrolledPage() throws {
    let width = 320, height = 240, header = 24
    let full = page(width: width, height: 1200)
    let stitcher = ScrollStitcher(firstFrame: frame(full, width: width, top: 0, height: height, header: header),
                                  width: width, height: height)
    var top = 0
    for step in [37, 52, 0, 80, 61, 44, 90, 33] {
        top += step
        let result = stitcher.add(frame(full, width: width, top: top, height: height, header: header))
        #expect(result == (step == 0 ? .unchanged : .appended))
    }
    let (bytes, _, total) = stitcher.pixels()
    #expect(total == top + height)
    // Everything below the header matches the page row for row.
    let stride = width * 4
    for y in Swift.stride(from: header, to: total, by: 7) {
        #expect(bytes[(y * stride)..<((y + 1) * stride)] == full[(y * stride)..<((y + 1) * stride)], "row \(y)")
    }
}

@Test func stitcherIgnoresAStillFrame() {
    let width = 200, height = 160
    let full = page(width: width, height: 400)
    let first = frame(full, width: width, top: 0, height: height, header: 0)
    let stitcher = ScrollStitcher(firstFrame: first, width: width, height: height)
    #expect(stitcher.add(first) == .unchanged)
    #expect(stitcher.frames == 1)
}

/// A chat page's bottom: a fade mask, then a translucent floating input box with a strip of content still
/// scrolling beneath it (rows `height-30..<height`). Content shows faintly through the box, so the box's
/// pixels change as the page scrolls.
private func chatFrame(_ page: [UInt8], width: Int, top: Int, height: Int) -> [UInt8] {
    var f = frame(page, width: width, top: top, height: height, header: 24)
    for y in (height - 110)..<(height - 70) {
        let fade = Double(y - (height - 110)) / 40 // 0 → 1 toward the box
        for x in 0..<width {
            let i = (y * width + x) * 4
            for c in 0..<3 { f[i + c] = UInt8(Double(f[i + c]) * (1 - fade * 0.8) + 255 * fade * 0.8) }
        }
    }
    for y in (height - 70)..<(height - 30) {
        for x in 0..<width {
            let i = (y * width + x) * 4
            for c in 0..<3 { f[i + c] = UInt8(Double(f[i + c]) * 0.15 + 230 * 0.85) }
            if x == 40 || x == width - 40 || y == height - 70 || y == height - 31 { f[i] = 90; f[i + 1] = 90; f[i + 2] = 200 }
        }
    }
    return f
}

@Test func stitcherKeepsAFloatingTranslucentBoxOutOfTheMiddle() throws {
    let width = 320, height = 300, header = 24
    let full = page(width: width, height: 1400)
    let stitcher = ScrollStitcher(firstFrame: chatFrame(full, width: width, top: 0, height: height), width: width, height: height)
    var top = 0
    for step in [40, 55, 38, 70, 46, 62, 51, 44] {
        top += step
        #expect(stitcher.add(chatFrame(full, width: width, top: top, height: height)) == .appended, "step \(step)")
    }
    let (bytes, _, total) = stitcher.pixels()
    #expect(total == top + height)
    // Everything above the last frame's fade and box is the page itself: no box copies, no faded text.
    let stride = width * 4
    for y in header..<(total - 110) {
        #expect(bytes[(y * stride)..<((y + 1) * stride)] == full[(y * stride)..<((y + 1) * stride)], "row \(y)")
        if bytes[(y * stride)..<((y + 1) * stride)] != full[(y * stride)..<((y + 1) * stride)] { break }
    }
}

/// A window with a toolbar across the top and a fixed side panel on the right: only the left column
/// (`split` px wide) scrolls.
private func twoColumnFrame(_page: [UInt8], pageWidth: Int, width: Int, split: Int, top: Int, height: Int) -> [UInt8] {
    var f = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            if y < 30 {
                // Toolbar: three "traffic lights" and a darker strip.
                let light = (x % 40 < 12 && x < 120 && y > 9 && y < 21)
                f[i] = light ? 60 : 40; f[i + 1] = light ? 200 : 40; f[i + 2] = light ? 90 : 44; f[i + 3] = 255
            } else if x < split {
                let j = ((top + y) * pageWidth + x) * 4
                f[i] = _page[j]; f[i + 1] = _page[j + 1]; f[i + 2] = _page[j + 2]; f[i + 3] = 255
            } else {
                // Side panel: a fixed, non-repeating texture of its own (a periodic one would match itself shifted).
                var h = UInt32(truncatingIfNeeded: x &* 73856093) ^ UInt32(truncatingIfNeeded: y &* 19349663)
                h = (h ^ (h >> 13)) &* 1274126177
                let v: UInt8 = (h >> 7) % 4 == 0 ? 120 : 236
                f[i] = v; f[i + 1] = v; f[i + 2] = v; f[i + 3] = 255
            }
        }
    }
    return f
}

@Test func stitcherKeepsOnlyTheColumnThatScrolls() throws {
    let pageWidth = 260, width = 420, split = 260, height = 260
    let full = page(width: pageWidth, height: 1300)
    let first = twoColumnFrame(_page: full, pageWidth: pageWidth, width: width, split: split, top: 0, height: height)
    let stitcher = ScrollStitcher(firstFrame: first, width: width, height: height)
    var top = 0
    for step in [44, 60, 37, 71, 52] {
        top += step
        #expect(stitcher.add(twoColumnFrame(_page: full, pageWidth: pageWidth, width: width, split: split, top: top, height: height)) == .appended, "step \(step)")
    }
    let (bytes, outWidth, total) = stitcher.pixels()
    #expect(outWidth == split)
    #expect(total == top + height)
    // The toolbar once at the top, then the page's column row for row.
    let outStride = outWidth * 4
    for y in 30..<total {
        let expected = Array(full[((y) * pageWidth * 4)..<((y) * pageWidth * 4 + outStride)])
        let row = Array(bytes[(y * outStride)..<((y + 1) * outStride)])
        // Compare RGB only: the page is RGBA with alpha 255 too.
        #expect(row == expected, "row \(y)")
        if row != expected { break }
    }
}

/// A chat window's sticky title bar: translucent, so the content scrolling under it shows through tinted —
/// and, the tint being the same on every row, content shifted inside the bar matches itself.
private func titleBarFrame(_ page: [UInt8], width: Int, top: Int, height: Int, bar: Int) -> [UInt8] {
    var f = Array(page[(top * width * 4)..<((top + height) * width * 4)])
    for y in 0..<bar {
        for x in 0..<width {
            let i = (y * width + x) * 4
            let title = y >= bar / 2 - 5 && y < bar / 2 + 5 && x >= 20 && x < 120
            for c in 0..<3 { f[i + c] = title ? 40 : UInt8(Double(f[i + c]) * 0.3 + 240 * 0.7) }
        }
    }
    return f
}

@Test func stitcherKeepsATranslucentTitleBarOnce() throws {
    let width = 320, height = 300, bar = 44
    let full = page(width: width, height: 1400)
    let stitcher = ScrollStitcher(firstFrame: titleBarFrame(full, width: width, top: 0, height: height, bar: bar),
                                  width: width, height: height)
    var top = 0
    for step in [40, 55, 38, 70, 46, 62, 51, 44] {
        top += step
        #expect(stitcher.add(titleBarFrame(full, width: width, top: top, height: height, bar: bar)) == .appended, "step \(step)")
    }
    let (bytes, _, total) = stitcher.pixels()
    #expect(total == top + height)
    // The bar once, at the top; below it the page itself, never the bar's tinted view of it.
    let stride = width * 4
    for y in bar..<total {
        #expect(bytes[(y * stride)..<((y + 1) * stride)] == full[(y * stride)..<((y + 1) * stride)], "row \(y)")
        if bytes[(y * stride)..<((y + 1) * stride)] != full[(y * stride)..<((y + 1) * stride)] { break }
    }
}
