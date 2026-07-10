import AppKit
import SwiftUI
import TranslationCore

/// Preferences UI: enter a DeepL API key (stored in the Keychain) and download
/// the on-device zh-TW language pack used by the offline fallback.
struct SettingsView: View {
    private let secrets = KeychainSecretStore()
    @State private var key: String = ""
    @State private var status: String = ""
    @State private var composeDisplay: String = HotkeyAccess.compose?.display ?? "⌥⌘T"
    @State private var readDisplay: String = HotkeyAccess.read?.display ?? "⌥⌘R"
    @State private var launchAtLogin: Bool = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Type Translator").font(.headline)
            Text("English → Taiwanese Mandarin (Traditional)")
                .font(.subheadline).foregroundStyle(.secondary)

            Divider()

            HStack(spacing: 8) {
                Text("Compose (English → 中):").font(.callout)
                HotkeyRecorder(current: composeDisplay) { keyCode, mods, display in
                    if HotkeyAccess.compose?.update(keyCode: keyCode, carbonMods: mods, display: display) == true {
                        composeDisplay = display; status = "Compose shortcut set to \(display)."
                    } else { status = "That shortcut is already in use — try another." }
                }.frame(width: 150, height: 26)
            }
            HStack(spacing: 8) {
                Text("Read (中 → English):").font(.callout)
                HotkeyRecorder(current: readDisplay) { keyCode, mods, display in
                    if HotkeyAccess.read?.update(keyCode: keyCode, carbonMods: mods, display: display) == true {
                        readDisplay = display; status = "Read shortcut set to \(display)."
                    } else { status = "That shortcut is already in use — try another." }
                }.frame(width: 150, height: 26)
            }
            Text("Click a button, then press the keys you want (must include ⌘, ⌥, ⌃, or ⇧). "
                 + "Compose translates what you typed in place; Read shows the English for selected Chinese in a popup.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    if let error = LoginItem.setEnabled(newValue) {
                        status = error
                        launchAtLogin = LoginItem.isEnabled   // reflect actual state
                    } else {
                        status = newValue ? "Will start automatically at login." : "Won't start at login."
                    }
                }

            Divider()

            Text("Google Cloud Translation API key (free tier: 500,000 characters/month). "
                 + "Leave blank to use Apple's on-device translation only.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("Google API key…", text: $key)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Save key") {
                    secrets.set(key.isEmpty ? nil : key, for: googleKeyName)
                    status = key.isEmpty
                        ? "Key cleared — using Apple on-device only."
                        : "Key saved to Keychain."
                }
                Button("Download zh-TW pack") {
                    Task {
                        if #available(macOS 15, *) {
                            _ = try? await AppleEngine().translate("hello", from: "en", to: "zh-TW")
                        }
                        status = "If macOS prompts, allow the language download. "
                               + "This enables offline translation."
                    }
                }
            }

            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { key = secrets.get(googleKeyName) ?? "" }
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
