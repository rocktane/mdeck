import Cocoa
import ApplicationServices

/// The notification badges the Dock shows on app icons ("19", "2", "•"), so the switcher can
/// draw them like the native one does.
///
/// macOS has no API for another app's badge; the Dock exposes it on each of its items through
/// Accessibility (`AXStatusLabel`), keyed here by the app's bundle path. That needs the
/// Accessibility permission — without it there are simply no badges — and an IPC round-trip
/// per Dock item, so it never runs on a summon: the switcher reads the cache, and a refresh
/// runs in the background at each summon and every few seconds while the module runs. A late
/// answer updates the open panel in place, like `AXStateCache`.
final class DockBadges {
    static let shared = DockBadges()

    private var labels: [String: String] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.yohan.mdeck.altty.badges", qos: .userInitiated)
    private var inFlight = false
    private var timer: Timer?

    /// Called on the main thread when a refresh changed at least one badge.
    var onChange: (() -> Void)?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        lock.lock(); labels.removeAll(); lock.unlock()
    }

    func label(for app: NSRunningApplication) -> String? {
        guard let path = app.bundleURL?.standardizedFileURL.path else { return nil }
        lock.lock(); defer { lock.unlock() }
        return labels[path]
    }

    func refresh() {
        guard AlttyPrefs.showNotificationBadges, Permissions.isAccessibilityTrusted, !inFlight else { return }
        inFlight = true
        queue.async {
            let fresh = Self.readDock()
            DispatchQueue.main.async {
                self.inFlight = false
                self.lock.lock()
                let changed = fresh != self.labels
                self.labels = fresh
                self.lock.unlock()
                if changed { self.onChange?() }
            }
        }
    }

    #if DEBUG
    /// For `--altty-demo` / `--altty-snapshot`, where the module is not running.
    func refreshNow() {
        let fresh = Self.readDock()
        lock.lock(); labels = fresh; lock.unlock()
    }
    #endif

    private static func readDock() -> [String: String] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [:] }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &value) == .success,
              let lists = value as? [AXUIElement]
        else { return [:] }

        let attributes = [kAXSubroleAttribute as String, kAXURLAttribute as String, "AXStatusLabel"] as CFArray
        var result: [String: String] = [:]
        for list in lists {
            var items: CFTypeRef?
            guard AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &items) == .success,
                  let items = items as? [AXUIElement] else { continue }
            for item in items {
                var values: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(item, attributes, [], &values) == .success,
                      let attrs = values as? [Any], attrs.count == 3,
                      attrs[0] as? String == "AXApplicationDockItem",
                      let label = attrs[2] as? String, !label.isEmpty
                else { continue }
                let url = (attrs[1] as? URL) ?? (attrs[1] as? NSURL).map { $0 as URL }
                guard let path = url?.standardizedFileURL.path else { continue }
                result[path] = label
            }
        }
        return result
    }
}
