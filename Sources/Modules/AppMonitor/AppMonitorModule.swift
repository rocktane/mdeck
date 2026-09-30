import Cocoa

enum AppMonitorPrefs {
    @Pref("appmonitor.gauges", default: 2) static var gauges: Int
    @Pref("appmonitor.refreshInterval", default: 2.0) private static var storedInterval: Double
    static let intervals: [Double] = [1, 2, 5, 10]
    static var refreshInterval: Double {
        get { intervals.contains(storedInterval) ? storedInterval : 2 }
        set { storedInterval = intervals.contains(newValue) ? newValue : 2 }
    }
}

final class AppMonitorModule: NSObject, Module {
    let id = "appmonitor"
    let name = "App Monitor"
    let summary = "See CPU and memory usage grouped by application."
    let symbolName = "chart.bar.fill"
    let tint = NSColor.systemOrange
    private(set) var isRunning = false
    private(set) var snapshot = AppMonitorSnapshot()
    private var timer: Timer?
    private var item: NSStatusItem?
    private var panel: AppMonitorPanel?
    private var sampler: AppSampler?
    private let queue = DispatchQueue(label: "mdeck.appmonitor", qos: .utility)
    private var generation = 0
    private var sampling = false
    var hasResources: Bool { timer != nil || item != nil || panel != nil || sampler != nil || sampling }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        sampler = AppSampler()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item?.button?.target = self
        item?.button?.action = #selector(togglePanel)
        item?.button?.sendAction(on: .leftMouseDown)
        updateIcon()
        collect()
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard isRunning else { return }
        let timer = Timer(timeInterval: AppMonitorPrefs.refreshInterval, repeats: true) { [weak self] _ in self?.collect() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        timer?.invalidate(); timer = nil
        panel?.dispose(); panel = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        // Drain the serial queue so disabling leaves no collection running.
        queue.sync {}
        sampler = nil
        sampling = false
        snapshot = AppMonitorSnapshot()
    }

    private func collect() {
        guard isRunning, !sampling, let sampler else { return }
        sampling = true
        let token = generation
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleURL != nil && !$0.isTerminated }
        let groups = Dictionary(grouping: running, by: { $0.bundleURL!.path })
        let apps = groups.values.map { roots -> MonitoredApp in
            let app = roots[0]
            return MonitoredApp(url: app.bundleURL!, name: app.localizedName ?? app.bundleURL!.deletingPathExtension().lastPathComponent,
                                icon: app.icon ?? NSWorkspace.shared.icon(forFile: app.bundleURL!.path), roots: roots)
        }
        queue.async { [weak self] in
            let snapshot = sampler.sample(apps: apps)
            DispatchQueue.main.async {
                guard let self, self.isRunning, self.generation == token else { return }
                self.sampling = false
                self.snapshot = snapshot
                self.updateIcon()
                self.panel?.update(snapshot)
            }
        }
    }

    func updateIcon() {
        let mode = AppMonitorPrefs.gauges
        let values = mode == 0 ? [snapshot.cpu] : mode == 1 ? [snapshot.memory] : [snapshot.cpu, snapshot.memory]
        let image = NSImage(size: NSSize(width: values.count == 2 ? 21 : 11, height: 18), flipped: false) { rect in
            for (index, value) in values.enumerated() {
                let bar = NSRect(x: CGFloat(index * 10) + 1, y: 1, width: 7, height: 16)
                NSColor.labelColor.setStroke()
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).stroke()
                NSColor.labelColor.setFill()
                NSBezierPath(rect: NSRect(x: bar.minX + 1, y: 2, width: 5, height: 14 * CGFloat(min(1, max(0, value))))).fill()
            }
            return true
        }
        image.isTemplate = true
        item?.button?.image = image
        item?.button?.toolTip = String(format: "App Monitor · CPU %.0f%% · Memory %.0f%%", snapshot.cpu * 100, snapshot.memory * 100)
        item?.button?.setAccessibilityLabel("App Monitor")
    }

    #if DEBUG
    func debugShowPanel() {
        guard let button = item?.button else { return }
        if panel == nil { panel = AppMonitorPanel() }
        panel?.update(snapshot)
        panel?.show(under: button)
    }
    var debugPanel: NSWindow? { panel }
    func debugVerifyPanelBehavior() -> Bool {
        debugShowPanel()
        guard let button = item?.button, let panel else { return false }
        let sizing = panel.debugVerifySizing()
        let excluded = panel.debugVerifyStatusClickExclusion()
        button.performClick(nil)
        let hidden = !panel.isVisible
        button.performClick(nil)
        return sizing && excluded && hidden && panel.isVisible
    }
    func debugVerifyPinning() -> Bool {
        debugShowPanel()
        let result = panel?.debugVerifyPinning() ?? false
        debugShowPanel()
        return result
    }
    #endif

    @objc private func togglePanel() {
        if panel?.isVisible == true { panel?.close(); return }
        guard let button = item?.button else { return }
        if panel == nil { panel = AppMonitorPanel() }
        panel?.update(snapshot)
        panel?.show(under: button)
    }

    func makeSettingsView() -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["CPU", "Memory", "CPU and Memory"])
        popup.selectItem(at: min(2, max(0, AppMonitorPrefs.gauges)))
        popup.target = self
        popup.action = #selector(gaugesChanged(_:))
        let refresh = NSPopUpButton(frame: .zero, pullsDown: false)
        refresh.addItems(withTitles: AppMonitorPrefs.intervals.map { "Every \(Int($0)) \($0 == 1 ? "second" : "seconds")" })
        refresh.selectItem(at: AppMonitorPrefs.intervals.firstIndex(of: AppMonitorPrefs.refreshInterval) ?? 1)
        refresh.target = self
        refresh.action = #selector(refreshChanged(_:))
        return RowsView([
            sectionHeader("MENU BAR"),
            SettingsRow("Show gauges", popup),
            SettingsRow("Refresh interval", refresh),
            caption("CPU is a percentage of the Mac’s total capacity. Memory lists each application’s physical footprint, including its associated processes. Pin the panel to keep it open."),
        ])
    }

    @objc private func refreshChanged(_ sender: NSPopUpButton) {
        guard AppMonitorPrefs.intervals.indices.contains(sender.indexOfSelectedItem) else { return }
        AppMonitorPrefs.refreshInterval = AppMonitorPrefs.intervals[sender.indexOfSelectedItem]
        restartTimer()
    }

    @objc private func gaugesChanged(_ sender: NSPopUpButton) {
        AppMonitorPrefs.gauges = sender.indexOfSelectedItem
        if isRunning { updateIcon() }
    }
}
