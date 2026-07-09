import AppKit
import Carbon

/// Owns the single global hotkey: loads the saved combo (default ⌥⌘T), registers
/// it, and re-registers when the user picks a new one in Settings. The chosen
/// combo persists in UserDefaults across launches.
@MainActor
final class HotkeyController {
    static let shared = HotkeyController()

    private enum Key {
        static let keyCode = "hotkeyKeyCode"
        static let modifiers = "hotkeyModifiers"
        static let display = "hotkeyDisplay"
    }

    private(set) var display: String
    private var keyCode: UInt32
    private var carbonMods: UInt32
    private var hotKey: HotKey?

    /// Invoked when the hotkey fires.
    var action: (() -> Void)?
    /// Invoked whenever the displayed shortcut changes (so the menu can update).
    var onChange: ((String) -> Void)?

    private init() {
        let d = UserDefaults.standard
        keyCode = UInt32(d.object(forKey: Key.keyCode) as? Int ?? kVK_ANSI_T)
        carbonMods = UInt32(d.object(forKey: Key.modifiers) as? Int ?? (cmdKey | optionKey))
        display = d.string(forKey: Key.display) ?? "⌥⌘T"
    }

    /// (Re)register the current combo. Returns false if the system rejected it
    /// (e.g. the combo is already claimed by another app).
    @discardableResult
    func register() -> Bool {
        hotKey = HotKey(keyCode: keyCode, modifiers: carbonMods) { [weak self] in
            self?.action?()
        }
        return hotKey != nil
    }

    /// Apply a newly-recorded combo. Reverts and returns false if it can't be
    /// registered, so the user is never left with a dead hotkey.
    @discardableResult
    func update(keyCode newKey: UInt32, carbonMods newMods: UInt32, display newDisplay: String) -> Bool {
        let (oldKey, oldMods, oldDisplay) = (keyCode, carbonMods, display)
        keyCode = newKey; carbonMods = newMods; display = newDisplay
        if register() {
            let d = UserDefaults.standard
            d.set(Int(newKey), forKey: Key.keyCode)
            d.set(Int(newMods), forKey: Key.modifiers)
            d.set(newDisplay, forKey: Key.display)
            onChange?(display)
            return true
        }
        // Rejected — restore the previous working combo.
        keyCode = oldKey; carbonMods = oldMods; display = oldDisplay
        _ = register()
        onChange?(display)
        return false
    }
}
