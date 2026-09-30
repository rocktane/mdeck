import Cocoa

/// The settings window: a sidebar (General, then one entry per module) and the selected page.
///
/// mdeck is an accessory app — no Dock icon, no menu bar of its own. While this window is open
/// it becomes a regular app so it can be switched back to; see `show()` / `windowWillClose`.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let split = NSSplitViewController()
    private let sidebar = SidebarViewController()
    private let detail = DetailViewController()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "mdeck"
        window.titlebarAppearsTransparent = true
        // The sidebar and the page headers say where you are; a title would sit on top of
        // the page as it scrolls.
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 440)
        window.setFrameAutosaveName("mdeck.settings")
        super.init(window: window)
        window.delegate = self

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 200
        split.addSplitViewItem(sidebarItem)
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 480
        split.addSplitViewItem(detailItem)
        window.contentViewController = split
        // The content view controller resizes the window to its fitting size; put it back.
        window.setContentSize(NSSize(width: 780, height: 600))

        sidebar.onSelect = { [weak self] page in self?.showPage(page) }

        // Coming back from System Settings is the moment a permission may have been granted.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            AccessibilityWatcher.shared.check()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(page: String? = nil) {
        guard let window else { return }
        showPage(page ?? AppPrefs.lastSettingsPage)
        // A Dock icon and a menu bar, but only while this window is up: an agent is otherwise
        // impossible to switch back to once it loses focus. Back to .accessory on close.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        // Opening the window shouldn't look like the first control is armed.
        window.makeFirstResponder(nil)
    }

    private func showPage(_ page: String) {
        let page = page == "general" || ModuleManager.shared.module(id: page) != nil ? page : "general"
        AppPrefs.lastSettingsPage = page
        sidebar.select(page)
        detail.show(page)
    }

    func windowWillClose(_ notification: Notification) {
        // After the close, so the window does not linger for a frame without its Dock icon.
        // Dropping back to .accessory also hands the focus to the app behind us.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - Sidebar

final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case page(String)
        case header(String)
    }

    private let table = NSTableView()
    private var rows: [Row] = []
    var onSelect: ((String) -> Void)?
    private var isSelectingProgrammatically = false

    override func loadView() {
        rows = [.page("general"), .header("Modules")] + ModuleManager.shared.modules.map { .page($0.id) }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .custom
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = true
        view = scroll

        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged),
                                               name: .moduleStateDidChange, object: nil)
    }

    @objc private func stateChanged() {
        let selected = table.selectedRow
        isSelectingProgrammatically = true
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        isSelectingProgrammatically = false
    }

    func select(_ page: String) {
        guard let index = rows.firstIndex(where: { if case .page(page) = $0 { return true }; return false })
        else { return }
        isSelectingProgrammatically = true
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        isSelectingProgrammatically = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 28 }
        return 32
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .page = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let cell = NSTableCellView()
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
            ])
            return cell
        case .page(let id):
            if id == "general" {
                return SidebarCell(title: "General", image: ModuleTile.general(size: 22), running: nil)
            }
            let module = ModuleManager.shared.module(id: id)!
            return SidebarCell(title: module.name, image: ModuleTile.image(for: module, size: 22),
                               running: module.isRunning)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSelectingProgrammatically, rows.indices.contains(table.selectedRow),
              case .page(let id) = rows[table.selectedRow] else { return }
        onSelect?(id)
    }
}

/// Tile, name, and — for a module — a dot that is green while it runs.
private final class SidebarCell: NSTableCellView {
    init(title: String, image: NSImage, running: Bool?) {
        super.init(frame: .zero)
        let icon = NSImageView(image: image)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        for v in [icon, label] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if let running {
            let dot = StatusDot(on: running)
            dot.translatesAutoresizingMaskIntoConstraints = false
            addSubview(dot)
            NSLayoutConstraint.activate([
                dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
                label.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -6),
            ])
            dot.setAccessibilityLabel(running ? "On" : "Off")
        } else {
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class StatusDot: NSView {
    private let on: Bool

    init(on: Bool) {
        self.on = on
        super.init(frame: .zero)
        toolTip = on ? "Running" : "Off"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        if on {
            NSColor.systemGreen.setFill()
            path.fill()
        } else {
            NSColor.tertiaryLabelColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

// MARK: - Detail

/// Scrollable page area. Pages are built on first display and kept.
final class DetailViewController: NSViewController {
    private let scroll = NSScrollView()
    private var pages: [String: NSView] = [:]
    private var current: NSView?

    override func loadView() {
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        // Automatic insets and Auto Layout between the clip view and the document disagree
        // about where "top" is; the page leaves room for the transparent title bar instead.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        view = scroll
    }

    func show(_ id: String) {
        _ = view
        let page = pages[id] ?? makePage(id)
        pages[id] = page
        guard page !== current else { return }
        current = page

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        page.removeFromSuperview()
        document.addSubview(page)
        scroll.documentView = document
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            page.topAnchor.constraint(equalTo: document.topAnchor, constant: 52),
            page.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            page.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
            document.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: 28),
        ])
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func makePage(_ id: String) -> NSView {
        if let module = ModuleManager.shared.module(id: id) {
            return ModulePageView(module: module)
        }
        return GeneralPageView()
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
