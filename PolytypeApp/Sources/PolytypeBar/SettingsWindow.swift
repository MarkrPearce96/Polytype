import AppKit
import SwiftUI
import TranslationCore

/// Preferences UI: set the two shortcuts, the Google API key (stored in the
/// Keychain), the login item, and reach macOS's offline-language downloads.
///
/// Hosted in the same dark floating panel the menu itself uses (see
/// `SettingsPanelController`) rather than a normal titled window — the back
/// arrow returns to the menu in place, rather than this being a separate app
/// surface elsewhere on screen. Native `Form` controls are kept (forced into
/// dark appearance by the hosting window, not hand-restyled) since
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

    /// The app's blue→violet identity gradient (matches the icon and menu).
    private var brand: LinearGradient {
        LinearGradient(
            colors: [Color(red: 74/255, green: 125/255, blue: 1.0),
                     Color(red: 150/255, green: 88/255, blue: 246/255)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The panel's own gradient — matches the menu shell exactly.
    private var panelBackground: LinearGradient {
        LinearGradient(
            colors: [Color(red: 34/255, green: 49/255, blue: 66/255),
                     Color(red: 27/255, green: 39/255, blue: 51/255)],
            startPoint: .top, endPoint: .bottom)
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
        .frame(width: 360, height: 520)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06)))
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

/// Shows Settings as a borderless panel anchored to the status item, in the
/// same screen position the menu itself appears — swapping in for the menu
/// rather than opening as a separate window elsewhere. Dismisses like a menu
/// too: closes as soon as it stops being the key window (a click anywhere
/// else), not just via its own back button.
@MainActor
final class SettingsPanelController: NSObject, NSWindowDelegate {
    static let shared = SettingsPanelController()
    private var window: NSWindow?
    private var reopenMenu: (() -> Void)?

    /// - Parameters:
    ///   - button: the status item's button, used to position the panel
    ///     exactly where the menu appears.
    ///   - reopenMenu: called when the back button is pressed, to hand
    ///     control back to the normal dropdown.
    func show(near button: NSStatusBarButton?, reopenMenu: @escaping () -> Void) {
        self.reopenMenu = reopenMenu

        let hosting = NSHostingController(rootView: SettingsView(onBack: { [weak self] in
            self?.goBack()
        }))
        let w: NSWindow
        if let existing = window {
            w = existing
            w.contentViewController = hosting
        } else {
            w = NSWindow(contentViewController: hosting)
            w.styleMask = [.borderless]
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false   // SwiftUI draws its own shadow-shaped-to-match the rounded panel
            w.level = .popUpMenu
            // Panel is always dark (matches the menu shell) regardless of the
            // system's light/dark setting — force it so native controls
            // (buttons, fields, the date picker) render with dark styling
            // and don't clash against the dark gradient background.
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }

        position(w, near: button)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func goBack() {
        window?.orderOut(nil)
        reopenMenu?()
    }

    /// Closing like a menu: dismiss the instant something else becomes key,
    /// not just via the explicit back button.
    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            window?.orderOut(nil)
        }
    }

    private func position(_ window: NSWindow, near button: NSStatusBarButton?) {
        guard let button, let buttonWindow = button.window else {
            window.center()
            return
        }
        let buttonFrameOnScreen = buttonWindow.convertToScreen(button.frame)
        let size = window.frame.size
        var origin = NSPoint(
            x: buttonFrameOnScreen.maxX - size.width,
            y: buttonFrameOnScreen.minY - size.height - 4)
        if let screenFrame = buttonWindow.screen?.visibleFrame {
            origin.x = max(screenFrame.minX + 8, min(origin.x, screenFrame.maxX - size.width - 8))
            origin.y = max(screenFrame.minY + 8, origin.y)
        }
        window.setFrameOrigin(origin)
    }
}
