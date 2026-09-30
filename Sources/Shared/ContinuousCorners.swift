import Cocoa

extension NSBezierPath {
    /// A rounded rectangle with *continuous* corners — the squircle macOS draws its icons,
    /// windows and controls with — rather than `roundedRect`'s circular arcs, whose curvature
    /// jumps where the arc meets the straight edge.
    ///
    /// Uses the well-known reverse-engineered Bézier approximation of Apple's curve: each corner
    /// starts 1.528 × radius before the corner point and is built from three cubic segments.
    /// The radius is capped so two corners never overlap.
    convenience init(continuousRoundedRect rect: NSRect, cornerRadius radius: CGFloat) {
        self.init()
        let r = min(radius, min(rect.width, rect.height) / 2 / 1.52866483)
        guard r > 0 else { appendRect(rect); return }

        // Corners in drawing order, each with the direction travelled into it (u) and out of it (v).
        let corners: [(NSPoint, CGVector, CGVector)] = [
            (NSPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
            (NSPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
            (NSPoint(x: rect.minX, y: rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
            (NSPoint(x: rect.minX, y: rect.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
        ]
        func p(_ c: NSPoint, _ u: CGVector, _ v: CGVector, _ a: CGFloat, _ b: CGFloat) -> NSPoint {
            // a × r back along the incoming edge, b × r forward along the outgoing one.
            NSPoint(x: c.x - a * r * u.dx + b * r * v.dx, y: c.y - a * r * u.dy + b * r * v.dy)
        }

        let (c0, u0, v0) = corners[3]
        move(to: p(c0, u0, v0, 0, 1.52866483))
        for (c, u, v) in corners {
            line(to: p(c, u, v, 1.52866483, 0))
            curve(to: p(c, u, v, 0.66993427, 0.06549600),
                  controlPoint1: p(c, u, v, 1.08849323, 0), controlPoint2: p(c, u, v, 0.86840689, 0))
            curve(to: p(c, u, v, 0.06549600, 0.66993427),
                  controlPoint1: p(c, u, v, 0.37282392, 0.16906001), controlPoint2: p(c, u, v, 0.16906001, 0.37282392))
            curve(to: p(c, u, v, 0, 1.52866483),
                  controlPoint1: p(c, u, v, 0, 0.86840689), controlPoint2: p(c, u, v, 0, 1.08849323))
        }
        close()
    }
}
