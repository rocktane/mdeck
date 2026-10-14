import Cocoa

/// A short editable list of text entries with +/− under it, like `AppListView` but for domains
/// and parameter names. + appends a row and starts editing it; an entry left empty, refused by
/// `normalize` or already present disappears when editing ends.
///
/// Fixed height, so the settings layout never reflows.
final class StringListView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static let tableHeight: CGFloat = 92
    static let height: CGFloat = tableHeight + 6 + 21

    private let table = AppListTable()
    private let scroll = NSScrollView()
    private let buttons = NSSegmentedControl()
    private let placeholder: NSTextField
    private let normalize: (String) -> String?
    private let onChange: ([String]) -> Void
    private var entries: [String]

    init(entries: [String], placeholder emptyText: String, addHelp: String, removeHelp: String,
         normalize: @escaping (String) -> String?, onChange: @escaping ([String]) -> Void) {
        self.entries = entries
        self.placeholder = NSTextField(labelWithString: emptyText)
        self.normalize = normalize
        self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 20
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

    private func refresh() {
        table.reloadData()
        placeholder.isHidden = !entries.isEmpty
        buttons.setEnabled(!table.selectedRowIndexes.isEmpty, forSegment: 1)
    }

    private func save() {
        onChange(entries.filter { !$0.isEmpty })
        refresh()
    }

    private func removeSelected() {
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty else { return }
        entries = entries.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        save()
    }

    @objc private func buttonPressed(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0:
            // An empty row being edited is not saved until it holds something valid.
            if let blank = entries.firstIndex(of: "") { return edit(row: blank) }
            entries.append("")
            refresh()
            edit(row: entries.count - 1)
        case 1: removeSelected()
        default: break
        }
    }

    private func edit(row: Int) {
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        table.editColumn(0, row: row, with: nil, select: true)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id)
        cell.textField?.stringValue = entries[row]
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(string: "")
        text.isBordered = false
        text.drawsBackground = false
        text.isEditable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.lineBreakMode = .byTruncatingTail
        text.cell?.usesSingleLineMode = true
        text.delegate = self
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        buttons.setEnabled(!table.selectedRowIndexes.isEmpty, forSegment: 1)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = table.row(for: field)
        guard entries.indices.contains(row) else { return }
        let value = normalize(field.stringValue)
        if let value, !entries.enumerated().contains(where: { $0.offset != row && $0.element == value }) {
            entries[row] = value
        } else {
            if !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { NSSound.beep() }
            entries.remove(at: row)
        }
        save()
    }
}
