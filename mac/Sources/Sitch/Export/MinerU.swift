import AppKit
import Foundation

/// "Restore as Markdown" (windows/Sitch/Export/MinerU.cs parity): MinerU, an external document parser
/// the user sets up, turns a capture of a complex page — tables, formulas, columns, figures — into
/// Markdown plus cropped images. Its models take tens of seconds to load, so one `mineru-api` server
/// (localhost, a free port) starts on first use and serves later requests in seconds; it exits after
/// 15 idle minutes, with Sitch, and — through a watchdog thread — if Sitch dies without saying so.
@MainActor
enum MinerU {
    private static var server: Process?
    private static var base: URL?
    private static var idle: Timer?
    private static var busy = false
    private static var log: [String] = []

    /// The MinerU virtual environment: Settings' folder, else the usual install places.
    static var folder: URL? {
        let fm = FileManager.default
        let configured = AppController.shared.settings.minerUFolder.trimmingCharacters(in: .whitespaces)
        let home = NSHomeDirectory()
        let candidates = configured.isEmpty
            ? [home + "/.local/share/mineru/current", home + "/.local/mineru"]
            : [(configured as NSString).expandingTildeInPath]
        return candidates.map { URL(fileURLWithPath: $0, isDirectory: true) }
            .first { fm.isExecutableFile(atPath: $0.appendingPathComponent("bin/python").path) }
    }

    static var configured: Bool { folder != nil }

    static func restore(_ image: CGImage, pointScale: CGFloat) {
        guard let folder else {
            Toast.show(Loc.t("Set the MinerU folder in Settings > Editor first."))
            return
        }
        guard !busy else {
            Toast.show(Loc.t("MinerU is still working on the previous capture."))
            return
        }
        busy = true
        idle?.invalidate()
        let running = server?.isRunning == true
        Toast.show(Loc.t(running ? "Restoring as Markdown…" : "Starting MinerU (the first run loads its models, about half a minute)…"))
        guard let png = Exporters.data(image, type: .png, pointScale: pointScale) else { busy = false; return }
        Task { @MainActor in
            defer {
                busy = false
                idle = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: false) { _ in MainActor.assumeIsolated { stop() } }
            }
            do {
                if server?.isRunning != true { try await start(folder) }
                let zip = try await parse(png)
                clearWorkDir()
                let (dir, md, markdown) = try await unpack(zip)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(markdown, forType: .string)
                Toast.show(Loc.f("Restored as Markdown in {0} — the text is on the clipboard", dir.lastPathComponent))
                NSWorkspace.shared.activateFileViewerSelecting([md])
            } catch {
                Toast.show(Loc.t("MinerU failed.") + "\n\(error.localizedDescription)")
            }
        }
    }

    static func restoreFile(_ url: URL) {
        guard let (image, scale) = AppController.loadImage(url) else {
            Toast.show(Loc.f("Couldn't open {0}", url.lastPathComponent))
            return
        }
        restore(image, pointScale: scale)
    }

    static func stop() {
        if let server, server.isRunning { server.terminate() }
        server = nil
    }

    // The server dies with its parent: launched through this wrapper, a thread watches getppid() —
    // the Mac stand-in for the Windows job object.
    private static let wrapper = """
        import os, sys, threading, time
        parent = os.getppid()
        def watch():
            while os.getppid() == parent:
                time.sleep(2)
            os._exit(0)
        threading.Thread(target=watch, daemon=True).start()
        from mineru.cli.fast_api import main
        sys.argv[0] = "mineru-api"
        sys.exit(main())
        """

    private static func start(_ folder: URL) async throws {
        stop()
        let port = try freePort()
        clearWorkDir()
        log = []
        let p = Process()
        p.executableURL = folder.appendingPathComponent("bin/python")
        p.arguments = ["-c", wrapper, "--host", "127.0.0.1", "--port", String(port)]
        p.currentDirectoryURL = workDir
        p.environment = ExternalTools.environment(localModels(folder).merging(["MINERU_API_OUTPUT_ROOT": workDir.path]) { $1 })
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            guard !text.isEmpty else { h.readabilityHandler = nil; return }
            Task { @MainActor in
                log.append(contentsOf: text.split(separator: "\n").map(String.init))
                if log.count > 8 { log.removeFirst(log.count - 8) }
            }
        }
        do { try p.run() } catch {
            throw ExternalTools.Failure(message: "\(p.executableURL!.path): \(error.localizedDescription)")
        }
        server = p
        let root = URL(string: "http://127.0.0.1:\(port)/")!
        base = root

        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if !p.isRunning { throw ExternalTools.Failure(message: log.isEmpty ? "MinerU exited" : log.joined(separator: "\n")) }
            if let (_, response) = try? await URLSession.shared.data(from: root.appendingPathComponent("health")),
               (response as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        stop()
        throw ExternalTools.Failure(message: "MinerU did not start within 3 minutes")
    }

    /// The install's own model setup, as its `mineru` launcher sets it: a config JSON and a Hugging Face
    /// cache beside the environment (`~/.local/share/mineru/{mineru.json,models/huggingface}`), or the
    /// Windows layout (`mineru-hf.json` inside, `mineru-model-cache/huggingface` beside). Absent: MinerU's defaults.
    private static func localModels(_ folder: URL) -> [String: String] {
        let fm = FileManager.default
        let real = folder.resolvingSymlinksInPath()
        let parent = real.deletingLastPathComponent()
        var env: [String: String] = [:]
        if let config = [real.appendingPathComponent("mineru-hf.json"), parent.appendingPathComponent("mineru.json")]
            .first(where: { fm.fileExists(atPath: $0.path) }) {
            env["MINERU_TOOLS_CONFIG_JSON"] = config.path
            env["MINERU_MODEL_SOURCE"] = "local"
        }
        if let cache = [parent.appendingPathComponent("models/huggingface"), parent.appendingPathComponent("mineru-model-cache/huggingface")]
            .first(where: { fm.fileExists(atPath: $0.path) }) {
            env["HF_HOME"] = cache.path
        }
        return env
    }

    private static func parse(_ png: Data) async throws -> Data {
        guard let base else { throw ExternalTools.Failure(message: "MinerU is not running") }
        let boundary = "sitch-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"capture.png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
        body.append(png)
        body.append(Data("\r\n".utf8))
        for (k, v) in [("backend", "pipeline"), ("lang_list", "ch"), ("parse_method", "auto"),
                       ("formula_enable", "true"), ("table_enable", "true"),
                       ("return_md", "true"), ("return_images", "true"), ("response_format_zip", "true")] {
            field(k, v)
        }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: base.appendingPathComponent("file_parse"), timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // Errors come back as JSON with an "error" field; show what MinerU said.
            var text = String(decoding: data, as: UTF8.self)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let e = json["error"] as? String { text = e }
            throw ExternalTools.Failure(message: "HTTP \(status): \(text)")
        }
        return data
    }

    /// The ZIP's Markdown and images go to "Sitch … (Markdown)" in the save folder.
    private static func unpack(_ zip: Data) async throws -> (URL, URL, String) {
        let fm = FileManager.default
        let root = Exporters.saveFolder()
        let name = "Sitch \(Exporters.timestamp(Date()))"
        var dir = root.appendingPathComponent("\(name) (Markdown)")
        var n = 2
        while fm.fileExists(atPath: dir.path) {
            dir = root.appendingPathComponent("\(name) (\(n)) (Markdown)")
            n += 1
        }

        let scratch = workDir.appendingPathComponent("unzip-\(UUID().uuidString)")
        let zipURL = workDir.appendingPathComponent("result-\(UUID().uuidString).zip")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        try zip.write(to: zipURL)
        defer {
            try? fm.removeItem(at: scratch)
            try? fm.removeItem(at: zipURL)
        }
        let out = try await ExternalTools.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zipURL.path, scratch.path], timeout: 60)
        guard out.status == 0 else { throw ExternalTools.Failure(message: ExternalTools.tail(out.stderr)) }

        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var mdURL: URL?, markdown: String?
        let walker = fm.enumerator(at: scratch, includingPropertiesForKeys: [.isRegularFileKey])
        while let file = walker?.nextObject() as? URL {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            // Flatten MinerU's "<name>/auto/" prefix; keep "images/…" so the Markdown's links resolve.
            let parts = file.path.dropFirst(scratch.path.count).split(separator: "/").map(String.init)
            if file.pathExtension.lowercased() == "md" {
                let target = dir.appendingPathComponent("\(name).md")
                let text = try String(contentsOf: file, encoding: .utf8)
                try text.write(to: target, atomically: true, encoding: .utf8)
                mdURL = target
                markdown = text
                continue
            }
            let relative = parts.firstIndex(of: "images").map { parts[$0...].joined(separator: "/") } ?? parts.last ?? ""
            guard !relative.isEmpty, !relative.contains("..") else { continue }
            let target = dir.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: file, to: target)
        }
        guard let mdURL, let markdown else { throw ExternalTools.Failure(message: "MinerU returned no Markdown") }
        return (dir, mdURL, markdown)
    }

    private static var workDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Sitch/mineru", isDirectory: true)
    }

    /// The server keeps every upload and result under its output root; clear them between runs.
    private static func clearWorkDir() {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil) {
            for item in items { try? fm.removeItem(at: item) }
        }
        try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ExternalTools.Failure(message: "socket() failed") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, len) == 0 && getsockname(fd, sa, &len) == 0
            }
        }
        guard ok else { throw ExternalTools.Failure(message: "No free port") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
