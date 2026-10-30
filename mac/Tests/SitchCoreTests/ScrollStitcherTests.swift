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
    let (bytes, total) = stitcher.pixels()
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
