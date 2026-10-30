import Foundation

/// Optional post-save compression through MediaMini, an external Python tool
/// (windows/Sitch/Export/MediaMini.cs parity). Its cli.py contract: one image, optimized in place, one
/// UTF-8 JSON line on stdout (status, orig_size, new_size, message); it keeps the file as it was when
/// the saving is under 2% or anything fails. Runs off the main thread, with the folder's .venv Python
/// when there is one.
@MainActor
enum MediaMini {
    /// `done` runs after a successful compression (e.g. reload a thumbnail on the line).
    static func compressLater(_ url: URL, done: (@MainActor () -> Void)? = nil) {
        let s = AppController.shared.settings
        guard s.compressWithMediaMini, ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { return }
        let name = url.lastPathComponent
        let folder = URL(fileURLWithPath: (s.mediaMiniFolder as NSString).expandingTildeInPath, isDirectory: true)
        let cli = folder.appendingPathComponent("cli.py")
        guard !s.mediaMiniFolder.isEmpty, FileManager.default.fileExists(atPath: cli.path) else {
            Toast.show(Loc.f("MediaMini could not compress {0}: {1}", name, Loc.f("cli.py not found in {0}", s.mediaMiniFolder)))
            return
        }
        // MediaMini's own virtual environment holds its packages (Pillow, imagequant); else Python from PATH.
        let venv = folder.appendingPathComponent(".venv/bin/python")
        guard let python = FileManager.default.isExecutableFile(atPath: venv.path) ? venv : ExternalTools.python else {
            Toast.show(Loc.f("MediaMini could not compress {0}: {1}", name, Loc.t("Python was not found.")))
            return
        }
        Task { @MainActor in
            do {
                let out = try await ExternalTools.run(python, [cli.path, "optimize", url.path, "--in-place", "--no-backup", "--json"],
                                                      cwd: folder, timeout: 120)
                let line = out.stdout.split(separator: "\n").last.map(String.init) ?? ""
                guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    throw ExternalTools.Failure(message: ExternalTools.tail(out.stderr.isEmpty ? out.stdout : out.stderr))
                }
                let before = (json["orig_size"] as? NSNumber)?.int64Value ?? 0
                let after = (json["new_size"] as? NSNumber)?.int64Value ?? 0
                switch json["status"] as? String {
                case "ERROR": throw ExternalTools.Failure(message: json["message"] as? String ?? "error")
                case "SUCCESS" where after < before: // already optimal / skipped: nothing to report
                    Toast.show(Loc.f("Compressed {0}: {1} → {2}", name, size(before), size(after)))
                    done?()
                default: break
                }
            } catch {
                Toast.show(Loc.f("MediaMini could not compress {0}: {1}", name, error.localizedDescription))
            }
        }
    }

    private static func size(_ bytes: Int64) -> String {
        bytes < 1024 * 1024 ? String(format: "%.1f KB", Double(bytes) / 1024) : String(format: "%.2f MB", Double(bytes) / 1_048_576)
    }
}
