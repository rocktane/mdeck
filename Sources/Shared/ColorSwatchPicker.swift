import Cocoa

/// A colour stored in preferences: one of the named system colours (which follow light/dark
/// and "Increase contrast"), or any colour picked on the wheel, kept as sRGB hex.
enum StoredColor {
    static let presets: [(id: String, name: String, color: NSColor)] = [
        ("red", "Red", .systemRed),
        ("orange", "Orange", .systemOrange),
        ("yellow", "Yellow", .systemYellow),
        ("green", "Green", .systemGreen),
        ("teal", "Teal", .systemTeal),
        ("blue", "Blue", .systemBlue),
        ("purple", "Purple", .systemPurple),
        ("pink", "Pink", .systemPink),
        ("graphite", "Graphite", .systemGray),
    ]

    /// `"blue"` → system blue; `"#RRGGBB"` → that sRGB colour.
    static func color(_ value: String) -> NSColor? {
        if let preset = presets.first(where: { $0.id == value }) { return preset.color }
        guard value.hasPrefix("#"), value.count == 7, let rgb = UInt32(value.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    static func isPreset(_ value: String) -> Bool { presets.contains { $0.id == value } }

    /// WCAG contrast ratio between two colours (1…21), resolved in the current appearance.
    static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            guard let c = color.usingColorSpace(.sRGB) else { return 0 }
            func lin(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        }
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The text colour for a badge of this colour: white, like the native badges, unless white
    /// misses the WCAG AA minimum for that text — 3:1 for large text (18 pt and up, or 14 pt
    /// bold) and for symbols, which count as graphics; 4.5:1 below — in which case black.
    static func badgeForeground(on background: NSColor, fontSize: CGFloat, bold: Bool = false,
                                isSymbol: Bool = false) -> NSColor {
        let large = isSymbol || fontSize >= 18 || (bold && fontSize >= 14)
        let required: CGFloat = large ? 3 : 4.5
        if contrast(.white, background) >= required { return .white }
        // Black whenever it does better — it always does on the colours white failed on.
        return contrast(.black, background) > contrast(.white, background) ? .black : .white
    }
}

/// A row of colour swatches — the presets, then a rainbow one that opens the system colour
/// panel on its wheel for any other colour. The chosen swatch carries a ring. Each swatch is a
/// real button: keyboard- and VoiceOver-reachable, with its name as tooltip.
final class ColorSwatchPicker: NSView, EnablableView {
    private static let size: CGFloat = 18
    private static let spacing: CGFloat = 6

    var value: String { didSet { refresh() } }

    /// Greyed out like a disabled control: every swatch inactive and faded.
    var isEnabled = true {
        didSet {
            buttons.forEach { $0.isEnabled = isEnabled }
            alphaValue = isEnabled ? 1 : 0.35
            if !isEnabled, NSColorPanel.shared.isVisible { NSColorPanel.shared.setTarget(nil) }
        }
    }
    private let onChange: (String) -> Void
    private var buttons: [NSButton] = []

    init(value: String, onChange: @escaping (String) -> Void) {
        self.value = value
        self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        var previous: NSButton?
        for i in 0...StoredColor.presets.count {
            let button = NSButton(title: "", target: self, action: #selector(pick(_:)))
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.tag = i
            button.translatesAutoresizingMaskIntoConstraints = false
            let name = i < StoredColor.presets.count ? StoredColor.presets[i].name : "Other colour…"
            button.toolTip = name
            button.setAccessibilityLabel(name)
            addSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: Self.size + 4),
                button.heightAnchor.constraint(equalToConstant: Self.size + 4),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                previous == nil
                    ? button.leadingAnchor.constraint(equalTo: leadingAnchor)
                    : button.leadingAnchor.constraint(equalTo: previous!.trailingAnchor, constant: Self.spacing - 4),
            ])
            buttons.append(button)
            previous = button
        }
        NSLayoutConstraint.activate([
            previous!.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: Self.size + 4),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        let custom = !StoredColor.isPreset(value)
        for (i, button) in buttons.enumerated() {
            if i < StoredColor.presets.count {
                let preset = StoredColor.presets[i]
                button.image = Self.swatch(fill: preset.color, rainbow: false, selected: value == preset.id)
                button.setAccessibilityValue(value == preset.id ? "selected" : nil)
            } else {
                button.image = Self.swatch(fill: custom ? StoredColor.color(value) : nil, rainbow: true, selected: custom)
                button.setAccessibilityValue(custom ? "selected, \(value)" : nil)
            }
        }
    }

    @objc private func pick(_ sender: NSButton) {
        if sender.tag < StoredColor.presets.count {
            set(StoredColor.presets[sender.tag].id)
            return
        }
        // Any colour: the system panel on its wheel, live-updating while it stays open.
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.mode = .wheel
        panel.isContinuous = true
        panel.color = StoredColor.color(value) ?? .systemRed
        panel.setTarget(self)
        panel.setAction(#selector(panelChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func panelChanged(_ sender: NSColorPanel) {
        set(StoredColor.hex(sender.color))
    }

    private func set(_ newValue: String) {
        guard newValue != value else { return }
        value = newValue
        onChange(newValue)
    }

    /// A filled circle — or, for the "other colour" swatch, a hue ring around the custom colour —
    /// with a ring in the accent colour when selected.
    private static func swatch(fill: NSColor?, rainbow: Bool, selected: Bool) -> NSImage {
        let outer = size + 4
        return NSImage(size: NSSize(width: outer, height: outer), flipped: false) { rect in
            let circle = rect.insetBy(dx: 2, dy: 2)
            if rainbow {
                let steps = 36
                let centre = NSPoint(x: circle.midX, y: circle.midY)
                for i in 0..<steps {
                    let path = NSBezierPath()
                    path.move(to: centre)
                    path.appendArc(withCenter: centre, radius: circle.width / 2,
                                   startAngle: CGFloat(i) * 360 / CGFloat(steps),
                                   endAngle: CGFloat(i + 1) * 360 / CGFloat(steps) + 0.5)
                    path.close()
                    NSColor(hue: CGFloat(i) / CGFloat(steps), saturation: 0.85, brightness: 1, alpha: 1).setFill()
                    path.fill()
                }
                if let fill {
                    fill.setFill()
                    NSBezierPath(ovalIn: circle.insetBy(dx: 4, dy: 4)).fill()
                }
            } else if let fill {
                fill.setFill()
                NSBezierPath(ovalIn: circle).fill()
            }
            NSColor.black.withAlphaComponent(0.15).setStroke()
            let edge = NSBezierPath(ovalIn: circle.insetBy(dx: 0.25, dy: 0.25))
            edge.lineWidth = 0.5
            edge.stroke()
            if selected {
                NSColor.controlAccentColor.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            return true
        }
    }
}
