import AppKit

/// One direction row in the menu-bar dropdown: a caption ("COMPOSE"), the
/// shortcut, a submenu chevron, and the direction ("English → 繁體中文").
///
/// A custom view inside an NSMenuItem does NOT get the system highlight, so this
/// view draws its own from `enclosingMenuItem?.isHighlighted`.
final class MenuCardView: NSView {
    private let captionLabel = NSTextField(labelWithString: "")
    private let keyLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let directionLabel = NSTextField(labelWithString: "")
    private var wasHighlighted = false

    /// The "English → 繁體中文" line.
    var direction: String {
        get { directionLabel.stringValue }
        set { directionLabel.stringValue = newValue }
    }

    /// The displayed shortcut, e.g. "⌥⌘T".
    var shortcut: String {
        get { keyLabel.stringValue }
        set { keyLabel.stringValue = newValue }
    }

    init(caption: String, shortcut: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 292, height: 48))

        captionLabel.stringValue = caption.uppercased()
        captionLabel.font = .systemFont(ofSize: 10, weight: .bold)
        captionLabel.textColor = .tertiaryLabelColor

        keyLabel.stringValue = shortcut
        keyLabel.font = .systemFont(ofSize: 11.5)
        keyLabel.textColor = .secondaryLabelColor

        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        chevron.contentTintColor = .secondaryLabelColor

        directionLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        directionLabel.textColor = .labelColor
        directionLabel.lineBreakMode = .byTruncatingTail

        for v in [captionLabel, keyLabel, directionLabel, chevron] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            captionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: captionLabel.centerYAnchor),
            keyLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -6),
            keyLabel.centerYAnchor.constraint(equalTo: captionLabel.centerYAnchor),

            directionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            directionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            directionLabel.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 2),
            directionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Sync label colors before drawing, so `draw(_:)` stays a pure fill.
    override func viewWillDraw() {
        let hi = enclosingMenuItem?.isHighlighted ?? false
        if hi != wasHighlighted {
            wasHighlighted = hi
            captionLabel.textColor = hi ? NSColor.white.withAlphaComponent(0.8) : .tertiaryLabelColor
            keyLabel.textColor = hi ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
            chevron.contentTintColor = hi ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
            directionLabel.textColor = hi ? .white : .labelColor
        }
        super.viewWillDraw()
    }

    override func draw(_ dirtyRect: NSRect) {
        if enclosingMenuItem?.isHighlighted == true {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }

    // A tracking area makes the highlight redraw reliably as the pointer moves.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { needsDisplay = true }
    override func mouseExited(with event: NSEvent) { needsDisplay = true }
}

/// A thin rounded meter: a track plus a fill whose width is `fraction`. Normally
/// the brand blue→violet gradient; flat gray once the free tier is spent.
final class MenuMeterBar: NSView {
    private let trackLayer = CALayer()
    private let fillLayer = CAGradientLayer()

    var fraction: CGFloat = 0 { didSet { needsLayout = true } }
    var isSpent = false { didSet { needsLayout = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        fillLayer.startPoint = CGPoint(x: 0, y: 0.5)
        fillLayer.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 4) }

    // CALayer colors don't follow appearance changes on their own.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let h = bounds.height
            trackLayer.frame = bounds
            trackLayer.cornerRadius = h / 2
            trackLayer.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.25).cgColor

            let w = max(0, min(1, fraction)) * bounds.width
            fillLayer.frame = CGRect(x: 0, y: 0, width: w, height: h)
            fillLayer.cornerRadius = h / 2
            if isSpent {
                let g = NSColor.systemGray.cgColor
                fillLayer.colors = [g, g]
            } else {
                fillLayer.colors = [
                    NSColor(srgbRed: 74/255, green: 125/255, blue: 1.0, alpha: 1).cgColor,
                    NSColor(srgbRed: 150/255, green: 88/255, blue: 246/255, alpha: 1).cgColor,
                ]
            }
        }
        CATransaction.commit()
    }
}
