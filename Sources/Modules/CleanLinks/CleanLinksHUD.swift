import Cocoa

/// The notice shown for a moment after a link was cleaned, low and centred on the screen under
/// the pointer, like Raycast's. It never takes focus, never intercepts a click, and follows the
/// user across Spaces and over fullscreen apps.
final class CleanLinksHUD: NSPanel {
    static let visibleDuration: TimeInterval = 1.6

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 52),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        contentView = background

        let icon = NSImageView(image: NSImage(systemSymbolName: "link", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 17, weight: .semibold)
        icon.contentTintColor = .systemGreen
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, detailLabel] { label.lineBreakMode = .byTruncatingMiddle }
        for view in [icon, titleLabel, detailLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -18),
            titleLabel.topAnchor.constraint(equalTo: background.topAnchor, constant: 9),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -18),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
        ])
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty

        let textWidth = max(titleLabel.intrinsicContentSize.width, detail.isEmpty ? 0 : detailLabel.intrinsicContentSize.width)
        let size = NSSize(width: min(560, max(220, ceil(textWidth) + 16 + 22 + 10 + 18)), height: 52)
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 96, width: size.width, height: size.height),
                     display: false)
        }

        hideWork?.cancel()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !isVisible {
            alphaValue = reduceMotion ? 1 : 0
            orderFrontRegardless()
            if !reduceMotion {
                NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
            }
        } else {
            alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: work)
    }

    private func fadeOut() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return orderOut(nil) }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; animator().alphaValue = 0 }) { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.orderOut(nil)
        }
    }

    /// On stop: nothing pending, nothing on screen.
    func dispose() {
        hideWork?.cancel()
        hideWork = nil
        orderOut(nil)
        close()
    }
}
