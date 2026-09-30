import Cocoa
import ApplicationServices

/// What kind of windows an app currently owns. `AppList` turns this into a yes/no by
/// applying the user's "what counts as an open window" toggles.
struct AppWindowState: Equatable {
    var normal = 0      // on-screen on the current Space, not fullscreen
    var fullscreen = 0
    var minimized = 0   // only ever non-zero when Accessibility is granted
    var offScreen = 0   // exists, but not on the current Space

    /// Subsets of `normal` / `fullscreen` sitting on the screen the switcher appears on.
    /// Minimized and other-Space windows have no screen, so they have no counterpart here.
    var normalHere = 0
    var fullscreenHere = 0

    var total: Int { normal + fullscreen + minimized + offScreen }
    var isEmpty: Bool { total == 0 }
}

enum Screens {
    /// The screen the switcher shows on: the one under the pointer.
    static var active: NSScreen {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// `CGWindowList` reports bounds in a flipped global space whose origin is the top-left of
    /// the primary display; `NSScreen` uses bottom-left origin, y up. `flipHeight` is the
    /// primary screen's `frame.maxY`, hoisted by the caller so a loop over windows doesn't
    /// re-query the display list for each one.
    static var flipHeight: CGFloat { NSScreen.screens[0].frame.maxY }

    static func contains(_ screen: NSScreen, cgBounds: [String: Any], flipHeight: CGFloat) -> Bool {
        guard let x = cgBounds["X"] as? Double, let y = cgBounds["Y"] as? Double,
              let w = cgBounds["Width"] as? Double, let h = cgBounds["Height"] as? Double
        else { return false }
        let center = NSPoint(x: x + w / 2, y: flipHeight - (y + h / 2))
        return screen.frame.contains(center)
    }
}

/// Answers "does this app currently own any real window?" — the whole point of Altty.
///
/// Two-tier on purpose:
///
///  1. `CGWindowList` is instant and needs **no permission at all**. It sees every window,
///     including off-screen ones, and never reports a window that doesn't exist. What it
///     cannot do is tell a *minimized* window apart from one sitting on another Space.
///  2. The Accessibility API makes that distinction (and confirms fullscreen), but needs the
///     user to grant permission and can block on an unresponsive app.
///
/// So AX is only ever consulted for the apps tier 1 finds nothing visible for, and only when
/// the user opted in. Worst case that's a few AX round-trips, not one per app.
enum WindowDetection {

    /// Layer 0 filters out the menu bar, Dock, wallpaper and status items; the size and alpha
    /// floors drop tooltip-sized and fully transparent surfaces that aren't real windows.
    private static func isRealWindow(_ w: [String: Any]) -> Bool {
        guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
              let bounds = w[kCGWindowBounds as String] as? [String: Any],
              let h = bounds["Height"] as? Double, h > 40,
              let width = bounds["Width"] as? Double, width > 40,
              (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.1
        else { return false }
        return true
    }

    /// A true fullscreen window covers a whole screen frame — menu bar included, which is what
    /// separates it from a merely zoomed window (that one stops at `visibleFrame`).
    private static func isFullscreen(_ bounds: [String: Any], screenSizes: [CGSize]) -> Bool {
        guard let width = bounds["Width"] as? Double, let h = bounds["Height"] as? Double
        else { return false }
        return screenSizes.contains { abs($0.width - width) < 2 && abs($0.height - h) < 2 }
    }

    /// Tier 1. One `CGWindowList` pass over what is actually on screen.
    ///
    /// Deliberately **not** the full window list: asking for off-screen windows too returns a
    /// pile of ghost surfaces — cached 1800×43 toolbar strips, 1920×24 menu-bar shadows, stale
    /// window buffers — that no size or layer filter separates from real windows. Finder and
    /// half the Electron apps come back looking like they own windows. The on-screen list has
    /// no such problem: it under-reports (it can't see other Spaces) but never invents.
    /// Everything off-screen is tier 2's job.
    static func cgStates(activeScreen: NSScreen) -> [pid_t: AppWindowState] {
        let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []

        let screenSizes = NSScreen.screens.map(\.frame.size)
        let flipHeight = Screens.flipHeight
        var states: [pid_t: AppWindowState] = [:]

        for w in info {
            guard isRealWindow(w), let pid = w[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let here = Screens.contains(activeScreen, cgBounds: bounds, flipHeight: flipHeight)
            var state = states[pid] ?? AppWindowState()
            if isFullscreen(bounds, screenSizes: screenSizes) {
                state.fullscreen += 1
                if here { state.fullscreenHere += 1 }
            } else {
                state.normal += 1
                if here { state.normalHere += 1 }
            }
            states[pid] = state
        }
        return states
    }

    /// The three attributes tier 2 needs per window, fetched in one IPC round-trip rather
    /// than three. Order matters: results come back positionally.
    private static let windowAttributes = [
        kAXSubroleAttribute as String,
        kAXMinimizedAttribute as String,
        "AXFullScreen",
    ] as CFArray

    /// Tier 2. Re-classifies an app's off-screen windows into minimized / fullscreen / other-Space,
    /// with a hard messaging timeout so a hung app can't freeze the switcher.
    /// Returns nil if AX is unavailable or the app doesn't answer.
    static func axState(_ pid: pid_t) -> AppWindowState? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return nil }

        var state = AppWindowState()
        for window in windows {
            var values: CFArray?
            // Without `.stopOnError`, an attribute the app doesn't report comes back as a
            // placeholder rather than failing the whole call; the casts below treat that as
            // "not set".
            guard AXUIElementCopyMultipleAttributeValues(window, windowAttributes, [], &values) == .success,
                  let attrs = values as? [Any], attrs.count == 3
            else { continue }

            // No subrole reported: assume it counts.
            if let subrole = attrs[0] as? String,
               subrole != kAXStandardWindowSubrole as String, subrole != kAXDialogSubrole as String {
                continue
            }
            if attrs[1] as? Bool == true {
                state.minimized += 1
            } else if attrs[2] as? Bool == true {
                state.fullscreen += 1
            } else {
                // Present, not minimized, yet tier 1 saw nothing on screen: another Space.
                state.offScreen += 1
            }
        }
        return state
    }

    struct WindowInfo {
        let element: AXUIElement
        let title: String
        let isMinimized: Bool
    }

    /// Every standard window of one app, in the order AX reports them (front to back), for
    /// the window-cycling shortcut. One IPC per window, same timeout as tier 2.
    static func windows(of pid: pid_t) -> [WindowInfo] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return [] }

        let attributes = [kAXSubroleAttribute as String, kAXMinimizedAttribute as String,
                          kAXTitleAttribute as String] as CFArray
        return windows.compactMap { window in
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(window, attributes, [], &values) == .success,
                  let attrs = values as? [Any], attrs.count == 3
            else { return nil }
            if let subrole = attrs[0] as? String, subrole != kAXStandardWindowSubrole as String {
                return nil
            }
            return WindowInfo(element: window,
                              title: attrs[2] as? String ?? "",
                              isMinimized: attrs[1] as? Bool == true)
        }
    }

    /// Brings one window to the front: un-minimizes it if needed, raises it, then activates
    /// its app without dragging every other window along.
    static func raise(_ window: AXUIElement, of app: NSRunningApplication, isMinimized: Bool) {
        if isMinimized {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        app.activate(options: [])
    }

    /// How long a summon waits for tier 2 before showing what it has. Responsive apps answer
    /// well within this; a hung one costs at most this much, once, and is filled in later.
    static let axBudget: TimeInterval = 0.05

    /// Final per-pid state for the given apps, applying both tiers.
    static func states(for apps: [NSRunningApplication], activeScreen: NSScreen) -> [pid_t: AppWindowState] {
        var states = cgStates(activeScreen: activeScreen)
        guard AlttyPrefs.detectAcrossSpaces, Permissions.isAccessibilityTrusted else { return states }

        // Only apps with nothing visible on the current Space are ambiguous.
        let suspects = apps.map(\.processIdentifier).filter {
            let s = states[$0] ?? AppWindowState()
            return s.normal == 0 && s.fullscreen == 0
        }
        guard !suspects.isEmpty else { return states }

        // Re-ask them all, in parallel, but only wait briefly: whatever is cached (or lands
        // within the budget) is used now, the rest updates the row in place when it arrives.
        AXStateCache.shared.refresh(suspects, wait: axBudget)
        for pid in suspects {
            if let s = AXStateCache.shared.state(for: pid) { states[pid] = s }
        }
        return states
    }
}
