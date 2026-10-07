#!/usr/bin/env swift
import Cocoa
import ApplicationServices

// Integration test of the running app: actual Carbon hotkeys, modifier-release polling,
// switcher ordering, and the application that macOS really activates. Requires two running
// apps with windows on this Space, Altty on Cmd+Tab, and permission for the test's host
// to control System Events. Modifier holds use System Events' persistent keyboard state.
// Usage: swift scripts/test-altty.swift <source bundle ID> <target bundle ID> [round trips]
//        [--settings-open] (reproduces activation failing while settings are open)

func pause(_ seconds: Double) {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
}
func frontPID() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
func frontName() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none" }
func automation(_ action: String) -> Bool {
    let script = Process()
    script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    script.arguments = ["-e", "tell application \"System Events\" to \(action)"]
    do {
        try script.run()
        script.waitUntilExit()
    } catch {
        print("Could not send test key: \(error.localizedDescription)")
        return false
    }
    return script.terminationStatus == 0
}
func key(_ code: CGKeyCode, down: Bool) {
    let action: String
    if code == 55 {
        action = "key \(down ? "down" : "up") command"
    } else {
        guard down else { return } // System Events sends both edges for a key code.
        action = "key code \(code)"
    }
    guard automation(action) else {
        _ = automation("key up command")
        print("System Events could not send the test key.")
        exit(2)
    }
}
func press(_ code: CGKeyCode) {
    key(code, down: true)
    pause(0.035)
}
func releaseModifiers() {
    key(55, down: false)
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}
func switcherOrder(_ pid: pid_t) -> [String] {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.25)
    let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    // The non-activating switcher exposes its icon cells directly as window children.
    // Read only these labels, never the application menu or other apps' window contents.
    for window in windows {
        let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
        let names = children.compactMap { child -> String? in
            guard attribute(child, kAXRoleAttribute) as? String == kAXButtonRole else { return nil }
            return attribute(child, kAXDescriptionAttribute) as? String
        }
        if names.count >= 2 { return names }
    }
    return []
}
func waitForFront(_ app: NSRunningApplication) -> Bool {
    let deadline = Date(timeIntervalSinceNow: 1.5)
    repeat {
        if frontPID() == app.processIdentifier { return true }
        pause(0.02)
    } while Date() < deadline
    return frontPID() == app.processIdentifier
}
func activate(_ app: NSRunningApplication) -> Bool {
    app.activate(options: [.activateAllWindows])
    guard waitForFront(app) else { return false }
    pause(0.15) // Let the workspace activation notification reach Altty's MRU tracker.
    return true
}

let opensSettings = CommandLine.arguments.contains("--settings-open")
let args = CommandLine.arguments.filter { $0 != "--settings-open" }
let trips = args.count == 4 ? Int(args[3]) ?? 0 : 5
guard (3...4).contains(args.count), trips > 0, trips <= 100 else {
    print("Usage: swift scripts/test-altty.swift <source bundle ID> <target bundle ID> [round trips: 1...100] [--settings-open]")
    exit(2)
}
guard AXIsProcessTrusted() else {
    print("Test host needs Accessibility to inspect the switcher's app order.")
    exit(2)
}
func running(_ bundleID: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
}
guard let source = running(args[1]), let target = running(args[2]),
      source.processIdentifier != target.processIdentifier,
      let mdeck = running("com.yohan.mdeck"),
      source.processIdentifier != mdeck.processIdentifier,
      target.processIdentifier != mdeck.processIdentifier else {
    print("mdeck and two distinct test apps must already be running.")
    exit(2)
}
guard NSEvent.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty else {
    print("Release the keyboard modifiers before starting the test (flags: \(NSEvent.modifierFlags.rawValue)).")
    exit(2)
}
let original = NSWorkspace.shared.frontmostApplication
let originalPointer = CGEvent(source: nil)?.location
var failures = 0
var checks = 0
func expect(_ ok: Bool, _ label: String) {
    checks += 1
    print("\(ok ? "PASS" : "FAIL") \(label)")
    if !ok { failures += 1 }
}
func run() {
    defer {
        releaseModifiers()
        if let original { _ = activate(original) }
        if let originalPointer { CGWarpMouseCursorPosition(originalPointer) }
    }
    // Keep hover selection from changing the target while keyboard switching is tested.
    let screen = NSScreen.screens.first {
        NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
    } ?? NSScreen.screens[0]
    let pointer = CGPoint(x: screen.frame.minX + 10,
                          y: NSScreen.screens[0].frame.maxY - screen.frame.maxY + 10)
    CGWarpMouseCursorPosition(pointer)
    if opensSettings {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", mdeck.bundleURL!.path]
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            expect(false, "could not open mdeck settings: \(error.localizedDescription)")
            return
        }
        guard open.terminationStatus == 0 else {
            expect(false, "could not open mdeck settings")
            return
        }
        pause(0.5)
        expect(mdeck.activationPolicy == .regular, "settings make mdeck a regular app")
    }
    guard activate(target), activate(source) else {
        expect(false, "could not establish the source and target activation order")
        return
    }
    // Inspect then cancel: first must be the actual foreground app; second, the target.
    key(55, down: true)
    press(48)
    pause(0.35)
    let order = switcherOrder(mdeck.processIdentifier)
    print("Switcher order: \(order.joined(separator: " → "))")
    expect(order.first == source.localizedName && order.dropFirst().first == target.localizedName,
           "panel shows source first and target second")
    press(53) // Cmd+Escape, registered by Altty even without its event tap.
    releaseModifiers()
    pause(0.15)
    expect(frontPID() == source.processIdentifier, "Escape cancels without switching")
    guard failures == 0 else { return }

    for round in 1...trips {
        for (from, to) in [(source, target), (target, source)] {
            let hold = round % 2 == 0 ? 0.01 : 0.35
            key(55, down: true)
            press(48)
            pause(hold)
            expect(frontPID() == from.processIdentifier, "round \(round): holding Cmd preserves focus")
            releaseModifiers()
            let switched = waitForFront(to)
            pause(0.15)
            expect(switched, "round \(round): \(hold < 0.15 ? "quick" : "held") Cmd+Tab → \(to.bundleIdentifier!) (actual \(frontName()))")
            if !switched {
                // The exact reported symptom: did a failed switch still put the target first?
                let actual = NSWorkspace.shared.frontmostApplication
                key(55, down: true)
                press(48)
                pause(0.35)
                let next = switcherOrder(mdeck.processIdentifier)
                print("After failure: foreground=\(frontName()), switcher order=\(next.joined(separator: " → "))")
                expect(next.first == actual?.localizedName, "switcher first app matches actual foreground after failure")
                press(53)
                releaseModifiers()
                return
            }
        }
    }
}
run()
print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
