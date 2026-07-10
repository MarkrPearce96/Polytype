import AppKit
import SwiftUI
import TranslationCore

/// Whether first-run setup has been completed/dismissed (shows the wizard once).
@MainActor
enum SetupState {
    static var completed: Bool {
        get { UserDefaults.standard.bool(forKey: "setupCompleted") }
        set { UserDefaults.standard.set(newValue, forKey: "setupCompleted") }
    }
}

/// Owns the single setup window. Marks setup complete when the window closes
/// (whether finished or dismissed), so it never re-nags.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    static let shared = SetupWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SetupView(onFinish: { [weak self] in
                self?.window?.close()
            }))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Set Up Type Translator"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { SetupState.completed = true }
    }
}

/// Gradient primary button matching the app's identity.
private struct GradientButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(
                LinearGradient(colors: [Color(red: 74/255, green: 125/255, blue: 1.0),
                                        Color(red: 150/255, green: 88/255, blue: 246/255)],
                               startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

struct SetupView: View {
    let onFinish: () -> Void

    private let secrets = KeychainSecretStore()
    private let stepCount = 6
    @State private var step = 0
    @State private var apiKey = ""
    @State private var composeCode = "zh-TW"
    @State private var composeDisplay = "⌥⌘T"
    @State private var readDisplay = "⌥⌘R"
    @State private var launchAtLogin = false
    @State private var accessibilityGranted = false

    private var brand: LinearGradient {
        LinearGradient(colors: [Color(red: 74/255, green: 125/255, blue: 1.0),
                                Color(red: 150/255, green: 88/255, blue: 246/255)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            footer
        }
        .frame(width: 460, height: 540)
        .onAppear {
            composeCode = LanguagePrefs.composeTargetCode
            apiKey = secrets.get(googleKeyName) ?? ""
            composeDisplay = HotkeyAccess.compose?.display ?? "⌥⌘T"
            readDisplay = HotkeyAccess.read?.display ?? "⌥⌘R"
            launchAtLogin = LoginItem.isEnabled
            accessibilityGranted = AXIsProcessTrusted()
        }
        .onReceive(Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()) { _ in
            accessibilityGranted = AXIsProcessTrusted()
        }
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch step {
        case 0: welcomeStep
        case 1: accessibilityStep
        case 2: apiKeyStep
        case 3: languageStep
        case 4: shortcutsStep
        default: doneStep
        }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 25, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(brand, in: RoundedRectangle(cornerRadius: 13))
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            icon("globe")
            Text("Welcome to Type Translator").font(.title2.weight(.semibold))
            Text("Type a message in English in any app, press a hotkey, and it's replaced with the translation — ready to send. Let's get you set up.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            icon("lock.shield")
            Text("Grant Accessibility access").font(.title2.weight(.semibold))
            Text("The hotkey needs permission to read and replace your selected text. Click below, then enable Type Translator in the list.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            HStack(spacing: 7) {
                Circle().fill(accessibilityGranted ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(accessibilityGranted ? "Access granted" : "Waiting for permission…")
                    .font(.callout).foregroundStyle(accessibilityGranted ? Color.green : Color.secondary)
            }
            Spacer()
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var apiKeyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            icon("key")
            Text("Add your translation key").font(.title2.weight(.semibold))
            Text("Paste a Google Cloud Translation key for the best quality — the free tier covers 500,000 characters/month.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Google API key…", text: $apiKey).textFieldStyle(.roundedBorder)
            Link("Get a free key →", destination: URL(string: "https://console.cloud.google.com/apis/library/translate.googleapis.com")!)
                .font(.callout)
            Text("No key? Skip to use Apple's on-device translation (free, offline, slightly lower quality).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var languageStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            icon("globe")
            Text("Choose your language").font(.title2.weight(.semibold))
            Text("Compose translates your English into…").font(.callout).foregroundStyle(.secondary)
            Picker("", selection: $composeCode) {
                ForEach(Languages.all, id: \.code) { lang in Text(lang.name).tag(lang.code) }
            }
            .labelsHidden().pickerStyle(.menu)
            Text("Reading goes the other way — it auto-detects any foreign text into English. Change either anytime from the menu-bar icon.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shortcutsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            icon("keyboard")
            Text("Choose your shortcuts").font(.title2.weight(.semibold))
            Text("These trigger a translation from anywhere. The defaults work for most people — or click one and press your own keys.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Compose").font(.callout)
                Spacer()
                HotkeyRecorder(current: composeDisplay) { keyCode, mods, display in
                    if HotkeyAccess.compose?.update(keyCode: keyCode, carbonMods: mods, display: display) == true {
                        composeDisplay = display
                    }
                }.frame(width: 122, height: 24)
            }
            HStack {
                Text("Read").font(.callout)
                Spacer()
                HotkeyRecorder(current: readDisplay) { keyCode, mods, display in
                    if HotkeyAccess.read?.update(keyCode: keyCode, carbonMods: mods, display: display) == true {
                        readDisplay = display
                    }
                }.frame(width: 122, height: 24)
            }
            Text("A shortcut must include ⌘, ⌥, ⌃, or ⇧. Change these anytime in Settings.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 46)).foregroundStyle(.green)
            Text("You're all set").font(.title2.weight(.semibold))
            Text("Press \(composeDisplay) in any app to translate what you typed. Select foreign text and press \(readDisplay) to read it in English.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in _ = LoginItem.setEnabled(newValue) }
            Spacer()
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<stepCount, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: i == step ? 16 : 6, height: 6)
                }
            }
            Spacer()
            footerButtons
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .overlay(Divider(), alignment: .top)
    }

    @ViewBuilder private var footerButtons: some View {
        switch step {
        case 0:
            Button("Get started") { step = 1 }.buttonStyle(GradientButtonStyle())
        case 1:
            Button("Back") { step = 0 }.buttonStyle(.plain).foregroundStyle(.secondary)
            Button("Next") { step = 2 }.buttonStyle(GradientButtonStyle())
                .disabled(!accessibilityGranted).opacity(accessibilityGranted ? 1 : 0.5)
        case 2:
            Button("Skip") { step = 3 }.buttonStyle(.plain).foregroundStyle(.secondary)
            Button("Save & continue") {
                secrets.set(apiKey.isEmpty ? nil : apiKey, for: googleKeyName)
                step = 3
            }.buttonStyle(GradientButtonStyle())
        case 3:
            Button("Back") { step = 2 }.buttonStyle(.plain).foregroundStyle(.secondary)
            Button("Continue") { LanguagePrefs.composeTargetCode = composeCode; step = 4 }
                .buttonStyle(GradientButtonStyle())
        case 4:
            Button("Back") { step = 3 }.buttonStyle(.plain).foregroundStyle(.secondary)
            Button("Continue") { step = 5 }.buttonStyle(GradientButtonStyle())
        default:
            Button("Start translating") { onFinish() }.buttonStyle(GradientButtonStyle())
        }
    }
}
