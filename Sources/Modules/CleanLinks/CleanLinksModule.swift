import Cocoa
import Carbon.HIToolbox

enum CleanLinksPrefs {
    // MARK: Cleaning
    @Pref("cleanlinks.trackingParameters", default: true) static var trackingParameters: Bool
    @Pref("cleanlinks.referralTags", default: true) static var referralTags: Bool
    @Pref("cleanlinks.pathTracking", default: true) static var pathTracking: Bool
    @Pref("cleanlinks.redirects", default: true) static var redirects: Bool
    @Pref("cleanlinks.amp", default: true) static var amp: Bool
    @Pref("cleanlinks.textFragments", default: true) static var textFragments: Bool
    @Pref("cleanlinks.shortLinks", default: true) static var shortLinks: Bool

    // MARK: Feedback
    @Pref("cleanlinks.showNotice", default: true) static var showNotice: Bool
    @Pref("cleanlinks.pasteOriginalShortcut", default: "default") private static var pasteOriginalRaw: String

    /// Pastes the link as it was copied. Optional (an empty string means the user cleared it),
    /// ⌃⌘V by default: ⌥⌘V is the Finder's “Move Item Here”, ⌥⇧⌘V “Paste and Match Style”.
    static var pasteOriginalShortcut: Shortcut? {
        get {
            if pasteOriginalRaw == "default" { return Shortcut(kVK_ANSI_V, [.control, .command]) }
            return Shortcut(stored: pasteOriginalRaw)
        }
        set { pasteOriginalRaw = newValue?.stored ?? "" }
    }

    // MARK: Lists
    @Pref("cleanlinks.excludedApps", default: []) static var excludedApps: [String]
    @Pref("cleanlinks.allowedSites", default: []) static var allowedSites: [String]
    @Pref("cleanlinks.keepParameters", default: []) static var keepParameters: [String]
    @Pref("cleanlinks.removeParameters", default: []) static var removeParameters: [String]
    @Pref("cleanlinks.shortenerDomains", default: []) static var shortenerDomains: [String]

    // MARK: Statistics
    @Pref("cleanlinks.stats.links", default: 0) static var linksCleaned: Int
    @Pref("cleanlinks.stats.trackers", default: 0) static var trackersRemoved: Int
    /// Seconds since 1970; 0 until the module first starts.
    @Pref("cleanlinks.stats.since", default: 0.0) static var statsSince: Double

    // MARK: Rules (seconds since 1970, 0 for never)
    @Pref("cleanlinks.rules.checkedAt", default: 0.0) static var rulesCheckedAt: Double
    @Pref("cleanlinks.rules.attemptedAt", default: 0.0) static var rulesAttemptedAt: Double
    @Pref("cleanlinks.rules.updatedAt", default: 0.0) static var rulesUpdatedAt: Double
    @Pref("cleanlinks.rules.hash", default: "") static var rulesHash: String
    @Pref("cleanlinks.rules.error", default: "") static var rulesError: String

    static var options: CleaningOptions {
        CleaningOptions(trackingParameters: trackingParameters, referralTags: referralTags, pathTracking: pathTracking,
                        redirects: redirects, amp: amp, textFragments: textFragments)
    }

    static var customRules: CustomRules {
        CustomRules(allowedSites: allowedSites.compactMap(DomainList.normalize),
                    keep: keepParameters.compactMap(ParameterRule.init),
                    remove: removeParameters.compactMap(ParameterRule.init))
    }
}

/// Clean Links: when the pasteboard holds a single web link, replaces it with the same link
/// minus its trackers (ClearURLs rules plus the user's), unwrapped from redirects and AMP and
/// expanded from short links. A shortcut pastes the original instead.
///
/// See `ClipboardWatcher` for how copies are noticed — through Tinycast's history when it runs,
/// so that history keeps both versions.
final class CleanLinksModule: Module {
    let id = "cleanlinks"
    let name = "Clean Links"
    let summary = "Removes trackers from the links you copy."
    let symbolName = "link"
    let tint = NSColor.systemGreen

    /// Posted on the main thread when the statistics, the rules or the watching mode change;
    /// the settings page listens. Kept off `moduleStateDidChange`, which rebuilds more.
    static let didChange = Notification.Name("mdeck.cleanlinks.didChange")

    private(set) var isRunning = false
    let rules = RulesStore()
    private var watcher: ClipboardWatcher?
    private var resolver: ShortLinkResolver?
    private var hud: CleanLinksHUD?
    private var hotkey: HotkeyManager.ID?
    private(set) var hotkeyRefused = false
    private var updateTimer: Timer?
    private var pendingRestore: DispatchWorkItem?
    private let queue = DispatchQueue(label: "mdeck.cleanlinks", qos: .userInitiated)
    private var generation = 0
    /// The last pasteboard state looked at, so a signal for an unchanged pasteboard is free.
    private var lastSeenChangeCount = 0

    /// The cleaning still on the pasteboard: what “Paste original” pastes, and what it puts back.
    private struct Cleaned {
        let original: String
        var changeCount: Int
        let representations: [(NSPasteboard.PasteboardType, Data)]
    }
    private var lastCleaned: Cleaned?

    init() {
        rules.onChange = { [weak self] in
            guard let self, self.isRunning else { return }
            self.notifyChange()
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        if CleanLinksPrefs.statsSince == 0 { CleanLinksPrefs.statsSince = Date().timeIntervalSince1970 }
        // What is on the pasteboard already was copied before: leave it.
        lastSeenChangeCount = NSPasteboard.general.changeCount
        rules.load()
        let watcher = ClipboardWatcher(onSignal: { [weak self] in self?.pasteboardMayHaveChanged() },
                                       onModeChange: { [weak self] in self?.notifyChange(statusToo: true) })
        self.watcher = watcher
        watcher.start()
        registerHotkey()
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.updateRulesIfDue() }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
        updateRulesIfDue()
    }

    func stop() {
        guard isRunning else { return }
        // Never leave the original on the pasteboard because we stopped mid-paste.
        if let restore = pendingRestore { restore.perform(); restore.cancel() }
        pendingRestore = nil
        isRunning = false
        generation += 1
        watcher?.stop()
        watcher = nil
        HotkeyManager.shared.unregister(hotkey)
        hotkey = nil
        updateTimer?.invalidate()
        updateTimer = nil
        resolver?.cancelAll()
        resolver = nil
        hud?.dispose()
        hud = nil
        queue.sync {}
        rules.unload()
        lastCleaned = nil
    }

    var needsAccessibility: Bool { CleanLinksPrefs.pasteOriginalShortcut != nil }

    func accessibilityDidChange() { notifyChange() }

    var watchMode: ClipboardWatcher.Mode { watcher?.mode ?? .stopped }

    var statusText: String? {
        switch watchMode {
        case .tinycast: return "Watching copies through Tinycast"
        case .polling: return "Watching the clipboard"
        case .stopped: return nil
        }
    }

    private func notifyChange(statusToo: Bool = false) {
        NotificationCenter.default.post(name: Self.didChange, object: self)
        if statusToo { ModuleManager.shared.noteChange() }
    }

    // MARK: - Cleaning

    private func pasteboardMayHaveChanged() {
        guard isRunning else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastSeenChangeCount else { return }
        lastSeenChangeCount = pasteboard.changeCount
        guard let copy = PasteboardLink.read(from: pasteboard), let compiled = rules.rules else { return }
        // The pasteboard does not say who copied: the app in front is the best guess.
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           CleanLinksPrefs.excludedApps.contains(front) { return }

        let cleaner = LinkCleaner(rules: compiled, options: CleanLinksPrefs.options, custom: CleanLinksPrefs.customRules)
        let shorteners = CleanLinksPrefs.shortLinks ? CleanLinksPrefs.shortenerDomains.compactMap(DomainList.normalize) : nil
        let token = generation
        queue.async { [weak self] in
            let report = cleaner.clean(copy.link)
            if let shorteners, let host = LinkCleaner.host(of: report.url),
               ShortLinkResolver.isShortLink(host: host, extra: shorteners), let url = URL(string: report.url) {
                DispatchQueue.main.async { self?.expand(url, report, copy, cleaner, token) }
                return
            }
            DispatchQueue.main.async { self?.apply(report, to: copy, token) }
        }
    }

    private func expand(_ url: URL, _ report: CleaningReport, _ copy: PasteboardLink, _ cleaner: LinkCleaner, _ token: Int) {
        guard isRunning, generation == token else { return }
        let resolver = self.resolver ?? ShortLinkResolver()
        self.resolver = resolver
        resolver.resolve(url) { [weak self] final in
            self?.queue.async {
                var combined = report
                if let final {
                    var expanded = cleaner.clean(final.absoluteString)
                    expanded.expanded = true
                    combined.absorb(expanded)
                }
                DispatchQueue.main.async { self?.apply(combined, to: copy, token) }
            }
        }
    }

    private func apply(_ report: CleaningReport, to copy: PasteboardLink, _ token: Int) {
        guard isRunning, generation == token, report.changed, report.url != copy.link else { return }
        let pasteboard = NSPasteboard.general
        // Something else was copied while this one was being cleaned: it wins.
        guard pasteboard.changeCount == copy.changeCount else { return }
        let representations = copy.replacing(with: report.url)
        let count = PasteboardLink.write(representations, to: pasteboard)
        lastSeenChangeCount = count
        lastCleaned = Cleaned(original: copy.link, changeCount: count, representations: representations)

        CleanLinksPrefs.linksCleaned += 1
        CleanLinksPrefs.trackersRemoved += report.trackersRemoved
        notifyChange()

        guard CleanLinksPrefs.showNotice else { return }
        var detail = report.summary
        if let shortcut = CleanLinksPrefs.pasteOriginalShortcut, hotkey != nil {
            detail += " · \(shortcut.display) pastes the original"
        }
        if hud == nil { hud = CleanLinksHUD() }
        hud?.show(title: "Link cleaned", detail: detail)
    }

    // MARK: - Paste original

    func registerHotkey() {
        HotkeyManager.shared.unregister(hotkey)
        hotkey = nil
        hotkeyRefused = false
        guard isRunning, let shortcut = CleanLinksPrefs.pasteOriginalShortcut else { return notifyChange() }
        hotkey = HotkeyManager.shared.register(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers) { [weak self] in
            self?.pasteOriginal()
        }
        hotkeyRefused = hotkey == nil
        notifyChange()
    }

    func suspendHotkey() {
        HotkeyManager.shared.unregister(hotkey)
        hotkey = nil
    }

    /// Pastes the link as it was copied into the frontmost app, then puts the clean one back.
    /// Only while the clean link is still what the pasteboard holds: after another copy there
    /// is no “original” to speak of.
    private func pasteOriginal() {
        let pasteboard = NSPasteboard.general
        guard isRunning, pendingRestore == nil, let cleaned = lastCleaned,
              pasteboard.changeCount == cleaned.changeCount else { return NSSound.beep() }
        guard Permissions.isAccessibilityTrusted else {
            NSSound.beep()
            if hud == nil { hud = CleanLinksHUD() }
            hud?.show(title: "Can’t paste the original link",
                      detail: "Clean Links needs the Accessibility permission to paste.")
            return
        }
        // Marked transient: clipboard histories (Tinycast included) skip it, and so do we.
        let transient = PasteboardLink.write([
            (.string, Data(cleaned.original.utf8)),
            (.URL, Data(cleaned.original.utf8)),
            (NSPasteboard.PasteboardType("org.nspasteboard.TransientType"), Data()),
        ], to: pasteboard)
        lastSeenChangeCount = transient
        Self.postCommandV()

        // The target app reads the pasteboard while handling ⌘V; give it time before restoring.
        let restore = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRestore = nil
            guard pasteboard.changeCount == transient else { return }
            let count = PasteboardLink.write(cleaned.representations, to: pasteboard)
            self.lastSeenChangeCount = count
            self.lastCleaned?.changeCount = count
        }
        pendingRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: restore)
    }

    /// ⌘V from a private event source, so the ⌃ still held for the shortcut does not leak in.
    private static func postCommandV() {
        let source = CGEventSource(stateID: .privateState)
        let key = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Rules and statistics

    private func updateRulesIfDue() {
        guard isRunning, rules.isUpdateDue else { return }
        rules.update()
    }

    /// From the settings page's “Update Now”.
    func updateRulesNow() {
        guard isRunning else { return }
        rules.update()
    }

    func resetStatistics() {
        CleanLinksPrefs.linksCleaned = 0
        CleanLinksPrefs.trackersRemoved = 0
        CleanLinksPrefs.statsSince = Date().timeIntervalSince1970
        notifyChange()
    }

    func makeSettingsView() -> NSView {
        CleanLinksSettingsView(module: self)
    }

    #if DEBUG
    var hasResources: Bool {
        (watcher?.hasResources ?? false) || hotkey != nil || updateTimer != nil || hud != nil
            || resolver != nil || rules.hasPendingWork || rules.rules != nil || pendingRestore != nil
    }
    var debugHasHotkey: Bool { hotkey != nil }
    #endif
}
