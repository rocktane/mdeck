import Cocoa

/// One cell of the switcher: an app, or — in window-cycling mode — one window of an app.
struct SwitcherItem {
    enum Target {
        case app
        case window(AXUIElement, isMinimized: Bool)
    }

    let app: NSRunningApplication
    let target: Target
    let name: String
    /// Captured once at build time: `NSRunningApplication.icon` is not free, and the view
    /// redraws on every hover.
    let icon: NSImage?
    let state: AppWindowState
    let isHidden: Bool
    /// The Dock's notification badge ("19", "•"), when there is one and badges are on.
    var notificationBadge: String?

    init(app: NSRunningApplication, state: AppWindowState) {
        self.app = app
        target = .app
        name = Self.name(of: app)
        icon = app.icon
        self.state = state
        isHidden = app.isHidden
        notificationBadge = AlttyPrefs.showNotificationBadges ? DockBadges.shared.label(for: app) : nil
    }

    init(app: NSRunningApplication, window: AXUIElement, title: String, isMinimized: Bool) {
        self.app = app
        target = .window(window, isMinimized: isMinimized)
        name = title.isEmpty ? Self.name(of: app) : title
        icon = app.icon
        state = AppWindowState()
        isHidden = false
    }

    #if DEBUG
    /// `--fake-states`: same app, invented window state, to look at the badges.
    init(faking state: AppWindowState, hidden: Bool, from item: SwitcherItem) {
        app = item.app
        target = .app
        name = item.name
        icon = item.icon
        self.state = state
        isHidden = hidden
        notificationBadge = item.notificationBadge
    }
    #endif

    private static func name(of app: NSRunningApplication) -> String {
        app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "?"
    }

    var isWindowless: Bool {
        if case .app = target { return state.isEmpty }
        return false
    }

    var isMinimizedWindow: Bool {
        if case .window(_, let minimized) = target { return minimized }
        return false
    }
}

enum AppList {
    /// Should this app appear at all?
    ///
    /// Each toggle owns one category outright rather than feeding a shared window count: an app
    /// with nothing but minimized windows disappears when "Show minimized apps" is off, whatever
    /// the other switches say. That is what the labels promise.
    ///
    /// A window on another Space always wins — it is unambiguously a real, restorable window.
    private static func isVisible(_ s: AppWindowState) -> Bool {
        if s.isEmpty { return AlttyPrefs.showWindowlessApps }

        // Narrowing to the switcher's screen only applies to windows we can actually locate,
        // i.e. the ones on the current Space. Minimized windows have no screen at all.
        let normal = AlttyPrefs.showOtherScreenApps ? s.normal : s.normalHere
        let fullscreen = AlttyPrefs.showOtherScreenApps ? s.fullscreen : s.fullscreenHere
        let otherSpaces = AlttyPrefs.showOtherSpaceApps ? s.offScreen : 0

        if normal > 0 || otherSpaces > 0 { return true }
        if fullscreen > 0 && AlttyPrefs.showFullscreenApps { return true }
        if s.minimized > 0 && AlttyPrefs.showMinimizedApps { return true }
        return false
    }

    /// The apps the native Cmd+Tab would show, MRU-ordered, with the user's filters applied.
    static func build() -> [SwitcherItem] {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let excluded = Set(AlttyPrefs.excludedBundleIDs)
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPid && !$0.isTerminated
                && !excluded.contains($0.bundleIdentifier ?? "")
        }

        let states = WindowDetection.states(for: apps, activeScreen: Screens.active)
        return MRUTracker.shared.sorted(apps).compactMap { app -> SwitcherItem? in
            let state = states[app.processIdentifier] ?? AppWindowState()
            // A ⌘H-hidden app has no on-screen window by definition, so the toggle decides
            // outright rather than going through the window state.
            let visible = app.isHidden ? AlttyPrefs.showHiddenApps : isVisible(state)
            return visible ? SwitcherItem(app: app, state: state) : nil
        }
    }

    /// The windows of the frontmost app, front to back, for the window-cycling shortcut.
    /// Empty when Accessibility is not granted or the app has no standard window.
    static func buildWindows() -> [SwitcherItem] {
        guard Permissions.isAccessibilityTrusted,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return [] }
        return WindowDetection.windows(of: app.processIdentifier).map {
            SwitcherItem(app: app, window: $0.element, title: $0.title, isMinimized: $0.isMinimized)
        }
    }
}
