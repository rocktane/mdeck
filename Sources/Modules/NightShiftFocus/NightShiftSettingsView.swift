import Cocoa

/// Night Shift Focus's page in the settings window.
final class NightShiftSettingsView: NSView {
    private weak var module: NightShiftFocusModule?
    private var apps: AppListView!
    private var manageNightShift: ActionSwitch!
    private var manageTrueTone: ActionSwitch!
    private var conditionalRows: [SettingsRow] = []

    init(module: NightShiftFocusModule) {
        self.module = module
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        sync()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        manageNightShift = ActionSwitch(isOn: NightShiftPrefs.manageNightShift) { [weak self] on in
            NightShiftPrefs.manageNightShift = on
            self?.module?.settingsChanged()
        }
        manageTrueTone = ActionSwitch(isOn: NightShiftPrefs.manageTrueTone) { [weak self] on in
            NightShiftPrefs.manageTrueTone = on
            self?.module?.settingsChanged()
        }
        apps = AppListView(
            ids: NightShiftPrefs.watchedApps, placeholder: "No watched apps",
            addHelp: "Add an app to watch", removeHelp: "Stop watching the selected apps",
            choosePrompt: "Watch") { [weak self] ids in
                NightShiftPrefs.watchedApps = ids
                self?.module?.settingsChanged()
            }

        let nightShiftRow = SettingsRow("Turn off Night Shift", manageNightShift,
                                        help: "Night Shift warms the display, which skews colours.",
                                        disabledReason: { NightShift.isAvailable ? nil : "Night Shift is not available on this Mac." })
        let trueToneRow = SettingsRow("Turn off True Tone", manageTrueTone,
                                      help: "True Tone adapts the white point to the room light, which skews colours.",
                                      disabledReason: { TrueTone.isAvailable ? nil : "None of the connected displays supports True Tone." })
        conditionalRows = [nightShiftRow, trueToneRow]

        let rows = RowsView([
            sectionHeader("WHILE A WATCHED APP IS IN FRONT"),
            nightShiftRow,
            trueToneRow,
            SettingsRow.separator(),
            sectionHeader("WATCHED APPS"),
            apps,
            caption("When you leave a watched app, the previous state comes back exactly: if Night Shift runs on a schedule and the schedule flipped meanwhile, the schedule wins — unless you had overridden it yourself. The state to restore is kept on disk while anything is suspended, so a crash never leaves the colours off."),
        ])
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func sync() {
        manageNightShift.state = NightShiftPrefs.manageNightShift ? .on : .off
        manageTrueTone.state = NightShiftPrefs.manageTrueTone ? .on : .off
        conditionalRows.forEach { $0.refresh() }
    }

    func reloadApps() {
        apps.reload(ids: NightShiftPrefs.watchedApps)
    }
}
