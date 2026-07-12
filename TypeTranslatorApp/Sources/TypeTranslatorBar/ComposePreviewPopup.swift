import AppKit
import CoreGraphics

/// A floating, non-activating panel that previews a Compose translation and its
/// back-translation, letting the user confirm (Return) or cancel (Esc / click /
/// timeout) before anything is pasted. While visible it installs a short-lived
/// CGEvent tap that CONSUMES Return/Enter/Esc so a confirm keypress can't leak
/// into the chat app underneath (e.g. sending a half-finished LINE message).
@MainActor
final class ComposePreviewPopup {
    static let shared = ComposePreviewPopup()

    private var panel: NSPanel?
    private var clickMonitor: Any?
    private var escMonitor: Any?
    private var keyMonitorFallback: Any?
    private var dismissTimer: Timer?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onInsert: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var generation = 0

    // Refs for filling in the back-translation after the popup is already shown.
    private var backRow: NSStackView?
    private var backCaptionLabel: NSTextField?
    private var backValueLabel: NSTextField?
    private weak var containerView: NSVisualEffectView?
    private var anchorPoint: NSPoint = .zero

    /// Shows the preview immediately using the already-computed forward
    /// translation; `back` is awaited AFTER the panel is on screen and fills in
    /// the "Means back" line, so the preview appears as fast as an instant paste.
    func show(original: String, translation: String, languageName: String,
              at screenPoint: NSPoint,
              onInsert: @escaping () -> Void, onCancel: @escaping () -> Void,
              back: @escaping () async -> (String?, String?)) {
        teardown()                       // clear any prior panel without firing callbacks
        generation += 1
        let gen = generation
        self.onInsert = onInsert
        self.onCancel = onCancel
        self.anchorPoint = screenPoint

        let content = buildContent(original: original, translation: translation,
                                   languageName: languageName)
        let container = NSVisualEffectView()
        container.material = .popover
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.containerView = container

        let fitting = container.fittingSize
        let size = NSSize(width: max(300, fitting.width), height: max(80, fitting.height))
        let origin = clampedOrigin(for: size, near: screenPoint)

        let newPanel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.hasShadow = true
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hidesOnDeactivate = false
        newPanel.contentView = container
        newPanel.orderFrontRegardless()
        self.panel = newPanel

        installEventTap()

        // Cancel on a click anywhere outside the interaction.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.finish(insert: false)
            }
        }

        // Esc always cancels — a reliable backup for the event tap. If the tap
        // consumes Esc this monitor never sees it; if the tap isn't delivering
        // events on this system, this still dismisses. Esc leaking to the app
        // underneath is harmless (unlike Return, which stays tap-only).
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.finish(insert: false)
            }
        }

        // Length-scaled auto-dismiss (= cancel), so a walked-away preview never
        // inserts on its own. Floor 25s, capped 90s.
        let readingTime = min(90, max(25, Double(translation.count) / 6))
        dismissTimer = Timer.scheduledTimer(withTimeInterval: readingTime, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.finish(insert: false)
            }
        }

        // Fill in the back-translation after the popup is visible.
        Task { @MainActor in
            let (text, engineName) = await back()
            guard self.generation == gen else { return }
            self.applyBack(text: text, engine: engineName)
        }
    }

    func dismiss() { teardown() }

    /// Fire exactly one of the callbacks, then tear everything down.
    fileprivate func finish(insert: Bool) {
        let ins = onInsert, can = onCancel
        onInsert = nil; onCancel = nil
        teardown()
        if insert { ins?() } else { can?() }
    }

    private func teardown() {
        dismissTimer?.invalidate(); dismissTimer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        if let keyMonitorFallback { NSEvent.removeMonitor(keyMonitorFallback) }
        clickMonitor = nil; escMonitor = nil; keyMonitorFallback = nil
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        runLoopSource = nil; eventTap = nil
        panel?.orderOut(nil); panel = nil
        onInsert = nil; onCancel = nil
    }

    // MARK: - Key interception

    /// Install a session-level keyDown tap that consumes Return/Enter/Esc. If the
    /// tap can't be created (should not happen — the app already holds
    /// Accessibility by the time a preview runs), fall back to a non-consuming
    /// global key monitor so the buttons still work.
    private func installEventTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: composePreviewTapCallback, userInfo: selfPtr) else {
            installKeyMonitorFallback()
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTap = tap
        self.runLoopSource = source
    }

    private func installKeyMonitorFallback() {
        let gen = generation
        keyMonitorFallback = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                switch event.keyCode {
                case 36, 76: self.finish(insert: true)
                case 53:     self.finish(insert: false)
                default:     break
                }
            }
        }
    }

    // MARK: - Layout

    private func buildContent(original: String, translation: String, languageName: String) -> NSView {
        func section(_ caption: String, _ value: String, emphasized: Bool) -> (NSStackView, NSTextField, NSTextField) {
            let cap = NSTextField(labelWithString: caption.uppercased())
            cap.font = .systemFont(ofSize: 10, weight: .semibold)
            cap.textColor = .tertiaryLabelColor
            let val = NSTextField(wrappingLabelWithString: value)
            val.font = emphasized ? .systemFont(ofSize: 16, weight: .semibold) : .systemFont(ofSize: 13)
            val.textColor = .labelColor
            val.isSelectable = true
            val.preferredMaxLayoutWidth = 340
            let s = NSStackView(views: [cap, val])
            s.orientation = .vertical; s.alignment = .leading; s.spacing = 2
            return (s, cap, val)
        }

        let (typedRow, _, _) = section("You typed", original, emphasized: false)
        let (sendRow, _, _) = section("Will send · \(languageName)", translation, emphasized: true)
        let (backRow, backCap, backVal) = section("Means back", "checking…", emphasized: false)
        self.backRow = backRow
        self.backCaptionLabel = backCap
        self.backValueLabel = backVal

        let sep = NSBox(); sep.boxType = .separator
        let hint = NSTextField(labelWithString: "⏎ Insert      esc Cancel")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [typedRow, sendRow, backRow, sep, hint])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        // Make the separator span the content width.
        sep.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        return stack
    }

    /// Fill in (or hide) the "Means back" row once the back-translation resolves,
    /// then resize the panel to fit the new content.
    fileprivate func applyBack(text: String?, engine: String?) {
        if let text, !text.isEmpty {
            let label = "Means back" + (engine.map { " · \($0)" } ?? "")
            backCaptionLabel?.stringValue = label.uppercased()
            backValueLabel?.stringValue = text
            backRow?.isHidden = false
        } else {
            backRow?.isHidden = true   // both engines failed — drop the row entirely
        }
        resizeToFit()
    }

    /// Re-fit the panel after the "Means back" line changes height.
    private func resizeToFit() {
        guard let panel, let container = containerView else { return }
        container.layoutSubtreeIfNeeded()
        let fitting = container.fittingSize
        let size = NSSize(width: max(300, fitting.width), height: max(80, fitting.height))
        let origin = clampedOrigin(for: size, near: anchorPoint)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }

    private func clampedOrigin(for size: NSSize, near point: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = point.x + 12
        var y = point.y - size.height - 12
        x = min(max(frame.minX, x), frame.maxX - size.width)
        y = min(max(frame.minY, y), frame.maxY - size.height)
        return NSPoint(x: x, y: y)
    }
}

/// C-callback for the preview key tap. Runs on the main run loop (the source is
/// added to `CFRunLoopGetMain`), so main-actor access is safe. Consumes
/// Return/Enter/Esc (returns nil); passes everything else through.
private func composePreviewTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                                       event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let popup = Unmanaged<ComposePreviewPopup>.fromOpaque(refcon).takeUnretainedValue()

    // The system disables a tap that times out or is interrupted; re-enable it.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { popup.reenableTap() }
        return Unmanaged.passUnretained(event)
    }
    if type == .keyDown {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        switch code {
        case 36, 76:   // Return / keypad Enter
            MainActor.assumeIsolated { popup.finish(insert: true) }
            return nil
        case 53:       // Esc
            MainActor.assumeIsolated { popup.finish(insert: false) }
            return nil
        default:
            break
        }
    }
    return Unmanaged.passUnretained(event)
}

extension ComposePreviewPopup {
    /// Re-enable the tap after the system disabled it (called from the callback).
    fileprivate func reenableTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}
