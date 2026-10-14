import Cocoa
import IOKit.pwr_mgt

#if DEBUG
extension KeepAwakeModule {
    /// Exercises real powerd assertions, rather than trusting the module's bookkeeping.
    /// All changed preferences are restored, including keys originally absent.
    func debugRunChecks() -> Bool {
        let defaults = UserDefaults.standard
        let keys = ["preventSystemSleep", "preventDisplaySleep", "startOnEnable", "showCountdown",
                    "defaultMinutes", "customMinutes", "whileAgentsWork", "agentGraceMinutes"].map { "keepawake.\($0)" }
        let saved = Dictionary(uniqueKeysWithValues: keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
        var created: [IOPMAssertionID] = []
        var failures = 0
        func expect(_ ok: Bool, _ label: String) {
            print(ok ? "ok   Keep Awake: \(label)" : "FAIL Keep Awake: \(label)")
            if !ok { failures += 1 }
        }
        func released(_ ids: [IOPMAssertionID]) -> Bool {
            ids.allSatisfy { KeepAwakeAssertions.properties($0) == nil }
        }
        func holds(_ kinds: Set<KeepAwakeAssertions.Kind>) -> Bool {
            Set(debugAssertionIDs.keys) == kinds && debugAssertionIDs.allSatisfy { kind, id in
                let properties = KeepAwakeAssertions.properties(id)
                return properties?[kIOPMAssertionTypeKey] as? String == kind.type
                    && (properties?[kIOPMAssertionLevelKey] as? NSNumber)?.intValue == kIOPMAssertionLevelOn
            }
        }
        stop()
        defer {
            assertions.debugFailKind = nil
            stop()
            assertions.debugDidCreate = nil
            for key in keys {
                if let value = saved[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            settingsChanged()
        }
        assertions.debugDidCreate = { created.append($0) }
        KeepAwakePrefs.startOnEnable = false
        // The test itself usually runs under an agent: real detection would hold assertions.
        KeepAwakePrefs.whileAgentsWork = false
        KeepAwakePrefs.preventSystemSleep = true
        KeepAwakePrefs.preventDisplaySleep = false
        KeepAwakePrefs.defaultMinutes = 0
        let inert = KeepAwakeModule()
        let inertView = inert.makeSettingsView()
        expect(!inert.hasResources && inertView.subviews.count > 0, "construction and settings are inert")
        expect(!beginSession(duration: 60) && !hasResources, "disabled module cannot acquire assertions")
        start()
        let originalItem = debugStatusItem
        start()
        expect(isRunning && !isActive && !debugHasTimer && debugStatusItem === originalItem,
               "duplicate start owns one status item; enabled module starts idle")
        expect(beginSession(duration: nil) && holds([.system]) && !debugHasTimer,
               "indefinite session holds only system assertion and no timer")
        let firstIDs = Array(debugAssertionIDs.values)
        endSession()
        expect(released(firstIDs) && !isActive && !debugHasTimer, "manual stop releases real system assertion")

        let menu = NSMenu()
        menuNeedsUpdate(menu)
        let durationMenu = menu.items.first { $0.submenu != nil }!.submenu!
        expect(durationMenu.items.filter { $0.representedObject is Int }.count == KeepAwakePrefs.durations.count,
               "native menu contains every quick duration")
        let quickDuration = durationMenu.items.first { ($0.representedObject as? Int) == 15 }!
        NSApp.sendAction(quickDuration.action!, to: quickDuration.target, from: quickDuration)
        expect(isActive && (session?.remaining ?? 0) > 890 && KeepAwakePrefs.defaultMinutes == 0,
               "quick-duration menu action starts a session without changing the default")
        let countdownIDs = debugAssertionIDs
        KeepAwakePrefs.showCountdown = true
        settingsChanged()
        expect(debugStatusItem?.button?.title.isEmpty == false, "timed session displays menu bar countdown")
        KeepAwakePrefs.showCountdown = false
        settingsChanged()
        expect(debugStatusItem?.button?.title.isEmpty == true && debugAssertionIDs == countdownIDs,
               "hiding countdown updates UI without touching assertions")
        let mainMenuAction = menuItems().first!
        NSApp.sendAction(mainMenuAction.action!, to: mainMenuAction.target, from: mainMenuAction)
        expect(!isActive && released(Array(countdownIDs.values)), "mdeck main-menu action stops the session")

        KeepAwakePrefs.preventSystemSleep = false
        KeepAwakePrefs.preventDisplaySleep = true
        expect(beginSession(duration: nil) && holds([.display]), "display-only protection is independent")
        KeepAwakePrefs.preventSystemSleep = true
        settingsChanged(reapplyProtection: true)
        expect(holds([.system, .display]), "running settings acquire both assertions immediately")
        KeepAwakePrefs.preventSystemSleep = false
        KeepAwakePrefs.preventDisplaySleep = false
        settingsChanged(reapplyProtection: true)
        expect(!isActive && debugAssertionIDs.isEmpty && released(created), "turning both protections off ends session")
        expect(!beginSession(duration: nil) && lastError != nil, "no-protection state explains why start is unavailable")

        KeepAwakePrefs.preventSystemSleep = true
        KeepAwakePrefs.preventDisplaySleep = true
        assertions.debugFailKind = .display
        expect(!beginSession(duration: 60) && !isActive && debugAssertionIDs.isEmpty && released(created) && lastError != nil,
               "partial acquisition failure rolls back kernel assertions and shows error")
        assertions.debugFailKind = nil
        expect(beginSession(duration: 60) && holds([.system, .display]) && lastError == nil,
               "session can recover after an assertion error")
        let remaining = session!.remaining!
        KeepAwakePrefs.preventDisplaySleep = false
        settingsChanged(reapplyProtection: true)
        expect(holds([.system]) && session!.remaining! <= remaining && session!.remaining! > remaining - 2,
               "changing protection preserves the deadline")
        expect(!beginSession(duration: .nan) && !beginSession(duration: .infinity)
               && !beginSession(duration: -1) && !beginSession(duration: 0)
               && !beginSession(duration: Double(KeepAwakePrefs.maximumMinutes * 60 + 1)) && isActive,
               "invalid durations preserve the existing session")
        expect(!beginSession(duration: 60, until: Date().addingTimeInterval(-1)) && isActive,
               "past end time is rejected")
        expect(beginSession(duration: nil, until: Date().addingTimeInterval(60)) && debugHasTimer,
               "end-time session is bounded even without explicit duration")

        KeepAwakePrefs.preventDisplaySleep = true
        expect(beginSession(duration: 2) && holds([.system, .display]), "short session acquires both real assertions")
        let timedIDs = Array(debugAssertionIDs.values)
        expect(timedIDs.allSatisfy {
            KeepAwakeAssertions.properties($0)?[kIOPMAssertionTimeoutActionKey] as? String == kIOPMAssertionTimeoutActionRelease
        }, "powerd owns a release timeout for each timed assertion")
        // Deliberately stall the app's run loop: macOS, not the UI timer, must release these.
        Thread.sleep(forTimeInterval: 3)
        expect(released(timedIDs), "kernel timeout releases both assertions while app timer is stalled")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        expect(!isActive && debugAssertionIDs.isEmpty && !debugHasTimer, "expiration clears session and timer")

        _ = beginSession(duration: 0.3)
        let replacedIDs = Array(debugAssertionIDs.values)
        _ = beginSession(duration: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        expect(isActive && holds([.system, .display]) && !debugHasTimer && released(replacedIDs),
               "replacing timed session cancels its timer and releases its assertions")
        expect(agentHoldChecks(expect: expect, released: released, holds: holds), "agent hold checks")
        _ = beginSession(duration: nil)
        showSessionPanel()
        let panel = debugPanel
        expect(panel?.isVisible == true, "session panel is owned by module")
        stop()
        stop()
        expect(!isRunning && !hasResources && panel?.isVisible == false && released(created),
               "duplicate stop releases all assertions, timers, observers, panel and status item")
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        expect(!hasResources && released(created), "late timer callbacks cannot reacquire resources")
        KeepAwakePrefs.whileAgentsWork = true
        settingsChanged(agentMode: true)
        expect(debugAgentMonitor == nil, "agent mode creates no monitor while the module is disabled")
        KeepAwakePrefs.startOnEnable = true
        KeepAwakePrefs.defaultMinutes = 5
        KeepAwakePrefs.whileAgentsWork = false
        start()
        expect(isActive && holds([.system, .display]) && debugHasTimer && (session?.remaining ?? 0) > 290,
               "restart with automatic start uses configured default duration")
        KeepAwakePrefs.whileAgentsWork = true
        settingsChanged(agentMode: true)
        expect(debugAgentMonitor?.isRunning == true, "enabling agent mode starts the monitor immediately")
        stop()
        expect(!hasResources && released(created), "restart teardown releases every kernel assertion and the agent monitor")
        expect(Self.debugAgentMonitorChecks(expect), "agent monitor checks")
        return failures == 0
    }

    private func agentHoldChecks(expect: (Bool, String) -> Void, released: ([IOPMAssertionID]) -> Bool,
                                 holds: (Set<KeepAwakeAssertions.Kind>) -> Bool) -> Bool {
        func timeout(_ id: IOPMAssertionID) -> Double {
            (KeepAwakeAssertions.properties(id)?[kIOPMAssertionTimeoutKey] as? NSNumber)?.doubleValue ?? 0
        }
        KeepAwakePrefs.preventSystemSleep = true
        KeepAwakePrefs.preventDisplaySleep = false
        endSession()
        agentsChanged([.claude])
        expect(!isActive && holds([.system]) && debugAssertionIDs.values.allSatisfy { timeout($0) == 0 }
               && statusText?.contains("Claude Code working") == true,
               "agent activity holds an untimed assertion without a manual session")
        expect(beginSession(duration: 2) && holds([.system]) && debugAssertionIDs.values.allSatisfy { timeout($0) == 0 },
               "a timed session during agent work gets no powerd timeout")
        let heldIDs = Array(debugAssertionIDs.values)
        Thread.sleep(forTimeInterval: 2.5)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        expect(!isActive && !debugHasTimer && holds([.system]),
               "expired manual session leaves the agent hold in place")
        agentsChanged([])
        expect(debugAssertionIDs.isEmpty && released(heldIDs) && statusText?.hasPrefix("Idle") == true,
               "idle agents release the hold")
        _ = beginSession(duration: 60)
        agentsChanged([.codex])
        expect(holds([.system]) && debugAssertionIDs.values.allSatisfy { timeout($0) == 0 }, "agent work lifts the session timeout")
        agentsChanged([])
        expect(isActive && holds([.system]) && debugAssertionIDs.values.allSatisfy { timeout($0) > 0 && timeout($0) <= 60 },
               "idle agents restore the remaining session timeout")
        agentsChanged([.claude, .codex])
        KeepAwakePrefs.preventSystemSleep = false
        settingsChanged(reapplyProtection: true)
        expect(!isActive && debugAssertionIDs.isEmpty, "turning protections off releases an agent hold")
        KeepAwakePrefs.preventSystemSleep = true
        settingsChanged(reapplyProtection: true)
        agentsChanged([])
        agentsChanged([.claude])
        expect(holds([.system]), "agent hold resumes once protection returns")
        agentsChanged([])
        KeepAwakePrefs.preventDisplaySleep = true
        return debugAssertionIDs.isEmpty
    }

    /// Real FSEvents and process-tree detection against a temporary folder and this process.
    static func debugAgentMonitorChecks(_ expect: (Bool, String) -> Void) -> Bool {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mdeck-agents-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = AgentActivityMonitor.Source(agent: .codex, processName: ProcessInfo.processInfo.processName,
                                                 transcripts: folder)
        var changes = 0
        let monitor = AgentActivityMonitor(sources: [source], grace: 2) { _ in changes += 1 }
        monitor.start()
        var ok = monitor.working.isEmpty && monitor.debugWatchCount == 1
        expect(ok, "idle agent: transcript folder watched, nothing reported")
        try? Data("{}\n".utf8).write(to: folder.appendingPathComponent("rollout.jsonl"))
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        let written = monitor.working == [.codex] && changes == 1
        expect(written, "transcript write marks the agent as working")
        Thread.sleep(forTimeInterval: 2.1)
        monitor.evaluate()
        let expired = monitor.working.isEmpty && changes == 2
        expect(expired, "transcript activity expires after the grace period")
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 5; true"] // Compound, so sh is not replaced by sleep.
        try? shell.run()
        Thread.sleep(forTimeInterval: 0.2)
        monitor.evaluate()
        let tool = monitor.working == [.codex]
        expect(tool, "a shell child of the agent process counts as a running tool")
        shell.terminate()
        shell.waitUntilExit()
        monitor.evaluate()
        let toolDone = monitor.working.isEmpty
        expect(toolDone, "the tool's exit ends the activity")
        monitor.stop()
        let stopped = !monitor.isRunning && monitor.debugWatchCount == 0
        expect(stopped, "stop removes the timer and FSEvents streams")
        ok = ok && written && expired && tool && toolDone && stopped
        return ok
    }

    /// Captures the same native NSMenu entries used by the dedicated menu bar item.
    func debugMenuWindow() -> NSWindow {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menuNeedsUpdate(menu)
        let rows = menu.items.filter { !$0.isSeparatorItem }.map { entry -> NSView in
            let text = (entry.state == .on ? "✓ " : "   ") + entry.title + (entry.submenu != nil ? "  ›" : "")
            let label = NSTextField(labelWithString: text)
            label.font = .menuFont(ofSize: 13)
            label.textColor = entry.isEnabled ? .labelColor : .secondaryLabelColor
            return label
        }
        let content = RowsView(rows, spacing: 12)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 275),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Keep Awake — Menu Entries"
        window.isReleasedWhenClosed = false
        window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
        ])
        window.center()
        window.orderFront(nil)
        return window
    }
}
#endif
