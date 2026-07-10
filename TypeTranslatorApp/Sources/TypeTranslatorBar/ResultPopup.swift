import AppKit

/// A small, non-activating floating panel that shows a line of text near a
/// screen point (e.g. the mouse). Used to display read-mode translations
/// without stealing focus or altering any document.
@MainActor
final class ResultPopup {
    static let shared = ResultPopup()

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var generation = 0

    func show(_ text: String, at screenPoint: NSPoint) {
        dismiss()
        generation += 1
        let gen = generation

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .labelColor
        label.isSelectable = true
        label.preferredMaxLayoutWidth = 360

        let container = NSVisualEffectView()
        container.material = .popover
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        let fitting = container.fittingSize
        let size = NSSize(width: max(120, fitting.width), height: max(40, fitting.height))
        let origin = clampedOrigin(for: size, near: screenPoint)

        let newPanel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.hasShadow = true
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        // Intentionally not dismissing on app deactivation: Type Translator is a
        // non-activating background menu-bar app, so it's essentially never the
        // "active" app and there's no meaningful deactivation event to key off
        // of. The popup should stay visible while the user keeps working in the
        // real target app, and is dismissed via Esc, a click elsewhere, or the
        // auto-dismiss timeout below.
        newPanel.hidesOnDeactivate = false
        newPanel.contentView = container
        newPanel.orderFrontRegardless()
        self.panel = newPanel

        // Dismiss on a click anywhere.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.dismiss()
            }
        }
        // Dismiss on Esc (global monitor, since the panel is non-activating and
        // never becomes key). Requires Accessibility, which the app already has.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {   // 53 = Escape
                Task { @MainActor in
                    guard let self, self.generation == gen else { return }
                    self.dismiss()
                }
            }
        }
        // Auto-dismiss fallback.
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.dismiss()
            }
        }
    }

    func dismiss() {
        dismissTimer?.invalidate(); dismissTimer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Keep the panel fully on the screen that contains `point`.
    private func clampedOrigin(for size: NSSize, near point: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Offset slightly below-right of the cursor.
        var x = point.x + 12
        var y = point.y - size.height - 12
        x = min(max(frame.minX, x), frame.maxX - size.width)
        y = min(max(frame.minY, y), frame.maxY - size.height)
        return NSPoint(x: x, y: y)
    }
}
