import Cocoa

/// The icon row, drawn to match the native macOS 27 ⌘Tab switcher: icons side by side, a
/// squircle "well" behind the selected one, its name in the bottom margin.
final class SwitcherView: NSView {

    /// Every dimension is a proportion of the icon size, measured on the native switcher at
    /// 128 pt icons: 6 pt between icons, 24 pt of margin, a well 4 pt inside the icon frame with
    /// a 34 pt continuous radius, the panel's radius concentric with it. The name lives in the
    /// bottom margin, so it never changes the panel's height.
    struct Metrics {
        static let minIconSize: CGFloat = 40

        let icon: CGFloat
        var gap: CGFloat { (icon * 0.047).rounded() }
        /// At least room for the name under the icons, at small sizes.
        var padding: CGFloat { max((icon * 0.19).rounded(), 20) }
        var wellInset: CGFloat { (icon * 0.031).rounded() }
        var wellRadius: CGFloat { (icon - wellInset * 2) * 0.28 }
        /// Concentric with the well: its radius plus the distance between the two edges.
        var cornerRadius: CGFloat { wellRadius + padding }
        var fontSize: CGFloat { max(11, (icon * 0.1).rounded()) }
        /// Baseline band of the name, centred in the bottom margin like the native one.
        var labelCentreY: CGFloat { (padding * 0.69).rounded() }

        func width(count: Int) -> CGFloat {
            padding * 2 + CGFloat(count) * icon + CGFloat(max(count - 1, 0)) * gap
        }
        var height: CGFloat { padding * 2 + icon }
    }

    var items: [SwitcherItem] = [] {
        didSet {
            needsDisplay = true
            rebuildAccessibilityChildren()
        }
    }
    var iconSize: CGFloat = IconSize.large.points {
        didSet {
            needsDisplay = true
            rebuildAccessibilityChildren()
        }
    }
    var showsLabel = true { didSet { needsDisplay = true } }
    var showsBadges = true { didSet { needsDisplay = true } }

    /// Moving the highlight only invalidates the two cells involved and the label band, not
    /// the whole row — every other icon would otherwise be redrawn on each hover.
    var selection: Int = 0 {
        didSet {
            guard selection != oldValue else { return }
            setNeedsDisplay(cellRect(oldValue))
            setNeedsDisplay(cellRect(selection))
            setNeedsDisplay(labelBand)
            announceSelection()
        }
    }

    /// Called when the pointer picks a different app, and when it clicks one.
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    private var cells: [NSAccessibilityElement] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        // "Increase contrast" changes what `Palette` resolves to.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func displayOptionsChanged() { needsDisplay = true }

    /// Dynamic colours are resolved while drawing, so a theme switch just needs a repaint.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Layout

    private var metrics: Metrics { Metrics(icon: iconSize) }

    /// Panel size for `count` apps at `baseIconSize`, plus the icon size that actually fits `maxWidth`.
    static func fittingSize(count: Int, maxWidth: CGFloat,
                            baseIconSize: CGFloat) -> (size: NSSize, iconSize: CGFloat) {
        guard count > 0 else { return (NSSize(width: 200, height: 100), baseIconSize) }
        var icon = baseIconSize
        while Metrics(icon: icon).width(count: count) > maxWidth && icon > Metrics.minIconSize {
            icon -= 4
        }
        let m = Metrics(icon: icon)
        return (NSSize(width: m.width(count: count), height: m.height), icon)
    }

    /// The icon's frame — also the hover and click target.
    private func cellRect(_ index: Int) -> NSRect {
        let m = metrics
        return NSRect(x: m.padding + CGFloat(index) * (m.icon + m.gap), y: m.padding,
                      width: m.icon, height: m.icon)
    }

    /// The bottom margin, where the selected app's name is drawn.
    private var labelBand: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: metrics.padding)
    }

    private func index(at point: NSPoint) -> Int? {
        (0..<items.count).first { cellRect($0).contains(point) }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !items.isEmpty else { return }

        for (i, item) in items.enumerated() {
            let rect = cellRect(i)
            guard rect.intersects(dirtyRect) else { continue }

            if i == selection {
                let m = metrics
                Palette.selection.setFill()
                NSBezierPath(continuousRoundedRect: rect.insetBy(dx: m.wellInset, dy: m.wellInset),
                             cornerRadius: m.wellRadius).fill()
            }

            let iconRect = rect
            if let icon = item.icon {
                // Windowless apps the user chose to keep visible are dimmed, so the
                // distinction survives even when they aren't filtered out. Same for a
                // minimized window in window-cycling mode.
                let alpha: CGFloat = item.isWindowless || item.isMinimizedWindow ? 0.45 : 1
                icon.draw(in: iconRect, from: .zero, operation: .sourceOver,
                          fraction: alpha, respectFlipped: true, hints: nil)
            }
            if showsBadges { drawBadges(for: item, in: iconRect) }
            if let badge = item.notificationBadge { drawNotificationBadge(badge, in: iconRect) }
        }

        if showsLabel, labelBand.intersects(dirtyRect) { drawLabel() }
    }

    /// What the detection knows about an app, on the icon itself, in badges the size of the
    /// notification one: how many windows it has (bottom right, when more than one) and
    /// whether they are all hidden or all minimized (bottom left).
    private func drawBadges(for item: SwitcherItem, in iconRect: NSRect) {
        guard case .app = item.target else { return }
        if item.state.total >= 2 {
            drawBadge(.text("\(item.state.total)"), corner: .bottomRight, in: iconRect,
                      color: Self.badgeColor(AlttyPrefs.windowBadgeColor, fallback: .systemBlue))
        }
        let glyph: String?
        if item.isHidden {
            glyph = "eye.slash.fill"
        } else if item.state.minimized > 0, item.state.total == item.state.minimized {
            glyph = "minus"
        } else {
            glyph = nil
        }
        if let glyph {
            drawBadge(.symbol(glyph), corner: .bottomLeft, in: iconRect,
                      color: Self.badgeColor(AlttyPrefs.stateBadgeColor, fallback: .systemGray))
        }
    }

    private func drawNotificationBadge(_ label: String, in iconRect: NSRect) {
        drawBadge(.text(label), corner: .topRight, in: iconRect,
                  color: Self.badgeColor(AlttyPrefs.notificationBadgeColor, fallback: .systemRed))
    }

    private static func badgeColor(_ stored: String, fallback: NSColor) -> NSColor {
        StoredColor.color(stored) ?? fallback
    }

    private enum BadgeContent { case text(String), symbol(String) }
    private enum BadgeCorner { case topRight, bottomRight, bottomLeft }

    /// Every badge is drawn like the Dock's notification badge on the native switcher —
    /// measured at 128 pt icons: a 50 pt circle (0.39 × icon), set 1.2 % in from the side and
    /// 1.6 % past the top of the icon's frame (mirrored for the bottom corners), ~25 pt label; a
    /// circle up to two characters, a pill beyond. `badgeSize` resizes them all together.
    /// The label is white like the native badges, or black where white would miss the WCAG
    /// minimum on the chosen colour (see `StoredColor.badgeForeground`).
    private func drawBadge(_ content: BadgeContent, corner: BadgeCorner, in iconRect: NSRect, color: NSColor) {
        let scale = AlttyPrefs.badgeSize.scale
        let diameter = (iconSize * 0.39 * scale).rounded()
        let fontSize = (iconSize * 0.195 * scale).rounded()
        var foreground = NSColor.white
        // Resolved in this view's appearance: system colours differ between light and dark.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if case .symbol = content {
                foreground = StoredColor.badgeForeground(on: color, fontSize: fontSize, isSymbol: true)
            } else {
                foreground = StoredColor.badgeForeground(on: color, fontSize: fontSize)
            }
        }

        var labelSize = NSSize.zero
        var draw: (NSRect) -> Void = { _ in }
        switch content {
        case .text(let string):
            let text = NSAttributedString(string: string, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: foreground,
            ])
            labelSize = text.size()
            draw = { rect in text.draw(at: NSPoint(x: rect.midX - labelSize.width / 2,
                                                   y: rect.midY - labelSize.height / 2)) }
        case .symbol(let name):
            let config = NSImage.SymbolConfiguration(pointSize: (fontSize * 0.8).rounded(), weight: .bold)
                .applying(.init(paletteColors: [foreground]))
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return }
            labelSize = image.size
            draw = { rect in image.draw(in: NSRect(x: rect.midX - labelSize.width / 2,
                                                   y: rect.midY - labelSize.height / 2,
                                                   width: labelSize.width, height: labelSize.height)) }
        }

        let width = max(diameter, (labelSize.width + diameter * 0.35).rounded())
        let side = (iconSize * 0.012).rounded()
        let overhang = (iconSize * 0.016).rounded()
        let x: CGFloat = corner == .bottomLeft ? iconRect.minX + side : iconRect.maxX - side - width
        let y: CGFloat = corner == .topRight ? iconRect.maxY + overhang - diameter : iconRect.minY - overhang
        let rect = NSRect(x: x, y: y, width: width, height: diameter)

        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: diameter / 2, yRadius: diameter / 2).fill()
        draw(rect)
    }

    private func drawLabel() {
        guard items.indices.contains(selection) else { return }
        let m = metrics

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail

        // Semibold, straight on the glass, like the native name — but white: on the grey glass
        // black only reaches 4.4:1, under WCAG's 4.5:1 for text this size, and even a 95 %
        // grey falls to 4.25:1; white gives 4.8:1 in light mode, 7.5:1 in dark. The soft shadow
        // holds it when a light window behind brightens the glass.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        let text = NSAttributedString(string: items[selection].name, attributes: [
            .font: NSFont.systemFont(ofSize: m.fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
            .shadow: shadow,
        ])

        // Centred under the selected icon, but never spilling out of the panel's straight part.
        let inset = m.cornerRadius * 0.6
        let ideal = text.size().width + 16
        let maxWidth = bounds.width - inset * 2
        let width = min(ideal, maxWidth)
        let centre = cellRect(selection).midX
        let x = min(max(inset, centre - width / 2), bounds.width - inset - width)
        let height = text.size().height

        text.draw(in: NSRect(x: x, y: m.labelCentreY - height / 2, width: width, height: height))
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)), i != selection else { return }
        onHover?(i)
    }

    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        onClick?(i)
    }

    // MARK: - Accessibility

    /// The row is hand-drawn, so VoiceOver would otherwise see one blank rectangle. Each cell
    /// is exposed as a button, and the selected one is announced as it changes — the panel
    /// never takes keyboard focus, so an announcement is the only way the change is heard.

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "App switcher" }
    override func accessibilityChildren() -> [Any]? { cells }

    private func rebuildAccessibilityChildren() {
        cells = items.enumerated().map { i, item in
            let e = NSAccessibilityElement()
            e.setAccessibilityRole(.button)
            e.setAccessibilityLabel(item.name)
            e.setAccessibilityParent(self)
            e.setAccessibilityFrameInParentSpace(cellRect(i))
            return e
        }
    }

    private func announceSelection() {
        guard NSWorkspace.shared.isVoiceOverEnabled, items.indices.contains(selection) else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: items[selection].name,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    func announceCurrentSelection() { announceSelection() }
}
