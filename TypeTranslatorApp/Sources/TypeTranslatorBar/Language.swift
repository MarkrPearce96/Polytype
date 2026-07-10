import Foundation

/// A translation language offered in the menus.
struct Language: Equatable {
    let code: String    // exact engine code, e.g. "zh-TW", "ja"
    let name: String    // native display name shown in the menu
}

/// The curated, baked-in language list. Add an entry here to offer more.
enum Languages {
    static let autoCode = "auto"

    static let all: [Language] = [
        Language(code: "zh-TW", name: "繁體中文 (Chinese, Traditional)"),
        Language(code: "zh-CN", name: "简体中文 (Chinese, Simplified)"),
        Language(code: "ja", name: "日本語 (Japanese)"),
        Language(code: "ko", name: "한국어 (Korean)"),
        Language(code: "es", name: "Español (Spanish)"),
        Language(code: "fr", name: "Français (French)"),
        Language(code: "de", name: "Deutsch (German)"),
        Language(code: "th", name: "ไทย (Thai)"),
        Language(code: "vi", name: "Tiếng Việt (Vietnamese)"),
    ]

    /// Display name for a code; `"auto"` → "Auto-detect"; unknown → the code.
    static func name(for code: String) -> String {
        if code == autoCode { return "Auto-detect" }
        return all.first { $0.code == code }?.name ?? code
    }
}

/// UserDefaults-backed current language selections, reachable from the menu
/// (AppDelegate) and TranslateService.
@MainActor
enum LanguagePrefs {
    private static var defaults: UserDefaults { .standard }

    /// Compose target (English → this). Default Traditional Chinese.
    static var composeTargetCode: String {
        get { defaults.string(forKey: "composeTargetCode") ?? "zh-TW" }
        set { defaults.set(newValue, forKey: "composeTargetCode") }
    }

    /// Read source (this → English). Default auto-detect.
    static var readSourceCode: String {
        get { defaults.string(forKey: "readSourceCode") ?? Languages.autoCode }
        set { defaults.set(newValue, forKey: "readSourceCode") }
    }

    /// The last *specific* (non-auto) Read language the user picked — used offline,
    /// where auto-detect isn't available. Falls back to the compose target, since
    /// you most likely read the language you're also writing.
    static var lastSpecificReadCode: String {
        get { defaults.string(forKey: "lastSpecificReadCode") ?? composeTargetCode }
        set { defaults.set(newValue, forKey: "lastSpecificReadCode") }
    }
}
