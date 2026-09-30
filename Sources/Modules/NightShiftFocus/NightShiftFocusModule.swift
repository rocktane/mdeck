import Cocoa

/// Night Shift Focus: while a watched app is frontmost, Night Shift and True Tone are turned
/// off; as soon as it isn't, the previous state is put back exactly as it was.
///
/// Needs no permission: focus comes from `NSWorkspace`, the colours from CoreBrightness.
final class NightShiftFocusModule: Module {
    let id = "nightshift"
    let name = "Night Shift Focus"
    let summary = "Turns Night Shift and True Tone off while a colour-critical app is in front."
    let symbolName = "moon.fill"
    let tint = NSColor.systemOrange

    private let controller = ColorController()
    private(set) var isRunning = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Last app *other than mdeck* to come to the front: opening our menu or settings must
    /// not count as a focus change.
    private var frontApp: NSRunningApplication?

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        NightShiftPrefs.seedIfNeeded()
        applyManagementPrefs()
        controller.recoverFromCrash()
        frontApp = NSWorkspace.shared.frontmostApplication

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier
            else { return }
            self?.frontApp = app
            self?.sync()
        }
        // True Tone sometimes comes back on its own after a wake or a display change.
        let reapply: (Notification) -> Void = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.sync() }
        }
        observe(workspace, NSWorkspace.didWakeNotification, reapply)
        observe(.default, NSApplication.didChangeScreenParametersNotification, reapply)
        sync()
    }

    /// Always leaves the display the way the user had it.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        controller.update(shouldSuppress: false)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping (Notification) -> Void) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: handler)))
    }

    // MARK: - State

    private var activeWatchedApp: String? {
        guard let id = frontApp?.bundleIdentifier, NightShiftPrefs.watchedApps.contains(id) else { return nil }
        return id
    }

    private func applyManagementPrefs() {
        controller.manageNightShift = NightShiftPrefs.manageNightShift
        controller.manageTrueTone = NightShiftPrefs.manageTrueTone
    }

    /// Re-reads the preferences and applies them right away — the settings page calls this
    /// after every edit.
    func settingsChanged() {
        applyManagementPrefs()
        if isRunning { sync() }
    }

    private func sync() {
        controller.update(shouldSuppress: activeWatchedApp != nil)
        ModuleManager.shared.noteChange()
    }

    var statusText: String? {
        guard controller.isSuppressing else { return "Idle — system colours in charge" }
        var parts: [String] = []
        if controller.nightShiftSuppressed { parts.append("Night Shift") }
        if controller.trueToneSuppressed { parts.append("True Tone") }
        let who = frontApp?.localizedName ?? "a watched app"
        return "\(parts.joined(separator: " + ")) off for \(who)"
    }

    func menuItems() -> [NSMenuItem] {
        guard let app = frontApp, let id = app.bundleIdentifier,
              app.activationPolicy == .regular else { return [] }
        let watched = NightShiftPrefs.watchedApps.contains(id)
        let name = app.localizedName ?? id
        let item = NSMenuItem(title: watched ? "Remove \(name) from watchlist" : "Add \(name) to watchlist",
                              action: #selector(toggleFrontApp(_:)), keyEquivalent: "")
        // "Add [icon] **Arc** to watchlist": the app — icon then name in semibold — stands
        // out from the verb, so the line reads at a glance.
        let font = NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString(string: watched ? "Remove " : "Add ", attributes: [.font: font])
        if let icon = app.icon?.copy() as? NSImage {
            let attachment = NSTextAttachment()
            attachment.image = icon
            let side = (font.pointSize + 3).rounded()
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - side) / 2, width: side, height: side)
            title.append(NSAttributedString(attachment: attachment))
            title.append(NSAttributedString(string: " ", attributes: [.font: font]))
        }
        title.append(NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
        ]))
        title.append(NSAttributedString(string: watched ? " from watchlist" : " to watchlist",
                                        attributes: [.font: font]))
        item.attributedTitle = title
        item.target = self
        item.representedObject = id
        return [item]
    }

    @objc private func toggleFrontApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if NightShiftPrefs.watchedApps.contains(id) {
            NightShiftPrefs.watchedApps.removeAll { $0 == id }
        } else {
            NightShiftPrefs.watchedApps.append(id)
        }
        settingsView?.reloadApps()
        sync()
    }

    // MARK: - Settings

    private weak var settingsView: NightShiftSettingsView?

    func makeSettingsView() -> NSView {
        let view = NightShiftSettingsView(module: self)
        settingsView = view
        return view
    }
}
