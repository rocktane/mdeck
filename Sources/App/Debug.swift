import Cocoa

#if DEBUG
/// Development-only entry points, compiled by `./build.sh --debug` only. Screenshotting from a
/// terminal needs Screen Recording, but an app may always capture *its own* windows — so the UI
/// can be checked without touching the user's screen.
///
///   --snapshot-settings <path> [--page <id>]   the settings window, on a page
///   --altty-snapshot <path>                    the switcher panel
///   --altty-demo                               the switcher panel for 5 s
///   --dock-info                                displays, Dock edge and Dock display
///   --lifecycle-test                           start and stop every module, check nothing is left
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
        if args.contains("--lifecycle-test") {
            lifecycleTest()
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
                capture(window: SettingsWindowController.shared.window, to: path)
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
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            if let monitor = m as? AppMonitorModule {
                expect(monitor.debugVerifyPanelBehavior(), "App Monitor limits rankings to six, fits content, and toggles with its status button")
                expect(monitor.debugVerifyPinning(), "App Monitor pin preserves panel; unpin dismisses and removes monitors")
            }
            m.stop()
            if let monitor = m as? AppMonitorModule {
                expect(!monitor.hasResources, "App Monitor released timer, sampler, panel and status item")
            }
            m.stop()
            expect(!m.isRunning, "\(m.name) stopped after duplicate stop")
            if m is AppMonitorModule {
                m.start()
                expect(m.isRunning, "App Monitor restarted")
                m.stop()
            }
            expect(HotkeyManager.shared.registeredCount == 0, "\(m.name) left no hotkey")
            if let d = m as? DockLockModule { expect(!d.hasEdgeGuard, "Dock Lock removed its tap") }
        }
        expect(!NativeSwitcher.isDisabledByUs, "native ⌘Tab untouched")
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }

    static func capture(window: NSWindow?, to path: String) {
        guard let window else { return }
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
