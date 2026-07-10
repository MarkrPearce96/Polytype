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
        .onAppear { key = secrets.get(googleKeyName) ?? "" }
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
