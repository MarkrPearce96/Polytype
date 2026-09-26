import AppKit
import Carbon

/// Thin wrapper around the Carbon `RegisterEventHotKey` API — the standard way
/// to register a *global* hotkey (fires regardless of which app is frontmost)
/// without needing an event tap. The Carbon handler is a C function pointer that
/// can't capture Swift context, so we dispatch through a static id→instance map.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private let action: () -> Void

    /// Weak so the registry is a lookup table, not an owner — a strong entry
    /// here would keep every past `HotKey` alive forever (nothing else would
    /// ever be its sole owner to release), so `deinit` — and the
    /// `UnregisterEventHotKey` call in it — would never run, leaking the old
    /// combo as a permanently-active global hotkey alongside the new one.
    private final class WeakBox { weak var value: HotKey?; init(_ v: HotKey) { value = v } }
    private static var registry: [UInt32: WeakBox] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    /// - Parameters:
    ///   - keyCode: a `kVK_ANSI_*` virtual key code.
    ///   - modifiers: Carbon modifier mask (e.g. `cmdKey | optionKey`).
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        self.id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x5454_5452), id: id) // 'TTTR'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, ref != nil else { return nil }
        HotKey.registry[id] = WeakBox(self)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.registry[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            HotKey.registry[hkID.id]?.value?.action()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
