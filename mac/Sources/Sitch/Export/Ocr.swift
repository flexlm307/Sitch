import CoreGraphics
import Foundation
import Vision

/// Reads the text in a capture (Windows Shelf/Core/Ocr.cs parity). Default: Vision, the OCR built into
/// macOS (the engine Live Text uses; no network). With Settings' OCR engine set to RapidOCR the external
/// worker reads it instead, falling back to Vision (and saying why) when that fails.
@MainActor
enum Ocr {
    /// The recognised rows joined by new lines; empty when nothing was read.
    static func read(_ image: CGImage) async throws -> String {
        if AppController.shared.settings.ocrEngine == "RapidOCR" {
            do { return try await RapidOcr.read(image) } catch {
                Toast.show(Loc.t("RapidOCR failed — using the macOS OCR instead.") + "\n\(error.localizedDescription)")
            }
        }
        return try await vision(image)
    }

    private static func vision(_ image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                // Chinese and English first (Vision reads mixed lines well with both), then the Mac's
                // own languages; only ones this Vision knows, or the request fails outright.
                let supported = (try? request.supportedRecognitionLanguages()) ?? []
                var chosen: [String] = []
                for lang in ["zh-Hans", "zh-Hant", "en-US"] + Locale.preferredLanguages {
                    let match = supported.first { $0 == lang } ?? supported.first { $0.hasPrefix(lang.prefix(2)) }
                    if let match, !chosen.contains(match) { chosen.append(match) }
                }
                if !chosen.isEmpty { request.recognitionLanguages = chosen }
                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    let rows = Self.rows((request.results ?? []).compactMap { obs in
                        obs.topCandidates(1).first.map { (obs.boundingBox, $0.string) }
                    })
                    continuation.resume(returning: rows)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Boxes whose vertical centres sit within half a box height share a row, read left to right —
    /// the same grouping as the RapidOCR worker, so a table reads as rows, not one cell per line.
    nonisolated static func rows(_ items: [(CGRect, String)]) -> String {
        // Vision boxes are normalised with a bottom-left origin: flip so rows run top to bottom.
        let boxes = items.compactMap { r, t -> (top: CGFloat, bottom: CGFloat, left: CGFloat, text: String)? in
            let text = t.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : (1 - r.maxY, 1 - r.minY, r.minX, text)
        }.sorted { ($0.top + $0.bottom) < ($1.top + $1.bottom) }
        var rows: [(mid: CGFloat, cells: [(CGFloat, String)])] = []
        for b in boxes {
            let mid = (b.top + b.bottom) / 2
            if let last = rows.last, abs(mid - last.mid) < (b.bottom - b.top) / 2 {
                rows[rows.count - 1].cells.append((b.left, b.text))
            } else {
                rows.append((mid, [(b.left, b.text)]))
            }
        }
        return rows.map { $0.cells.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "  ") }.joined(separator: "\n")
    }
}

/// OCR through RapidOCR (PaddleOCR models on ONNX Runtime, `pip install rapidocr`): an alternative to
/// Vision for mixed Chinese and English. Loading the models costs seconds, so one Python worker starts
/// on first use, reads image paths from stdin and answers one JSON line each, and exits after ten idle
/// minutes, or when Sitch goes away (its stdin closes).
@MainActor
enum RapidOcr {
    private static var worker: LineWorker?
    private static var idle: Timer?
    private static var busy = false

    // Rows: boxes whose vertical centres sit within half a box height share a line, read left to right.
    // Scores under 0.6 are mostly icons read as letters.
    private static let script = """
        import sys, json
        sys.stdin.reconfigure(encoding="utf-8")
        sys.stdout.reconfigure(encoding="utf-8")
        from rapidocr import RapidOCR
        engine = RapidOCR()

        def text_of(r):
            items = []
            for box, txt, score in zip(r.boxes, r.txts, r.scores):
                txt = txt.strip()
                if score < 0.6 or not txt:
                    continue
                ys = [p[1] for p in box]
                items.append((min(ys), max(ys), min(p[0] for p in box), txt))
            items.sort(key=lambda i: (i[0] + i[1]) / 2)
            rows = []
            for top, bottom, left, txt in items:
                mid = (top + bottom) / 2
                if rows and abs(mid - rows[-1][0]) < (bottom - top) / 2:
                    rows[-1][1].append((left, txt))
                else:
                    rows.append((mid, [(left, txt)]))
            return "\\n".join("  ".join(t for _, t in sorted(cells)) for _, cells in rows)

        print(json.dumps({"ready": True}), flush=True)
        for line in sys.stdin:
            path = line.strip()
            if not path:
                continue
            try:
                r = engine(path)
                out = {"text": text_of(r) if r.txts else ""}
            except Exception as e:
                out = {"error": str(e)}
            print(json.dumps(out, ensure_ascii=False), flush=True)
        """

    static func read(_ image: CGImage) async throws -> String {
        guard !busy else { throw ExternalTools.Failure(message: Loc.t("RapidOCR is still reading the previous image.")) }
        busy = true
        idle?.invalidate()
        defer {
            busy = false
            idle = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { _ in MainActor.assumeIsolated { stop() } }
        }
        // The worker reads files, so the image takes a short trip through the temp folder.
        let url = try TempFiles.writePNG(image, name: "ocr-\(UUID().uuidString)", pointScale: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let w: LineWorker
            if let running = worker, running.isRunning { w = running } else {
                guard let python = ExternalTools.python else { throw ExternalTools.Failure(message: Loc.t("Python was not found.")) }
                w = try LineWorker(python, ["-c", script])
                worker = w
                _ = try await w.readLine(timeout: 90) // {"ready": true}
            }
            try w.writeLine(url.path)
            let line = try await w.readLine(timeout: 60)
            guard let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                throw ExternalTools.Failure(message: line)
            }
            if let error = json["error"] as? String { throw ExternalTools.Failure(message: error) }
            return json["text"] as? String ?? ""
        } catch {
            stop() // a confused worker would answer the next request with this one's reply
            throw error
        }
    }

    static func stop() {
        worker?.terminate()
        worker = nil
    }
}

/// A long-running child that talks in lines: one written to its stdin, one read back from stdout.
/// stderr is drained and its tail kept for the error when the child dies.
final class LineWorker: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [String] = []
    private var waiter: CheckedContinuation<String?, Never>?
    private var stderrTail: [String] = []
    private var ended = false

    init(_ exe: URL, _ args: [String], cwd: URL? = nil, env: [String: String] = [:]) throws {
        process.executableURL = exe
        process.arguments = args
        process.environment = ExternalTools.environment(env)
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] h in self?.received(h.availableData) }
        errors.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            self?.lock.withLock {
                self?.stderrTail.append(contentsOf: text.split(separator: "\n").map(String.init))
                if let n = self?.stderrTail.count, n > 8 { self?.stderrTail.removeFirst(n - 8) }
            }
        }
        process.terminationHandler = { [weak self] _ in self?.received(Data()) }
        do { try process.run() } catch {
            throw ExternalTools.Failure(message: "\(exe.lastPathComponent): \(error.localizedDescription)")
        }
    }

    var isRunning: Bool { process.isRunning }

    var errorTail: String { lock.withLock { stderrTail.joined(separator: "\n") } }

    func writeLine(_ line: String) throws {
        do { try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8)) } catch {
            throw ExternalTools.Failure(message: errorTail.isEmpty ? error.localizedDescription : errorTail)
        }
    }

    /// The next stdout line; throws with the stderr tail when the child exits first.
    func readLine(timeout: TimeInterval) async throws -> String {
        let line: String? = await withCheckedContinuation { c in
            lock.lock()
            if !lines.isEmpty { let l = lines.removeFirst(); lock.unlock(); c.resume(returning: l); return }
            if ended { lock.unlock(); c.resume(returning: nil); return }
            waiter = c
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.resumeWaiter(nil) }
        }
        guard let line else {
            if process.isRunning {
                throw ExternalTools.Failure(message: Loc.timeoutMessage(Int(timeout)))
            }
            let tail = errorTail
            throw ExternalTools.Failure(message: tail.isEmpty ? "exited" : tail)
        }
        return line
    }

    func terminate() {
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
    }

    private func received(_ data: Data) {
        lock.lock()
        if data.isEmpty {
            ended = true
            let w = waiter
            waiter = nil
            lock.unlock()
            w?.resume(returning: nil)
            output.fileHandleForReading.readabilityHandler = nil
            return
        }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        if let w = waiter, !lines.isEmpty {
            waiter = nil
            let l = lines.removeFirst()
            lock.unlock()
            w.resume(returning: l)
            return
        }
        lock.unlock()
    }

    private func resumeWaiter(_ value: String?) {
        lock.lock()
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: value)
    }
}

extension Loc {
    /// Callable off the main actor (LineWorker's timeout); English is fine for a rare error.
    nonisolated static func timeoutMessage(_ seconds: Int) -> String { "No answer within \(seconds) s" }
}
