import Foundation

/// Everything the app remembers, as one JSON file in Application Support,
/// the same shape as the Windows app's settings.
struct Settings: Codable {
    var pegged: [String] = []
    var pinnedPaths: [String] = []
    /// Where each photo hangs, as a fraction of the width of the screen, by file path.
    var spots: [String: Double] = [:]
    /// Sticky notes, by the path of the picture each is drawn into.
    var notes: [String: NoteData] = [:]
    var soundOn = true
    var catchClipboard = false
    var stayDownWhileUnused = false
    var takeDownAfterDrag = false
    var autoArrange = false
    /// How far below the menu bar the line hangs, in points.
    var lineOffset: Double = 0
    /// A preset name like "bronze", or a hex colour like "#8C5A2E".
    var ropeColor = "bronze"
    /// wood, metal, mixed, red, blue, green or yellow.
    var pegStyle = "wood"
    var bows = true
    /// auto, light or dark.
    var appearance = "auto"
    /// auto, en or ar.
    var language = "auto"
    var welcomed = false

    struct NoteData: Codable {
        var text = ""
        var color = "yellow"
    }

    // MARK: Storage

    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sitch/Line", isDirectory: true)
    }()

    /// The standalone Snapline app's folder. Its settings and caught captures are copied over
    /// on first run (not moved: Snapline keeps working if still installed).
    private static let snaplineFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Snapline", isDirectory: true)
    }()

    private static func migrateFromSnapline() -> Settings? {
        let fm = FileManager.default
        let old = snaplineFolder.appendingPathComponent("settings.json")
        guard !fm.fileExists(atPath: file.path), let data = try? Data(contentsOf: old),
              var s = try? JSONDecoder().decode(Settings.self, from: data) else { return nil }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["Screenshots", "Originals"] {
            let from = snaplineFolder.appendingPathComponent(name), to = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) { try? fm.copyItem(at: from, to: to) }
        }
        let oldPrefix = snaplineFolder.path + "/", newPrefix = folder.path + "/"
        func move(_ path: String) -> String { path.hasPrefix(oldPrefix) ? newPrefix + path.dropFirst(oldPrefix.count) : path }
        s.pegged = s.pegged.map(move)
        s.pinnedPaths = s.pinnedPaths.map(move)
        s.spots = Dictionary(s.spots.map { (move($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        s.notes = Dictionary(s.notes.map { (move($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        return s
    }

    private static let file = folder.appendingPathComponent("settings.json")

    /// True while rendering art: the real settings file is left alone.
    nonisolated(unsafe) static var readOnly = false

    nonisolated(unsafe) static var current: Settings = load()

    private static func load() -> Settings {
        if let migrated = migrateFromSnapline() {
            write(migrated)
            return migrated
        }
        guard let data = try? Data(contentsOf: file),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return settings
    }

    static func save() { write(current) }

    private static func write(_ settings: Settings) {
        if readOnly { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: file, options: .atomic)
        } catch {
            log.error("Could not save settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
