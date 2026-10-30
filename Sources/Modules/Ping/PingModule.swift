import Cocoa

enum PingPrefs {
    static let defaultHost = "1.1.1.1"
    /// What the user typed; `PingTarget.normalize` turns it into the pinged host.
    @Pref("ping.host", default: defaultHost) static var host: String
    @Pref("ping.interval", default: 5) private static var intervalRaw: Int
    @Pref("ping.failuresBeforeAlert", default: 1) private static var failuresRaw: Int
    /// A `StoredColor` value: the dot while pings succeed. Failure is always red.
    @Pref("ping.color", default: "green") static var color: String

    static let intervals = [1, 2, 5, 10, 15, 30, 60, 120, 300]
    static var interval: Int {
        get { intervals.contains(intervalRaw) ? intervalRaw : 5 }
        set { intervalRaw = intervals.contains(newValue) ? newValue : 5 }
    }
    static let failureCounts = [1, 2, 3, 5]
    static var failuresBeforeAlert: Int {
        get { failureCounts.contains(failuresRaw) ? failuresRaw : 1 }
        set { failuresRaw = failureCounts.contains(newValue) ? newValue : 1 }
    }
    /// Never longer than the interval, so a slow ping cannot make checks pile up.
    static var timeout: TimeInterval { Double(min(interval, 3)) }

    static func intervalLabel(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min"
    }
}

final class PingModule: NSObject, Module, NSMenuDelegate {
    enum State: Equatable {
        case unknown
        case online
        case offline
        case invalidHost
    }

    let id = "ping"
    let name = "Ping"
    let summary = "Pings a host of your choice and shows a dot in the menu bar that turns red when it stops replying."
    let symbolName = "network"
    let tint = NSColor.systemGreen
    private(set) var isRunning = false
    private(set) var state = State.unknown
    private(set) var lastResult: PingResult?
    private(set) var consecutiveFailures = 0
    /// When the current state began: shown as "since 14:02" while offline.
    private(set) var stateSince: Date?
    private(set) var host: String?
    private let probe = PingProbe()
    private let queue = DispatchQueue(label: "mdeck.ping", qos: .utility)
    private var generation = 0
    private var checking = false
    private var item: NSStatusItem?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private weak var settingsView: PingSettingsView?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        let current = generation
        probe.resume()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        // Fixed width, dot drawn against the right edge: a variable-length item pads both sides
        // of its image, which left a wide gap between the dot and mdeck's icon.
        item = NSStatusBar.system.statusItem(withLength: Self.itemWidth)
        item?.autosaveName = "mdeck.ping"
        item?.menu = menu
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning, self.generation == current else { return }
            self.checkNow()
        }
        resetState()
        restartTimer()
        checkNow()
        ModuleManager.shared.noteChange()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        timer?.invalidate(); timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        // Kill the ping in flight, then drain: disabling leaves no process behind.
        probe.cancel()
        queue.sync {}
        checking = false
        if let item {
            item.menu?.cancelTracking()
            item.menu?.delegate = nil
            item.menu?.removeAllItems()
            NSStatusBar.system.removeStatusItem(item)
        }
        item = nil
        resetState()
        settingsView?.sync()
        ModuleManager.shared.noteChange()
    }

    private func resetState() {
        state = .unknown
        lastResult = nil
        consecutiveFailures = 0
        stateSince = nil
        host = nil
    }

    private func restartTimer() {
        timer?.invalidate(); timer = nil
        guard isRunning else { return }
        let current = generation
        let timer = Timer(timeInterval: Double(PingPrefs.interval), repeats: true) { [weak self] _ in
            guard let self, self.isRunning, self.generation == current else { return }
            self.checkNow()
        }
        timer.tolerance = min(1, Double(PingPrefs.interval) / 10)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// One ping, unless one is already on its way.
    @objc func checkNow() {
        guard isRunning, !checking else { return }
        guard let host = PingTarget.normalize(PingPrefs.host) else {
            self.host = nil
            setState(.invalidHost)
            return
        }
        self.host = host
        checking = true
        let current = generation
        let timeout = PingPrefs.timeout
        queue.async { [weak self, probe] in
            let result = probe.run(host: host, timeout: timeout)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning, self.generation == current else { return }
                self.checking = false
                self.record(result)
            }
        }
    }

    private func record(_ result: PingResult) {
        lastResult = result
        if result.ok {
            consecutiveFailures = 0
            setState(.online)
        } else {
            consecutiveFailures += 1
            if consecutiveFailures >= PingPrefs.failuresBeforeAlert {
                setState(.offline)
            } else {
                refreshUI()
            }
        }
    }

    /// Transitions go to the menu and sidebar; repeated identical results only refresh the dot.
    private func setState(_ new: State) {
        guard new != state else { refreshUI(); return }
        state = new
        stateSince = Date()
        refreshUI()
        ModuleManager.shared.noteChange()
    }

    /// The host or interval changed: forget results about the old target and check right away.
    func settingsChanged(target: Bool = false, interval: Bool = false) {
        guard isRunning else { settingsView?.sync(); return }
        if target {
            generation += 1
            probe.cancel()
            queue.async { [probe] in probe.resume() }
            checking = false
            resetState()
            restartTimer()
            checkNow()
            ModuleManager.shared.noteChange()
        } else if interval {
            // Only the timer changes: the reply in flight is still about the same host.
            restartTimer()
        } else if consecutiveFailures > 0, state != .invalidHost {
            // The failure threshold changed: re-judge the current streak.
            state = consecutiveFailures >= PingPrefs.failuresBeforeAlert ? .offline
                : (state == .offline ? .online : state)
            ModuleManager.shared.noteChange()
        }
        refreshUI()
    }

    var targetLabel: String { host ?? PingPrefs.host }

    var statusText: String? {
        guard isRunning else { return "Module disabled" }
        switch state {
        case .invalidHost:
            return "Enter an IP address or a host name to ping."
        case .unknown:
            return "Checking \(targetLabel)…"
        case .online:
            if consecutiveFailures > 0 {
                return "Online · \(consecutiveFailures) missed \(consecutiveFailures == 1 ? "reply" : "replies") from \(targetLabel)"
            }
            if let latency = lastResult?.latency {
                return "Online · \(targetLabel) replied in \(Self.milliseconds(latency))"
            }
            return "Online · \(targetLabel) replies"
        case .offline:
            let since = stateSince.map { " since " + DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? ""
            return "Offline · \(lastResult?.detail ?? "No reply") from \(targetLabel)\(since)"
        }
    }

    static func milliseconds(_ seconds: TimeInterval) -> String {
        let ms = seconds * 1000
        return ms < 10 ? String(format: "%.1f ms", ms) : String(format: "%.0f ms", ms)
    }

    // MARK: - Menu bar dot

    var dotColor: NSColor {
        switch state {
        case .online: return StoredColor.color(PingPrefs.color) ?? .systemGreen
        case .offline, .invalidHost: return .systemRed
        case .unknown: return (StoredColor.color(PingPrefs.color) ?? .systemGreen).withAlphaComponent(0.35)
        }
    }

    private func refreshUI() {
        if let button = item?.button {
            button.image = Self.dot(Self.resolved(dotColor, in: button.effectiveAppearance), width: Self.itemWidth)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.toolTip = "Ping — \(statusText ?? "")"
            button.setAccessibilityLabel("Ping — \(statusText ?? "")")
        }
        settingsView?.sync()
    }

    /// The dot is rasterized and cached by AppKit, so a dynamic system colour is resolved first
    /// (and redrawn at every check, which follows a menu bar appearance change soon enough).
    private static func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var cg = color.cgColor
        appearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
        return NSColor(cgColor: cg) ?? color
    }

    private static let itemWidth: CGFloat = 14

    /// The dot, right-aligned in an image `width` wide (its own size when nil).
    static func dot(_ fill: NSColor, diameter: CGFloat = 9, width: CGFloat? = nil) -> NSImage {
        let side = diameter + 1
        let image = NSImage(size: NSSize(width: width ?? side, height: side), flipped: false) { rect in
            let circle = NSRect(x: rect.maxX - side, y: 0, width: side, height: side).insetBy(dx: 0.5, dy: 0.5)
            fill.setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            let edge = NSBezierPath(ovalIn: circle.insetBy(dx: 0.25, dy: 0.25))
            edge.lineWidth = 0.5
            edge.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: statusText ?? "Ping", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(action("Check Now", #selector(checkNow)))
        menu.addItem(action("Ping Settings…", #selector(openSettings)))
    }

    func menuItems() -> [NSMenuItem] {
        [action("Check Now", #selector(checkNow))]
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func openSettings() { SettingsWindowController.shared.show(page: id) }

    func makeSettingsView() -> NSView {
        let view = PingSettingsView(module: self)
        settingsView = view
        return view
    }

    #if DEBUG
    var hasResources: Bool {
        item != nil || timer != nil || wakeObserver != nil || checking || probe.isPinging
    }
    var debugStatusItem: NSStatusItem? { item }
    var debugIsChecking: Bool { checking }
    #endif
}
