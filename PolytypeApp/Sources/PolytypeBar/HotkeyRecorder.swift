import AppKit
import Carbon
import SwiftUI

/// Convert Cocoa modifier flags to the Carbon mask `RegisterEventHotKey` expects.
func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var mods: UInt32 = 0
    if flags.contains(.command) { mods |= UInt32(cmdKey) }
    if flags.contains(.option)  { mods |= UInt32(optionKey) }
    if flags.contains(.control) { mods |= UInt32(controlKey) }
    if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
    return mods
}

/// Human-readable shortcut string, e.g. "⌥⌘T".
enum HotkeyFormat {
    /// Names for common non-printing keys, by virtual key code.
    private static let special: [UInt16: String] = [
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Delete): "⌫", UInt16(kVK_Escape): "⎋",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_ANSI_KeypadEnter): "⌤",
    ]

    static func string(flags: NSEvent.ModifierFlags, chars: String?, keyCode: UInt16) -> String {
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option)  { out += "⌥" }
        if flags.contains(.shift)   { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        if let name = special[keyCode] {
            out += name
        } else if let c = chars, let first = c.first, first.isLetter || first.isNumber || first.isPunctuation || first.isSymbol {
            out += String(first).uppercased()
        } else {
            out += "key\(keyCode)"
        }
        return out
    }
}

/// A push-button that, while "recording", captures the next key combo the user
/// presses (requiring at least one modifier) and reports it.
final class HotkeyRecorderButton: NSButton {
    var onCapture: ((UInt32, UInt32, String) -> Void)?
    var idleTitle: String = "" { didSet { if !recording { title = idleTitle } } }
    private(set) var recording = false {
        didSet { title = recording ? "Press shortcut…" : idleTitle }
    }

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        setButtonType(.momentaryPushIn)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
    }

    @objc private func beginRecording() {
        recording = true
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == UInt16(kVK_Escape) { recording = false; return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let mods = carbonModifiers(from: flags)
        guard mods != 0 else { NSSound.beep(); return }   // require a modifier
        let display = HotkeyFormat.string(flags: flags, chars: event.charactersIgnoringModifiers, keyCode: event.keyCode)
        onCapture?(UInt32(event.keyCode), mods, display)
        recording = false
    }

    // Capture combinations that would otherwise be swallowed as menu shortcuts.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recording { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// SwiftUI wrapper around `HotkeyRecorderButton`.
struct HotkeyRecorder: NSViewRepresentable {
    let current: String
    let onCapture: (UInt32, UInt32, String) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderButton {
        let button = HotkeyRecorderButton()
        button.idleTitle = current
        button.onCapture = onCapture
        return button
    }

    func updateNSView(_ button: HotkeyRecorderButton, context: Context) {
        button.idleTitle = current
    }
}
