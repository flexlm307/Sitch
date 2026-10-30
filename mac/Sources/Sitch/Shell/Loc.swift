import Foundation

/// Sitch's UI words in English (the keys) and Chinese (windows/Sitch/Shell/Loc.cs parity). The
/// language is resolved once, on first use after settings load, so a change in Settings applies after
/// a restart — menus and windows are built once.
@MainActor
enum Loc {
    private static var chinese: Bool?

    /// "System" follows the first preferred language of the Mac.
    static var isChinese: Bool {
        if let chinese { return chinese }
        let resolved = switch AppController.shared.settings.language {
        case "zh": true
        case "en": false
        default: Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
        chinese = resolved
        return resolved
    }

    static func t(_ en: String) -> String { isChinese ? zh[en] ?? en : en }

    /// `t` with "{0}", "{1}"… replaced by the arguments.
    static func f(_ en: String, _ args: Any...) -> String {
        var text = t(en)
        for (i, a) in args.enumerated() { text = text.replacingOccurrences(of: "{\(i)}", with: "\(a)") }
        return text
    }
}
