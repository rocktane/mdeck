import Cocoa

/// Altty's page in the settings window.
///
/// The layout is built once and never rebuilt. Toggling a setting only ever changes a
/// control's value, its enabled state, or the text of a fixed-height label — nothing
/// appears, disappears or resizes, so the page never shifts under the pointer.
final class AlttySettingsView: NSView {
    private var appShortcut: ShortcutRecorder!
    private var windowShortcut: ShortcutRecorder!
    /// Rows that can be greyed out; `sync()` asks each to re-evaluate its reason.
    private var conditionalRows: [SettingsRow] = []
    private var showWindowless: ActionSwitch!
    private var showHidden: ActionSwitch!
    private var showMinimized: ActionSwitch!
    private var showFullscreen: ActionSwitch!
    private var showOtherScreens: ActionSwitch!
    private var showOtherSpaces: ActionSwitch!
    private var showAppNames: ActionSwitch!
    private var iconSize: NSSegmentedControl!
    private var showBadges: ActionSwitch!
    private var showNotificationBadges: ActionSwitch!
    private var badgeSize: NSSegmentedControl!
    /// The size and colour rows, greyed while the badges they style are not shown.
    private var badgeRows: [SettingsRow] = []
    private var detectAcrossSpaces: ActionSwitch!
    private var accessibilityButton: NSButton!
    private var statusLabel: NSTextField!

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        sync()
        // The settings window posts this when it comes back to the front: the permission may
        // have been granted in System Settings meanwhile.
        NotificationCenter.default.addObserver(self, selector: #selector(syncFromNotification),
                                               name: .moduleStateDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func syncFromNotification() { sync() }

    private func build() {
        // Recording a chord means nothing may intercept it — not our own hotkeys, not the
        // native ⌘Tab — so both recorders park the controller for the duration.
        let recording: (Bool) -> Void = { isRecording in
            isRecording ? SwitcherController.shared.suspendHotkeys()
                        : SwitcherController.shared.registerHotkeys()
        }
        appShortcut = ShortcutRecorder()
        appShortcut.onRecordingChange = recording
        appShortcut.isTaken = { $0 == AlttyPrefs.windowShortcut }
        appShortcut.onChange = { [weak self] shortcut in
            if let shortcut { AlttyPrefs.appShortcut = shortcut }
            SwitcherController.shared.registerHotkeys()
            ModuleManager.shared.noteChange()
            self?.sync()
        }
        windowShortcut = ShortcutRecorder()
        windowShortcut.allowsEmpty = true
        windowShortcut.onRecordingChange = recording
        windowShortcut.isTaken = { $0 == AlttyPrefs.appShortcut }
        windowShortcut.onChange = { [weak self] shortcut in
            AlttyPrefs.windowShortcut = shortcut
            SwitcherController.shared.registerHotkeys()
            self?.sync()
        }
        // Why a control that depends on all-Spaces detection is greyed out right now.
        let needsAX: () -> String? = {
            if !AlttyPrefs.detectAcrossSpaces {
                return "Turn on “Detect windows on all Spaces” first — this depends on it."
            }
            if !Permissions.isAccessibilityTrusted {
                return "Waiting for the Accessibility permission — use “Request Permission…” below."
            }
            return nil
        }
        let requestReason: () -> String? = {
            if !AlttyPrefs.detectAcrossSpaces {
                return "Nothing to request while “Detect windows on all Spaces” is off: Altty needs no permission."
            }
            if Permissions.isAccessibilityTrusted {
                return "The Accessibility permission is granted; there is nothing left to request."
            }
            return nil
        }

        showWindowless = ActionSwitch(isOn: AlttyPrefs.showWindowlessApps) { AlttyPrefs.showWindowlessApps = $0 }
        showHidden = ActionSwitch(isOn: AlttyPrefs.showHiddenApps) { AlttyPrefs.showHiddenApps = $0 }
        showMinimized = ActionSwitch(isOn: AlttyPrefs.showMinimizedApps) { AlttyPrefs.showMinimizedApps = $0 }
        showFullscreen = ActionSwitch(isOn: AlttyPrefs.showFullscreenApps) { AlttyPrefs.showFullscreenApps = $0 }
        showOtherScreens = ActionSwitch(isOn: AlttyPrefs.showOtherScreenApps) { AlttyPrefs.showOtherScreenApps = $0 }
        showOtherSpaces = ActionSwitch(isOn: AlttyPrefs.showOtherSpaceApps) { AlttyPrefs.showOtherSpaceApps = $0 }
        showAppNames = ActionSwitch(isOn: AlttyPrefs.showAppNames) { AlttyPrefs.showAppNames = $0 }
        showBadges = ActionSwitch(isOn: AlttyPrefs.showWindowBadges) { [weak self] on in
            AlttyPrefs.showWindowBadges = on
            self?.sync()
        }
        showNotificationBadges = ActionSwitch(isOn: AlttyPrefs.showNotificationBadges) { [weak self] on in
            AlttyPrefs.showNotificationBadges = on
            DockBadges.shared.refresh()
            self?.sync()
        }
        badgeSize = NSSegmentedControl(labels: BadgeSize.allCases.map(\.label), trackingMode: .selectOne,
                                       target: self, action: #selector(badgeSizeChanged(_:)))
        iconSize = NSSegmentedControl(labels: IconSize.allCases.map(\.label), trackingMode: .selectOne,
                                      target: self, action: #selector(iconSizeChanged(_:)))

        detectAcrossSpaces = ActionSwitch(isOn: AlttyPrefs.detectAcrossSpaces) { [weak self] on in
            AlttyPrefs.detectAcrossSpaces = on
            if on && !Permissions.isAccessibilityTrusted && SwitcherController.shared.isRunning {
                Permissions.requestAccessibility()
            }
            SwitcherController.shared.refreshEventTap()
            SwitcherController.shared.registerHotkeys()
            AXStateCache.shared.refreshAll()
            AccessibilityWatcher.shared.reevaluate()
            self?.sync()
        }

        accessibilityButton = NSButton(title: "Request Permission…", target: self,
                                       action: #selector(requestPermission))
        accessibilityButton.bezelStyle = .rounded

        // One line, full width, above the button; every state's text fits on it.
        statusLabel = NSTextField(labelWithString: " ")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let statusRow = SettingsRow(NSView(), accessibilityButton, disabledReason: requestReason,
                                    infoPlacement: .beforeControl)
        let windowShortcutRow = SettingsRow("Switch windows of the active app", windowShortcut,
                                            help: "Cycles through the windows of the frontmost app, like the native ⌘`.\n\nNeeds “Detect windows on all Spaces” and the Accessibility permission to bring a window forward. Press Delete while recording to remove it.",
                                            disabledReason: needsAX)
        let otherSpacesRow = SettingsRow("Show apps from other Spaces", showOtherSpaces, indented: true,
                                         help: "Apps whose windows all live on another desktop.\n\nTurn this off to keep accurate minimized detection while still restricting the switcher to the desktop you are on.",
                                         disabledReason: needsAX)
        let minimizedRow = SettingsRow("Show minimized apps", showMinimized, indented: true,
                                       help: "Apps whose windows are all minimized to the Dock.\n\nDepends on “Detect windows on all Spaces”: without it, a minimized window cannot be told apart from one sitting on another desktop.",
                                       disabledReason: needsAX)
        conditionalRows = [windowShortcutRow, otherSpacesRow, minimizedRow, statusRow]

        let notificationsOff: () -> String? = {
            AlttyPrefs.showNotificationBadges ? nil : "Turn on “Show notification badges” first."
        }
        let windowBadgesOff: () -> String? = {
            AlttyPrefs.showWindowBadges ? nil : "Turn on “Show window badges” first."
        }
        let badgeSizeRow = SettingsRow("Badge size", badgeSize,
                                       help: "One size for every badge. Large is the size of the native notification badge.",
                                       disabledReason: {
            AlttyPrefs.showNotificationBadges || AlttyPrefs.showWindowBadges
                ? nil : "No badge is shown: turn on notification or window badges first."
        })
        let notificationColorRow = colorRow("Notifications", value: AlttyPrefs.notificationBadgeColor,
                                            disabledReason: notificationsOff) { AlttyPrefs.notificationBadgeColor = $0 }
        let windowColorRow = colorRow("Window count", value: AlttyPrefs.windowBadgeColor,
                                      disabledReason: windowBadgesOff) { AlttyPrefs.windowBadgeColor = $0 }
        let stateColorRow = colorRow("Hidden / minimized", value: AlttyPrefs.stateBadgeColor,
                                     disabledReason: windowBadgesOff) { AlttyPrefs.stateBadgeColor = $0 }
        badgeRows = [badgeSizeRow, notificationColorRow, windowColorRow, stateColorRow]

        let exclusions = AppListView(
            ids: AlttyPrefs.excludedBundleIDs, placeholder: "No excluded apps",
            addHelp: "Add an app to exclude", removeHelp: "Remove the selected apps",
            choosePrompt: "Exclude") { AlttyPrefs.excludedBundleIDs = $0 }

        let rows = RowsView([
            sectionHeader("SHORTCUTS"),
            SettingsRow("Switch apps", appShortcut,
                        help: "Click, then type the chord. Hold its modifiers and press the key to cycle, add Shift to go back, release to switch."),
            windowShortcutRow,
            SettingsRow.separator(),
            sectionHeader("APPEARANCE"),
            SettingsRow("Icon size", iconSize),
            SettingsRow("Show app names", showAppNames,
                        help: "The name of the selected app, under its icon, like the native switcher. It sits in the panel’s bottom margin, so the panel keeps its size either way."),
            SettingsRow("Show notification badges", showNotificationBadges,
                        help: "The red badges the Dock shows on app icons (unread counts…), top right of each icon like the native switcher.\n\nRead from the Dock through the Accessibility permission: without it, no badge is shown."),
            SettingsRow("Show window badges", showBadges,
                        help: "On each icon: how many windows the app has (when more than one, bottom right), and a marker when they are all hidden or all minimized (bottom left)."),
            badgeSizeRow,
            sectionHeader("BADGE COLOURS"),
            notificationColorRow,
            windowColorRow,
            stateColorRow,
            SettingsRow.separator(),
            sectionHeader("SWITCHER LIST"),
            SettingsRow("Show apps with no open window", showWindowless,
                        help: "Apps still running with every window closed — an Electron app you quit the UI of."),
            SettingsRow("Show hidden apps (⌘H)", showHidden,
                        help: "Apps you sent away with ⌘H. The native switcher shows them."),
            SettingsRow("Show fullscreen apps", showFullscreen,
                        help: "Apps whose windows are all fullscreen, each on its own Space."),
            SettingsRow("Show apps from other screens", showOtherScreens,
                        help: "Off restricts the switcher to apps with a window on the display it appears on — the one under the pointer.\n\nMinimized windows sit on no display, so this never hides them."),
            SettingsRow.separator(),
            sectionHeader("DETECTION"),
            SettingsRow("Detect windows on all Spaces", detectAcrossSpaces,
                        help: "Look for windows beyond the current desktop, and for minimized ones.\n\nThis is the only part of Altty that needs the Accessibility permission; it asks for nothing while this is off."),
            // Indented under the setting they depend on: without all-Spaces detection there is
            // nothing on another desktop to show, and a minimized window cannot be told apart
            // from one sitting on another desktop.
            otherSpacesRow,
            minimizedRow,
            statusLabel,
            statusRow,
            SettingsRow.separator(),
            sectionHeader("NEVER SHOW THESE APPS"),
            exclusions,
        ])
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func colorRow(_ title: String, value: String, disabledReason: @escaping () -> String?,
                          onChange: @escaping (String) -> Void) -> SettingsRow {
        let picker = ColorSwatchPicker(value: value, onChange: onChange)
        picker.setAccessibilityLabel("\(title) badge colour")
        return SettingsRow(title, picker, indented: true,
                           help: "The last swatch opens the colour wheel for any other colour.",
                           disabledReason: disabledReason)
    }

    @objc private func badgeSizeChanged(_ sender: NSSegmentedControl) {
        AlttyPrefs.badgeSize = BadgeSize(rawValue: sender.selectedSegment) ?? .large
    }

    // MARK: - Value sync, no layout changes

    func sync() {
        appShortcut.shortcut = AlttyPrefs.appShortcut
        windowShortcut.shortcut = AlttyPrefs.windowShortcut
        showWindowless.state = AlttyPrefs.showWindowlessApps ? .on : .off
        showHidden.state = AlttyPrefs.showHiddenApps ? .on : .off
        showFullscreen.state = AlttyPrefs.showFullscreenApps ? .on : .off
        showOtherScreens.state = AlttyPrefs.showOtherScreenApps ? .on : .off
        showAppNames.state = AlttyPrefs.showAppNames ? .on : .off
        showBadges.state = AlttyPrefs.showWindowBadges ? .on : .off
        showNotificationBadges.state = AlttyPrefs.showNotificationBadges ? .on : .off
        badgeSize.selectedSegment = AlttyPrefs.badgeSize.rawValue
        badgeRows.forEach { $0.refresh() }
        iconSize.selectedSegment = AlttyPrefs.iconSize.rawValue

        let trusted = Permissions.isAccessibilityTrusted
        let axActive = AlttyPrefs.detectAcrossSpaces && trusted
        detectAcrossSpaces.state = AlttyPrefs.detectAcrossSpaces ? .on : .off

        // A minimized window can't be told from one on another Space without Accessibility.
        showMinimized.state = axActive && AlttyPrefs.showMinimizedApps ? .on : .off
        showOtherSpaces.state = axActive && AlttyPrefs.showOtherSpaceApps ? .on : .off
        conditionalRows.forEach { $0.refresh() }

        if axActive {
            statusLabel.stringValue = "All desktops and minimized windows are scanned."
        } else if AlttyPrefs.detectAcrossSpaces {
            // Deliberately not asserting a cause: we cannot tell "never granted" from
            // "granted, then invalidated".
            statusLabel.stringValue = "Waiting for the Accessibility permission."
        } else {
            statusLabel.stringValue = "Only the current desktop is scanned."
        }
    }

    // MARK: - Actions

    @objc private func iconSizeChanged(_ sender: NSSegmentedControl) {
        AlttyPrefs.iconSize = IconSize(rawValue: sender.selectedSegment) ?? .large
    }

    @objc private func requestPermission() {
        Permissions.resetAndRequest()
    }
}
