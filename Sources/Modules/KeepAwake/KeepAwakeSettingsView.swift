import Cocoa

final class KeepAwakeSettingsView: NSView {
    private weak var module: KeepAwakeModule?
    private var systemSwitch: ActionSwitch!
    private var displaySwitch: ActionSwitch!
    private var sessionButton: NSButton!
    private var customButton: NSButton!
    private var durationPicker: NSPopUpButton!
    private var agentSwitch: ActionSwitch!
    private var gracePicker: NSPopUpButton!
    private var liveStatus: NSTextField!

    init(module: KeepAwakeModule) {
        self.module = module
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        systemSwitch = ActionSwitch(isOn: KeepAwakePrefs.preventSystemSleep) { [weak module] on in
            KeepAwakePrefs.preventSystemSleep = on
            module?.settingsChanged(reapplyProtection: true)
        }
        displaySwitch = ActionSwitch(isOn: KeepAwakePrefs.preventDisplaySleep) { [weak module] on in
            KeepAwakePrefs.preventDisplaySleep = on
            module?.settingsChanged(reapplyProtection: true)
        }
        systemSwitch.setAccessibilityLabel("Prevent system sleep")
        displaySwitch.setAccessibilityLabel("Prevent display sleep")
        durationPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        for minutes in KeepAwakePrefs.durations {
            durationPicker.addItem(withTitle: KeepAwakePrefs.durationLabel(minutes))
            durationPicker.lastItem?.tag = minutes
        }
        durationPicker.selectItem(withTag: KeepAwakePrefs.defaultMinutes)
        durationPicker.target = self
        durationPicker.action = #selector(durationChanged)
        durationPicker.setAccessibilityLabel("Default session duration")
        let autoStart = ActionSwitch(isOn: KeepAwakePrefs.startOnEnable) { on in
            KeepAwakePrefs.startOnEnable = on
        }
        autoStart.setAccessibilityLabel("Start a session when enabled")
        let countdown = ActionSwitch(isOn: KeepAwakePrefs.showCountdown) { [weak module] on in
            KeepAwakePrefs.showCountdown = on
            module?.settingsChanged()
        }
        countdown.setAccessibilityLabel("Show menu bar countdown")
        agentSwitch = ActionSwitch(isOn: KeepAwakePrefs.whileAgentsWork) { [weak module] on in
            KeepAwakePrefs.whileAgentsWork = on
            module?.settingsChanged(agentMode: true)
        }
        agentSwitch.setAccessibilityLabel("Stay awake while Claude Code or Codex works")
        gracePicker = NSPopUpButton(frame: .zero, pullsDown: false)
        for minutes in KeepAwakePrefs.agentGraces {
            gracePicker.addItem(withTitle: KeepAwakePrefs.durationLabel(minutes))
            gracePicker.lastItem?.tag = minutes
        }
        gracePicker.selectItem(withTag: KeepAwakePrefs.agentGraceMinutes)
        gracePicker.target = self
        gracePicker.action = #selector(graceChanged)
        gracePicker.setAccessibilityLabel("Agent quiet period")
        sessionButton = NSButton(title: "Start Keep Awake", target: module, action: #selector(KeepAwakeModule.toggleSession))
        sessionButton.bezelStyle = .rounded
        sessionButton.widthAnchor.constraint(equalToConstant: 150).isActive = true
        customButton = NSButton(title: "Choose…", target: module, action: #selector(KeepAwakeModule.showSessionPanel))
        customButton.bezelStyle = .rounded
        liveStatus = caption(" ")
        // Reserve two lines so the countdown and error states do not move controls.
        liveStatus.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let rows = RowsView([
            sectionHeader("SLEEP PREVENTION"),
            SettingsRow("Prevent system sleep", systemSwitch,
                        help: "Keeps macOS running while idle. The display can still sleep independently."),
            SettingsRow("Prevent display sleep", displaySwitch,
                        help: "Keeps displays awake while idle. Does not change brightness or the screen saver settings."),
            caption("Choose either or both. Turning both off ends the current session."),
            SettingsRow.separator(),
            sectionHeader("AGENTS"),
            SettingsRow("Stay awake while Claude Code or Codex works", agentSwitch,
                        help: "Holds the protections above while an agent is answering or running a tool, then lets the Mac sleep again. Open but idle sessions do not count."),
            SettingsRow("Quiet period", gracePicker, indented: true,
                        help: "How long after an agent's last message or tool result it still counts as working. Covers long model turns that write nothing."),
            caption("Detected from transcript writes in ~/.claude/projects and ~/.codex/sessions, and from shell commands started by a claude or codex process. Works for the CLIs, the desktop apps and tools built on them. No hooks or configuration needed."),
            SettingsRow.separator(),
            sectionHeader("SESSIONS"),
            SettingsRow("Default duration", durationPicker,
                        help: "Used by Start Keep Awake and automatic start. Changing this does not extend a running session."),
            SettingsRow("Start a session when enabled", autoStart,
                        help: "Also starts a fresh session when mdeck launches with this module enabled. An expired session stays stopped."),
            SettingsRow("Show menu bar countdown", countdown),
            SettingsRow("Current session", sessionButton),
            SettingsRow("Custom duration or end time", customButton),
            liveStatus,
            SettingsRow.separator(),
            caption("Keep Awake prevents idle sleep using public macOS power assertions. It does not override Sleep, a closed laptop lid or low-battery protection, and does not simulate activity in other apps."),
        ])
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        sync()
    }

    required init?(coder: NSCoder) { fatalError() }

    func sync() {
        guard let module else { return }
        systemSwitch.state = KeepAwakePrefs.preventSystemSleep ? .on : .off
        displaySwitch.state = KeepAwakePrefs.preventDisplaySleep ? .on : .off
        agentSwitch.state = KeepAwakePrefs.whileAgentsWork ? .on : .off
        gracePicker.isEnabled = KeepAwakePrefs.whileAgentsWork
        sessionButton.title = module.isActive ? "Stop Keep Awake" : "Start Keep Awake"
        sessionButton.isEnabled = module.isRunning && (module.isActive || KeepAwakePrefs.hasProtection)
        customButton.isEnabled = module.isRunning && KeepAwakePrefs.hasProtection
        let hint = module.isRunning ? "Choose system or display protection first." : "Enable the module to start a session."
        sessionButton.toolTip = sessionButton.isEnabled ? nil : hint
        customButton.toolTip = customButton.isEnabled ? nil : hint
        liveStatus.stringValue = module.statusText ?? "Idle"
        liveStatus.textColor = module.lastError == nil ? .secondaryLabelColor : .systemRed
    }

    @objc private func graceChanged() {
        KeepAwakePrefs.agentGraceMinutes = gracePicker.selectedTag()
        module?.settingsChanged(agentMode: true)
    }

    @objc private func durationChanged() {
        KeepAwakePrefs.defaultMinutes = durationPicker.selectedTag()
        module?.settingsChanged()
    }
}
