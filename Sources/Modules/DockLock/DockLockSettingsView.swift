import Cocoa

/// Dock Lock's page in the settings window.
final class DockLockSettingsView: NSView {
    private weak var module: DockLockModule?
    private var targetPopup: NSPopUpButton!
    private var autoReturn: ActionSwitch!
    private var statusLabel: NSTextField!
    private var conditionalRows: [SettingsRow] = []
    /// What each popup item stands for, by index.
    private var choices: [DisplayInfo?] = []

    init(module: DockLockModule) {
        self.module = module
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        sync()
        NotificationCenter.default.addObserver(self, selector: #selector(sync),
                                               name: .moduleStateDidChange, object: nil)
        // The module only follows display changes while running; the page must follow them
        // either way to keep the popup current.
        NotificationCenter.default.addObserver(self, selector: #selector(sync),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        targetPopup.target = self
        targetPopup.action = #selector(targetChosen(_:))
        targetPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        autoReturn = ActionSwitch(isOn: DockLockPrefs.autoReturn) { DockLockPrefs.autoReturn = $0 }

        let moveButton = NSButton(title: "Move Dock Now", target: self, action: #selector(moveNow))
        moveButton.bezelStyle = .rounded
        let permissionButton = NSButton(title: "Request Permission…", target: self, action: #selector(requestPermission))
        permissionButton.bezelStyle = .rounded

        statusLabel = NSTextField(labelWithString: " ")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let moveRow = SettingsRow(statusLabel, moveButton, disabledReason: { [weak self] in
            guard let module = self?.module else { return nil }
            if !module.isRunning { return "Turn Dock Lock on first." }
            switch module.state {
            case .needsPermission: return "Dock Lock needs the Accessibility permission to move the Dock."
            case .targetMissing: return "\(DockLockPrefs.targetName) is not connected."
            case .locked: return Displays.active().count > 1 ? nil : "Only one display is connected: the Dock has nowhere else to be."
            }
        }, infoPlacement: .beforeControl)
        let permissionRow = SettingsRow(NSTextField(labelWithString: "Accessibility permission"), permissionButton, disabledReason: {
            Permissions.isAccessibilityTrusted ? "Granted — nothing left to request." : nil
        }, infoPlacement: .beforeControl)
        conditionalRows = [moveRow, permissionRow]

        let rows = RowsView([
            sectionHeader("DOCK"),
            SettingsRow("Keep the Dock on", targetPopup,
                        help: "The display the Dock belongs on. While it is not connected, Dock Lock stands aside and the Dock goes wherever macOS puts it."),
            SettingsRow("Bring the Dock back after display changes", autoReturn,
                        help: "Plugging in a screen, waking up or changing the main display can make macOS move the Dock. With this on, Dock Lock moves it back a couple of seconds later."),
            moveRow,
            SettingsRow.separator(),
            sectionHeader("PERMISSION"),
            permissionRow,
            caption("macOS moves the Dock to whichever display you push the pointer against at its Dock edge. Dock Lock holds the pointer two points short of that edge on every other display — only where the edge is an outer one, so moving between stacked screens is never blocked. Intercepting the pointer, reading where the Dock is and moving it all need the Accessibility permission."),
        ])
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func sync() {
        // Built-in first, then the external displays; the saved target stays listed while
        // unplugged so choosing another one is a deliberate act.
        let displays = Displays.active().sorted { $0.isBuiltin && !$1.isBuiltin }
        choices = displays
        targetPopup.removeAllItems()
        for display in displays {
            targetPopup.addItem(withTitle: display.isBuiltin ? "\(display.name) (built-in)" : display.name)
        }
        if let index = displays.firstIndex(where: { $0.key == DockLockPrefs.target }) {
            targetPopup.selectItem(at: index)
        } else {
            targetPopup.addItem(withTitle: "\(DockLockPrefs.targetName) (not connected)")
            choices.append(nil)
            targetPopup.selectItem(at: choices.count - 1)
        }

        autoReturn.state = DockLockPrefs.autoReturn ? .on : .off

        if let module, module.isRunning {
            statusLabel.stringValue = module.statusText ?? " "
        } else {
            statusLabel.stringValue = "Dock Lock is off."
        }
        conditionalRows.forEach { $0.refresh() }
    }

    @objc private func targetChosen(_ sender: NSPopUpButton) {
        guard choices.indices.contains(sender.indexOfSelectedItem),
              let display = choices[sender.indexOfSelectedItem] else { return }
        if let module {
            module.setTarget(display)
        } else {
            DockLockPrefs.target = display.key
            DockLockPrefs.targetName = display.name
        }
        sync()
    }

    @objc private func moveNow() {
        module?.moveDockNow()
    }

    @objc private func requestPermission() {
        Permissions.resetAndRequest()
    }
}
