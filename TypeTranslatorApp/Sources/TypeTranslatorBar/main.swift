import AppKit

// Menu-bar utility: no Dock icon, no main window — lives in the status bar and
// listens for the global ⌥⌘T hotkey.
// Top-level startup code runs on the main thread, so it's safe to assume the
// main actor here — this lets us construct the @MainActor AppDelegate.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
