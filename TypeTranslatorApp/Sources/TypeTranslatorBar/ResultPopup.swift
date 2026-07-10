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

    func show(_ text: String, at screenPoint: NSPoint) {
        dismiss()

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

        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.contentView = container
        panel.orderFrontRegardless()
        self.panel = panel

        // Dismiss on a click anywhere.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        // Dismiss on Esc (global monitor, since the panel is non-activating and
        // never becomes key). Requires Accessibility, which the app already has.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { Task { @MainActor in self?.dismiss() } }   // 53 = Escape
        }
        // Auto-dismiss fallback.
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
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
