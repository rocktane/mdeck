import Cocoa

/// Tier 2 (Accessibility) answers, kept warm between sessions so a summon never waits on a
/// slow app.
///
/// AltTab gets instant summons by holding AX observers on every app all day. Altty gets the
/// same *visible* result with none of that: it refreshes an app's answer in the background
/// when something happened to it (launched, activated, deactivated, hidden, a Space change),
/// and a summon only waits a few milliseconds for the batch before showing what it has. A
/// slow app is then filled in when it finally answers — the row updates in place.
///
/// Only apps with nothing visible on the current Space are ever looked up (see
/// `WindowDetection.states`), so a cached answer is never used to decide about a window
/// tier 1 can see.
final class AXStateCache {
    static let shared = AXStateCache()

    private var states: [pid_t: AppWindowState] = [:]
    private var inFlight: Set<pid_t> = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.yohan.mdeck.altty.ax", qos: .userInitiated, attributes: .concurrent)
    private var observers: [NSObjectProtocol] = []
    private var isStarted = false

    /// Called on the main thread when a background refresh changed at least one answer.
    var onChange: (() -> Void)?

    private var isActive: Bool { isStarted && AlttyPrefs.detectAcrossSpaces && Permissions.isAccessibilityTrusted }

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let nc = NSWorkspace.shared.notificationCenter
        let perApp: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in perApp {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.refresh([app.processIdentifier])
            })
        }
        // A freshly launched app has no windows yet; ask once it has had time to make some.
        observers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.refresh([app.processIdentifier]) }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.forget(app.processIdentifier)
        })
        // Every window's "is it on this Space" answer just changed.
        observers.append(nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshAll()
        })
        refreshAll()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        lock.lock(); states.removeAll(); lock.unlock()
    }

    /// Warm everything — at launch and when the permission or the setting flips on.
    func refreshAll() {
        guard isActive else { return }
        let own = ProcessInfo.processInfo.processIdentifier
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != own }
            .map(\.processIdentifier)
        refresh(pids)
    }

    private func forget(_ pid: pid_t) {
        lock.lock(); states[pid] = nil; lock.unlock()
    }

    // MARK: - Reads

    func state(for pid: pid_t) -> AppWindowState? {
        lock.lock(); defer { lock.unlock() }
        return states[pid]
    }

    // MARK: - Refresh

    /// Re-asks the given apps, in parallel, skipping any already being asked. Blocks the
    /// caller at most `wait` seconds for the batch — long enough for a responsive app to land
    /// in the summon that asked, short enough that a hung one only delays it by that much.
    func refresh(_ pids: [pid_t], wait: TimeInterval = 0) {
        guard isActive else { return }
        lock.lock()
        let todo = pids.filter { !inFlight.contains($0) }
        inFlight.formUnion(todo)
        lock.unlock()
        guard !todo.isEmpty else { return }

        let group = DispatchGroup()
        var changed = false
        for pid in todo {
            group.enter()
            queue.async {
                let fresh = WindowDetection.axState(pid)
                self.lock.lock()
                self.inFlight.remove(pid)
                // An app that didn't answer keeps its last known state rather than losing it.
                if let fresh, fresh != self.states[pid] {
                    self.states[pid] = fresh
                    changed = true
                }
                self.lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            if changed { self?.onChange?() }
        }
        if wait > 0 { _ = group.wait(timeout: .now() + wait) }
    }
}
