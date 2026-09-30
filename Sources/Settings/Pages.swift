import Cocoa

/// Big tile, title, one line under it, and an optional control on the right — the top of
/// every page.
private func makePageHeader(image: NSImage, title: String, subtitle: NSTextField, accessory: NSView?) -> NSView {
    let header = NSView()
    header.translatesAutoresizingMaskIntoConstraints = false
    let icon = NSImageView(image: image)
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
    subtitle.font = .systemFont(ofSize: 12)
    subtitle.textColor = .secondaryLabelColor
    for v in [icon, titleLabel, subtitle] as [NSView] {
        v.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(v)
    }
    let textTrailing: NSLayoutXAxisAnchor
    if let accessory {
        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessory.setContentHuggingPriority(.required, for: .horizontal)
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        header.addSubview(accessory)
        NSLayoutConstraint.activate([
            accessory.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            accessory.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
        ])
        textTrailing = accessory.leadingAnchor
    } else {
        textTrailing = header.trailingAnchor
    }
    subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    NSLayoutConstraint.activate([
        icon.leadingAnchor.constraint(equalTo: header.leadingAnchor),
        icon.topAnchor.constraint(equalTo: header.topAnchor),
        icon.widthAnchor.constraint(equalToConstant: 48),
        icon.heightAnchor.constraint(equalToConstant: 48),
        header.bottomAnchor.constraint(greaterThanOrEqualTo: icon.bottomAnchor),
        titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
        titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 2),
        titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: textTrailing, constant: -12),
        subtitle.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
        subtitle.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
        subtitle.trailingAnchor.constraint(lessThanOrEqualTo: textTrailing, constant: -12),
        header.bottomAnchor.constraint(greaterThanOrEqualTo: subtitle.bottomAnchor),
    ])
    return header
}

/// Pins `content` to all four edges of `container`.
private func fill(_ container: NSView, with content: NSView) {
    content.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(content)
    NSLayoutConstraint.activate([
        content.topAnchor.constraint(equalTo: container.topAnchor),
        content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
}

// MARK: - Module page

/// Header with the on/off switch, then whatever the module puts below it. The module's own
/// settings stay editable while it is off: they apply the next time it starts.
final class ModulePageView: NSView {
    private let module: Module
    private let toggle: ActionSwitch
    private var showInMenu: ActionSwitch!

    init(module: Module) {
        self.module = module
        toggle = ActionSwitch(isOn: ModuleManager.shared.isEnabled(module)) { on in
            ModuleManager.shared.setEnabled(module, on)
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let summary = NSTextField(wrappingLabelWithString: module.summary)
        let header = makePageHeader(image: ModuleTile.image(for: module, size: 48), title: module.name,
                                subtitle: summary, accessory: toggle)
        toggle.setAccessibilityLabel("Enable \(module.name)")

        showInMenu = ActionSwitch(isOn: ModuleManager.shared.isShownInMenu(module)) { on in
            ModuleManager.shared.setShownInMenu(module, on)
        }
        let menuRow = SettingsRow("Show in the menu bar menu", showInMenu,
                                  help: "Lists \(module.name) in mdeck’s menu bar menu, whether it is on or off. Hiding it changes nothing to what it does.")

        fill(self, with: RowsView([
            header,
            menuRow,
            SettingsRow.separator(),
            module.makeSettingsView(),
        ], spacing: 14))
        sync()
        NotificationCenter.default.addObserver(self, selector: #selector(sync),
                                               name: .moduleStateDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func sync() {
        toggle.state = ModuleManager.shared.isEnabled(module) ? .on : .off
        showInMenu.state = ModuleManager.shared.isShownInMenu(module) ? .on : .off
    }
}

// MARK: - General page

final class GeneralPageView: NSView {
    private var launchAtLogin: ActionSwitch!
    private var theme: NSSegmentedControl!
    private var moduleSwitches: [(Module, ActionSwitch)] = []
    private var permissionLabel: NSTextField!
    private var permissionRow: SettingsRow!

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        sync()
        NotificationCenter.default.addObserver(self, selector: #selector(sync),
                                               name: .moduleStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sync),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let subtitle = NSTextField(labelWithString: "Version \(version) · One menu bar app, many small utilities.")
        let header = makePageHeader(image: NSApp.applicationIconImage, title: "mdeck", subtitle: subtitle, accessory: nil)

        launchAtLogin = ActionSwitch(isOn: LaunchAtLogin.isEnabled) { [weak self] on in
            do {
                try LaunchAtLogin.set(on)
            } catch {
                let alert = NSAlert()
                alert.messageText = "macOS refused the login item"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
            self?.sync()
        }

        theme = NSSegmentedControl(labels: Theme.allCases.map(\.label), trackingMode: .selectOne,
                                   target: self, action: #selector(themeChanged(_:)))

        var rows: [NSView] = [
            header,
            SettingsRow.separator(),
            SettingsRow("Launch at login", launchAtLogin),
            SettingsRow("Appearance", theme,
                        help: "mdeck’s settings, menu and Altty’s switcher: follow the system, or stay light or dark."),
            SettingsRow.separator(),
            sectionHeader("MODULES"),
        ]
        for module in ModuleManager.shared.modules {
            let toggle = ActionSwitch(isOn: ModuleManager.shared.isEnabled(module)) { on in
                ModuleManager.shared.setEnabled(module, on)
            }
            toggle.setAccessibilityLabel("Enable \(module.name)")
            moduleSwitches.append((module, toggle))
            rows.append(SettingsRow(moduleLabel(module), toggle))
        }
        rows.append(caption("A module that is off does not run at all: no observer, no shortcut, no event tap."))

        permissionLabel = NSTextField(labelWithString: " ")
        permissionLabel.lineBreakMode = .byTruncatingTail
        let request = NSButton(title: "Request Permission…", target: self, action: #selector(requestPermission))
        request.bezelStyle = .rounded
        permissionRow = SettingsRow(permissionLabel, request, disabledReason: {
            if Permissions.isAccessibilityTrusted { return "Granted — nothing left to request." }
            return nil
        }, infoPlacement: .beforeControl)

        let quit = NSButton(title: "Quit mdeck", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded

        rows += [
            SettingsRow.separator(),
            sectionHeader("PERMISSIONS"),
            permissionRow,
            caption("Only Dock Lock, and Altty’s “Detect windows on all Spaces”, need Accessibility. mdeck asks for it when you turn one of them on, never before."),
            SettingsRow.separator(),
            SettingsRow(NSView(), quit),
        ]
        fill(self, with: RowsView(rows))
    }

    /// Tile, name and summary, stacked, as the leading side of a row.
    private func moduleLabel(_ module: Module) -> NSView {
        let view = NSView()
        let icon = NSImageView(image: ModuleTile.image(for: module, size: 28))
        let name = NSTextField(labelWithString: module.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        let summary = NSTextField(labelWithString: module.summary)
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [icon, name, summary] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            view.heightAnchor.constraint(equalToConstant: 34),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.topAnchor.constraint(equalTo: view.topAnchor, constant: 1),
            summary.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            summary.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
        ])
        return view
    }

    @objc private func sync() {
        launchAtLogin.state = LaunchAtLogin.isEnabled ? .on : .off
        theme.selectedSegment = AppPrefs.theme.rawValue
        for (module, toggle) in moduleSwitches {
            toggle.state = ModuleManager.shared.isEnabled(module) ? .on : .off
        }
        let trusted = Permissions.isAccessibilityTrusted
        permissionLabel.stringValue = trusted ? "Accessibility: granted" : "Accessibility: not granted"
        permissionRow.refresh()
    }

    @objc private func themeChanged(_ sender: NSSegmentedControl) {
        AppPrefs.theme = Theme(rawValue: sender.selectedSegment) ?? .system
    }

    @objc private func requestPermission() {
        Permissions.resetAndRequest()
    }
}
