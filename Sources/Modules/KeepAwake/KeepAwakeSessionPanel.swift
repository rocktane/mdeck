import Cocoa

/// A module-owned, nonmodal panel; opening it never changes NSApp's activation policy.
final class KeepAwakeSessionPanel: NSPanel {
    private weak var module: KeepAwakeModule?
    private let mode = NSSegmentedControl(labels: ["For a Duration", "Until a Time"], trackingMode: .selectOne,
                                          target: nil, action: nil)
    private let minutes = NSTextField(string: "")
    private let endTime = NSDatePicker()
    private let validation = caption(" ")
    private let startButton = NSButton(title: "Start Session", target: nil, action: nil)

    init(module: KeepAwakeModule) {
        self.module = module
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 265),
                   styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        title = "Keep Awake Session"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(modeChanged)
        minutes.stringValue = String(KeepAwakePrefs.customMinutes)
        minutes.widthAnchor.constraint(equalToConstant: 90).isActive = true
        minutes.setAccessibilityLabel("Session duration in minutes")
        endTime.datePickerStyle = .textFieldAndStepper
        endTime.datePickerElements = [.yearMonthDay, .hourMinute]
        endTime.setAccessibilityLabel("Session end date and time")
        startButton.bezelStyle = .rounded
        startButton.target = self
        startButton.action = #selector(startSession)
        startButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSession))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, startButton])
        buttons.spacing = 8
        validation.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let rows = RowsView([
            SettingsRow("Session", mode),
            SettingsRow("Duration (minutes)", minutes),
            SettingsRow("End time", endTime),
            caption("Choose 1 minute to 7 days, or an end time within the next 7 days. A new session replaces the current end time."),
            validation,
            SettingsRow(NSView(), buttons),
        ])
        contentView!.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor, constant: 20),
            rows.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor, constant: -20),
            rows.topAnchor.constraint(equalTo: contentView!.topAnchor, constant: 20),
            rows.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor, constant: -20),
        ])
        modeChanged()
    }

    func show() {
        validation.stringValue = " "
        startButton.title = module?.isActive == true ? "Update Session" : "Start Session"
        let now = Date()
        endTime.minDate = now
        endTime.maxDate = now.addingTimeInterval(Double(KeepAwakePrefs.maximumMinutes * 60))
        if endTime.dateValue <= now { endTime.dateValue = now.addingTimeInterval(3600) }
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    @objc private func modeChanged() {
        minutes.isEnabled = mode.selectedSegment == 0
        endTime.isEnabled = mode.selectedSegment == 1
        validation.stringValue = " "
    }

    @objc private func startSession() {
        guard let module, module.isRunning else { close(); return }
        let duration: TimeInterval
        var until: Date?
        if mode.selectedSegment == 0 {
            guard let value = Int(minutes.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (1...KeepAwakePrefs.maximumMinutes).contains(value) else {
                validation.stringValue = "Enter a whole number between 1 and \(KeepAwakePrefs.maximumMinutes)."
                return
            }
            KeepAwakePrefs.customMinutes = value
            duration = Double(value * 60)
        } else {
            until = endTime.dateValue
            duration = endTime.dateValue.timeIntervalSinceNow
            guard duration > 0, duration <= Double(KeepAwakePrefs.maximumMinutes * 60) else {
                validation.stringValue = "Choose a future end time within the next 7 days."
                return
            }
        }
        if module.beginSession(duration: duration, until: until) { close() }
        else { validation.stringValue = module.lastError ?? "The session could not start." }
    }

    @objc private func cancelSession() { close() }
}
