import Cocoa

#if DEBUG
/// Development-only entry points, compiled by `./build.sh --debug` only. Screenshotting from a
/// terminal needs Screen Recording, but an app may always capture *its own* windows — so the UI
/// can be checked without touching the user's screen.
///
///   --snapshot-settings <path> [--page <id>]   the settings window, on a page
///                     [--full-page]            the whole page, scrolled part included
///   --altty-snapshot <path>                    the switcher panel
///   --altty-demo                               the switcher panel for 5 s
///   --dock-info                                displays, Dock edge and Dock display
///   --lifecycle-test                           start and stop every module, check nothing is left
///   --statusbar-gap [--no-icon]                our status items for 8 s, to measure from outside
///   --clean-url <url>                          what Clean Links does with a link
///   --cleanlinks-hud <path>                    Clean Links' notice
///   --appearance dark|light
enum Debug {
    static func handleFlags() -> Bool {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return nil }
            return args[i + 1]
        }

        if let name = value(after: "--appearance") {
            NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
        }
        if args.contains("--badge-contrast") {
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                    print(name == .aqua ? "LIGHT" : "DARK")
                    for preset in StoredColor.presets {
                        let cases: [(String, CGFloat, Bool)] = [("25pt", 25, false), ("12.5pt", 12.5, false), ("symbol", 20, true)]
                        let cells = cases.map { label, size, symbol -> String in
                            let fg = StoredColor.badgeForeground(on: preset.color, fontSize: size, isSymbol: symbol)
                            let ratio = StoredColor.contrast(fg, preset.color)
                            let need: CGFloat = (symbol || size >= 18) ? 3 : 4.5
                            return String(format: "%@ %@ %.2f%@", label, fg == .white ? "white" : "black", ratio, ratio >= need ? "" : " FAIL")
                        }
                        print("  " + preset.id.padding(toLength: 9, withPad: " ", startingAt: 0) + cells.joined(separator: " | "))
                    }
                }
            }
            NSApp.terminate(nil)
            return true
        }
        if args.contains("--menu-colors") {
            StatusMenu.debugColors()
            NSApp.terminate(nil)
            return true
        }
        if args.contains("--statusbar-gap") {
            statusBarGap(showIcon: !args.contains("--no-icon"))
            return true
        }
        if args.contains("--menu-size") {
            let delegate = NSApp.delegate as! AppDelegate
            print("menu size:", delegate.statusMenu!.debugSize())
            NSApp.terminate(nil)
            return true
        }
        if args.contains("--appmonitor-test") || value(after: "--appmonitor-snapshot") != nil {
            guard let monitor = ModuleManager.shared.module(id: "appmonitor") as? AppMonitorModule else { return true }
            let cpuUnitsValid = AppSampler.debugVerifyCPUTimeUnits()
            print(cpuUnitsValid ? "CPU time units PASSED" : "CPU time units FAILED")
            monitor.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + max(3, AppMonitorPrefs.refreshInterval + 0.5)) {
                let snapshot = monitor.snapshot
                print("CPU: \(snapshot.cpu * 100)% Memory: \(snapshot.memory * 100)% Ready: \(snapshot.ready)")
                for app in snapshot.apps.sorted(by: { $0.memory > $1.memory }) {
                    print("\(app.name): CPU \(app.cpu)% Memory \(app.memory) Processes \(app.count)")
                }
                if let path = value(after: "--appmonitor-snapshot") {
                    monitor.debugShowPanel()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        capture(window: monitor.debugPanel, to: path)
                        monitor.stop()
                        NSApp.terminate(nil)
                    }
                } else {
                    let valid = cpuUnitsValid && snapshot.ready && !snapshot.apps.isEmpty && snapshot.cpu.isFinite && (0...1).contains(snapshot.cpu) && (0...1).contains(snapshot.memory)
                    monitor.stop()
                    print(valid && !monitor.hasResources ? "ALL PASSED" : "FAILED")
                    exit(valid && !monitor.hasResources ? 0 : 1)
                }
            }
            return true
        }
        if let path = value(after: "--cleanlinks-hud") {
            CleanLinksDebug.snapshotHUD(to: path)
            return true
        }
        if let url = value(after: "--clean-url") {
            CleanLinksDebug.cleanURL(url)
            return true
        }
        if args.contains("--lifecycle-test") {
            lifecycleTest()
            return true
        }
        if args.contains("--keepawake-test") {
            ModuleManager.shared.stopAll()
            let module = ModuleManager.shared.module(id: "keepawake") as! KeepAwakeModule
            let passed = module.debugRunChecks()
            print(passed ? "ALL PASSED" : "FAILED")
            exit(passed ? 0 : 1)
        }
        if args.contains("--keepawake-agents") {
            // Watches the real transcript folders for a few seconds, then prints what counts as work.
            let monitor = AgentActivityMonitor(grace: 300) { _ in }
            monitor.start()
            RunLoop.main.run(until: Date().addingTimeInterval(6))
            monitor.evaluate()
            let tools = AgentActivityMonitor.agentsRunningTools(AgentActivityMonitor.defaultSources)
            print("watched folders: \(monitor.debugWatchCount)")
            print("running tools: \(tools.map(\.rawValue).sorted())")
            print("working: \(monitor.working.map(\.rawValue).sorted())")
            monitor.stop()
            exit(0)
        }
        if let path = value(after: "--keepawake-snapshot") {
            let module = ModuleManager.shared.module(id: "keepawake") as! KeepAwakeModule
            module.start()
            module.showSessionPanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                capture(window: module.debugPanel, to: path)
                module.stop()
                NSApp.terminate(nil)
            }
            return true
        }
        if let path = value(after: "--keepawake-menu-snapshot") {
            let module = ModuleManager.shared.module(id: "keepawake") as! KeepAwakeModule
            module.start()
            if args.contains("--keepawake-active") { _ = module.beginSession(duration: 90 * 60) }
            let window = module.debugMenuWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                capture(window: window, to: path)
                window.close()
                module.stop()
                NSApp.terminate(nil)
            }
            return true
        }
        if args.contains("--dock-info") {
            let displays = Displays.active()
            for d in displays { print("display \(d.id) \(d.name) key=\(d.key) bounds=\(d.bounds)") }
            print("edge:", DockEdge.current.rawValue)
            print("dock frame:", DockMover.dockFrame().map { "\($0)" } ?? "unavailable (Accessibility?)")
            print("dock display:", DockMover.dockDisplay(in: displays)?.name ?? "?")
            NSApp.terminate(nil)
            return true
        }
        if let path = value(after: "--snapshot-settings") {
            SettingsWindowController.shared.show(page: value(after: "--page") ?? "general")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if args.contains("--full-page") {
                    captureFullPage(of: SettingsWindowController.shared.window, to: path)
                } else {
                    capture(window: SettingsWindowController.shared.window, to: path)
                }
                NSApp.terminate(nil)
            }
            return true
        }
        if let path = value(after: "--altty-snapshot") {
            SwitcherController.shared.snapshot(to: path)
            return true
        }
        if args.contains("--altty-demo") {
            SwitcherController.shared.demo()
            return true
        }
        return false
    }

    /// `--statusbar-gap [--no-icon]`: Ping and App Monitor running beside mdeck's icon for 8 s,
    /// logging what AppKit reports for each of our status items. Since macOS 26 the system hosts
    /// status items, so their windows report no usable frame here: measure the real on-screen
    /// gap from outside, with the Accessibility frames and a capture of the menu bar.
    private static func statusBarGap(showIcon: Bool) {
        if showIcon { (NSApp.delegate as? AppDelegate)?.statusMenu?.debugForceVisible() }
        for id in ["appmonitor", "ping"] { ModuleManager.shared.module(id: id)?.start() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            for window in NSApp.windows where window.className.contains("StatusBarWindow") {
                guard let button = window.contentView.flatMap({ find(NSStatusBarButton.self, in: $0) }) else { continue }
                print("\(button.accessibilityLabel() ?? "?"): window \(NSStringFromRect(window.frame))"
                      + " · button \(NSStringFromRect(button.frame))"
                      + " · image \(button.image.map { NSStringFromSize($0.size) } ?? "-")")
            }
            fflush(stdout)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            for id in ["appmonitor", "ping"] { ModuleManager.shared.module(id: id)?.stop() }
            NSApp.terminate(nil)
        }
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        (view as? T) ?? view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    /// Runs each module for a moment without touching the saved on/off state.
    private static func lifecycleTest() {
        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            print(ok ? "ok   \(what)" : "FAIL \(what)")
            if !ok { failures += 1 }
        }
        let modules = ModuleManager.shared.modules
        for m in modules where m.isRunning { m.stop() }
        expect(HotkeyManager.shared.registeredCount == 0, "no hotkey before start")

        for m in modules {
            m.start()
            expect(m.isRunning, "\(m.name) running after start")
            m.start()
            expect(m.isRunning, "\(m.name) running after duplicate start")
            print("     status: \(m.statusText ?? "-") · menu items: \(m.menuItems().map(\.title))")
            if m is AlttyModule {
                expect(HotkeyManager.shared.registeredCount >= 1, "Altty registered its shortcut")
            }
            if let d = m as? DockLockModule {
                expect(d.hasEdgeGuard == Permissions.isAccessibilityTrusted, "Dock Lock tap iff Accessibility")
            }
            if let c = m as? CleanLinksModule {
                expect(c.watchMode != .stopped, "Clean Links watches the clipboard")
                expect(c.debugHasHotkey == (CleanLinksPrefs.pasteOriginalShortcut != nil), "Clean Links registered its shortcut")
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            if let c = m as? CleanLinksModule {
                expect(c.rules.rules != nil, "Clean Links loaded its rules")
            }
            if let monitor = m as? AppMonitorModule {
                expect(monitor.debugVerifyPanelBehavior(), "App Monitor limits rankings to six, fits content, and toggles with its status button")
                expect(monitor.debugVerifyPinning(), "App Monitor pin preserves panel; unpin dismisses and removes monitors")
                let gauges = monitor.debugStatusItem
                expect(gauges?.length == NSStatusItem.variableLength, "App Monitor gauges padded on both sides without Ping")
                let ping = ModuleManager.shared.module(id: "ping")
                ping?.start()
                expect(gauges?.length == (gauges?.button?.image?.size.width ?? -1)
                       && gauges?.button?.image?.isTemplate == true, "App Monitor gauges flush against the Ping dot")
                ping?.stop()
                expect(gauges?.length == NSStatusItem.variableLength, "App Monitor gauges padded again after Ping stops")
            }
            if let awake = m as? KeepAwakeModule {
                expect(awake.debugRunChecks(), "Keep Awake lifecycle and kernel assertion checks")
            }
            if let net = m as? PingModule {
                expect(net.debugRunChecks(), "Ping probe, state and lifecycle checks")
            }
            m.stop()
            if let awake = m as? KeepAwakeModule {
                expect(!awake.hasResources, "Keep Awake released assertions, timers, observers, panel and status item")
            }
            if let monitor = m as? AppMonitorModule {
                expect(!monitor.hasResources, "App Monitor released timer, sampler, panel and status item")
            }
            if let net = m as? PingModule {
                expect(!net.hasResources, "Ping released its timer, wake observer, ping and status item")
            }
            m.stop()
            expect(!m.isRunning, "\(m.name) stopped after duplicate stop")
            if m is AppMonitorModule {
                m.start()
                expect(m.isRunning, "App Monitor restarted")
                m.stop()
            }
            if let c = m as? CleanLinksModule {
                expect(!c.hasResources, "Clean Links released its watcher, shortcut, timer, notice, requests and rules")
                c.start()
                expect(c.isRunning && c.watchMode != .stopped, "Clean Links restarted")
                c.stop()
                expect(!c.hasResources, "Clean Links released everything after restart")
            }
            expect(HotkeyManager.shared.registeredCount == 0, "\(m.name) left no hotkey")
            if let d = m as? DockLockModule { expect(!d.hasEdgeGuard, "Dock Lock removed its tap") }
        }
        expect(!NativeSwitcher.isDisabledByUs, "native ⌘Tab untouched")
        for (what, ok) in CleanLinksDebug.verify() { expect(ok, what) }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }

    /// While the screen is locked the WindowServer composites nothing and captures come out
    /// empty: draw the view hierarchy instead, on a plain window background, since
    /// behind-window materials only exist on screen.
    private static func drawOffscreen(window: NSWindow, to path: String) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size, flipped: false) { rect in
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            }
            rep.draw(in: rect)
            return true
        }
        guard let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?
            .representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (drawn off screen: the screen is locked)")
    }

    /// The whole scrollable page, one capture per screenful (`out-1.png`, `out-2.png`…),
    /// scrolling the real window so each part is drawn exactly as on screen.
    static func captureFullPage(of window: NSWindow?, to path: String) {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        guard let content = window?.contentView,
              let scroll = scrollViews(in: content).max(by: {
                  ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
              }),
              let page = scroll.documentView else { return }
        let visible = scroll.contentView.bounds.height
        let base = (path as NSString).deletingPathExtension
        var offset: CGFloat = 0
        var index = 1
        while true {
            let y = min(offset, max(0, page.bounds.height - visible))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: page.isFlipped ? y : page.bounds.height - visible - y))
            scroll.reflectScrolledClipView(scroll.contentView)
            window?.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            capture(window: window, to: "\(base)-\(index).png")
            if y + visible >= page.bounds.height { break }
            offset += visible * 0.9
            index += 1
        }
    }

    static func capture(window: NSWindow?, to path: String) {
        guard let window else { return }
        if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true {
            return drawOffscreen(window: window, to: path)
        }
        let wid = CGWindowID(window.windowNumber)
        guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, wid,
                                               [.boundsIgnoreFraming, .bestResolution]),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write("capture failed\n".data(using: .utf8)!)
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(cg.width)x\(cg.height)")
    }
}
#endif
