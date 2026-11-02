#!/usr/bin/env swift
import Cocoa
// Regression test: Altty must activate an app that the current app previously handed
// activation to (a browser opening a link in it). This script plays that source app: it
// yields to the target, takes the foreground back, then presses Cmd+Tab through System Events.
// Before the fix, mdeck's request was rejected as expired ("CPS: Rejecting expired request"
// in the WindowServer log) and the target never came forward. Needs Altty on Cmd+Tab, the
// target running with a window on this Space, and permission to control System Events.
// Run it compiled, as its own app process:
// Usage: swiftc -O scripts/test-altty-handoff.swift -o /tmp/test-altty-handoff
//        /tmp/test-altty-handoff <target bundle ID> [rounds]
func pause(_ s: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }
func front() -> NSRunningApplication? { NSWorkspace.shared.frontmostApplication }
func waitFront(_ pid: pid_t, _ t: Double = 1.5) -> Bool {
    let d = Date(timeIntervalSinceNow: t)
    while Date() < d { if front()?.processIdentifier == pid { return true }; pause(0.02) }
    return front()?.processIdentifier == pid
}
func se(_ a: String) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "tell application \"System Events\" to \(a)"]; try? p.run(); p.waitUntilExit() }
func cmdTab() { se("key down command"); se("key code 48"); pause(0.02); se("key up command") }

let args = CommandLine.arguments
guard args.count >= 2, let target = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first
else { print("target not running"); exit(2) }
let rounds = args.count > 2 ? Int(args[2]) ?? 3 : 3
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 360, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
w.title = "Altty hand-off test (source app)"
w.makeKeyAndOrderFront(nil)
let me = NSRunningApplication.current
let original = front()
var fails = 0
func becomeFront() -> Bool {
    // Make the source app foreground again the way a user would, with a real click on its window.
    w.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if waitFront(me.processIdentifier, 0.6) { return true }
    let f = w.frame; let h = NSScreen.screens[0].frame.maxY
    let pt = CGPoint(x: f.midX, y: h - f.maxY + 10) // title bar
    for t in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
        pause(0.05)
    }
    return waitFront(me.processIdentifier)
}
DispatchQueue.main.async {
    pause(0.3)
    guard becomeFront() else { print("SETUP FAIL: source app cannot become frontmost"); exit(2) }
    // What Arc does when it opens a link handled by another app: yield activation to it.
    target.activate(from: me, options: [.activateAllWindows])
    print("yield to target → front=\(front()?.bundleIdentifier ?? "?") ok=\(waitFront(target.processIdentifier))")
    for r in 1...rounds {
        pause(0.8)
        guard becomeFront() else { print("SETUP FAIL round \(r)"); exit(2) }
        pause(0.5)
        se("key code 123") // a user keyboard event after the stale yield (left arrow, harmless here)
        pause(0.3)
        cmdTab()
        let ok = waitFront(target.processIdentifier)
        print("\(ok ? "PASS" : "FAIL") round \(r): ⌘Tab from source → \(args[1]) (actual \(front()?.bundleIdentifier ?? "?"))")
        if !ok { fails += 1 }
    }
    original?.activate(options: [])
    pause(0.3)
    print(fails == 0 ? "ALL PASSED" : "\(fails)/\(rounds) FAILED")
    exit(fails == 0 ? 0 : 1)
}
app.run()
