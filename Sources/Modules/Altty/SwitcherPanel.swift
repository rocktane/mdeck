import Cocoa

/// `NSVisualEffectView` whose hairline border tracks the system theme. A `CGColor` on a layer
/// is a resolved, static colour, so unlike everything drawn in `draw(_:)` it has to be
/// re-applied whenever the effective appearance changes.
final class AdaptiveEffectView: NSVisualEffectView {
    /// `cgColor` resolves against `NSAppearance.current`, not this view's — so the resolution
    /// is pinned to the view's own appearance rather than to whatever happens to be current.
    func applyBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.borderColor = Palette.border.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorderColor()
    }
}

/// Dark mode leaves clear glass untinted, so the background can brighten it.
/// Refresh explicitly when changing appearance: retaining the light tint would darken it.
@available(macOS 26.0, *)
final class AdaptiveGlassView: NSGlassEffectView {
    func applyTintColor() {
        tintColor = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? nil : NSColor.black.withAlphaComponent(0.2)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTintColor()
    }
}

/// Soft drop shadow drawn around the switcher in place of the window shadow. The WindowServer
/// gives a dark-appearance window a crisp black rim around its shadow (a grey one in light mode),
/// which the native switcher does not have. The shadow is masked out under the panel, so it
/// never darkens the translucent glass.
final class SwitcherShadowView: NSView {
    private let mask = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        layer?.shadowRadius = 22
        mask.fillRule = .evenOdd
        layer?.mask = mask
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `rect` is the panel's frame in this view, `radius` its corner radius.
    func update(panelRect rect: NSRect, radius: CGFloat) {
        let shape = NSBezierPath(continuousRoundedRect: rect, cornerRadius: radius).cgPathCompat
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.shadowPath = shape
        let cutout = CGMutablePath()
        cutout.addRect(bounds)
        cutout.addPath(shape)
        mask.frame = bounds
        mask.path = cutout
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.shadowOpacity = dark ? 0.45 : 0.22
        CATransaction.commit()
    }
}

/// Non-activating borderless HUD panel. Non-activating matters: showing the switcher must not
/// take focus away from the current app, otherwise the menu bar flickers and the "previous app"
/// notion gets muddled.
///
/// On macOS 26+ the background is Liquid Glass, like the native switcher; before that, the
/// `.hudWindow` material with a hairline border. Both follow the light/dark appearance.
final class SwitcherPanel: NSPanel {
    let switcherView = SwitcherView()
    /// Room around the panel for `shadowView`, which the window has to contain.
    private static let shadowMargin: CGFloat = 48
    private let shadowView = SwitcherShadowView()
    /// The glass (macOS 26+) or the material — whichever holds `switcherView`.
    private var background: NSView!
    private var maskRadius: CGFloat = -1

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)

        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        animationBehavior = .none

        switcherView.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = AdaptiveGlassView()
            // Clear, not regular: the native switcher is the translucent grey glass that lets
            // what is behind show through; regular renders an opaque light slab.
            glass.style = .clear
            // Keep the measured light tint; dark glass follows what is behind without it.
            glass.applyTintColor()
            switcherView.drawsPanelBorder = true
            glass.contentView = switcherView
            background = glass
        } else {
            let effect = AdaptiveEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            // Still needed, for the subviews and the hairline border — the mask set in
            // `present` only handles the material.
            effect.wantsLayer = true
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            effect.layer?.borderWidth = 0.5
            effect.applyBorderColor()
            effect.addSubview(switcherView)
            background = effect
        }
        let container = NSView()
        container.addSubview(shadowView)
        container.addSubview(background)
        contentView = container
    }

    /// Resizable squircle mask: one corner-sized tile stretched via cap insets, so a single image
    /// works at any panel width. A continuous corner reaches 1.53 × its radius along each edge.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let reach = (radius * 1.53).rounded(.up)
        let edge = reach * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(continuousRoundedRect: rect, cornerRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: reach, left: reach, bottom: reach, right: reach)
        image.resizingMode = .stretch
        return image
    }

    /// The corner radius follows the icon size, so it is applied at each summon.
    private func applyCornerRadius(_ radius: CGFloat) {
        guard radius != maskRadius else { return }
        maskRadius = radius
        if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else if let effect = background as? AdaptiveEffectView {
            // A `behindWindow` material is composited by the WindowServer, *outside* our layer
            // tree — so `layer.cornerRadius` does not clip it. `maskImage` is the only thing that
            // does (and the window shadow follows it too).
            effect.maskImage = Self.roundedMask(radius: radius)
            effect.layer?.cornerRadius = radius
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Resizes to fit `items` and centres on the screen holding the pointer.
    func present(items: [SwitcherItem], selection: Int, mode: SwitcherController.Mode) {
        // Same screen `AppList` filtered against, so "this screen only" stays coherent.
        let screen = Screens.active

        // Window titles are the only thing telling two windows of one app apart, so that
        // band stays whatever the app-name setting says.
        let showsLabel = AlttyPrefs.showAppNames || mode == .windows
        let (size, iconSize) = SwitcherView.fittingSize(count: items.count,
                                                        maxWidth: screen.visibleFrame.width - 80,
                                                        baseIconSize: AlttyPrefs.iconSize.points)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2,
                             y: screen.frame.midY - size.height / 2)
        applyCornerRadius(SwitcherView.Metrics(icon: iconSize).cornerRadius)
        let margin = Self.shadowMargin
        let panelRect = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        // A theme change while the panel was hidden may not have reached the view, so the
        // layer-stored border colour is refreshed on every summon.
        (background as? AdaptiveEffectView)?.applyBorderColor()
        if #available(macOS 26.0, *) {
            (background as? AdaptiveGlassView)?.applyTintColor()
        }

        setFrame(NSRect(x: origin.x - margin, y: origin.y - margin,
                        width: size.width + margin * 2, height: size.height + margin * 2),
                 display: false)
        background.frame = panelRect
        shadowView.frame = contentView?.bounds ?? .zero
        shadowView.update(panelRect: panelRect, radius: maskRadius)
        switcherView.frame = NSRect(origin: .zero, size: size)
        switcherView.iconSize = iconSize
        switcherView.showsLabel = showsLabel
        switcherView.showsBadges = AlttyPrefs.showWindowBadges
        switcherView.items = items
        switcherView.selection = selection
        switcherView.announceCurrentSelection()

        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }
}
