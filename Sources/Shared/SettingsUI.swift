import Cocoa

/// Section header: a small bold caption above a group of rows.
func sectionHeader(_ title: String) -> NSView {
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = .secondaryLabelColor
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
}

/// `NSSwitch` that carries its own closure, so callers don't need a target object per row.
final class ActionSwitch: NSSwitch {
    var onChange: ((Bool) -> Void)?

    convenience init(isOn: Bool, onChange: @escaping (Bool) -> Void) {
        self.init(frame: .zero)
        state = isOn ? .on : .off
        self.onChange = onChange
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        target = self
        action = #selector(changed)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() { onChange?(state == .on) }
}

/// A composite control that is not an `NSControl` but can still be greyed out by a
/// `SettingsRow` (the colour swatches).
protocol EnablableView: NSView {
    var isEnabled: Bool { get set }
}

/// One settings row: label pinned to the left edge, control pinned to the right edge, the
/// label free to take everything in between.
///
/// Not an `NSGridView`: a grid sizes its label column to the longest label and centres the
/// whole thing, which leaves the controls floating in the middle of the window.
final class SettingsRow: NSView {
    /// Where the ⓘ goes when the row can be greyed out: right after the text, or — for a row
    /// with no text — just left of the control. Never after the control, so the column of
    /// switches and buttons stays aligned.
    enum InfoPlacement { case afterLabel, beforeControl }

    private let control: NSView
    private var info: NSButton?
    private var disabledReason: (() -> String?)?

    convenience init(_ title: String, _ control: NSView, indented: Bool = false, help: String? = nil,
                     disabledReason: (() -> String?)? = nil) {
        let label = NSTextField(labelWithString: title)
        // Only for labels we make: applying it to any leading view would silently defeat a
        // caller's wrapping label, which would then squeeze onto one line and truncate.
        label.lineBreakMode = .byTruncatingTail
        self.init(label, control, indented: indented, help: help, disabledReason: disabledReason)
    }

    init(_ label: NSView, _ control: NSView, indented: Bool = false, help: String? = nil,
         disabledReason: (() -> String?)? = nil, infoPlacement: InfoPlacement = .afterLabel) {
        self.control = control
        self.disabledReason = disabledReason
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Vertically too, otherwise the solver happily squashes a 32 pt push button down to
        // the row's 26 pt minimum instead of growing the row.
        control.setContentHuggingPriority(.required, for: .vertical)
        control.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .vertical)

        // On the row as well as its parts: a disabled `NSSwitch` swallows tracking, so the
        // tooltip has to come from something that is still hoverable — which is how the user
        // finds out *why* it is disabled.
        toolTip = help
        label.toolTip = help
        control.toolTip = help

        addSubview(label)
        addSubview(control)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 26),
            // Without these the row keeps its 26 pt minimum and a taller control — a push
            // button is ~32 pt — spills past the row, and past the window with it.
            heightAnchor.constraint(greaterThanOrEqualTo: control.heightAnchor),
            heightAnchor.constraint(greaterThanOrEqualTo: label.heightAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indented ? 20 : 0),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // A disabled control cannot be hovered for its tooltip, so a greyed row carries a ⓘ
        // that says why. It is hidden — not removed — while the control is enabled, and it
        // takes the space between text and control, which is free anyway.
        if disabledReason != nil {
            let button = NSButton(image: NSImage(systemSymbolName: "info.circle",
                                                 accessibilityDescription: "Why is this disabled?")!,
                                  target: self, action: #selector(explain(_:)))
            button.isBordered = false
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(button)
            info = button
            switch infoPlacement {
            case .afterLabel:
                NSLayoutConstraint.activate([
                    button.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 5),
                    button.centerYAnchor.constraint(equalTo: label.centerYAnchor),
                    button.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12),
                ])
            case .beforeControl:
                NSLayoutConstraint.activate([
                    button.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -8),
                    button.centerYAnchor.constraint(equalTo: control.centerYAnchor),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
                ])
            }
        } else {
            label.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12).isActive = true
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Re-evaluates the reason: enables or greys the control and shows or hides the ⓘ.
    func refresh() {
        guard let disabledReason else { return }
        let reason = disabledReason()
        if let control = control as? NSControl {
            control.isEnabled = reason == nil
        } else if let control = control as? EnablableView {
            control.isEnabled = reason == nil
        }
        info?.isHidden = reason == nil
    }

    @objc private func explain(_ sender: NSButton) {
        guard let text = disabledReason?() else { return }
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.preferredMaxLayoutWidth = 260
        let height = label.sizeThatFits(NSSize(width: 260, height: 400)).height
        label.frame = NSRect(x: 12, y: 12, width: 260, height: height)
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 284, height: height + 24))
        content.view.addSubview(label)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    static func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }
}

/// Secondary text that wraps to the width it is given — explanations under a group of rows.
func caption(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

/// A column of settings rows, each pinned to the full width and chained top to bottom.
///
/// Chained by hand rather than stacked: an `NSStackView` sizes arranged subviews from their
/// intrinsic content size, and these rows have none — they are pure Auto Layout. A stack laid
/// the last row out below its own bounds and clipped it.
final class RowsView: NSView {
    init(_ rows: [NSView], spacing: CGFloat = 10) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        var previous: NSView?
        for row in rows {
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor),
                row.trailingAnchor.constraint(equalTo: trailingAnchor),
                previous == nil
                    ? row.topAnchor.constraint(equalTo: topAnchor)
                    : row.topAnchor.constraint(equalTo: previous!.bottomAnchor, constant: spacing),
            ])
            previous = row
        }
        if let previous {
            bottomAnchor.constraint(equalTo: previous.bottomAnchor).isActive = true
        } else {
            heightAnchor.constraint(equalToConstant: 0).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}
