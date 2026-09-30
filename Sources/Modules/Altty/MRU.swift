import Cocoa

/// Most-recently-used ordering of applications, the way the native Cmd+Tab orders them.
/// `NSWorkspace` exposes no such history, so we build it by listening to activations.
final class MRUTracker {
    static let shared = MRUTracker()

    private(set) var order: [pid_t] = []

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(activated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(terminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        // Seed: we have no history at launch, so put the frontmost app first and let the
        // real ordering converge as the user works.
        if let front = NSWorkspace.shared.frontmostApplication {
            order = [front.processIdentifier]
        }
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        order = []
    }

    @objc private func activated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        touch(app.processIdentifier)
    }

    @objc private func terminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        order.removeAll { $0 == app.processIdentifier }
    }

    func touch(_ pid: pid_t) {
        order.removeAll { $0 == pid }
        order.insert(pid, at: 0)
    }

    /// Sorts apps by MRU; anything we've never seen activated keeps its original relative order
    /// at the back of the list.
    func sorted(_ apps: [NSRunningApplication]) -> [NSRunningApplication] {
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return apps.enumerated().sorted { a, b in
            let ra = rank[a.element.processIdentifier] ?? (order.count + a.offset)
            let rb = rank[b.element.processIdentifier] ?? (order.count + b.offset)
            return ra < rb
        }.map(\.element)
    }
}
