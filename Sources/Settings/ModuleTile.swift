import Cocoa

/// The coloured rounded square with a white symbol that stands for a module — System Settings'
/// sidebar idiom. Drawn rather than composed from views so the same image serves the sidebar,
/// the pages and the menu bar menu.
enum ModuleTile {
    static func image(symbol: String, tint: NSColor, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let radius = size * 0.225
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSGradient(colors: [tint.blended(withFraction: 0.18, of: .white) ?? tint, tint])?
                .draw(in: path, angle: -90)

            let config = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = glyph.size
                glyph.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2,
                                      width: s.width, height: s.height))
            }
            return true
        }
        return image
    }

    static func image(for module: Module, size: CGFloat) -> NSImage {
        image(symbol: module.symbolName, tint: module.tint, size: size)
    }

    /// mdeck's own tile, for the General page.
    static func general(size: CGFloat) -> NSImage {
        image(symbol: "gearshape.fill", tint: .systemGray, size: size)
    }
}
