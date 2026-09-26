import AppKit

/// The single floating panel the status item shows — replaces the native
/// `NSMenu` dropdown entirely, so Settings can swap in as the panel's content
/// in place, rather than needing a second window that can only ever guess at
/// where the first one was. A custom borderless window instead of `NSMenu`
/// means dismiss-on-click-outside and Escape-to-close have to be
/// reimplemented (see `windowDidResignKey` and `GradientPanelView.onEscape`), but menu
/// positioning is fully within our control instead of AppKit's own opaque
/// placement logic.
/// A plain borderless `NSWindow` never becomes key by default (Apple grants
/// that only to windows with a title bar or resize bar, or to `NSPanel`) —
/// without this override, `makeKeyAndOrderFront` would show the panel but
/// keyboard input inside it (typing into Settings' fields, recording a
/// hotkey, Escape-to-close) would silently go nowhere.
private final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class DropdownPanel: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let shellView: GradientPanelView
    /// Where the panel's top-right corner should sit — recomputed each time
    /// it's shown (the status item can move, e.g. other menu-bar items
    /// changing), then held fixed while visible so the panel grows/shrinks
    /// from that same anchor rather than drifting as content changes size.
    private var anchorTopRight: NSPoint = .zero
    /// Catches a click elsewhere *within this app* but outside the panel
    /// (e.g. Setup Assistant's window) — `windowDidResignKey` covers clicks
    /// in another app or on the desktop (see below), but never fires for a
    /// click on a *different window of this same app*, since this app stays
    /// the active app throughout.
    ///
    /// A *global* click monitor used to cover the "another app" case too, but
    /// traced empirically it's unreliable on this system: the same physical
    /// click on the status item was observed being redelivered to it anywhere
    /// from ~150ms to several *seconds* later, sometimes arriving after a
    /// subsequent open and hiding a panel that click had nothing to do with.
    /// `windowDidResignKey` needs no such workaround now that the window can
    /// actually become key at all (see `KeyableBorderlessWindow`) — it's a
    /// first-party AppKit notification, not a hand-rolled polling mechanism,
    /// so it doesn't share the global monitor's delivery quirks.
    private var localClickMonitor: Any?
    /// Set for a brief window around a status-button click. That click's own
    /// mouseDown can cause `windowDidResignKey` to fire *before* its mouseUp
    /// finally runs `toggle(near:)` below (the button's action only fires on
    /// mouseUp) — left unhandled, that resignKey's own `hide()` runs first,
    /// so `toggle(near:)` then sees an already-hidden window and reopens it:
    /// a click meant to close instead does nothing (or flashes). This isn't
    /// the same problem the old, wider suppression window caused (blocking
    /// genuinely later, unrelated dismiss-clicks) — it only needs to bridge
    /// one click's own mouseDown-to-mouseUp gap, not linger afterward, so the
    /// window here is short and doesn't touch the local monitor's identity
    /// check at all (that one needs no timing to begin with).
    private var suppressResignKey = false

    /// Called right before the panel becomes visible (so callers can refresh
    /// content first) and right after it's dismissed for any reason —
    /// clicking away, Escape, or an explicit `hide()` — the equivalents of
    /// `NSMenuDelegate`'s `menuWillOpen`/`menuDidClose`.
    var onWillShow: (() -> Void)?
    var onDidHide: (() -> Void)?

    override init() {
        shellView = GradientPanelView()
        window = KeyableBorderlessWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
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
        suppressResignKey = true
        if window.isVisible { hide() } else { show(near: button) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.suppressResignKey = false
        }
    }

    func show(near button: NSStatusBarButton?) {
        onWillShow?()
        computeAnchor(near: button)
        applyFrame(forContentSize: shellView.fittingSize)
        // Only activating when not already active measurably reduces (but,
        // traced empirically, doesn't fully eliminate) a rare, still-
        // unexplained spontaneous windowDidResignKey a few hundred ms to a
        // couple of seconds after showing, with no click involved — it can
        // still happen even on a cycle where this line doesn't run at all,
        // so it isn't the sole cause, just a contributing one. Worth
        // revisiting if a real root cause turns up.
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        startClickOutsideMonitors(statusButtonWindow: button?.window)
    }

    func hide() {
        guard window.isVisible else { return }
        stopClickOutsideMonitors()
        window.orderOut(nil)
        onDidHide?()
    }

    /// - Parameter statusButtonWindow: excluded by identity, not timing — a
    ///   status-button click's mouseDown can be delivered to this monitor
    ///   anywhere from immediately up to (rarely) a couple of seconds later
    ///   (traced empirically), well past any reasonable timing-based
    ///   suppression window. It's never actually "outside" regardless of when
    ///   it arrives, since `toggle(near:)` already decides open vs. closed for
    ///   that click on its own.
    private func startClickOutsideMonitors(statusButtonWindow: NSWindow?) {
        stopClickOutsideMonitors()
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window !== self.window, event.window !== statusButtonWindow else { return event }
            self.hide()
            return event   // never swallow the click — just observe it
        }
    }

    private func stopClickOutsideMonitors() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        localClickMonitor = nil
    }

    /// Swaps the panel's whole content (menu ↔ settings) with a quick
    /// crossfade and an animated resize — this is a deliberate transition the
    /// user chooses (clicking "Settings…" or the back arrow), unlike opening
    /// the panel or expanding a field's list, so it's worth the extra beat
    /// rather than snapping instantly.
    func setContent(_ view: NSView) {
        let animate = window.isVisible
        shellView.setContent(view, animated: animate)
        if animate { applyFrame(forContentSize: shellView.fittingSize, animated: true) }
    }

    /// Call after content inside the *current* view changes size (a field's
    /// inline list expands or collapses) so the window resizes from its
    /// fixed top-right anchor instead of the content just overflowing it.
    func invalidateSize(animated: Bool = false) {
        guard window.isVisible else { return }
        applyFrame(forContentSize: shellView.fittingSize, animated: animated)
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

    private func applyFrame(forContentSize size: NSSize, animated: Bool = false) {
        var origin = NSPoint(x: anchorTopRight.x - size.width, y: anchorTopRight.y - size.height)
        if let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = max(screenFrame.minX + 8, min(origin.x, screenFrame.maxX - size.width - 8))
            origin.y = max(screenFrame.minY + 8, origin.y)
        }
        let newFrame = NSRect(origin: origin, size: size)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(newFrame, display: true)
            }
        } else {
            window.setFrame(newFrame, display: true, animate: false)
        }
    }

    /// Dismiss the instant something else becomes key — clicking anywhere
    /// outside the panel, exactly like a menu would close. A status-button
    /// click that closes the panel also triggers this (as a natural side
    /// effect of `hide()`'s own `orderOut`), but that's already harmless:
    /// `hide()` no-ops once the window is no longer visible.
    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !suppressResignKey else { return }
            hide()
        }
    }
}

/// The panel's outer shell: the dark gradient, rounded corners, and its own
/// shadow (rather than the window's, which can't easily match a rounded,
/// non-rectangular shape). Hosts whichever content view is currently active.
final class GradientPanelView: NSView {
    private let fillLayer = CAGradientLayer()
    /// Holds the fill + content, clipped to this view's own bounds. Kept
    /// separate from the root layer (which only casts the shadow) so it can
    /// mask content to bounds without also cutting the shadow off — and,
    /// critically, so content is only ever visible within the panel's
    /// *current* on-screen size. Content views (a `VerticalRowStack`, an
    /// `NSHostingView`) are resized to their new target size as soon as a
    /// change starts, ahead of the window's own resize animation catching up
    /// — without this clip, that meant a newly-expanded field's rows briefly
    /// existed at full size before the window had animated open to reveal
    /// them, reading as an initial "jump" before the smooth part took over.
    /// Clipping to `clipView`'s bounds — which `layout()` keeps in sync with
    /// this view's actual bounds on every frame of the window's resize
    /// animation, not just at the start and end — means the extra content
    /// stays hidden until the window has genuinely grown enough to show it.
    /// Flipped so the content it holds (also positioned at local origin
    /// (0,0)) anchors to its *top* regardless of its current height — the
    /// same reasoning as `VerticalRowStack` being flipped: growth should
    /// come from the bottom, revealed as the panel grows, not require the
    /// top content to shift to compensate for a size that hasn't caught up
    /// with the animation yet.
    private let clipView = FlippedContainerView()
    private var contentView: NSView?
    var onEscape: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Shadow lives on this view's own root layer (unclipped) so it isn't
        // cut off by the rounded-corner mask below.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 26
        layer?.shadowOffset = CGSize(width: 0, height: -10)

        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = 12
        clipView.layer?.masksToBounds = true
        clipView.layer?.borderWidth = 1
        clipView.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        addSubview(clipView)

        fillLayer.colors = [
            NSColor(srgbRed: 34/255, green: 49/255, blue: 66/255, alpha: 1).cgColor,
            NSColor(srgbRed: 27/255, green: 39/255, blue: 51/255, alpha: 1).cgColor,
        ]
        fillLayer.startPoint = CGPoint(x: 0.5, y: 1)
        fillLayer.endPoint = CGPoint(x: 0.5, y: 0)
        clipView.layer?.addSublayer(fillLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        clipView.frame = bounds
        fillLayer.frame = clipView.bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
    }

    /// Deliberately NOT Auto Layout constraints pinning the content to
    /// `clipView`'s edges: this view's own size is computed *from* the
    /// content's natural size (see `fittingSize`/`DropdownPanel.applyFrame`),
    /// so constraining the content to fill it back would be circular — on
    /// first show, before the window has ever been sized, bounds start at
    /// zero, the constraints would immediately force the content down to
    /// zero to match, and the size computed from it would then also be zero.
    /// A plain frame, set once from the content's own natural size, breaks
    /// that cycle; `clipView`'s masking (above) is what keeps oversized
    /// content from being visible before the window grows to fit it.
    func setContent(_ view: NSView, animated: Bool = false) {
        let oldView = contentView
        contentView = view
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = NSRect(origin: .zero, size: naturalSize(of: view))

        guard animated, let oldView else {
            oldView?.removeFromSuperview()
            clipView.addSubview(view)
            return
        }

        view.alphaValue = 0
        clipView.addSubview(view)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            oldView.animator().alphaValue = 0
            view.animator().alphaValue = 1
        }, completionHandler: {
            oldView.removeFromSuperview()
        })
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
/// here.
///
/// Flipped (`isFlipped == true`) so `rows[0]` sits at local y=0 — genuinely
/// the top, not "the bottom, in a coordinate system some outer math has to
/// cancel out." That matters here specifically: the panel grows *downward
/// from a fixed top*, so a row's position must never depend on the total
/// stack height, or every row above wherever something was inserted would
/// need to shift to compensate — relying on that shift landing in perfect
/// lockstep with the window's own (separate) resize animation. In a flipped,
/// top-anchored layout, a row's position only depends on the rows *before*
/// it, so inserting or removing rows anywhere never moves anything above the
/// change point at all — nothing to keep in sync, because nothing there
/// needs to move.
final class VerticalRowStack: NSView, ExplicitlySized {
    override var isFlipped: Bool { true }
    private(set) var rows: [NSView] = []
    var rowWidth: CGFloat = 300 { didSet { relayout(animated: false) } }

    var explicitSize: NSSize { NSSize(width: rowWidth, height: frame.height) }

    func setRows(_ newRows: [NSView]) {
        for row in rows { row.removeFromSuperview() }
        rows = newRows
        for row in rows { addSubview(row) }
        relayout(animated: false)
    }

    /// Inserts and fades/slides the new rows in, while every row already
    /// below the insertion point animates down to make room.
    func insertRows(_ newRows: [NSView], at index: Int, animated: Bool = false) {
        for (offset, row) in newRows.enumerated() {
            rows.insert(row, at: index + offset)
            row.alphaValue = animated ? 0 : 1
            addSubview(row)
        }
        relayout(animated: animated)
        guard animated else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = Self.animationTiming
            for row in newRows { row.animator().alphaValue = 1 }
        }
    }

    /// Removes the rows from the layout immediately (so a row it's animating
    /// out never overlaps a subsequent expand elsewhere), but keeps their
    /// views on screen a beat to fade out while everything else slides up to
    /// close the gap.
    func removeRows(_ rowsToRemove: [NSView], animated: Bool = false) {
        rows.removeAll { row in rowsToRemove.contains { $0 === row } }
        guard animated else {
            for row in rowsToRemove { row.removeFromSuperview() }
            relayout(animated: false)
            return
        }
        relayout(animated: true)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.animationDuration
            context.timingFunction = Self.animationTiming
            for row in rowsToRemove { row.animator().alphaValue = 0 }
        }, completionHandler: {
            for row in rowsToRemove { row.removeFromSuperview() }
        })
    }

    private static let animationDuration = 0.18
    private static let animationTiming = CAMediaTimingFunction(name: .easeInEaseOut)

    private func relayout(animated: Bool) {
        var y: CGFloat = 0
        var targets: [(row: NSView, rect: NSRect)] = []
        for row in rows {
            let h = row.frame.height
            targets.append((row, NSRect(x: 0, y: y, width: rowWidth, height: h)))
            y += h
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.animationDuration
                context.timingFunction = Self.animationTiming
                for (row, rect) in targets { row.animator().frame = rect }
            }
        } else {
            for (row, rect) in targets { row.frame = rect }
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

/// A plain container whose local origin (0,0) is its top-left instead of
/// AppKit's default bottom-left — see `GradientPanelView.clipView` and
/// `VerticalRowStack` for why that's what a top-anchored, growing-downward
/// panel actually needs.
final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}
