import AppKit
import SwiftUI
import TranslationCore

/// Preferences UI: set the two shortcuts, the Google API key (stored in the
/// Keychain), the login item, and reach macOS's offline-language downloads.
///
/// Hosted directly inside the same dropdown panel the menu itself uses (see
/// `DropdownPanel`/`AppDelegate.openSettings`), swapped in as its content in
/// place rather than opening as a separate window — the back arrow swaps the
/// panel's content back to the menu. Native `Form` controls are kept (forced
/// into dark appearance by the hosting window, not hand-restyled) since
/// reimplementing a date picker, secure field, and toggle from scratch would
/// add real risk for no benefit over what AppKit already renders correctly.
struct SettingsView: View {
    let onBack: () -> Void

    private let secrets = KeychainSecretStore()
    @State private var key: String = ""
    @State private var status: String = ""
    @State private var composeDisplay: String = HotkeyAccess.compose?.display ?? "⌥⌘T"
    @State private var readDisplay: String = HotkeyAccess.read?.display ?? "⌥⌘R"
    @State private var launchAtLogin: Bool = LoginItem.isEnabled
    @State private var usageInput: String = "0"   // seeded from the meter in .onAppear
    @State private var renewDate: Date = Date()   // seeded from the meter in .onAppear

    /// The renewal date must be a future day (a today/past date would roll over
    /// immediately and wipe the entered usage).
    private var minRenewDate: Date {
        let cal = Calendar(identifier: .gregorian)
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date().addingTimeInterval(86_400)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section("Shortcuts") {
                    LabeledContent("Compose") {
                        HotkeyRecorder(current: composeDisplay) { keyCode, mods, display in
                            if HotkeyAccess.compose?.update(keyCode: keyCode, carbonMods: mods, display: display) == true {
                                composeDisplay = display; status = "Compose shortcut set to \(display)."
                            } else { status = "That shortcut is already in use — try another." }
                        }.frame(width: 118, height: 24)
                    }
                    LabeledContent("Read") {
                        HotkeyRecorder(current: readDisplay) { keyCode, mods, display in
                            if HotkeyAccess.read?.update(keyCode: keyCode, carbonMods: mods, display: display) == true {
                                readDisplay = display; status = "Read shortcut set to \(display)."
                            } else { status = "That shortcut is already in use — try another." }
                        }.frame(width: 118, height: 24)
                    }
                    caption("Click a field, then press the keys (⌘, ⌥, ⌃, or ⇧). Pick languages from the menu.")
                }

                Section("Translation") {
                    LabeledContent("Google API key") {
                        SecureField("Paste key…", text: $key)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)
                    }
                    caption("Free tier: 500,000 characters/month. Leave blank for Apple on-device only.")
                    HStack {
                        Button("Save key") {
                            // A real Google API key is ~39 characters. Something much
                            // shorter replacing an already-saved key is a strong sign
                            // the field got tab-focused (which auto-selects its full
                            // contents) and the next keystroke silently wiped it —
                            // confirm rather than clobber a real key without a chance
                            // to notice.
                            let previous = secrets.get(googleKeyName) ?? ""
                            if !key.isEmpty, key.count < 20, !previous.isEmpty {
                                let alert = NSAlert()
                                alert.messageText = "Save this API key?"
                                alert.informativeText = "This is much shorter than your saved key (\(previous.count) → \(key.count) characters) — a real Google API key is usually 30+ characters. If you didn't mean to change it, click Cancel and re-paste your key."
                                alert.addButton(withTitle: "Cancel")
                                alert.addButton(withTitle: "Save Anyway")
                                guard alert.runModal() == .alertSecondButtonReturn else { return }
                            }
                            secrets.set(key.isEmpty ? nil : key, for: googleKeyName)
                            status = key.isEmpty ? "Key cleared — using Apple on-device only."
                                                 : "Key saved to Keychain."
                        }
                        Spacer()
                        Button("Manage offline…") {
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
                            .frame(width: 120)
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
                    Button("Setup Assistant…") {
                        SetupWindowController.shared.show()
                    }
                    caption("Re-run the first-launch walkthrough (Accessibility, API key, language, shortcuts).")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            footer
        }
        .frame(width: 340, height: 520)
        // No own background/corner-clip/shadow here — this view is embedded
        // directly into the shared panel shell (`GradientPanelView`), which
        // already provides the gradient, rounded corners, and shadow; adding
        // a second set here would double up rather than match it.
        .onAppear {
            key = secrets.get(googleKeyName) ?? ""
            renewDate = MeterAccess.meter?.nextResetDate ?? Date()
            usageInput = String(MeterAccess.meter?.used ?? 0)   // 0 for a fresh setup
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            Text("Settings").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    @ViewBuilder private var footer: some View {
        if !status.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "info.circle").foregroundStyle(.white.opacity(0.5))
                Text(status).font(.caption).foregroundStyle(.white.opacity(0.7))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
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

