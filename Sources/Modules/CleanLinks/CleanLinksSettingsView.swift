import Cocoa

/// Clean Links' page in the settings window. Built once; state changes only update values,
/// enabled states and fixed-height labels, so the page never reflows.
final class CleanLinksSettingsView: NSView {
    private weak var module: CleanLinksModule?
    private var shortcut: ShortcutRecorder!
    private var statusLabel: NSTextField!
    private var statsLabel: NSTextField!
    private var rulesLabel: NSTextField!
    private var rulesDetail: NSTextField!
    private var conditionalRows: [SettingsRow] = []

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        return formatter
    }()

    init(module: CleanLinksModule) {
        self.module = module
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        sync()
        NotificationCenter.default.addObserver(self, selector: #selector(sync), name: .moduleStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sync), name: CleanLinksModule.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func toggle(_ value: Bool, _ set: @escaping (Bool) -> Void) -> ActionSwitch {
        ActionSwitch(isOn: value, onChange: set)
    }

    private func label(_ text: String = " ") -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func build() {
        shortcut = ShortcutRecorder()
        shortcut.allowsEmpty = true
        shortcut.shortcut = CleanLinksPrefs.pasteOriginalShortcut
        shortcut.isTaken = { $0 == AlttyPrefs.appShortcut || $0 == AlttyPrefs.windowShortcut }
        shortcut.onRecordingChange = { [weak self] recording in
            recording ? self?.module?.suspendHotkey() : self?.module?.registerHotkey()
        }
        shortcut.onChange = { [weak self] value in
            CleanLinksPrefs.pasteOriginalShortcut = value
            self?.module?.registerHotkey()
            if value != nil, self?.module?.isRunning == true, !Permissions.isAccessibilityTrusted {
                Permissions.requestAccessibility()
            }
            AccessibilityWatcher.shared.reevaluate()
            self?.sync()
        }

        let permissionButton = NSButton(title: "Request Permission…", target: self, action: #selector(requestPermission))
        permissionButton.bezelStyle = .rounded
        let permissionRow = SettingsRow(NSTextField(labelWithString: "Accessibility permission"), permissionButton, disabledReason: {
            if CleanLinksPrefs.pasteOriginalShortcut == nil { return "Without a shortcut, Clean Links needs no permission." }
            return Permissions.isAccessibilityTrusted ? "Granted — nothing left to request." : nil
        }, infoPlacement: .beforeControl)

        let resetButton = NSButton(title: "Reset", target: self, action: #selector(resetStatistics))
        resetButton.bezelStyle = .rounded
        statsLabel = NSTextField(labelWithString: " ")
        statsLabel.lineBreakMode = .byTruncatingTail

        let updateButton = NSButton(title: "Update Now", target: self, action: #selector(updateRules))
        updateButton.bezelStyle = .rounded
        rulesLabel = NSTextField(labelWithString: " ")
        rulesLabel.lineBreakMode = .byTruncatingTail
        let updateRow = SettingsRow(rulesLabel, updateButton, disabledReason: { [weak self] in
            guard let module = self?.module, module.isRunning else { return "Turn Clean Links on first." }
            return module.rules.isUpdating ? "Already checking for new rules." : nil
        }, infoPlacement: .beforeControl)
        rulesDetail = label()
        statusLabel = label()
        conditionalRows = [permissionRow, updateRow]

        let exclusions = AppListView(
            ids: CleanLinksPrefs.excludedApps, placeholder: "No excluded apps",
            addHelp: "Add an app whose copies are left alone", removeHelp: "Remove the selected apps",
            choosePrompt: "Exclude") { CleanLinksPrefs.excludedApps = $0 }

        let rows = RowsView([
            sectionHeader("CLEANING"),
            SettingsRow("Remove tracking parameters", toggle(CleanLinksPrefs.trackingParameters) { CleanLinksPrefs.trackingParameters = $0 },
                        help: "utm_source, fbclid, gclid, YouTube’s si… ClearURLs’ rules for every site, plus those of the 200-odd sites it knows."),
            SettingsRow("Remove affiliate and referral tags", toggle(CleanLinksPrefs.referralTags) { CleanLinksPrefs.referralTags = $0 },
                        help: "Amazon’s tag=, ref=… Whoever shared the link no longer earns a commission on it."),
            SettingsRow("Remove tracking from the link path", toggle(CleanLinksPrefs.pathTracking) { CleanLinksPrefs.pathTracking = $0 },
                        help: "Tracking written into the address itself, such as Amazon’s /ref=sr_1_1."),
            SettingsRow("Unwrap redirect links", toggle(CleanLinksPrefs.redirects) { CleanLinksPrefs.redirects = $0 },
                        help: "google.com/url?q=…, l.facebook.com, Outlook Safe Links, Slack… become the link they lead to. The destination is read from the link itself: nothing is sent anywhere."),
            SettingsRow("Replace AMP links with the original page", toggle(CleanLinksPrefs.amp) { CleanLinksPrefs.amp = $0 },
                        help: "google.com/amp/s/… and *.cdn.ampproject.org/… become the publisher’s own address."),
            SettingsRow("Remove text highlight fragments", toggle(CleanLinksPrefs.textFragments) { CleanLinksPrefs.textFragments = $0 },
                        help: "#:~:text=…, added by “Copy Link to Highlight”. An ordinary #anchor is kept."),
            SettingsRow("Expand short links", toggle(CleanLinksPrefs.shortLinks) { CleanLinksPrefs.shortLinks = $0 },
                        help: "bit.ly, t.co, amzn.to… are followed to where they lead, then cleaned. This sends one request to the shortening service, which learns that the link was opened; only the response headers are read. It takes up to 3 seconds; on failure the link is left as it was."),
            SettingsRow.separator(),
            sectionHeader("FEEDBACK"),
            SettingsRow("Show a notice when a link is cleaned", toggle(CleanLinksPrefs.showNotice) { CleanLinksPrefs.showNotice = $0 },
                        help: "A short notice at the bottom of the screen saying what was removed. It never takes focus."),
            SettingsRow("Paste the original link", shortcut,
                        help: "Pastes the link as it was copied, into the app in front, and keeps the clean one in the clipboard. Works while the cleaned link is still in the clipboard.\n\nSends ⌘V, which needs the Accessibility permission. Press Delete while recording to remove the shortcut."),
            permissionRow,
            SettingsRow.separator(),
            sectionHeader("EXCLUDED APPS"),
            exclusions,
            caption("Links copied while one of these apps is in front are left alone. Copies marked as secret by password managers, and pastes from clipboard histories, always are."),
            SettingsRow.separator(),
            sectionHeader("YOUR RULES"),
            makeRuleLists(),
            caption("Sites cover their subdomains. Parameters are names, with * as a wildcard (utm_*), optionally limited to a site (github.com:ref). Kept parameters win over every removal."),
            SettingsRow.separator(),
            sectionHeader("STATISTICS"),
            SettingsRow(statsLabel, resetButton),
            SettingsRow.separator(),
            sectionHeader("RULES"),
            updateRow,
            rulesDetail,
            caption("From ClearURLs (LGPL-3.0), checked weekly on rules2.clearurls.xyz and verified against their published checksum, with a few additions of mdeck’s own (x.com, LinkedIn, Outlook Safe Links…)."),
            SettingsRow.separator(),
            sectionHeader("WATCHING"),
            statusLabel,
            caption("While Tinycast runs with its clipboard history on, Clean Links waits for it to save each copy before cleaning, so its history keeps both the original and the clean link, and nothing polls the clipboard. Links Tinycast does not save (apps it ignores) are then left alone. Otherwise the clipboard is checked twice a second."),
        ])
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// The four lists, two by two.
    private func makeRuleLists() -> NSView {
        let parameter: (String) -> String? = { ParameterRule($0)?.entry }
        let lists = [
            labeled("Allowed sites", StringListView(
                entries: CleanLinksPrefs.allowedSites, placeholder: "Every site is cleaned",
                addHelp: "Add a site whose links are never changed", removeHelp: "Remove the selected sites",
                normalize: DomainList.normalize) { CleanLinksPrefs.allowedSites = $0 }),
            labeled("Parameters to keep", StringListView(
                entries: CleanLinksPrefs.keepParameters, placeholder: "None",
                addHelp: "Add a parameter that is never removed", removeHelp: "Remove the selected parameters",
                normalize: parameter) { CleanLinksPrefs.keepParameters = $0 }),
            labeled("Parameters to remove", StringListView(
                entries: CleanLinksPrefs.removeParameters, placeholder: "None",
                addHelp: "Add a parameter to remove", removeHelp: "Remove the selected parameters",
                normalize: parameter) { CleanLinksPrefs.removeParameters = $0 }),
            labeled("Short link domains", StringListView(
                entries: CleanLinksPrefs.shortenerDomains, placeholder: "Built-in list only",
                addHelp: "Add a link shortener to expand", removeHelp: "Remove the selected domains",
                normalize: DomainList.normalize) { CleanLinksPrefs.shortenerDomains = $0 }),
        ]
        let grid = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        lists.forEach(grid.addSubview)
        let (a, b, c, d) = (lists[0], lists[1], lists[2], lists[3])
        NSLayoutConstraint.activate([
            a.topAnchor.constraint(equalTo: grid.topAnchor), b.topAnchor.constraint(equalTo: grid.topAnchor),
            a.leadingAnchor.constraint(equalTo: grid.leadingAnchor), c.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            b.trailingAnchor.constraint(equalTo: grid.trailingAnchor), d.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            b.leadingAnchor.constraint(equalTo: a.trailingAnchor, constant: 16),
            d.leadingAnchor.constraint(equalTo: c.trailingAnchor, constant: 16),
            a.widthAnchor.constraint(equalTo: b.widthAnchor), c.widthAnchor.constraint(equalTo: d.widthAnchor),
            a.widthAnchor.constraint(equalTo: c.widthAnchor),
            c.topAnchor.constraint(equalTo: a.bottomAnchor, constant: 12),
            d.topAnchor.constraint(equalTo: b.bottomAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: c.bottomAnchor),
        ])
        return grid
    }

    private func labeled(_ title: String, _ list: StringListView) -> NSView {
        let label = NSTextField(labelWithString: title)
        return RowsView([label, list], spacing: 4)
    }

    @objc private func sync() {
        let links = CleanLinksPrefs.linksCleaned
        let trackers = CleanLinksPrefs.trackersRemoved
        let since = CleanLinksPrefs.statsSince
        var stats = "\(links) link\(links == 1 ? "" : "s") cleaned, \(trackers) tracker\(trackers == 1 ? "" : "s") removed"
        if since > 0 { stats += " since \(Self.dateFormatter.string(from: Date(timeIntervalSince1970: since)))" }
        statsLabel.stringValue = stats

        rulesLabel.stringValue = rulesSummary
        rulesDetail.stringValue = rulesStatus

        if let module, module.isRunning {
            var status = module.statusText ?? " "
            if module.hotkeyRefused, let shortcut = CleanLinksPrefs.pasteOriginalShortcut {
                status += " · \(shortcut.display) is taken by another app"
            }
            statusLabel.stringValue = status
        } else {
            statusLabel.stringValue = "Clean Links is off."
        }
        if !shortcut.isRecording { shortcut.shortcut = CleanLinksPrefs.pasteOriginalShortcut }
        conditionalRows.forEach { $0.refresh() }
    }

    private var rulesSummary: String {
        guard let module, module.isRunning, let rules = module.rules.rules else {
            let updated = CleanLinksPrefs.rulesUpdatedAt
            if updated > 0, FileManager.default.fileExists(atPath: RulesStore.downloadedFile.path) {
                return "ClearURLs rules downloaded \(Self.dateFormatter.string(from: Date(timeIntervalSince1970: updated)))"
            }
            return "Built-in ClearURLs rules"
        }
        var text = "ClearURLs rules for \(rules.siteCount) sites"
        if module.rules.source == .downloaded, CleanLinksPrefs.rulesUpdatedAt > 0 {
            text += ", downloaded \(Self.dateFormatter.string(from: Date(timeIntervalSince1970: CleanLinksPrefs.rulesUpdatedAt)))"
        } else {
            text += ", built in"
        }
        return text
    }

    private var rulesStatus: String {
        if module?.rules.isUpdating == true { return "Checking for new rules…" }
        if !CleanLinksPrefs.rulesError.isEmpty { return "The last check failed: \(CleanLinksPrefs.rulesError)" }
        let checked = CleanLinksPrefs.rulesCheckedAt
        guard checked > 0 else { return "Not checked for updates yet." }
        let ago = Self.relativeFormatter.localizedString(for: Date(timeIntervalSince1970: checked), relativeTo: Date())
        return "Checked for updates \(ago)."
    }

    @objc private func requestPermission() { Permissions.resetAndRequest() }

    @objc private func resetStatistics() { module?.resetStatistics() }

    @objc private func updateRules() { module?.updateRulesNow() }
}
