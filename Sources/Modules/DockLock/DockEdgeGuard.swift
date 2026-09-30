import Cocoa

/// Keeps the pointer from ever touching the Dock edge of any display other than the target one.
///
/// macOS moves the Dock to another display when the pointer is pushed against that display's
/// Dock edge (the bottom, or the side the Dock is on). There is no setting to turn that off,
/// so Dock Lock stops the push from happening: every mouse-move and drag event is looked at
/// before the system acts on it, and one that would reach a guarded edge is held a couple of
/// points short of it.
///
/// Only *outer* edges are guarded. Where another display continues past the edge — a screen
/// stacked below — the pointer must cross freely, and the Dock never triggers there anyway.
///
/// An active event tap needs the Accessibility permission. The callback does a handful of
/// rectangle tests against geometry precomputed on display changes: nothing in it allocates or
/// asks the system anything.
final class DockEdgeGuard {
    struct Geometry: Equatable {
        /// Displays whose Dock edge is guarded — every display but the target.
        var guarded: [CGRect] = []
        /// Every active display, to tell an outer edge from a shared one.
        var all: [CGRect] = []
        var edge: DockEdge = .bottom
    }

    /// How far short of the edge the pointer is stopped. The Dock needs the very last row.
    private static let margin: CGFloat = 2

    var geometry = Geometry()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Nil when the tap cannot be created, i.e. without the Accessibility permission.
    init?() {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // HID level: the earliest point, before the WindowServer places the cursor and before
        // the Dock gets a say.
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<DockEdgeGuard>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else { return nil }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap it finds too slow; re-arm instead of dying silently.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if let clamped = Self.clamp(event.location, geometry) {
            event.location = clamped
            // Moving the event is not always enough to move the cursor itself; the warp makes
            // sure it stays put. Re-associating right away avoids the short freeze a warp
            // otherwise causes.
            CGWarpMouseCursorPosition(clamped)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        return Unmanaged.passUnretained(event)
    }

    /// Where the pointer must be held instead of `p`, or nil when `p` is fine.
    static func clamp(_ p: CGPoint, _ g: Geometry) -> CGPoint? {
        func covered(_ q: CGPoint) -> Bool { g.all.contains { $0.contains(q) } }

        for r in g.guarded where r.minX <= p.x && p.x <= r.maxX && r.minY <= p.y && p.y <= r.maxY {
            switch g.edge {
            case .bottom:
                let limit = r.maxY - margin
                if p.y > limit, !covered(CGPoint(x: p.x, y: r.maxY + 1)) {
                    return CGPoint(x: p.x, y: limit)
                }
            case .left:
                let limit = r.minX + margin
                if p.x < limit, !covered(CGPoint(x: r.minX - 1, y: p.y)) {
                    return CGPoint(x: limit, y: p.y)
                }
            case .right:
                let limit = r.maxX - margin
                if p.x > limit, !covered(CGPoint(x: r.maxX + 1, y: p.y)) {
                    return CGPoint(x: limit, y: p.y)
                }
            }
        }
        return nil
    }
}
