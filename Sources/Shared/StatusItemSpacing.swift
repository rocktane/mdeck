import Cocoa

/// The Ping dot is created after mdeck's other status items, so it sits at their left. macOS
/// leaves 4 pt between two status items and a variable-length item pads its image by 4 pt on
/// each side: the dot stood 9 pt from the gauges or icon to its right. While the dot is shown,
/// mdeck's image-only items drop the padding on their leading side, which brings the gap down
/// to the system's 4 pt. Their trailing padding, and everything while Ping is off, is unchanged.
enum StatusItemSpacing {
    /// What AppKit adds on each side of a variable-length item's image.
    static let padding: CGFloat = 4

    static var flushLeading: Bool { ModuleManager.shared.module(id: "ping")?.isRunning == true }

    /// `image` in `item`: variable length, or flush to the item's leading edge next to the dot.
    /// `flush: false` for an item that also shows a title, which only variable length lays out.
    static func setImage(_ image: NSImage?, of item: NSStatusItem?, flush: Bool = true) {
        guard let item, let button = item.button else { return }
        guard flush, flushLeading, let image else {
            item.length = NSStatusItem.variableLength
            button.image = image
            return
        }
        let size = NSSize(width: image.size.width + padding, height: image.size.height)
        let padded = NSImage(size: size, flipped: false) { _ in
            image.draw(in: NSRect(origin: .zero, size: image.size))
            return true
        }
        padded.isTemplate = image.isTemplate
        padded.accessibilityDescription = image.accessibilityDescription
        button.image = padded
        item.length = size.width
    }
}
