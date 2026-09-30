import Cocoa

/// mdeck's menu bar item: Open mdeck, the modules not hidden from it (a dot on the running
/// ones, their extra actions under them), then Quit. Rebuilt each time it opens, so it never shows
/// stale state.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.setAccessibilityLabel("mdeck")
        refreshIcon()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshIcon),
                                               name: .moduleStateDidChange, object: nil)
    }

    /// Filled while at least one module runs, outlined when mdeck is doing nothing.
    @objc private func refreshIcon() {
        let active = !ModuleManager.shared.runningModules.isEmpty
        let image = NSImage(systemSymbolName: active ? "square.grid.2x2.fill" : "square.grid.2x2",
                            accessibilityDescription: "mdeck")
        image?.isTemplate = true
        item.button?.image = image
        let names = ModuleManager.shared.runningModules.map(\.name)
        item.button?.toolTip = names.isEmpty ? "mdeck — no module running" : "mdeck — " + names.joined(separator: ", ")
    }

    #if DEBUG
    /// `--menu-size`: the menu's computed size, without opening it.
    func debugSize() -> NSSize {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        return menu.size
    }
    #endif

    #if DEBUG
    /// `--menu-colors`: the dot's and the connector's drawn colour under each appearance.
    static func debugColors() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: name)
            for (label, image, point) in [("dot", runningDot(), NSPoint(x: 4, y: 4)),
                                          ("connector", connector(last: true), NSPoint(x: 8, y: 12))] {
                let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
                let c = rep.colorAt(x: Int(point.x), y: rep.pixelsHigh - Int(point.y))!
                print(name.rawValue, label, String(format: "white=%.2f alpha=%.2f",
                                                   c.usingColorSpace(.genericGray)!.whiteComponent, c.alphaComponent))
            }
        }
        NSApp.appearance = nil
    }
    #endif

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // No key equivalents: in a menu bar menu they only work while it is open, and their
        // column alone made the menu ~50 pt wider.

        let open = NSMenuItem(title: "Open mdeck", action: #selector(openSettings), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        // One line per module, no separators between them. A module opens its settings page
        // when clicked; turning it on or off happens there. The dot marks the running ones.
        let dot = Self.runningDot()
        let shown = ModuleManager.shared.modules.filter { ModuleManager.shared.isShownInMenu($0) }
        for module in shown {
            let item = NSMenuItem(title: module.name, action: #selector(openModule(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = module.id
            item.state = module.isRunning ? .on : .off
            item.onStateImage = dot
            item.offStateImage = Self.stateSpacer
            item.image = ModuleTile.image(for: module, size: 16)
            menu.addItem(item)

            guard module.isRunning else { continue }
            let extras = module.menuItems()
            for (i, extra) in extras.enumerated() {
                // A tree line in the image column, hanging from the module's tile above.
                extra.image = Self.connector(last: i == extras.count - 1)
                extra.state = .off
                extra.offStateImage = Self.stateSpacer
                menu.addItem(extra)
            }
        }
        if !shown.isEmpty { menu.addItem(.separator()) }

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
    }

    /// A system colour resolved for the current light/dark appearance. The images below are
    /// rasterized and cached by AppKit, so a dynamic colour drawn inside them would stay frozen
    /// in whatever theme was active the first time; they are rebuilt with fresh colours each
    /// time the menu opens instead.
    private static func resolved(_ color: NSColor) -> NSColor {
        var cg = color.cgColor
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
        return NSColor(cgColor: cg) ?? color
    }

    /// Grey dot in the state column, for a running module.
    private static func runningDot() -> NSImage {
        let fill = resolved(.secondaryLabelColor)
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.accessibilityDescription = "Running"
        return image
    }

    /// └ (or ├ when more actions follow), in the image column under the module's tile.
    ///
    /// Same 16 pt box as the tile and *not* a template (the menu lays those out like symbols),
    /// so it lines up with the tile — given the row also keeps its state column, see
    /// `stateSpacer`.
    private static func connector(last: Bool) -> NSImage {
        let stroke = resolved(.tertiaryLabelColor)
        return NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let x = rect.midX.rounded() + 0.5
            let y = rect.midY.rounded() + 0.5
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: rect.maxY))
            path.line(to: NSPoint(x: x, y: last ? y : rect.minY))
            path.move(to: NSPoint(x: x, y: y))
            path.line(to: NSPoint(x: rect.maxX - 1, y: y))
            path.lineWidth = 1
            stroke.setStroke()
            path.stroke()
            return true
        }
    }

    /// A row with no state image loses its state column and everything in it slides left, out
    /// of line with the rows above and below. An empty image of the dot's size keeps the column.
    private static let stateSpacer = NSImage(size: NSSize(width: 8, height: 8))

    @objc private func openModule(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        SettingsWindowController.shared.show(page: id)
    }

    /// "Open mdeck" always lands on General — a module's page is reached by clicking the module.
    @objc private func openSettings() {
        SettingsWindowController.shared.show(page: "general")
    }
}
