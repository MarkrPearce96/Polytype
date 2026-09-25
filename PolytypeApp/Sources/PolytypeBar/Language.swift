import Foundation

/// A translation language offered in the menus.
struct Language: Equatable {
    let code: String    // exact engine code, e.g. "zh-TW", "ja"
    let name: String    // native display name shown in the menu
}

/// The curated, baked-in language list. Add an entry here to offer more.
enum Languages {
    static let autoCode = "auto"
    static let englishCode = "en"

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

    /// Display name for a code; `"auto"` → "Auto-detect"; `"en"` → "English";
    /// unknown → the code.
    static func name(for code: String) -> String {
        if code == autoCode { return "Auto-detect" }
        if code == englishCode { return "English" }
        return all.first { $0.code == code }?.name ?? code
    }
}

/// UserDefaults-backed current language selections, reachable from the menu
/// (AppDelegate) and TranslateService.
@MainActor
enum LanguagePrefs {
    private static var defaults: UserDefaults { .standard }

    /// Compose source. Default English. Independent of `composeTargetCode` and
    /// may be Auto-detect — useful when pasting in text you don't want to
    /// bother identifying yourself.
    static var composeSourceCode: String {
        get { defaults.string(forKey: "composeSourceCode") ?? Languages.englishCode }
        set { defaults.set(newValue, forKey: "composeSourceCode") }
    }

    /// Compose target — what Compose translates *into*. Default Traditional
    /// Chinese. Never Auto-detect, since a target has to be a concrete language.
    static var composeTargetCode: String {
        get { defaults.string(forKey: "composeTargetCode") ?? "zh-TW" }
        set { defaults.set(newValue, forKey: "composeTargetCode") }
    }

    /// The last *specific* (non-auto) Compose source the user picked — used
    /// offline, and when swapping away from Auto-detect (see `swapCompose`).
    static var lastSpecificComposeSourceCode: String {
        get { defaults.string(forKey: "lastSpecificComposeSourceCode") ?? Languages.englishCode }
        set { defaults.set(newValue, forKey: "lastSpecificComposeSourceCode") }
    }

    /// A temporary, in-memory override for the compose source (never
    /// persisted) — the Compose-side twin of `readSourceOverride`.
    static var composeSourceOverride: String?

    /// The compose source actually used for translation: the offline override
    /// if set, otherwise the saved preference.
    static var effectiveComposeSourceCode: String {
        composeSourceOverride ?? composeSourceCode
    }

    /// Swap Compose's source and target. Since Auto-detect can't become a
    /// target, a source of Auto-detect is substituted with the last specific
    /// language you picked before the swap, so the target afterward is always
    /// a concrete language.
    static func swapCompose() {
        let oldSource = composeSourceCode == Languages.autoCode ? lastSpecificComposeSourceCode : composeSourceCode
        let oldTarget = composeTargetCode
        composeSourceCode = oldTarget
        composeSourceOverride = nil
        lastSpecificComposeSourceCode = oldTarget   // oldTarget is always concrete, never auto
        composeTargetCode = oldSource
    }

    /// Read source. Default auto-detect. Independent of `readTargetCode` — Read
    /// isn't a strict swap pair since Auto-detect can only ever be a source.
    static var readSourceCode: String {
        get { defaults.string(forKey: "readSourceCode") ?? Languages.autoCode }
        set { defaults.set(newValue, forKey: "readSourceCode") }
    }

    /// Read target — what Read translates *into*. Default English; never
    /// Auto-detect, since a target has to be a concrete language.
    static var readTargetCode: String {
        get { defaults.string(forKey: "readTargetCode") ?? Languages.englishCode }
        set { defaults.set(newValue, forKey: "readTargetCode") }
    }

    /// Swap Read's source and target. Since Auto-detect can't become a target,
    /// a source of Auto-detect is substituted with the last specific language
    /// you picked (the same fallback already used for offline mode) before the
    /// swap, so the target after swapping is always a concrete language.
    static func swapReadDirection() {
        let oldSource = readSourceCode == Languages.autoCode ? lastSpecificReadCode : readSourceCode
        let oldTarget = readTargetCode
        readSourceCode = oldTarget
        readSourceOverride = nil
        lastSpecificReadCode = oldTarget   // oldTarget is always concrete, never auto
        readTargetCode = oldSource
    }

    /// The last *specific* (non-auto) Read language the user picked — used offline,
    /// where auto-detect isn't available. Falls back to the compose target, since
    /// you most likely read the language you're also writing.
    static var lastSpecificReadCode: String {
        get { defaults.string(forKey: "lastSpecificReadCode") ?? composeTargetCode }
        set { defaults.set(newValue, forKey: "lastSpecificReadCode") }
    }

    /// A temporary, in-memory override for the read source (never persisted). Set
    /// while offline to translate from a specific language without touching the
    /// user's saved `readSourceCode` preference — so quitting while offline can't
    /// corrupt it. Cleared when back online.
    static var readSourceOverride: String?

    /// The read source actually used for translation: the offline override if set,
    /// otherwise the saved preference.
    static var effectiveReadSourceCode: String {
        readSourceOverride ?? readSourceCode
    }

}
