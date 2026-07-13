import AppKit
import SwiftUI
import TranslationCore

/// Preferences UI: set the two shortcuts, the Google API key (stored in the
/// Keychain), the login item, and reach macOS's offline-language downloads.
struct SettingsView: View {
    private let secrets = KeychainSecretStore()
    @State private var key: String = ""
    @State private var status: String = ""
    @State private var composeDisplay: String = HotkeyAccess.compose?.display ?? "⌥⌘T"
    @State private var readDisplay: String = HotkeyAccess.read?.display ?? "⌥⌘R"
    @State private var launchAtLogin: Bool = LoginItem.isEnabled
    @State private var previewEnabled: Bool = false                       // seeded in .onAppear
    @State private var previewUsesComposeHotkey: Bool = false             // seeded in .onAppear
    @State private var previewDisplay: String = "⌥⇧⌘T"                    // seeded in .onAppear
    @State private var usageInput: String = "0"   // seeded from the meter in .onAppear
    @State private var renewDate: Date = Date()   // seeded from the meter in .onAppear

    /// The renewal date must be a future day (a today/past date would roll over
    /// immediately and wipe the entered usage).
    private var minRenewDate: Date {
        let cal = Calendar(identifier: .gregorian)
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date().addingTimeInterval(86_400)
    }

    /// The app's blue→violet identity gradient (matches the icon).
    private var brand: LinearGradient {
        LinearGradient(
            colors: [Color(red: 74/255, green: 125/255, blue: 1.0),
                     Color(red: 150/255, green: 88/255, blue: 246/255)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section("Shortcuts") {
                    LabeledContent("Compose") {
                        HotkeyRecorder(current: composeDisplay) { keyCode, mods, display in
                            if HotkeyAccess.compose?.update(keyCode: keyCode, carbonMods: mods, display: display) == true {
                                composeDisplay = display; status = "Compose shortcut set to \(display)."
                            } else { status = "That shortcut is already in use — try another." }
                        }.frame(width: 132, height: 24)
                    }
                    LabeledContent("Read") {
                        HotkeyRecorder(current: readDisplay) { keyCode, mods, display in
                            if HotkeyAccess.read?.update(keyCode: keyCode, carbonMods: mods, display: display) == true {
                                readDisplay = display; status = "Read shortcut set to \(display)."
                            } else { status = "That shortcut is already in use — try another." }
                        }.frame(width: 132, height: 24)
                    }
                    caption("Click a field, then press the keys (include ⌘, ⌥, ⌃, or ⇧). Compose replaces your text in place; Read shows a popup. Pick languages from the menu-bar icon.")
                }

                Section("Translation") {
                    LabeledContent("Google API key") {
                        SecureField("Paste key…", text: $key)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 210)
                    }
                    caption("Free tier: 500,000 characters/month. Leave blank to use Apple's on-device translation only.")
                    HStack {
                        Button("Save key") {
                            secrets.set(key.isEmpty ? nil : key, for: googleKeyName)
                            status = key.isEmpty ? "Key cleared — using Apple on-device only."
                                                 : "Key saved to Keychain."
                        }
                        Spacer()
                        Button("Manage offline languages…") {
                            // Apple's on-device (offline) translation uses the languages
                            // in System Settings ▸ General ▸ Language & Region ▸
                            // Translation Languages. Google (online) needs no downloads.
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                            status = "In Language & Region, open “Translation Languages” to download languages for offline use."
                        }
                    }
                }

                Section("Preview") {
                    Toggle("Preview before inserting", isOn: $previewEnabled)
                        .onChange(of: previewEnabled) { _, on in
                            LanguagePrefs.previewEnabled = on
                            PreviewControl.onSettingsChanged?()
                            status = on ? "Preview on — Compose will show a confirm step."
                                        : "Preview off — Compose inserts instantly."
                        }
                    if previewEnabled {
                        Picker("Trigger", selection: $previewUsesComposeHotkey) {
                            Text("Separate hotkey").tag(false)
                            Text("Use my Compose hotkey").tag(true)
                        }
                        .onChange(of: previewUsesComposeHotkey) { _, useCompose in
                            LanguagePrefs.previewUsesComposeHotkey = useCompose
                            PreviewControl.onSettingsChanged?()
                        }
                        if !previewUsesComposeHotkey {
                            LabeledContent("Preview shortcut") {
                                HotkeyRecorder(current: previewDisplay) { keyCode, mods, display in
                                    if HotkeyAccess.preview?.update(keyCode: keyCode, carbonMods: mods, display: display) == true {
                                        previewDisplay = display; status = "Preview shortcut set to \(display)."
                                    } else { status = "That shortcut is already in use — try another." }
                                }.frame(width: 132, height: 24)
                            }
                        }
                        caption("Shows the translation and what it means back in English before inserting. Return inserts; Esc cancels. The back-check prefers Apple's free on-device engine (macOS 15 with the language downloaded), so it usually doesn't count against your Google free tier; otherwise it falls back to Google.")
                    }
                }

                Section("Usage") {
                    Text(usageSummary).font(.callout)
                    Button("View exact usage in Google Cloud →") {
                        if let url = URL(string: "https://console.cloud.google.com/apis/api/translate.googleapis.com/metrics") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Text("Match this to your Google account: enter this month's exact character count and the date it renews.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Current usage") {
                        TextField("e.g. 42000", text: $usageInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                    }
                    DatePicker("Renews on", selection: $renewDate, in: minRenewDate..., displayedComponents: .date)
                    Button("Update usage & renewal") {
                        let digits = usageInput.filter(\.isNumber)
                        guard let count = Int(digits), let meter = MeterAccess.meter else {
                            status = "Enter a whole number for current usage."
                            return
                        }
                        meter.calibrate(used: count, nextReset: renewDate)
                        usageInput = String(count)
                        status = "Usage set to \(count.formatted()); renews \(MeterAccess.resetDateString())."
                    }
                }

                Section("Startup") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            if let error = LoginItem.setEnabled(newValue) {
                                status = error
                                launchAtLogin = LoginItem.isEnabled   // reflect actual state
                            } else {
                                status = newValue ? "Will start automatically at login." : "Won't start at login."
                            }
                        }
                }
            }
            .formStyle(.grouped)

            footer
        }
        .frame(width: 460, height: 540)
        .onAppear {
            key = secrets.get(googleKeyName) ?? ""
            renewDate = MeterAccess.meter?.nextResetDate ?? Date()
            usageInput = String(MeterAccess.meter?.used ?? 0)   // 0 for a fresh setup
            previewEnabled = LanguagePrefs.previewEnabled
            previewUsesComposeHotkey = LanguagePrefs.previewUsesComposeHotkey
            previewDisplay = HotkeyAccess.preview?.display ?? "⌥⇧⌘T"
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "globe")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(brand)
            VStack(alignment: .leading, spacing: 2) {
                Text("Type Translator").font(.title2.weight(.semibold))
                Text("Translate as you type, in any app")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    @ViewBuilder private var footer: some View {
        if status.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(status).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private var usageSummary: String {
        guard let meter = MeterAccess.meter else { return "Usage tracking unavailable." }
        let used = meter.used
        if meter.hasNotified || used >= meter.cap {
            return "Free limit reached (\(used.formatted()) / \(meter.limit.formatted())). "
                 + "Using Apple on-device until \(MeterAccess.resetDateString())."
        }
        return "≈\(used.formatted()) / \(meter.limit.formatted()) characters this month · "
             + "Resets \(MeterAccess.resetDateString())."
    }
}

/// Owns the single settings window so repeated "Settings…" clicks reuse it.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: hosting)
            w.title = "Type Translator Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
