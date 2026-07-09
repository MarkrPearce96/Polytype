import AppKit
import SwiftUI
import TranslationCore

/// Preferences UI: enter a DeepL API key (stored in the Keychain) and download
/// the on-device zh-TW language pack used by the offline fallback.
struct SettingsView: View {
    private let secrets = KeychainSecretStore()
    @State private var key: String = ""
    @State private var status: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Type Translator").font(.headline)
            Text("English → Taiwanese Mandarin (Traditional)")
                .font(.subheadline).foregroundStyle(.secondary)

            Divider()

            Text("DeepL API key — optional. Leave blank to use Apple's on-device translation only.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("DeepL-Auth-Key…", text: $key)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Save key") {
                    secrets.set(key.isEmpty ? nil : key, for: deepLKeyName)
                    status = key.isEmpty
                        ? "Key cleared — using Apple on-device only."
                        : "Key saved to Keychain."
                }
                Button("Download zh-TW pack") {
                    Task {
                        if #available(macOS 15, *) {
                            _ = try? await AppleEngine().translate("hello", to: "zh-TW")
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
        .onAppear { key = secrets.get(deepLKeyName) ?? "" }
    }
}

/// Owns the single settings window so repeated "Settings…" clicks reuse it.
/// Methods touch AppKit and are only ever invoked from the main thread (menu
/// actions), so no explicit actor annotation is needed in Swift 5 mode.
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
