import Cocoa

final class KeepAwakeModule: NSObject, Module, NSMenuDelegate {
    let id = "keepawake"
    let name = "Keep Awake"
    let summary = "Keeps your Mac or display awake for as long as you choose, or while Claude Code or Codex works."
    let symbolName = "cup.and.saucer.fill"
    let tint = NSColor.systemOrange
    private(set) var isRunning = false
    private(set) var session: KeepAwakeSession?
    private(set) var lastError: String?
    let assertions = KeepAwakeAssertions()
    private var item: NSStatusItem?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var spacingObserver: NSObjectProtocol?
    private var generation = 0
    private var sessionPanel: KeepAwakeSessionPanel?
    private weak var settingsView: KeepAwakeSettingsView?
    private weak var menuStatus: NSMenuItem?
    private var agentMonitor: AgentActivityMonitor?
    private(set) var workingAgents: Set<AgentActivityMonitor.Agent> = []

    /// A manual session; agent activity holds assertions without being a session.
    var isActive: Bool { session != nil }
    var isAgentHold: Bool { !workingAgents.isEmpty }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        let current = generation
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item?.menu = menu
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning, self.generation == current else { return }
            self.tick()
        }
        // The Ping dot starting or stopping changes the cup's leading padding.
        spacingObserver = NotificationCenter.default.addObserver(
            forName: .moduleStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshUI() }
        if KeepAwakePrefs.startOnEnable { beginDefaultSession() }
        syncAgentMonitor()
        publishChange()
    }

    func stop() {
        isRunning = false
        generation += 1
        syncAgentMonitor()
        endSession(notify: false)
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        if let spacingObserver { NotificationCenter.default.removeObserver(spacingObserver) }
        spacingObserver = nil
        sessionPanel?.close()
        sessionPanel = nil
        menuStatus = nil
        if let item {
            item.menu?.cancelTracking()
            item.menu?.delegate = nil
            item.menu?.removeAllItems()
            NSStatusBar.system.removeStatusItem(item)
        }
        item = nil
        publishChange()
    }

    @discardableResult
    func beginSession(duration: TimeInterval?, until: Date? = nil) -> Bool {
        guard isRunning else { return false }
        guard KeepAwakePrefs.hasProtection else {
            endSession(notify: false)
            lastError = "Choose system or display protection before starting."
            publishChange()
            return false
        }
        if let duration, !duration.isFinite || duration <= 0 || duration > Double(KeepAwakePrefs.maximumMinutes * 60) {
            lastError = "Choose a duration between 1 minute and 7 days."
            publishChange()
            return false
        }
        if let until, !until.timeIntervalSinceNow.isFinite || until <= Date() {
            lastError = "Choose an end time in the future."
            publishChange()
            return false
        }
        let effectiveDuration = until.map { min(duration ?? $0.timeIntervalSinceNow, $0.timeIntervalSinceNow) } ?? duration
        if let effectiveDuration, effectiveDuration > Double(KeepAwakePrefs.maximumMinutes * 60) {
            lastError = "Choose an end time within the next 7 days."
            publishChange()
            return false
        }
        let candidate = KeepAwakeSession(duration: effectiveDuration, until: until)
        return applySession(candidate)
    }

    private func applySession(_ candidate: KeepAwakeSession) -> Bool {
        if let remaining = candidate.remaining, remaining <= 0 { endSession(); return false }
        timer?.invalidate(); timer = nil
        session = nil
        // While an agent works the hold is indefinite; powerd's timeout only bounds a manual session.
        if !acquireAssertions(timeout: isAgentHold ? nil : candidate.remaining) {
            publishChange()
            return false
        }
        session = candidate
        if candidate.remaining != nil {
            let currentTimerSession = candidate.continuousEnd
            let current = generation
            let newTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, self.isRunning, self.generation == current,
                      self.session?.continuousEnd == currentTimerSession else { return }
                self.tick()
            }
            timer = newTimer
            RunLoop.main.add(newTimer, forMode: .common)
        }
        publishChange()
        return true
    }

    /// Ends the manual session. Assertions stay (untimed) if an agent is still working.
    func endSession(notify: Bool = true) {
        timer?.invalidate(); timer = nil
        session = nil
        if isRunning, isAgentHold, KeepAwakePrefs.hasProtection {
            _ = acquireAssertions(timeout: nil)
        } else if let error = assertions.releaseAll() {
            lastError = String(format: "macOS could not release a power assertion (0x%08x). Disable Keep Awake to retry.", error)
        } else {
            lastError = nil
        }
        if notify { publishChange() }
    }

    private func acquireAssertions(timeout: TimeInterval?) -> Bool {
        if let error = assertions.acquire(system: KeepAwakePrefs.preventSystemSleep,
                                          display: KeepAwakePrefs.preventDisplaySleep, timeout: timeout) {
            lastError = String(format: "macOS refused a power assertion (0x%08x). Try starting again.", error)
            return false
        }
        lastError = nil
        return true
    }

    /// Reacquires for the current manual session and/or agent activity.
    private func reconcileHold() {
        if let session { _ = applySession(session) } else { endSession() }
    }

    func settingsChanged(reapplyProtection: Bool = false, agentMode: Bool = false) {
        if agentMode { syncAgentMonitor() }
        if isRunning, reapplyProtection, isActive || isAgentHold {
            if KeepAwakePrefs.hasProtection { reconcileHold() } else { endSession() }
        } else {
            publishChange()
        }
    }

    private func syncAgentMonitor() {
        let wanted = isRunning && KeepAwakePrefs.whileAgentsWork
        let grace = Double(KeepAwakePrefs.agentGraceMinutes * 60)
        if wanted, agentMonitor == nil {
            let current = generation
            agentMonitor = AgentActivityMonitor(grace: grace) { [weak self] agents in
                guard let self, self.isRunning, self.generation == current else { return }
                self.agentsChanged(agents)
            }
            agentMonitor?.start()
        } else if !wanted, let agentMonitor {
            agentMonitor.stop()
            self.agentMonitor = nil
            agentsChanged([])
        }
        agentMonitor?.grace = grace
    }

    func agentsChanged(_ agents: Set<AgentActivityMonitor.Agent>) {
        let wasHolding = isAgentHold
        workingAgents = agents
        guard isRunning, wasHolding != isAgentHold, KeepAwakePrefs.hasProtection else { publishChange(); return }
        reconcileHold()
    }

    var agentsLabel: String {
        AgentActivityMonitor.Agent.allCases.filter(workingAgents.contains).map(\.rawValue).joined(separator: " and ")
    }

    private func tick() {
        if let remaining = session?.remaining, remaining <= 0 { endSession(); return }
        refreshUI() // Countdown updates stay local; no global notification every second.
    }

    var statusText: String? {
        if let lastError { return lastError }
        guard isRunning else { return "Module disabled" }
        let protection = KeepAwakePrefs.preventSystemSleep
            ? (KeepAwakePrefs.preventDisplaySleep ? "System and display awake" : "System awake · display may sleep")
            : "Display awake"
        let agents = isAgentHold && KeepAwakePrefs.hasProtection ? "\(agentsLabel) working" : nil
        guard let session else {
            if let agents { return "\(protection) · \(agents)" }
            return KeepAwakePrefs.whileAgentsWork ? "Idle — waiting for Claude Code or Codex to work" : "Idle — sleep is allowed"
        }
        guard let remaining = session.remaining else { return "\(protection) · indefinitely" }
        return ["\(protection) · \(Self.countdown(remaining)) left", agents].compactMap { $0 }.joined(separator: " · ")
    }

    static func countdown(_ remaining: TimeInterval) -> String {
        let seconds = Int(ceil(max(0, min(remaining, Double(KeepAwakePrefs.maximumMinutes * 60)))))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func publishChange() {
        refreshUI()
        ModuleManager.shared.noteChange()
    }

    private func refreshUI() {
        let image = NSImage(systemSymbolName: assertions.ids.isEmpty ? "cup.and.saucer" : "cup.and.saucer.fill",
                            accessibilityDescription: "Keep Awake")
        image?.isTemplate = true
        let title = KeepAwakePrefs.showCountdown && session?.remaining != nil
            ? " " + Self.countdown(session?.remaining ?? 0) : ""
        item?.button?.title = title
        StatusItemSpacing.setImage(image, of: item, flush: title.isEmpty)
        item?.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        item?.button?.toolTip = "Keep Awake — \(statusText ?? "")"
        item?.button?.setAccessibilityLabel("Keep Awake — \(statusText ?? "")")
        menuStatus?.title = statusText ?? "Keep Awake"
        settingsView?.sync()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        tick()
        menu.removeAllItems()
        for entry in sessionMenuItems() { menu.addItem(entry) }
    }

    private func action(_ title: String, _ selector: Selector, enabled: Bool = true) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        entry.isEnabled = enabled
        return entry
    }

    private func sessionMenuItems() -> [NSMenuItem] {
        let status = NSMenuItem(title: statusText ?? "Keep Awake", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menuStatus = status
        var entries = [status, NSMenuItem.separator(),
                       action(isActive ? "Stop Keep Awake" : "Start Keep Awake", #selector(toggleSession),
                              enabled: isActive || KeepAwakePrefs.hasProtection)]
        let durationMenu = NSMenu()
        durationMenu.autoenablesItems = false
        for minutes in KeepAwakePrefs.durations {
            let title = minutes == 0 && isActive ? "Keep Awake Indefinitely" : KeepAwakePrefs.durationLabel(minutes)
            let entry = action(title, #selector(selectDuration(_:)),
                               enabled: KeepAwakePrefs.hasProtection)
            entry.representedObject = minutes
            durationMenu.addItem(entry)
        }
        durationMenu.addItem(.separator())
        durationMenu.addItem(action("Custom Duration or End Time…", #selector(showSessionPanel),
                                    enabled: KeepAwakePrefs.hasProtection))
        let durations = NSMenuItem(title: isActive ? "Stop In" : "Start For", action: nil, keyEquivalent: "")
        durations.submenu = durationMenu
        entries += [durations, .separator()]
        let system = action("Prevent System Sleep", #selector(toggleSystem))
        system.state = KeepAwakePrefs.preventSystemSleep ? .on : .off
        let display = action("Prevent Display Sleep", #selector(toggleDisplay))
        display.state = KeepAwakePrefs.preventDisplaySleep ? .on : .off
        let agents = action("While Claude Code or Codex Works", #selector(toggleAgentMode))
        agents.state = KeepAwakePrefs.whileAgentsWork ? .on : .off
        entries += [system, display, agents, .separator(), action("Keep Awake Settings…", #selector(openSettings))]
        return entries
    }

    func menuItems() -> [NSMenuItem] {
        let controls = NSMenuItem(title: "Session and Duration", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        controls.submenu = menu
        return [action(isActive ? "Stop Keep Awake" : "Start Keep Awake", #selector(toggleSession),
                       enabled: isActive || KeepAwakePrefs.hasProtection), controls]
    }

    @objc func toggleSession() {
        guard isRunning else { return }
        if isActive { endSession() } else { beginDefaultSession() }
    }

    private func beginDefaultSession() {
        let minutes = KeepAwakePrefs.defaultMinutes
        _ = beginSession(duration: minutes == 0 ? nil : Double(minutes * 60))
    }

    @objc private func selectDuration(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        _ = beginSession(duration: minutes == 0 ? nil : Double(minutes * 60))
    }
    @objc private func toggleSystem() {
        guard isRunning else { return }
        KeepAwakePrefs.preventSystemSleep.toggle()
        settingsChanged(reapplyProtection: true)
    }
    @objc private func toggleDisplay() {
        guard isRunning else { return }
        KeepAwakePrefs.preventDisplaySleep.toggle()
        settingsChanged(reapplyProtection: true)
    }
    @objc private func toggleAgentMode() {
        guard isRunning else { return }
        KeepAwakePrefs.whileAgentsWork.toggle()
        settingsChanged(agentMode: true)
    }
    @objc private func openSettings() { SettingsWindowController.shared.show(page: id) }

    @objc func showSessionPanel() {
        guard isRunning else { return }
        if sessionPanel == nil { sessionPanel = KeepAwakeSessionPanel(module: self) }
        sessionPanel?.show()
    }

    func makeSettingsView() -> NSView {
        let view = KeepAwakeSettingsView(module: self)
        settingsView = view
        return view
    }

    #if DEBUG
    var hasResources: Bool {
        !assertions.ids.isEmpty || timer != nil || wakeObserver != nil || spacingObserver != nil || item != nil || sessionPanel != nil
            || agentMonitor != nil || isAgentHold
    }
    var debugAssertionIDs: [KeepAwakeAssertions.Kind: UInt32] { assertions.ids }
    var debugHasTimer: Bool { timer != nil }
    var debugPanel: NSWindow? { sessionPanel }
    var debugStatusItem: NSStatusItem? { item }
    var debugAgentMonitor: AgentActivityMonitor? { agentMonitor }
    #endif
}
