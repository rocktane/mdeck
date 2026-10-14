import Cocoa

/// Tells Clean Links when the pasteboard may hold a new copy. macOS has no notification for
/// that, so there are two ways to find out:
///
/// - **Through Tinycast**, while it runs with its clipboard history on. Tinycast polls the
///   pasteboard itself and writes every new copy to its SQLite history at once. A vnode source on
///   that database's write-ahead log wakes us right after the write — no polling on our side,
///   and the cleaned link only replaces the original once the original is in the history, so
///   the history keeps both.
/// - **By polling** `changeCount` every half second otherwise.
///
/// Tinycast's launch and quit come from NSWorkspace notifications; whether its history is on is
/// re-read from its preferences when the active app changes (the user toggles it in Tinycast).
/// Callbacks may fire for writes that are not copies (pins, pruning…): the module compares
/// `changeCount` before doing anything.
final class ClipboardWatcher {
    static let tinycastBundleID = "com.tinycast.app"
    static let pollInterval: TimeInterval = 0.5

    enum Mode: Equatable { case stopped, tinycast, polling }

    private(set) var mode: Mode = .stopped
    private let onSignal: () -> Void
    private let onModeChange: () -> Void
    /// The database's log; injectable so the debug test can drive a scratch file.
    private let logPath: String
    private let bundleID: String

    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var tinycastRunning = false

    static var tinycastLogPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.tinycast.app/clipboard.sqlite3-wal").path
    }

    init(logPath: String = ClipboardWatcher.tinycastLogPath, bundleID: String = ClipboardWatcher.tinycastBundleID,
         onSignal: @escaping () -> Void, onModeChange: @escaping () -> Void = {}) {
        self.logPath = logPath
        self.bundleID = bundleID
        self.onSignal = onSignal
        self.onModeChange = onModeChange
    }

    var hasResources: Bool { source != nil || timer != nil || !observers.isEmpty }

    func start() {
        guard mode == .stopped else { return }
        let center = NSWorkspace.shared.notificationCenter
        let bundleID = self.bundleID
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == bundleID else { return }
                self?.tinycastRunning = name == NSWorkspace.didLaunchApplicationNotification
                self?.reevaluate()
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.reevaluate()
        })
        tinycastRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        mode = .polling
        reevaluate()
    }

    func stop() {
        guard mode != .stopped else { return }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        detach()
        timer?.invalidate()
        timer = nil
        mode = .stopped
    }

    /// Picks the cheapest way that works right now.
    private func reevaluate() {
        guard mode != .stopped else { return }
        let previous = mode
        if tinycastRunning && tinycastHistoryEnabled && (source != nil || attach()) {
            mode = .tinycast
            timer?.invalidate()
            timer = nil
        } else {
            detach()
            mode = .polling
            if timer == nil {
                let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in self?.tick() }
                timer.tolerance = 0.1
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
        }
        if mode != previous { onModeChange() }
    }

    private func tick() {
        onSignal()
        // Tinycast creates its log a moment after launching: keep trying while it runs.
        if tinycastRunning, source == nil, FileManager.default.fileExists(atPath: logPath) { reevaluate() }
    }

    /// Tinycast's “Clipboard history” switch; absent means on, its default.
    private var tinycastHistoryEnabled: Bool {
        guard bundleID == Self.tinycastBundleID else { return true }
        CFPreferencesAppSynchronize(bundleID as CFString)
        return CFPreferencesCopyAppValue("clipboardEnabled" as CFString, bundleID as CFString) as? Bool ?? true
    }

    private func attach() -> Bool {
        let fd = open(logPath, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let event = source.data
            if !event.isDisjoint(with: [.delete, .rename, .revoke]) {
                // Tinycast quit (SQLite removes the log with its last connection) or the file
                // was replaced: pick the best mode again.
                self.detach()
                self.reevaluate()
            } else {
                self.onSignal()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        return true
    }

    private func detach() {
        source?.cancel()
        source = nil
    }

    #if DEBUG
    /// For the lifecycle test, which drives a scratch file instead of Tinycast's log.
    func debugSetTinycastRunning(_ running: Bool) {
        tinycastRunning = running
        reevaluate()
    }
    #endif
}
