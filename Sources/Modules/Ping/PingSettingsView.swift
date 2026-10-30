import Cocoa

final class PingSettingsView: NSView, NSTextFieldDelegate {
    private weak var module: PingModule?
    private var hostField: NSTextField!
    private var intervalPicker: NSPopUpButton!
    private var failuresPicker: NSPopUpButton!
    private var colorPicker: ColorSwatchPicker!
    private var checkButton: NSButton!
    private var dot: NSImageView!
    private var liveStatus: NSTextField!
    private var statusGap: NSLayoutConstraint!

    init(module: PingModule) {
        self.module = module
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        hostField = NSTextField(string: PingPrefs.host)
        hostField.placeholderString = PingPrefs.defaultHost
        hostField.delegate = self
        hostField.target = self
        hostField.action = #selector(hostCommitted)
        hostField.setAccessibilityLabel("Host to ping")
        hostField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        intervalPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        for seconds in PingPrefs.intervals {
            intervalPicker.addItem(withTitle: PingPrefs.intervalLabel(seconds))
            intervalPicker.lastItem?.tag = seconds
        }
        intervalPicker.selectItem(withTag: PingPrefs.interval)
        intervalPicker.target = self
        intervalPicker.action = #selector(intervalChanged)
        intervalPicker.setAccessibilityLabel("Check every")

        failuresPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        for count in PingPrefs.failureCounts {
            failuresPicker.addItem(withTitle: count == 1 ? "1 failed ping" : "\(count) failed pings in a row")
            failuresPicker.lastItem?.tag = count
        }
        failuresPicker.selectItem(withTag: PingPrefs.failuresBeforeAlert)
        failuresPicker.target = self
        failuresPicker.action = #selector(failuresChanged)
        failuresPicker.setAccessibilityLabel("Turn red after")

        colorPicker = ColorSwatchPicker(value: PingPrefs.color) { [weak module] value in
            PingPrefs.color = value
            module?.settingsChanged()
        }
        colorPicker.setAccessibilityLabel("Dot colour")

        checkButton = NSButton(title: "Check Now", target: module, action: #selector(PingModule.checkNow))
        checkButton.bezelStyle = .rounded

        dot = NSImageView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.setContentHuggingPriority(.required, for: .horizontal)
        liveStatus = caption(" ")
        liveStatus.maximumNumberOfLines = 2
        let statusLine = NSView()
        statusLine.translatesAutoresizingMaskIntoConstraints = false
        statusLine.addSubview(dot)
        statusLine.addSubview(liveStatus)
        statusGap = liveStatus.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6)
        NSLayoutConstraint.activate([
            // Two lines reserved so a long error does not move the rows below.
            statusLine.heightAnchor.constraint(equalToConstant: 32),
            dot.leadingAnchor.constraint(equalTo: statusLine.leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: statusLine.centerYAnchor),
            statusGap,
            liveStatus.trailingAnchor.constraint(equalTo: statusLine.trailingAnchor),
            liveStatus.centerYAnchor.constraint(equalTo: statusLine.centerYAnchor),
        ])

        let rows = RowsView([
            sectionHeader("TARGET"),
            SettingsRow("IP address or host name", hostField,
                        help: "Pinged with one ICMP echo per check. A pasted URL is reduced to its host."),
            SettingsRow("Check every", intervalPicker,
                        help: "Each ping waits up to 3 seconds for a reply, or the interval if it is shorter."),
            SettingsRow("Turn red after", failuresPicker,
                        help: "Requiring several failures in a row ignores a single lost packet."),
            SettingsRow("Check now", checkButton),
            statusLine,
            SettingsRow.separator(),
            sectionHeader("MENU BAR"),
            SettingsRow("Dot colour while online", colorPicker,
                        help: "The dot turns red when the host stops replying, and is faded until the first reply."),
            caption("The dot has its own menu bar item, normally left of mdeck’s icon. ⌘-drag it to move it."),
            SettingsRow.separator(),
            caption("A ping tests that the host answers ICMP echo, not that websites load. Some networks — captive portals, corporate firewalls — block ping while browsing still works; pick a host that answers on yours."),
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
        checkButton.isEnabled = module.isRunning
        checkButton.toolTip = module.isRunning ? nil : "Enable the module to check the connection."
        dot.image = module.isRunning ? PingModule.dot(module.dotColor) : nil
        statusGap.constant = module.isRunning ? 6 : 0
        liveStatus.stringValue = module.statusText ?? " "
        liveStatus.textColor = module.isRunning && (module.state == .offline || module.state == .invalidHost)
            ? .systemRed : .secondaryLabelColor
    }

    func controlTextDidEndEditing(_ obj: Notification) { hostCommitted() }

    @objc private func hostCommitted() {
        var value = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { value = PingPrefs.defaultHost }
        hostField.stringValue = value
        guard value != PingPrefs.host else { return }
        PingPrefs.host = value
        module?.settingsChanged(target: true)
    }

    @objc private func intervalChanged() {
        PingPrefs.interval = intervalPicker.selectedTag()
        module?.settingsChanged(interval: true)
    }

    @objc private func failuresChanged() {
        PingPrefs.failuresBeforeAlert = failuresPicker.selectedTag()
        module?.settingsChanged()
    }
}
