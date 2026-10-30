import Foundation

/// User preferences. Same fields as the Windows `AppSettings` (Mac defaults where the
/// platforms differ), stored as JSON so the two builds stay easy to compare.
public struct AppSettings: Codable, Equatable, Sendable {
    // -- General ------------------------------------------------------------
    /// "System" | "Light" | "Dark"
    public var theme = "System"
    /// Dock icon while an editor is open (Windows: "show editor windows in the taskbar").
    public var showInDock = true
    public var openAtLogin = false
    /// The one-time "Open Sitch at login?" offer has been made (made on the first launch from an
    /// Applications folder, so a first run straight off the disk image doesn't use it up).
    public var offeredLoginItem = false
    /// "System" | "en" | "zh"; read once at launch (see Shell/Loc), so a change applies after a restart.
    public var language = "System"

    // -- Capture --------------------------------------------------------------
    public var captureHotkey = "Cmd+Opt+4"
    public var recaptureHotkey = "Cmd+Opt+Shift+4"
    /// Quick Capture → Clipboard. ⌃ echoes the system's own "to the clipboard" chord (⌃⇧⌘4).
    public var quickCopyHotkey = "Ctrl+Opt+Cmd+4"
    /// Pin the clipboard image on top of everything (Shell/Pins).
    public var pinHotkey = "Cmd+Opt+P"
    /// Scrolling capture: pick a region, scroll it, get one long image.
    public var scrollHotkey = "Cmd+Opt+Shift+S"
    /// Screen recording: pick a region, record it to recordFormat.
    public var recordHotkey = "Cmd+Opt+Shift+R"
    /// "gif" | "mp4"
    public var recordFormat = "gif"
    public var recordPointer = true
    public var defaultSaveFolder = ""
    /// "png" | "jpg" | "pdf" | "tiff"
    public var defaultFormat = "png"
    public var afterShowEditor = true
    /// Every capture lands on the clipboard immediately, ready to paste (on by default).
    public var afterCopy = true
    public var afterSave = false
    /// Run MediaMini (an external Python tool) over every PNG/JPG Sitch saves.
    public var compressWithMediaMini = false
    /// Folder holding MediaMini's cli.py.
    public var mediaMiniFolder = ""
    /// Region capture: hover snaps to the accessibility element under the pointer, not just its window.
    public var snapToElements = true
    /// Region capture: a magnifier with the colour under the pointer (C copies it).
    public var showMagnifier = true
    /// "Vision" (built in) | "RapidOCR" (external Python worker, see Export/RapidOcr).
    public var ocrEngine = "Vision"
    /// MinerU's virtual environment for "Restore as Markdown"; empty = look in the usual places.
    public var minerUFolder = ""
    /// Hang every capture on the screenshot line (merged from Snapline), when the line is on.
    public var afterHang = true
    /// The screenshot line along the top of the screen. Its own settings live in SitchShelf.
    public var lineEnabled = true
    /// 0 = off; 3, 5 or 10 seconds.
    public var timerSeconds = 0
    public var watchSystemScreenshots = false
    /// Last region, global screen points (top-left origin of the primary display).
    public var lastRegion: PixelRect?

    // -- Editor window memory (points; 0 = never opened, use size-to-capture) --
    public var editorWidth: Double = 0
    public var editorHeight: Double = 0

    // -- Editor defaults --------------------------------------------------------
    public var defaultColor = "#FF3366"
    public var arrowWidth: Double = 20
    public var shapeWidth: Double = 6
    public var penWidth: Double = 6
    public var highlightWidth: Double = 26
    public var textSize: Double = 28
    public var fontFamily = TextLayout.systemFamily
    /// "pixelate" | "blur" | "block" | "stripes"
    public var obscureStyle = "pixelate"
    public var spotlightDim = 0.55
    public var rememberLastTool = true
    public var lastTool = "arrow"

    public init() {}

    // Tolerant decoding: a missing or mistyped key keeps its default instead of failing the
    // whole file (synthesized Codable would throw and reset every preference).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let d = AppSettings()
        theme = v(.theme, d.theme)
        showInDock = v(.showInDock, d.showInDock)
        openAtLogin = v(.openAtLogin, d.openAtLogin)
        offeredLoginItem = v(.offeredLoginItem, d.offeredLoginItem)
        language = v(.language, d.language)
        captureHotkey = v(.captureHotkey, d.captureHotkey)
        recaptureHotkey = v(.recaptureHotkey, d.recaptureHotkey)
        quickCopyHotkey = v(.quickCopyHotkey, d.quickCopyHotkey)
        pinHotkey = v(.pinHotkey, d.pinHotkey)
        scrollHotkey = v(.scrollHotkey, d.scrollHotkey)
        recordHotkey = v(.recordHotkey, d.recordHotkey)
        recordFormat = v(.recordFormat, d.recordFormat)
        recordPointer = v(.recordPointer, d.recordPointer)
        defaultSaveFolder = v(.defaultSaveFolder, d.defaultSaveFolder)
        defaultFormat = v(.defaultFormat, d.defaultFormat)
        afterShowEditor = v(.afterShowEditor, d.afterShowEditor)
        afterCopy = v(.afterCopy, d.afterCopy)
        afterSave = v(.afterSave, d.afterSave)
        compressWithMediaMini = v(.compressWithMediaMini, d.compressWithMediaMini)
        mediaMiniFolder = v(.mediaMiniFolder, d.mediaMiniFolder)
        snapToElements = v(.snapToElements, d.snapToElements)
        showMagnifier = v(.showMagnifier, d.showMagnifier)
        ocrEngine = v(.ocrEngine, d.ocrEngine)
        minerUFolder = v(.minerUFolder, d.minerUFolder)
        afterHang = v(.afterHang, d.afterHang)
        lineEnabled = v(.lineEnabled, d.lineEnabled)
        timerSeconds = v(.timerSeconds, d.timerSeconds)
        watchSystemScreenshots = v(.watchSystemScreenshots, d.watchSystemScreenshots)
        lastRegion = v(.lastRegion, d.lastRegion)
        editorWidth = v(.editorWidth, d.editorWidth)
        editorHeight = v(.editorHeight, d.editorHeight)
        defaultColor = v(.defaultColor, d.defaultColor)
        arrowWidth = v(.arrowWidth, d.arrowWidth)
        shapeWidth = v(.shapeWidth, d.shapeWidth)
        penWidth = v(.penWidth, d.penWidth)
        highlightWidth = v(.highlightWidth, d.highlightWidth)
        textSize = v(.textSize, d.textSize)
        fontFamily = v(.fontFamily, d.fontFamily)
        obscureStyle = v(.obscureStyle, d.obscureStyle)
        spotlightDim = v(.spotlightDim, d.spotlightDim)
        rememberLastTool = v(.rememberLastTool, d.rememberLastTool)
        lastTool = v(.lastTool, d.lastTool)
    }
}

/// JSON at ~/Library/Application Support/Sitch/settings.json, atomic, best-effort.
public enum SettingsStore {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sitch", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("settings.json") }

    /// Settings plus whether the file was missing or unreadable (i.e. a fresh install).
    public static func load(from url: URL? = nil) -> (settings: AppSettings, firstRun: Bool) {
        let url = url ?? fileURL
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return (AppSettings(), true) }
        return (s, false)
    }

    public static func save(_ settings: AppSettings, to url: URL? = nil) {
        let url = url ?? fileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(settings).write(to: url, options: .atomic)
        } catch { /* best-effort persistence */ }
    }
}
