import Cocoa
import ApplicationServices

/// Finds which display holds the Dock, and brings it to another one.
///
/// Both need the Accessibility permission: the Dock's frame comes from its AX tree, and moving
/// it means posting pointer events.
enum DockMover {

    /// The Dock's icon strip, in global CG coordinates (y down). Still reported while the Dock
    /// is auto-hidden, sitting just past the edge of its display.
    static func dockFrame() -> CGRect? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else { return nil }

        var frame: CGRect?
        for child in children {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            guard role as? String == kAXListRole as String, let bounds = bounds(of: child) else { continue }
            frame = frame.map { $0.union(bounds) } ?? bounds
        }
        return frame
    }

    private static func bounds(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    static func dockDisplay(in displays: [DisplayInfo]) -> DisplayInfo? {
        guard let frame = dockFrame() else { return nil }
        return Displays.display(for: frame, in: displays)
    }

    private static let queue = DispatchQueue(label: "com.yohan.mdeck.docklock.move")
    private static var isMoving = false

    /// Does what a user would: takes the pointer to the Dock edge of `display` and keeps
    /// pushing against it until the Dock follows, then puts the pointer back where it was.
    /// Takes about a second; `completion` runs on the main thread.
    static func move(to display: DisplayInfo, edge: DockEdge, completion: (() -> Void)? = nil) {
        guard !isMoving else { return }
        isMoving = true
        let original = CGEvent(source: nil)?.location
        let b = display.bounds

        // The last row or column along the edge, and one step of approach towards it.
        let (target, step): (CGPoint, CGVector) = {
            switch edge {
            case .bottom: return (CGPoint(x: b.midX, y: b.maxY - 1), CGVector(dx: 0, dy: 1))
            case .left:   return (CGPoint(x: b.minX, y: b.midY), CGVector(dx: -1, dy: 0))
            case .right:  return (CGPoint(x: b.maxX - 1, y: b.midY), CGVector(dx: 1, dy: 0))
            }
        }()

        queue.async {
            let source = CGEventSource(stateID: .hidSystemState)
            func post(_ p: CGPoint, push: Int64) {
                guard let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                      mouseCursorPosition: p, mouseButton: .left) else { return }
                e.setIntegerValueField(.mouseEventDeltaX, value: Int64(step.dx) * push)
                e.setIntegerValueField(.mouseEventDeltaY, value: Int64(step.dy) * push)
                e.post(tap: .cghidEventTap)
            }
            // Approach from 60 pt away, then keep pushing into the edge.
            for i in stride(from: 60, through: 0, by: -5) {
                post(CGPoint(x: target.x - step.dx * CGFloat(i), y: target.y - step.dy * CGFloat(i)), push: 5)
                usleep(8_000)
            }
            for _ in 0..<45 {
                post(target, push: 4)
                usleep(15_000)
            }
            usleep(250_000)
            DispatchQueue.main.async {
                if let original {
                    CGWarpMouseCursorPosition(original)
                    CGAssociateMouseAndMouseCursorPosition(1)
                }
                isMoving = false
                completion?()
            }
        }
    }
}
