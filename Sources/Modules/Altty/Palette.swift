import Cocoa

/// The switcher panel is the only place Altty paints anything itself, so it is the only place
/// that needs colours to follow the system theme by hand. Everything in the settings window is
/// a stock AppKit control using semantic colours, which adapt on their own.
///
/// `NSColor(name:dynamicProvider:)` is resolved against whatever appearance is current when the
/// colour is *used* — which is the right thing inside `draw(_:)`, and the wrong thing for a
/// `CGColor` stored on a layer. See `AdaptiveEffectView` for that case.
///
/// Computed rather than stored so the "Increase contrast" accessibility setting is read at
/// each use; `SwitcherView` repaints when it changes.
enum Palette {
    private static var highContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    private static func dynamic(_ name: String,
                                light: @escaping () -> NSColor,
                                dark: @escaping () -> NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark() : light()
        }
    }

    /// Native selection: a graphite well in light mode, a translucent white halo in dark.
    static var selection: NSColor {
        let strong = highContrast
        return dynamic("AlttySelection",
                       light: { .black.withAlphaComponent(strong ? 0.65 : 0.55) },
                       dark: { .white.withAlphaComponent(strong ? 0.80 : 0.60) })
    }

    /// Soft neutral edge around the selected well, scaled with the icons by `SwitcherView`.
    static var selectionHalo: NSColor {
        dynamic("AlttySelectionHalo",
                light: { .white.withAlphaComponent(0.10) },
                dark: { .white.withAlphaComponent(0.18) })
    }

    /// Fine reflective edge on the glass, and on the older HUD material.
    static var border: NSColor {
        let strong = highContrast
        return dynamic("AlttyBorder",
                       light: { .white.withAlphaComponent(strong ? 0.65 : 0.22) },
                       dark: { .white.withAlphaComponent(strong ? 0.65 : 0.25) })
    }
}
