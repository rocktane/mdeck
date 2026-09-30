import Cocoa

/// One active display, in the global CoreGraphics space: origin at the top-left of the primary
/// display, y pointing *down*. That is the space mouse events and the Accessibility API report
/// in, so Dock Lock never converts to `NSScreen` coordinates.
struct DisplayInfo: Equatable {
    let id: CGDirectDisplayID
    let bounds: CGRect
    let isBuiltin: Bool
    let name: String

    /// Survives unplugging and replugging, unlike `id`: the built-in panel is simply
    /// "builtin", an external display is identified by vendor, model and serial.
    var key: String {
        isBuiltin ? DisplayTarget.builtinKey
                  : "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }
}

enum DisplayTarget {
    static let builtinKey = "builtin"
}

enum Displays {
    /// Active displays, minus the secondary members of a mirror set (they duplicate another
    /// display's area and never hold a Dock of their own).
    static func active() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        let names = Dictionary(NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return (number.uint32Value, screen.localizedName)
        }, uniquingKeysWith: { a, _ in a })

        return ids.prefix(Int(count))
            .filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
            .map { id in
                let builtin = CGDisplayIsBuiltin(id) != 0
                return DisplayInfo(id: id, bounds: CGDisplayBounds(id), isBuiltin: builtin,
                                   name: names[id] ?? (builtin ? "Built-in Display" : "Display \(id)"))
            }
    }

    /// The display that should hold `rect` — the one containing its centre or, for a Dock
    /// that is auto-hidden just past the edge, the closest one.
    static func display(for rect: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        if let hit = displays.first(where: { $0.bounds.contains(centre) }) { return hit }
        return displays.min { distance(centre, $0.bounds) < distance(centre, $1.bounds) }
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }
}

/// Which screen edge the Dock sits on, from the Dock's own preferences.
enum DockEdge: String {
    case bottom, left, right

    static var current: DockEdge {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let raw = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String
        return DockEdge(rawValue: raw ?? "bottom") ?? .bottom
    }
}
