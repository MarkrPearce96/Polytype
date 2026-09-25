import AppKit

/// The single floating panel the status item shows — replaces the native
/// `NSMenu` dropdown entirely, so Settings can swap in as the panel's content
/// in place, rather than needing a second window that can only ever guess at
/// where the first one was. A custom borderless window instead of `NSMenu`
/// means dismiss-on-click-outside and Escape-to-close have to be
/// reimplemented (see `windowDidResignKey` and `PanelHostingView`), but menu
/// positioning is fully within our control instead of AppKit's own opaque
/// placement logic.
@MainActor
final class DropdownPanel: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let shellView: GradientPanelView
    /// Where the panel's top-right corner should sit — recomputed each time
    /// it's shown (the status item can move, e.g. other menu-bar items
    /// changing), then held fixed while visible so the panel grows/shrinks
    /// from that same anchor rather than drifting as content changes size.
    private var anchorTopRight: NSPoint = .zero

    /// Called right before the panel becomes visible (so callers can refresh
    /// content first) and right after it's dismissed for any reason —
    /// clicking away, Escape, or an explicit `hide()` — the equivalents of
    /// `NSMenuDelegate`'s `menuWillOpen`/`menuDidClose`.
    var onWillShow: (() -> Void)?
    var onDidHide: (() -> Void)?

    override init() {
        shellView = GradientPanelView()
        window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false   // the shell draws its own shadow, shaped to its rounded corners
        window.level = .popUpMenu
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)   // panel is always dark, regardless of system setting
        window.contentView = shellView
        window.delegate = self
        shellView.onEscape = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { window.isVisible }

    func toggle(near button: NSStatusBarButton?) {
        if window.isVisible { hide() } else { show(near: button) }
    }

    func show(near button: NSStatusBarButton?) {
        onWillShow?()
        computeAnchor(near: button)
        applyFrame(forContentSize: shellView.fittingSize)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard window.isVisible else { return }
        window.orderOut(nil)
        onDidHide?()
    }

    /// Swaps the panel's whole content (menu ↔ settings).
    func setContent(_ view: NSView) {
        shellView.setContent(view)
        if window.isVisible { applyFrame(forContentSize: shellView.fittingSize) }
    }

    /// Call after content inside the *current* view changes size (a field's
    /// inline list expands or collapses) so the window resizes from its
    /// fixed top-right anchor instead of the content just overflowing it.
    func invalidateSize() {
        guard window.isVisible else { return }
        applyFrame(forContentSize: shellView.fittingSize)
    }

    private func computeAnchor(near button: NSStatusBarButton?) {
        guard let button, let buttonWindow = button.window else {
            let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            anchorTopRight = NSPoint(x: screen.midX + 150, y: screen.maxY - 30)
            return
        }
        let buttonFrameOnScreen = buttonWindow.convertToScreen(button.frame)
        anchorTopRight = NSPoint(x: buttonFrameOnScreen.maxX, y: buttonFrameOnScreen.minY - 4)
    }

    private func applyFrame(forContentSize size: NSSize) {
        var origin = NSPoint(x: anchorTopRight.x - size.width, y: anchorTopRight.y - size.height)
        if let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = max(screenFrame.minX + 8, min(origin.x, screenFrame.maxX - size.width - 8))
            origin.y = max(screenFrame.minY + 8, origin.y)
        }
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }

    /// Dismiss the instant something else becomes key — clicking anywhere
    /// outside the panel, exactly like a menu would close.
    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { hide() }
    }
}

/// The panel's outer shell: the dark gradient, rounded corners, and its own
/// shadow (rather than the window's, which can't easily match a rounded,
/// non-rectangular shape). Hosts whichever content view is currently active.
final class GradientPanelView: NSView {
    private let fillLayer = CAGradientLayer()
    private var contentView: NSView?
    var onEscape: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Shadow lives on this view's own root layer (unclipped) so it isn't
        // cut off by the rounded-corner mask below, which is on a sublayer.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 26
        layer?.shadowOffset = CGSize(width: 0, height: -10)

        fillLayer.colors = [
            NSColor(srgbRed: 34/255, green: 49/255, blue: 66/255, alpha: 1).cgColor,
            NSColor(srgbRed: 27/255, green: 39/255, blue: 51/255, alpha: 1).cgColor,
        ]
        fillLayer.startPoint = CGPoint(x: 0.5, y: 1)
        fillLayer.endPoint = CGPoint(x: 0.5, y: 0)
        fillLayer.cornerRadius = 12
        fillLayer.masksToBounds = true
        fillLayer.borderWidth = 1
        fillLayer.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.addSublayer(fillLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        fillLayer.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
    }

    /// Deliberately NOT Auto Layout constraints pinning the content to this
    /// view's edges: this view's own size is computed *from* the content's
    /// natural size (see `fittingSize`/`DropdownPanel.applyFrame`), so
    /// constraining the content to fill this view back would be circular —
    /// on first show, before the window has ever been sized, this view's
    /// bounds start at zero, the constraints would immediately force the
    /// content down to zero to match, and the size computed from it would
    /// then also be zero. A plain frame, set once from the content's own
    /// natural size, breaks that cycle.
    func setContent(_ view: NSView) {
        contentView?.removeFromSuperview()
        contentView = view
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = NSRect(origin: .zero, size: naturalSize(of: view))
        addSubview(view)
    }

    private func naturalSize(of view: NSView) -> NSSize {
        if let sized = view as? ExplicitlySized { return sized.explicitSize }
        return view.fittingSize
    }

    override var fittingSize: NSSize {
        guard let contentView else { return NSSize(width: 300, height: 40) }
        return naturalSize(of: contentView)
    }

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }   // Escape
        super.keyDown(with: event)
    }
}

/// Frame-based views (like `VerticalRowStack`) don't reliably report a
/// correct `fittingSize` without real Auto Layout constraints driving it —
/// this lets them report their true size explicitly instead.
protocol ExplicitlySized: NSView {
    var explicitSize: NSSize { get }
}

/// A simple vertically-stacked container that positions each row by an
/// explicit frame — not Auto Layout's fitting-size machinery, which doesn't
/// mix well with the frame-based custom views already used throughout this
/// menu (`MenuCardView`, `LanguageRow`, the status row). Rows keep whatever
/// height they were constructed with; only their y-position and width change
/// here. `rows[0]` renders at the top, matching reading order, even though
/// AppKit's coordinate origin is bottom-left.
final class VerticalRowStack: NSView, ExplicitlySized {
    private(set) var rows: [NSView] = []
    var rowWidth: CGFloat = 300 { didSet { relayout() } }

    var explicitSize: NSSize { NSSize(width: rowWidth, height: frame.height) }

    func setRows(_ newRows: [NSView]) {
        for row in rows { row.removeFromSuperview() }
        rows = newRows
        for row in rows { addSubview(row) }
        relayout()
    }

    func insertRows(_ newRows: [NSView], at index: Int) {
        for (offset, row) in newRows.enumerated() {
            rows.insert(row, at: index + offset)
            addSubview(row)
        }
        relayout()
    }

    func removeRows(_ rowsToRemove: [NSView]) {
        for row in rowsToRemove {
            row.removeFromSuperview()
            rows.removeAll { $0 === row }
        }
        relayout()
    }

    private func relayout() {
        var y: CGFloat = 0
        for row in rows.reversed() {
            let h = row.frame.height
            row.frame = NSRect(x: 0, y: y, width: rowWidth, height: h)
            y += h
        }
        frame = NSRect(x: frame.origin.x, y: frame.origin.y, width: rowWidth, height: y)
    }
}

/// A thin horizontal divider, matching a native menu's separator — a fixed-
/// height row (for `VerticalRowStack`'s frame-based layout) containing a 1pt
/// line inset from both edges.
final class SeparatorRow: NSView {
    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 9))
        let line = NSView(frame: NSRect(x: 10, y: 4, width: width - 20, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        line.autoresizingMask = [.width]
        addSubview(line)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A footer row like "Settings…" or "Quit" — a full-width clickable row with
/// a title and a trailing key-equivalent hint, styled to match `LanguageRow`'s
/// hover behavior. A real NSButton (not a native menu-item action) so this
/// menu's rules apply here too: clicking it is handled by the button's own
/// event tracking, same reasoning as everywhere else in this panel.
final class FooterRow: NSButton {
    private let titleField = NSTextField(labelWithString: "")
    private let hintField = NSTextField(labelWithString: "")
    private var isHovering = false { didSet { applyHoverStyle() } }

    init(title: String, hint: String, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 27))
        isBordered = false
        self.title = ""
        wantsLayer = true
        layer?.cornerRadius = 6

        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 13)
        titleField.textColor = .white

        hintField.stringValue = hint
        hintField.font = .systemFont(ofSize: 11)
        hintField.textColor = NSColor.white.withAlphaComponent(0.4)

        for v in [titleField, hintField] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            hintField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            hintField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyHoverStyle() {
        layer?.backgroundColor = isHovering ? NSColor.white.withAlphaComponent(0.08).cgColor : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
}
