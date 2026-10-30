import Foundation

/// Finds and runs the optional command-line tools some features lean on (Python, FFmpeg). None ship
/// with Sitch. An app opened from Finder gets launchd's bare PATH (/usr/bin:/bin:…), so the places a
/// user's shell would add — ~/.local/bin, Homebrew, MacPorts — are searched first, then that PATH.
enum ExternalTools {
    static var searchDirectories: [String] {
        let home = NSHomeDirectory()
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        return ([home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] + path)
            .filter { seen.insert($0).inserted }
    }

    /// First executable named any of `names`, in directory order.
    static func find(_ names: [String]) -> URL? {
        let fm = FileManager.default
        for dir in searchDirectories {
            for name in names {
                let path = (dir as NSString).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    /// python3 from ~/.local/bin or Homebrew before the system's (Apple's 3.9 stub rarely has the user's packages).
    static var python: URL? { find(["python3", "python"]) }
    static var ffmpeg: URL? { find(["ffmpeg"]) }

    /// The environment for a child: our own plus the searched directories on PATH, so tools that call
    /// other tools (MediaMini runs ffprobe) find them too.
    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchDirectories.joined(separator: ":")
        env["PYTHONIOENCODING"] = "utf-8"
        for (k, v) in extra { env[k] = v }
        return env
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs a tool to completion off the main thread; past `timeout` it is terminated and this throws.
    static func run(_ exe: URL, _ args: [String], cwd: URL? = nil, env: [String: String] = [:],
                    timeout: TimeInterval) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = exe
                p.arguments = args
                p.environment = environment(env)
                if let cwd { p.currentDirectoryURL = cwd }
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    continuation.resume(throwing: Failure(message: "\(exe.lastPathComponent): \(error.localizedDescription)"))
                    return
                }
                // Drain both pipes while it runs: a full pipe would stall the child.
                let group = DispatchGroup()
                let outData = DataBox(), errData = DataBox()
                group.enter()
                DispatchQueue.global().async { outData.data = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                DispatchQueue.global().async { errData.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                if group.wait(timeout: .now() + timeout) == .timedOut {
                    p.terminate()
                    continuation.resume(throwing: Failure(message: "\(exe.lastPathComponent) took longer than \(Int(timeout)) s"))
                    return
                }
                p.waitUntilExit()
                continuation.resume(returning: Output(status: p.terminationStatus,
                                                      stdout: String(decoding: outData.data, as: UTF8.self),
                                                      stderr: String(decoding: errData.data, as: UTF8.self)))
            }
        }
    }

    /// The last few lines of a tool's stderr, for an error message.
    static func tail(_ text: String, lines: Int = 6) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }
}

/// One pipe's bytes, written by its reader thread and read after the DispatchGroup wait.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
