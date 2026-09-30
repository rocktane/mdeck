import Cocoa
import UniformTypeIdentifiers

/// A list of apps in a settings page — Altty's exclusions, Night Shift Focus's watched apps: a
/// short table of bundle IDs with the usual +/− controls under it. Stored as bundle IDs so an
/// entry survives the app being moved or updated; name and icon are resolved for display.
///
/// Fixed height, like every other row: the settings layout never reflows.
final class AppListView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private static let tableHeight: CGFloat = 120
    static let height: CGFloat = tableHeight + 6 + 21

    private let table = AppListTable()
    private let scroll = NSScrollView()
    private let buttons = NSSegmentedControl()
    private let placeholder: NSTextField
    private let choosePrompt: String
    private let onChange: ([String]) -> Void
    private var ids: [String]

    /// `onChange` receives the whole list after every edit.
    init(ids: [String], placeholder emptyText: String, addHelp: String, removeHelp: String,
         choosePrompt: String, onChange: @escaping ([String]) -> Void) {
        self.ids = ids
        self.placeholder = NSTextField(labelWithString: emptyText)
        self.choosePrompt = choosePrompt
        self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.style = .plain
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.onDelete = { [weak self] in self?.removeSelected() }

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        placeholder.font = .systemFont(ofSize: 11)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        buttons.segmentStyle = .smallSquare
        buttons.trackingMode = .momentary
        buttons.segmentCount = 2
        buttons.setImage(NSImage(named: NSImage.addTemplateName), forSegment: 0)
        buttons.setImage(NSImage(named: NSImage.removeTemplateName), forSegment: 1)
        buttons.setWidth(24, forSegment: 0)
        buttons.setWidth(24, forSegment: 1)
        buttons.controlSize = .small
        buttons.target = self
        buttons.action = #selector(buttonPressed(_:))
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.setToolTip(addHelp, forSegment: 0)
        buttons.setToolTip(removeHelp, forSegment: 1)

        addSubview(scroll)
        addSubview(placeholder)
        addSubview(buttons)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: Self.tableHeight),
            placeholder.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Model

    /// Replaces the list after an edit made elsewhere (the menu bar menu), without calling
    /// `onChange` back.
    func reload(ids: [String]) {
        self.ids = ids
        refresh()
    }

    private func save() {
        onChange(ids)
        refresh()
    }

    private func refresh() {
        table.reloadData()
        placeholder.isHidden = !ids.isEmpty
        buttons.setEnabled(!table.selectedRowIndexes.isEmpty, forSegment: 1)
    }

    private func add(_ id: String) {
        guard !ids.contains(id) else { return }
        ids.append(id)
        ids.sort { Self.info(for: $0).name.localizedCaseInsensitiveCompare(Self.info(for: $1).name) == .orderedAscending }
        save()
    }

    private func removeSelected() {
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty else { return }
        ids = ids.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        save()
    }

    /// Display name and icon for a bundle ID, or the ID itself when the app is nowhere to be
    /// found (uninstalled since — the entry is kept, it costs nothing).
    static func info(for id: String) -> (name: String, icon: NSImage?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return (id, nil)
        }
        return (displayName(of: url), NSWorkspace.shared.icon(forFile: url.path))
    }

    static func displayName(of url: URL) -> String {
        let bundle = Bundle(url: url)
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = bundle?.localizedInfoDictionary?[key] as? String, !name.isEmpty { return name }
            if let name = bundle?.infoDictionary?[key] as? String, !name.isEmpty { return name }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { ids.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id)
        let info = Self.info(for: ids[row])
        cell.textField?.stringValue = info.name
        cell.imageView?.image = info.icon
        cell.toolTip = ids[row]
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        for v in [image, text] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        buttons.setEnabled(!table.selectedRowIndexes.isEmpty, forSegment: 1)
    }

    // MARK: - Buttons

    @objc private func buttonPressed(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: showAddMenu()
        case 1: removeSelected()
        default: break
        }
    }

    /// Running apps first — that is almost always the one the user has in mind — then a file
    /// picker for anything else.
    private func showAddMenu() {
        let menu = NSMenu()
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != NSRunningApplication.current }
            .compactMap { app -> (String, String, NSImage?)? in
                guard let id = app.bundleIdentifier, !ids.contains(id) else { return nil }
                return (id, app.localizedName ?? id, app.icon)
            }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        for (id, name, icon) in running {
            let item = NSMenuItem(title: name, action: #selector(addFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            let small = icon?.copy() as? NSImage
            small?.size = NSSize(width: 16, height: 16)
            item.image = small
            menu.addItem(item)
        }
        if !running.isEmpty { menu.addItem(.separator()) }
        let other = NSMenuItem(title: "Other…", action: #selector(chooseApplication), keyEquivalent: "")
        other.target = self
        menu.addItem(other)

        let origin = NSPoint(x: 0, y: buttons.bounds.height + 2)
        menu.popUp(positioning: nil, at: origin, in: buttons)
    }

    @objc private func addFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { add(id) }
    }

    @objc private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = choosePrompt
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls {
                if let id = Bundle(url: url)?.bundleIdentifier { self?.add(id) }
            }
        }
    }
}

/// Delete / Backspace on the table removes the selection, like every list in System Settings.
final class AppListTable: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { // delete, forward delete
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}
