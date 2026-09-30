import Cocoa

private final class MonitorButton: NSButton {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: 10)
        target = self
        action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { handler() }
}

/// A stable row: hover changes visibility, never the row's layout or application target.
private final class MonitorAppRow: NSView {
    let value = NSTextField(labelWithString: "")
    private let processes = NSTextField(labelWithString: "")
    private let actions: NSStackView
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var normalTextLimit: NSLayoutConstraint!
    private var hoverTextLimit: NSLayoutConstraint!

    init(app: MonitoredApp, quit: @escaping () -> Void, force: @escaping () -> Void) {
        let quitButton = MonitorButton("Quit", handler: quit)
        let forceButton = MonitorButton("Force Quit", handler: force)
        actions = NSStackView(views: [quitButton, forceButton])
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        let icon = NSImageView()
        icon.image = app.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: app.name)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        processes.font = .systemFont(ofSize: 10)
        processes.textColor = .secondaryLabelColor
        let details = NSStackView(views: [name, processes])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 4
        value.font = .monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
        value.alignment = .right
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        value.setContentHuggingPriority(.required, for: .horizontal)
        actions.orientation = .vertical
        actions.spacing = 2
        quitButton.setAccessibilityLabel("Quit \(app.name)")
        forceButton.setAccessibilityLabel("Force Quit \(app.name)")
        let ownApp = app.roots.contains { $0.processIdentifier == getpid() }
        quitButton.isEnabled = !ownApp
        forceButton.isEnabled = !ownApp
        for view in [icon, details, value, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 64),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            details.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            details.centerYAnchor.constraint(equalTo: centerYAnchor),

            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            // The actions sit immediately before the metric. Hidden controls retain their
            // geometry, so hovering does not shift the value or change the click target.
            actions.trailingAnchor.constraint(equalTo: value.leadingAnchor, constant: -10),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.widthAnchor.constraint(equalToConstant: 76),
            quitButton.widthAnchor.constraint(equalTo: actions.widthAnchor),
            forceButton.widthAnchor.constraint(equalTo: actions.widthAnchor),
        ])
        normalTextLimit = details.trailingAnchor.constraint(lessThanOrEqualTo: value.leadingAnchor, constant: -10)
        hoverTextLimit = details.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -10)
        normalTextLimit.isActive = true
        actions.isHidden = true
        update(app: app, metric: "")
        refreshBackground()
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(app: MonitoredApp, metric: String) {
        value.stringValue = metric
        processes.stringValue = "\(app.count) \(app.count == 1 ? "process" : "processes")"
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        if let window {
            setHovered(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
        }
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    private func setHovered(_ value: Bool) {
        hovered = value
        actions.isHidden = !value
        normalTextLimit.isActive = !value
        hoverTextLimit.isActive = value
        refreshBackground()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBackground()
    }
    private func refreshBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            layer?.backgroundColor = (dark
                ? NSColor.white.withAlphaComponent(hovered ? 0.12 : 0.065)
                : NSColor.black.withAlphaComponent(hovered ? 0.075 : 0.035)).cgColor
        }
    }
}

private final class MonitorList: NSStackView {
    override var isFlipped: Bool { true }
}

final class AppMonitorPanel: NSPanel {
    private var pinned = false
    private var confirming = false
    private weak var statusWindow: NSWindow?
    private weak var statusButton: NSStatusBarButton?
    private var outside: Any?
    private var local: Any?
    private let cpuList = MonitorList()
    private let memoryList = MonitorList()
    private let cpuTitle = NSTextField(labelWithString: "CPU")
    private let memoryTitle = NSTextField(labelWithString: "Memory")
    private var rowIDs: [[String]] = [[], []]
    private var rows: [[MonitorAppRow]] = [[], []]
    private var latest = AppMonitorSnapshot()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: 590), styleMask: [.borderless], backing: .buffered, defer: false)
        title = "App Monitor"
        isReleasedWhenClosed = false
        level = .floating
        hidesOnDeactivate = false
        isFloatingPanel = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Mask the visual effect itself: layer clipping alone does not clip the
        // WindowServer's behind-window material at the rounded corners.
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.masksToBounds = true
        contentView = root
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        let mask = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        mask.resizingMode = .stretch
        background.maskImage = mask
        background.frame = root.bounds
        background.autoresizingMask = [.width, .height]
        root.addSubview(background)
        // Keep the window backing transparent as well as its view hierarchy.
        backgroundColor = .clear
        isOpaque = false
        let pin = MonitorButton("") { [weak self] in self?.togglePin() }
        pin.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin panel")
        pin.isBordered = false
        pin.focusRingType = .none
        pin.toolTip = "Pin panel"
        pin.setAccessibilityLabel("Pin panel")
        pinButton = pin
        let header = NSView()
        let columns = NSStackView(views: [cpuList, memoryList])
        columns.orientation = .horizontal
        columns.distribution = .fillEqually
        columns.alignment = .top
        columns.spacing = 16
        for (heading, list) in [(cpuTitle, cpuList), (memoryTitle, memoryList)] {
            heading.font = .systemFont(ofSize: 15, weight: .semibold)
            heading.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(heading)
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 6
        }
        pin.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(pin)
        for view in [header, columns] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            header.heightAnchor.constraint(equalToConstant: 28),
            cpuTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            cpuTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            memoryTitle.leadingAnchor.constraint(equalTo: memoryList.leadingAnchor),
            memoryTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            memoryTitle.trailingAnchor.constraint(lessThanOrEqualTo: pin.leadingAnchor, constant: -8),
            pin.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            pin.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            pin.widthAnchor.constraint(equalToConstant: 28),
            pin.heightAnchor.constraint(equalToConstant: 28),
            columns.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            columns.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            columns.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            columns.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),
        ])
    }
    private var pinButton: NSButton?
    override var canBecomeKey: Bool { true }
    private func togglePin() {
        pinned.toggle()
        level = pinned ? .statusBar : .floating
        collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace, .fullScreenAuxiliary]
        if pinned { orderFrontRegardless() }
        pinButton?.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: pinned ? "Unpin panel" : "Pin panel")
        pinButton?.toolTip = pinned ? "Unpin panel" : "Pin panel"
        pinButton?.setAccessibilityLabel(pinned ? "Unpin panel" : "Pin panel")
    }

    func show(under button: NSStatusBarButton) {
        guard let window = button.window else { return }
        statusWindow = window
        statusButton = button
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        setFrameOrigin(NSPoint(x: max(screen.minX, min(anchor.midX - frame.width / 2, screen.maxX - frame.width)),
                               y: max(screen.minY, anchor.minY - frame.height - 6)))
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        if outside == nil {
            outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.handleOutsideClick() }
            local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown, event.keyCode == 53, !self.confirming { self.close(); return nil }
                if event.type != .keyDown, event.window !== self && event.window !== self.statusWindow { self.handleOutsideClick() }
                return event
            }
        }
    }
    #if DEBUG
    func debugVerifyStatusClickExclusion() -> Bool {
        guard let button = statusButton, let window = button.window else { return false }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        handleOutsideClick(at: NSPoint(x: rect.midX, y: rect.midY))
        return isVisible
    }

    func debugVerifySizing() -> Bool {
        let saved = latest
        let wasVisible = isVisible
        orderOut(nil) // Avoid freezing ranking under the user's pointer during fixture checks.
        let apps = (0..<8).map { index in
            MonitoredApp(url: URL(fileURLWithPath: "/tmp/MonitorFixture\(index).app"),
                         name: "Fixture \(index)", icon: NSImage(size: NSSize(width: 40, height: 40)),
                         roots: [], cpu: Double(index), memory: UInt64(8 - index), count: 1)
        }
        let top = frame.maxY
        update(AppMonitorSnapshot(apps: apps, ready: true))
        let sixHeight = frame.height
        let capped = rows.allSatisfy { $0.count == 6 }
            && rowIDs[0].first?.hasPrefix(apps[7].url.path) == true
            && rowIDs[1].first?.hasPrefix(apps[0].url.path) == true
        update(AppMonitorSnapshot(apps: Array(apps.prefix(3)), ready: true))
        let shrunk = rows.allSatisfy { $0.count == 3 } && frame.height < sixHeight && frame.maxY == top
        update(AppMonitorSnapshot())
        let empty = rows.allSatisfy { $0.isEmpty } && frame.height < sixHeight
        update(saved)
        if wasVisible { orderFrontRegardless() }
        return capped && shrunk && empty
    }

    func debugVerifyPinning() -> Bool {
        togglePin()
        dismissOutside()
        let keptOpen = isVisible && !hidesOnDeactivate && level == .statusBar && collectionBehavior.contains(.canJoinAllSpaces)
        togglePin()
        dismissOutside()
        return keptOpen && !isVisible && outside == nil && local == nil
    }
    #endif

    private func handleOutsideClick(at point: NSPoint = NSEvent.mouseLocation) {
        if let button = statusButton, let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            // NSStatusItem clicks may be delivered via another menu-bar window. Excluding
            // the button's screen rectangle avoids dismiss-then-reopen on the same click.
            if rect.contains(point) { return }
        }
        dismissOutside()
    }

    private func dismissOutside() { if !pinned && !confirming { close() } }
    override func close() {
        if let outside { NSEvent.removeMonitor(outside) }; outside = nil
        if let local { NSEvent.removeMonitor(local) }; local = nil
        super.close()
    }
    func dispose() { close(); cpuList.arrangedSubviews.forEach { $0.removeFromSuperview() }; memoryList.arrangedSubviews.forEach { $0.removeFromSuperview() } }

    func update(_ snapshot: AppMonitorSnapshot) {
        latest = snapshot
        guard !confirming else { return }
        cpuTitle.stringValue = snapshot.ready ? String(format: "CPU · %.0f%%", snapshot.cpu * 100) : "CPU · Measuring…"
        memoryTitle.stringValue = String(format: "Memory · %.0f%%", snapshot.memory * 100)
        for (column, list) in [cpuList, memoryList].enumerated() {
            var apps = snapshot.apps.sorted {
                let a = column == 0 ? $0.cpu : Double($0.memory)
                let b = column == 0 ? $1.cpu : Double($1.memory)
                return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a > b
            }
            apps = Array(apps.prefix(6))
            // Freeze existing rows while the pointer is in the panel, so a refresh cannot
            // move a different application's Quit button underneath a click.
            if isVisible && frame.contains(NSEvent.mouseLocation) {
                let order = Dictionary(uniqueKeysWithValues: rowIDs[column].enumerated().map { ($0.element, $0.offset) })
                func identity(_ app: MonitoredApp) -> String {
                    app.url.path + ":" + app.roots.map { String($0.processIdentifier) }.sorted().joined(separator: ",")
                }
                apps.sort { (order[identity($0)] ?? Int.max) < (order[identity($1)] ?? Int.max) }
            }
            let ids = apps.map { $0.url.path + ":" + $0.roots.map { String($0.processIdentifier) }.sorted().joined(separator: ",") }
            // Preserve buttons and scroll position when the order is unchanged.
            if ids != rowIDs[column] || list.arrangedSubviews.isEmpty {
                list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
                rows[column] = []
                rowIDs[column] = ids
                for app in apps {
                    let row = MonitorAppRow(app: app,
                        quit: { [weak self] in self?.terminate(app, force: false) },
                        force: { [weak self] in self?.terminate(app, force: true) })
                    rows[column].append(row)
                    list.addView(row, in: .top)
                    row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                }
                if apps.isEmpty { list.addView(NSTextField(labelWithString: "No applications to display."), in: .top) }
            }
            for (app, row) in zip(apps, rows[column]) {
                let value = column == 0 ? (snapshot.ready ? String(format: "%.1f%%", min(100, app.cpu)) : "Measuring…") : Self.formatMemory(app.memory)
                row.update(app: app, metric: value)
            }
        }
        let count = min(6, snapshot.apps.count)
        let rowsHeight = count == 0 ? 32 : CGFloat(count * 64 + (count - 1) * 6)
        let height = 12 + 28 + 12 + rowsHeight + 16
        if frame.height != height {
            // Anchor the top edge below the menu bar when the application count changes.
            let top = frame.maxY
            setFrame(NSRect(x: frame.minX, y: top - height, width: frame.width, height: height), display: true)
            invalidateShadow()
        }
    }

    private static func formatMemory(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        return megabytes >= 1024 ? String(format: "%.2f GB", megabytes / 1024) : String(format: "%.0f MB", megabytes)
    }

    private func terminate(_ app: MonitoredApp, force: Bool) {
        guard !confirming else { return }
        if force {
            confirming = true
            let alert = NSAlert()
            alert.messageText = "Force quit \(app.name)?"
            alert.informativeText = "Unsaved changes may be lost."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Force Quit")
            alert.beginSheetModal(for: self) { [weak self] response in
                guard let self else { return }
                self.confirming = false
                if response == .alertSecondButtonReturn { self.requestTermination(app, force: true) }
                self.update(self.latest)
            }
        } else { requestTermination(app, force: false) }
    }
    private func requestTermination(_ app: MonitoredApp, force: Bool) {
        let roots = app.roots.filter { !$0.isTerminated && $0.processIdentifier != getpid() }
        let failed = roots.map { force ? $0.forceTerminate() : $0.terminate() }.contains(false)
        if failed {
            confirming = true
            let alert = NSAlert()
            alert.messageText = "Could not quit \(app.name)."
            alert.informativeText = "The application may have refused the request or macOS may have denied it."
            alert.beginSheetModal(for: self) { [weak self] _ in self?.confirming = false }
        }
    }
}
