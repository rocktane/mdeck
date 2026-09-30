import Cocoa

enum DockLockPrefs {
    /// `DisplayInfo.key` of the display the Dock belongs on.
    @Pref("docklock.target", default: DisplayTarget.builtinKey)
    static var target: String

    /// Last known name of the target, to show it while it is disconnected.
    @Pref("docklock.targetName", default: "Built-in Display")
    static var targetName: String

    /// Bring the Dock back when a display change (plugging a screen in, waking up) moved it.
    @Pref("docklock.autoReturn", default: true)
    static var autoReturn: Bool
}

/// Dock Lock: pins the Dock to one display — the MacBook's own screen by default — however
/// many external displays are connected.
///
/// Two halves: `DockEdgeGuard` stops the pointer from dragging the Dock onto another display,
/// and `DockMover` brings it back when macOS moved it on its own (a display plugged in or
/// rearranged, the main display changed).
final class DockLockModule: Module {
    let id = "docklock"
    let name = "Dock Lock"
    let summary = "Keeps the Dock on one display, even with external screens connected."
    let symbolName = "dock.rectangle"
    let tint = NSColor.systemTeal

    private(set) var isRunning = false
    private var edgeGuard: DockEdgeGuard?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pendingReturn: DispatchWorkItem?
    /// The Dock edge can change in System Settings at any time; re-read now and then.
    private var edgeTimer: Timer?

    private(set) var displays: [DisplayInfo] = []

    var targetDisplay: DisplayInfo? { displays.first { $0.key == DockLockPrefs.target } }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
            self?.displaysChanged()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] _ in
            self?.displaysChanged()
        }
        edgeTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshGeometry()
        }
        installGuard()
        displaysChanged()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        pendingReturn?.cancel(); pendingReturn = nil
        edgeTimer?.invalidate(); edgeTimer = nil
        edgeGuard = nil
    }

    #if DEBUG
    var hasEdgeGuard: Bool { edgeGuard != nil }
    #endif

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping (Notification) -> Void) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: handler)))
    }

    var needsAccessibility: Bool { true }

    func accessibilityDidChange() {
        installGuard()
        displaysChanged()
    }

    private func installGuard() {
        guard isRunning, edgeGuard == nil, Permissions.isAccessibilityTrusted else { return }
        edgeGuard = DockEdgeGuard()
        refreshGeometry()
    }

    // MARK: - Displays

    private func displaysChanged() {
        refreshGeometry()
        // Displays take a moment to settle, and macOS places the Dock after that: wait,
        // then look where it ended up.
        pendingReturn?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, DockLockPrefs.autoReturn else { return }
            self.refreshGeometry()
            self.returnDockIfNeeded()
        }
        pendingReturn = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func refreshGeometry() {
        let previous = displays
        displays = Displays.active()
        if let target = targetDisplay { DockLockPrefs.targetName = target.name }
        // With the target gone there is nothing to protect: the Dock may go wherever
        // macOS puts it until the target is back.
        let guarded = targetDisplay == nil ? [] : displays.filter { $0.key != DockLockPrefs.target }
        let geometry = DockEdgeGuard.Geometry(guarded: guarded.map(\.bounds),
                                              all: displays.map(\.bounds),
                                              edge: DockEdge.current)
        let changed = displays != previous || (edgeGuard.map { $0.geometry != geometry } ?? false)
        edgeGuard?.geometry = geometry
        if changed { ModuleManager.shared.noteChange() }
    }

    private func returnDockIfNeeded() {
        guard isRunning, Permissions.isAccessibilityTrusted, let target = targetDisplay,
              displays.count > 1,
              let current = DockMover.dockDisplay(in: displays), current.key != target.key
        else { return }
        DockMover.move(to: target, edge: DockEdge.current) {
            ModuleManager.shared.noteChange()
        }
    }

    /// From the menu and the settings page.
    @objc func moveDockNow() {
        refreshGeometry()
        guard Permissions.isAccessibilityTrusted, let target = targetDisplay else { return }
        DockMover.move(to: target, edge: DockEdge.current) {
            ModuleManager.shared.noteChange()
        }
    }

    func setTarget(_ display: DisplayInfo) {
        DockLockPrefs.target = display.key
        DockLockPrefs.targetName = display.name
        refreshGeometry()
        if isRunning { returnDockIfNeeded() }
    }

    // MARK: - Status

    enum State { case needsPermission, targetMissing, locked(String) }

    var state: State {
        if !Permissions.isAccessibilityTrusted { return .needsPermission }
        guard let target = targetDisplay else { return .targetMissing }
        return .locked(target.name)
    }

    var statusText: String? {
        switch state {
        case .needsPermission: return "Waiting for the Accessibility permission"
        case .targetMissing: return "\(DockLockPrefs.targetName) not connected — idle"
        case .locked(let name): return "Dock kept on \(name)"
        }
    }

    func menuItems() -> [NSMenuItem] {
        guard case .locked(let name) = state, displays.count > 1 else { return [] }
        let item = NSMenuItem(title: "Move Dock to \(name) Now", action: #selector(moveDockNow), keyEquivalent: "")
        item.target = self
        return [item]
    }

    func makeSettingsView() -> NSView {
        DockLockSettingsView(module: self)
    }
}
