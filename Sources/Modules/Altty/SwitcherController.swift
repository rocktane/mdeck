import Cocoa
import Carbon.HIToolbox

/// Session state machine: trigger pressed → build list → (maybe) show panel → commit on release.
final class SwitcherController {
    static let shared = SwitcherController()

    /// What a session cycles through.
    enum Mode { case apps, windows }

    private let panel = SwitcherPanel()
    private var items: [SwitcherItem] = []
    private var selection = 0
    private var mode = Mode.apps
    /// The chord that opened the session; releasing its modifiers commits.
    private var activeShortcut = AlttyPrefs.appShortcut
    private var isSessionActive = false
    private var isPanelVisible = false
    private var releasePoll: Timer?
    private var showTimer: Timer?
    private var eventTap: SessionEventTap?
    /// Registered for the session only: a global hotkey is swallowed system-wide for as long
    /// as it exists, and ⌥Esc belongs to other apps outside a session.
    private var escapeHotkey: HotkeyManager.ID?
    /// The switching chords, released as a set when they change or the module stops.
    private var chordHotkeys: [HotkeyManager.ID] = []
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    private init() {
        panel.switcherView.onHover = { [weak self] i in self?.select(i) }
        panel.switcherView.onClick = { [weak self] i in self?.select(i); self?.commit() }
        // A slow app answered after the panel was already up.
        AXStateCache.shared.onChange = { [weak self] in
            guard let self, self.isSessionActive, self.mode == .apps else { return }
            self.rebuildInPlace()
        }
        // Same for a badge that changed since the cache was last read.
        DockBadges.shared.onChange = { [weak self] in
            guard let self, self.isSessionActive, self.mode == .apps else { return }
            self.rebuildInPlace()
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // Quitting or hiding from inside the switcher is asynchronous on the target app's side,
        // so the row is refreshed when macOS reports the change rather than right after asking.
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.isSessionActive else { return }
                self.rebuildInPlace()
            })
        }
        MRUTracker.shared.start()
        AXStateCache.shared.start()
        DockBadges.shared.start()
        registerHotkeys()
        refreshEventTap()
    }

    /// Leaves nothing behind: no hotkey, no tap, no observer — and the native ⌘Tab back.
    func stop() {
        guard isRunning else { return }
        cancel()
        isRunning = false
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        HotkeyManager.shared.unregister(chordHotkeys)
        chordHotkeys = []
        NativeSwitcher.restoreIfNeeded()
        eventTap = nil
        MRUTracker.shared.stop()
        AXStateCache.shared.stop()
        DockBadges.shared.stop()
    }

    // MARK: - Wiring

    /// Whether window cycling can work at all right now.
    static var canCycleWindows: Bool { AlttyPrefs.detectAcrossSpaces && Permissions.isAccessibilityTrusted }

    func registerHotkeys() {
        HotkeyManager.shared.unregister(chordHotkeys)
        chordHotkeys = []
        guard isRunning else { return }

        register(AlttyPrefs.appShortcut, label: "app shortcut") { [weak self] delta in
            self?.step(delta, mode: .apps)
        }
        if Self.canCycleWindows, let windows = AlttyPrefs.windowShortcut {
            register(windows, label: "window shortcut") { [weak self] delta in
                self?.step(delta, mode: .windows)
            }
        }

        let takesCommandTab = AlttyPrefs.appShortcut.isCommandTab
            || (Self.canCycleWindows && AlttyPrefs.windowShortcut?.isCommandTab == true)
        NativeSwitcher.setEnabled(!takesCommandTab)
    }

    /// Forward chord plus, when the chord leaves Shift free, the Shift variant for backwards.
    private func register(_ shortcut: Shortcut, label: String, handler: @escaping (Int) -> Void) {
        if let id = HotkeyManager.shared.register(keyCode: shortcut.keyCode,
                                                  modifiers: shortcut.carbonModifiers, handler: { handler(+1) }) {
            chordHotkeys.append(id)
        } else {
            FileHandle.standardError.write("altty: could not register \(label) \(shortcut.display) — another app owns it\n".data(using: .utf8)!)
        }
        if let reversed = shortcut.reversed,
           let id = HotkeyManager.shared.register(keyCode: reversed.keyCode,
                                                  modifiers: reversed.carbonModifiers, handler: { handler(-1) }) {
            chordHotkeys.append(id)
        }
    }

    /// While a `ShortcutRecorder` listens, nothing must intercept the chord — not our own
    /// hotkeys, not the native ⌘Tab. `registerHotkeys()` puts everything back.
    func suspendHotkeys() {
        guard isRunning else { return }
        cancel()
        HotkeyManager.shared.unregister(chordHotkeys)
        chordHotkeys = []
        NativeSwitcher.setEnabled(false)
    }

    func refreshEventTap() {
        guard isRunning, AlttyPrefs.detectAcrossSpaces, Permissions.isAccessibilityTrusted else {
            eventTap = nil
            return
        }
        guard eventTap == nil else { return }
        eventTap = SessionEventTap { [weak self] action in
            DispatchQueue.main.async { self?.perform(action) }
        }
    }

    private func perform(_ action: SessionEventTap.Action) {
        switch action {
        case .next:         step(+1, mode: mode)
        case .previous:     step(-1, mode: mode)
        case .cancel:       cancel()
        case .commit:       commit()
        case .quitSelected: if mode == .apps { selectedItem?.app.terminate() }
        case .hideSelected: if mode == .apps { selectedItem?.app.hide() }
        }
    }

    private var selectedItem: SwitcherItem? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    // MARK: - Session

    private func step(_ delta: Int, mode: Mode) {
        if !isSessionActive {
            begin(delta: delta, mode: mode)
        } else if mode == self.mode {
            select(((selection + delta) % items.count + items.count) % items.count)
            // A second press means the user is browsing, not quick-swapping: show now.
            showPanel()
        }
        // The other chord during a session is ignored rather than switching modes mid-way.
    }

    private func build(_ mode: Mode) -> [SwitcherItem] {
        mode == .apps ? AppList.build() : AppList.buildWindows()
    }

    private func begin(delta: Int, mode: Mode) {
        // Uses the cached badges now; a fresher answer updates the panel in place.
        DockBadges.shared.refresh()
        items = build(mode)
        guard !items.isEmpty else { return }

        self.mode = mode
        activeShortcut = mode == .apps ? AlttyPrefs.appShortcut : (AlttyPrefs.windowShortcut ?? AlttyPrefs.appShortcut)
        isSessionActive = true
        // items[0] is the current app (or window), so one step forward lands on the previous one.
        selection = items.count == 1 ? 0 : ((delta % items.count) + items.count) % items.count

        eventTap?.setEnabled(true)
        // Permission-free way to cancel a session. Full arrow/Escape handling needs the tap.
        escapeHotkey = HotkeyManager.shared.register(keyCode: UInt32(kVK_Escape),
                                                     modifiers: activeShortcut.carbonModifiers) { [weak self] in
            self?.cancel()
        }

        showTimer = Timer.scheduledTimer(withTimeInterval: AlttyPrefs.showDelay, repeats: false) { [weak self] _ in
            self?.showPanel()
        }
        let held = activeShortcut.modifiers
        releasePoll = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = NSEvent.modifierFlags.intersection(Shortcut.relevantModifiers)
            if !now.isSuperset(of: held) { self.commit() }
        }
    }

    private func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        selection = index
        panel.switcherView.selection = index
    }

    private func showPanel() {
        guard isSessionActive, !isPanelVisible, !items.isEmpty else { return }
        isPanelVisible = true
        panel.present(items: items, selection: selection, mode: mode)
    }

    /// After quitting or hiding an app from inside the switcher, or a late tier-2 answer,
    /// refresh the row without losing the session. A rebuild that changes nothing is dropped
    /// so the panel doesn't flicker.
    private func rebuildInPlace() {
        let previous = selectedItem
        let fresh = build(mode)
        guard !fresh.isEmpty else { return cancel() }
        guard fresh.count != items.count
                || !zip(fresh, items).allSatisfy({ $0.matches($1) && $0.notificationBadge == $1.notificationBadge })
        else { return }
        items = fresh
        if let previous, let i = items.firstIndex(where: { $0.matches(previous) }) {
            selection = i
        } else {
            selection = min(selection, items.count - 1)
        }
        if isPanelVisible { panel.present(items: items, selection: selection, mode: mode) }
    }

    private func commit() {
        guard isSessionActive else { return }
        let target = selectedItem
        end()
        guard let target, !target.app.isTerminated else { return }
        switch target.target {
        case .app:
            // Opening settings turns mdeck into a regular app. A background regular app's
            // plain activation request can leave focus unchanged, even when it returns true.
            // Explicitly transfer activation from the app the user is switching away from.
            if #available(macOS 14.0, *), let source = NSWorkspace.shared.frontmostApplication {
                target.app.activate(from: source, options: [.activateAllWindows])
            } else {
                target.app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
        case .window(let window, let isMinimized):
            WindowDetection.raise(window, of: target.app, isMinimized: isMinimized)
        }
        // MRUTracker observes actual activations; a request that fails must not reorder it.
    }

    private func cancel() {
        guard isSessionActive else { return }
        end()
    }

    private func end() {
        isSessionActive = false
        isPanelVisible = false
        showTimer?.invalidate(); showTimer = nil
        releasePoll?.invalidate(); releasePoll = nil
        eventTap?.setEnabled(false)
        HotkeyManager.shared.unregister(escapeHotkey); escapeHotkey = nil
        panel.dismiss()
        items = []
    }

    // MARK: - Debug helpers (compiled with `./build.sh --debug` only)

    #if DEBUG
    /// Shows the panel outside any hotkey session, so the layout can be inspected. Returns
    /// false when there is nothing to show.
    @discardableResult
    private func presentStandalone(mode: Mode = .apps) -> Bool {
        DockBadges.shared.refreshNow()
        items = build(mode)
        guard !items.isEmpty else { return false }
        if CommandLine.arguments.contains("--fake-states") {
            items = items.enumerated().map { i, item in
                var state = AppWindowState()
                switch i % 4 {
                case 0: state.normal = i + 1
                case 1: state.minimized = 2
                case 2: state.normal = 12
                default: state.normal = 1
                }
                return SwitcherItem(faking: state, hidden: i % 4 == 3, from: item)
            }
        }
        self.mode = mode
        selection = min(1, items.count - 1)
        isSessionActive = true
        showPanel()
        return true
    }

    /// `mdeck --altty-demo`: renders the panel for `duration`, then quits.
    func demo(duration: TimeInterval = 5) {
        guard presentStandalone() else { return NSApp.terminate(nil) }
        Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            self.end()
            NSApp.terminate(nil)
        }
    }

    /// `mdeck --altty-snapshot <path>`: captures our own panel
    /// (no Screen Recording needed for that).
    func snapshot(to path: String, mode: Mode = .apps) {
        guard presentStandalone(mode: mode) else {
            FileHandle.standardError.write("nothing to show\n".data(using: .utf8)!)
            return NSApp.terminate(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Debug.capture(window: self.panel, to: path)
            self.end()
            NSApp.terminate(nil)
        }
    }

    #endif
}

extension SwitcherItem {
    /// Same app, and same window when cycling windows — used to keep the selection across a
    /// rebuild.
    func matches(_ other: SwitcherItem) -> Bool {
        guard app.processIdentifier == other.app.processIdentifier else { return false }
        switch (target, other.target) {
        case (.app, .app): return true
        case (.window(let a, _), .window(let b, _)): return CFEqual(a, b)
        default: return false
        }
    }
}
