import AppKit
import Carbon

/// Owns a single named global hotkey: loads the saved combo (falling back to
/// the caller-supplied default), registers it, and re-registers when the user
/// picks a new one in Settings. The chosen combo persists in UserDefaults
/// across launches, namespaced by `id` so multiple hotkeys can coexist.
@MainActor
final class HotkeyController {
    private let id: String
    private var keyCode: UInt32
    private var carbonMods: UInt32
    private(set) var display: String
    private var hotKey: HotKey?

    /// Invoked when the hotkey fires.
    var action: (() -> Void)?
    /// Invoked whenever the displayed shortcut changes (so the menu can update).
    var onChange: ((String) -> Void)?

    init(id: String, defaultKeyCode: UInt32, defaultModifiers: UInt32, defaultDisplay: String) {
        self.id = id
        let d = UserDefaults.standard

        // One-time migration: the compose hotkey used to persist under flat keys
        // (hotkeyKeyCode/hotkeyModifiers/hotkeyDisplay) before hotkeys were
        // namespaced by id. If a user had customized it, carry that forward as the
        // effective default so the upgrade doesn't silently reset their shortcut.
        var effKeyCode = defaultKeyCode
        var effMods = defaultModifiers
        var effDisplay = defaultDisplay
        if id == "compose",
           d.object(forKey: "hotkey.compose.keyCode") == nil,
           let legacyKeyCode = d.object(forKey: "hotkeyKeyCode") as? Int {
            effKeyCode = UInt32(legacyKeyCode)
            effMods = UInt32(d.object(forKey: "hotkeyModifiers") as? Int ?? Int(defaultModifiers))
            effDisplay = d.string(forKey: "hotkeyDisplay") ?? defaultDisplay
        }

        keyCode = UInt32(d.object(forKey: "hotkey.\(id).keyCode") as? Int ?? Int(effKeyCode))
        carbonMods = UInt32(d.object(forKey: "hotkey.\(id).modifiers") as? Int ?? Int(effMods))
        display = d.string(forKey: "hotkey.\(id).display") ?? effDisplay
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
            d.set(Int(newKey), forKey: "hotkey.\(id).keyCode")
            d.set(Int(newMods), forKey: "hotkey.\(id).modifiers")
            d.set(newDisplay, forKey: "hotkey.\(id).display")
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

/// Lets the SwiftUI Settings view reach the controllers created in AppDelegate.
@MainActor
enum HotkeyAccess {
    static var compose: HotkeyController?
    static var read: HotkeyController?
}
