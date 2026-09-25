import AppKit

/// One selectable row inside an expanded field's inline list (e.g. one
/// language choice under Compose Source). A real NSButton, like
/// `DirectionChip` and the swap button — picking a row must fold its list
/// back up without dismissing the *enclosing* status-bar menu, and only a
/// custom view consuming its own click (rather than a native NSMenuItem
/// action, which always dismisses the whole menu on selection) achieves that.
final class LanguageRow: NSButton {
    let code: String
    private let checkmark = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var isHovering = false { didSet { applyHoverStyle() } }

    /// Fired on click; the caller applies the choice and folds this list back up.
    var onSelect: (() -> Void)?

    var isChecked = false {
        didSet { checkmark.alphaValue = isChecked ? 1 : 0 }
    }

    init(code: String, title: String) {
        self.code = code
        super.init(frame: NSRect(x: 0, y: 0, width: 292, height: 24))
        isBordered = false
        self.title = ""
        wantsLayer = true
        target = self
        action = #selector(tapped)

        checkmark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        checkmark.contentTintColor = .labelColor
        checkmark.alphaValue = 0

        label.stringValue = title
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail

        for v in [checkmark, label] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            checkmark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            checkmark.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmark.widthAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: checkmark.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func tapped() { onSelect?() }

    private func applyHoverStyle() {
        layer?.backgroundColor = isHovering ? NSColor.selectedContentBackgroundColor.cgColor : nil
        label.textColor = isHovering ? .white : .labelColor
        checkmark.contentTintColor = isHovering ? .white : .labelColor
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

/// A single clickable language name within a direction row ("English" or
/// "繁體中文") — its own hover highlight and its own click target, distinct
/// from its sibling chip and from the swap button, so it's unambiguous which
/// of the two you're about to change. A real NSButton so its click is handled
/// by its own event tracking (like the swap button), never dismissing the
/// enclosing menu.
private final class DirectionChip: NSButton {
    private var isHovering = false { didSet { applyHoverStyle() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .noImage
        font = .systemFont(ofSize: 14, weight: .semibold)
        alignment = .left
        wantsLayer = true
        layer?.cornerRadius = 5
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyHoverStyle() {
        layer?.backgroundColor = isHovering ? NSColor.white.withAlphaComponent(0.14).cgColor : nil
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

/// One direction row in the menu-bar dropdown: a caption ("COMPOSE"), the
/// shortcut, a disclosure chevron, and the direction ("English ⇄ 繁體中文").
/// The two language names are each independently clickable (see
/// `onSourceClicked`/`onTargetClicked`) — clicking one expands *only that
/// field's* list inline, directly below the card, so it's always clear which
/// of the two you're changing. The arrow between them is a separate button
/// that swaps them.
final class MenuCardView: NSView {
    private let captionLabel = NSTextField(labelWithString: "")
    private let keyLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let sourceChip = DirectionChip()
    private let targetChip = DirectionChip()
    private let swapButton = NSButton()

    /// The brand blue used to tint the swap icon at rest (matches the meter bar).
    private static let brandBlue = NSColor(srgbRed: 74/255, green: 125/255, blue: 1.0, alpha: 1)

    /// Fired when the swap button is clicked. The caller updates the underlying
    /// direction preference and then calls `setDirection` again to reflect it —
    /// this view has no opinion on what "swapped" means.
    var onSwap: (() -> Void)?

    /// Whether the swap control can be used right now — set to false while the
    /// source is Auto-detect, since "swap" has no literal meaning when one side
    /// can never become a target.
    var swapEnabled: Bool = true {
        didSet {
            swapButton.isEnabled = swapEnabled
            swapButton.alphaValue = swapEnabled ? 1 : 0.25
        }
    }

    /// Fired on a click on the source language name (left side).
    var onSourceClicked: (() -> Void)?
    /// Fired on a click on the target language name (right side).
    var onTargetClicked: (() -> Void)?

    /// Whether either of this card's fields currently has its list expanded —
    /// just rotates the disclosure chevron; the caller owns the actual list.
    var isExpanded = false {
        didSet { updateChevron(animated: true) }
    }

    /// Sets the two language names either side of the swap arrow. Uses an
    /// attributed title, not plain `.title` — a borderless NSButton's default
    /// text rendering comes out dimmer than a plain label's `.labelColor`
    /// (visibly duller than "Settings…"/"Quit" beside it), so the color is
    /// pinned explicitly here instead.
    func setDirection(left: String, right: String) {
        sourceChip.attributedTitle = Self.chipTitle(left)
        targetChip.attributedTitle = Self.chipTitle(right)
    }

    private static func chipTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
        ])
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
        chevron.wantsLayer = true

        sourceChip.target = self
        sourceChip.action = #selector(sourceTapped)
        // The source side ("English") is short and fixed-ish; never let it
        // truncate or stretch — any squeeze under width pressure should land
        // on the target side, which can be a longer language name.
        sourceChip.setContentHuggingPriority(.required, for: .horizontal)
        sourceChip.setContentCompressionResistancePriority(.required, for: .horizontal)

        targetChip.target = self
        targetChip.action = #selector(targetTapped)
        targetChip.lineBreakMode = .byTruncatingTail

        swapButton.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Swap direction")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        swapButton.isBordered = false
        swapButton.bezelStyle = .inline
        swapButton.imageScaling = .scaleProportionallyDown
        swapButton.contentTintColor = Self.brandBlue
        swapButton.wantsLayer = true
        swapButton.target = self
        swapButton.action = #selector(swapTapped)
        swapButton.toolTip = "Swap direction"

        for v in [captionLabel, keyLabel, sourceChip, swapButton, targetChip, chevron] as [NSView] {
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

            sourceChip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            sourceChip.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 0),
            sourceChip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),

            swapButton.leadingAnchor.constraint(equalTo: sourceChip.trailingAnchor, constant: 3),
            swapButton.centerYAnchor.constraint(equalTo: sourceChip.centerYAnchor),
            swapButton.widthAnchor.constraint(equalToConstant: 20),
            swapButton.heightAnchor.constraint(equalToConstant: 20),

            targetChip.leadingAnchor.constraint(equalTo: swapButton.trailingAnchor, constant: 3),
            targetChip.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            targetChip.centerYAnchor.constraint(equalTo: sourceChip.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func sourceTapped() { onSourceClicked?() }
    @objc private func targetTapped() { onTargetClicked?() }

    @objc private func swapTapped() {
        onSwap?()
        guard let layer = swapButton.layer else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = CGFloat.pi
        spin.duration = 0.28
        spin.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(spin, forKey: "swapRotate")
    }

    /// Rotates the disclosure chevron to point down when expanded.
    private func updateChevron(animated: Bool) {
        guard let layer = chevron.layer else { return }
        let angle: CGFloat = isExpanded ? .pi / 2 : 0
        if animated {
            let rotate = CABasicAnimation(keyPath: "transform.rotation.z")
            rotate.fromValue = layer.presentation()?.value(forKeyPath: "transform.rotation.z") ?? 0
            rotate.toValue = angle
            rotate.duration = 0.18
            rotate.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(rotate, forKey: "chevronRotate")
        }
        layer.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
    }
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
