import Foundation
import TranslationCore

/// Tracks whether Google Translate is currently usable and keeps the
/// language preferences' Auto-detect overrides and Apple on-device
/// availability in sync with that — the reactive health-tracking behavior
/// that used to live directly on `AppDelegate`.
@MainActor
final class GoogleHealthMonitor {
    private let networkMonitor: NetworkMonitor
    private(set) var lastEngineUsed: String?

    /// Which curated languages currently have their on-device pack installed,
    /// checked against English (the common pairing) — nil until computed.
    /// Populated lazily while relying on Apple (see `reconcile`) so the
    /// pickers can filter to only what's actually usable right now; left nil
    /// (no filtering) while Google's healthy, since Google can translate any
    /// pair with nothing to download.
    private(set) var installedLanguageCodes: Set<String>?

    /// Fired after reconciling — the language menu (checkmarks, direction
    /// labels, swap-enabled state) needs to refresh from the updated
    /// preferences/installed-set.
    var onChange: (() -> Void)?

    init(networkMonitor: NetworkMonitor) {
        self.networkMonitor = networkMonitor
    }

    /// Best-effort read on whether Google Translate is currently usable —
    /// combines raw network reachability with the outcome of the last real
    /// translation attempt (reactive: no extra network calls or quota spent
    /// purely for health-checking).
    var isHealthy: Bool {
        networkMonitor.isOnline && lastEngineUsed != "apple" && lastEngineUsed != "failed"
    }

    func recordEngineUsed(_ name: String) {
        lastEngineUsed = name
        reconcile()
    }

    func recordNetworkChange(online: Bool) {
        // Clear a stale failure so the status light doesn't stay orange after
        // connectivity returns — reconcile() below handles the rest.
        if online, lastEngineUsed == "failed" { lastEngineUsed = nil }
        reconcile()
    }

    /// Keeps each card's Auto-detect override in sync with Google's health:
    /// substitutes a concrete language when Google breaks, and clears the
    /// substitution the moment Google's healthy again — which reverts to
    /// Auto-detect exactly when the standing preference is still "auto" (a
    /// pick made *during* an outage lands there; one made while healthy
    /// becomes the new standing preference instead, and is untouched by this).
    private func reconcile() {
        if isHealthy {
            LanguagePrefs.readSourceOverride = nil
            LanguagePrefs.composeSourceOverride = nil
            installedLanguageCodes = nil   // recompute fresh next time we actually rely on Apple
        } else {
            if LanguagePrefs.readSourceCode == Languages.autoCode && LanguagePrefs.readSourceOverride == nil {
                LanguagePrefs.readSourceOverride = LanguagePrefs.lastSpecificReadCode
            }
            if LanguagePrefs.composeSourceCode == Languages.autoCode && LanguagePrefs.composeSourceOverride == nil {
                LanguagePrefs.composeSourceOverride = LanguagePrefs.lastSpecificComposeSourceCode
            }
            if installedLanguageCodes == nil { refreshInstalledLanguageAvailability() }
        }
        onChange?()
    }

    /// Populates `installedLanguageCodes` — async, since checking Apple's
    /// on-device pack status is a real system query, not instant. Until it
    /// resolves, the pickers just show everything unfiltered rather than
    /// waiting; this fills in shortly after, in practice before most users
    /// even open a list.
    private func refreshInstalledLanguageAvailability() {
        guard #available(macOS 15, *) else { installedLanguageCodes = []; return }
        Task { @MainActor in
            var installed: Set<String> = [Languages.englishCode]
            for lang in Languages.all {
                let toEnglish = await AppleLanguagePack.isInstalled(from: lang.code, to: Languages.englishCode)
                let fromEnglish = await AppleLanguagePack.isInstalled(from: Languages.englishCode, to: lang.code)
                if toEnglish || fromEnglish { installed.insert(lang.code) }
            }
            guard !self.isHealthy else { return }   // recovered while checking — no longer relevant
            self.installedLanguageCodes = installed
        }
    }
}
