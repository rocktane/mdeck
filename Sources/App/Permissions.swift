import Cocoa
import ApplicationServices

enum Permissions {
    /// Never prompts. Cheap enough to call on every switcher summon.
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts, i.e. opens the system dialog that deep-links to
    /// System Settings › Privacy & Security › Accessibility. Only ever called when the user
    /// turns on something that needs it, never at launch.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Clears any leftover entry, then prompts.
    ///
    /// Only ever reachable while we are *not* trusted, so whatever sits in the Accessibility
    /// list is stale — granted to an earlier build of mdeck with another code identity. macOS
    /// keeps showing it as enabled while it authorises nothing, which is indistinguishable
    /// from a bug unless you clear it. Resetting first makes the prompt bind to the binary
    /// that is actually running.
    static func resetAndRequest() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? ""]
        try? task.run()
        task.waitUntilExit()

        requestAccessibility()
        openAccessibilitySettings()
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

/// The user grants Accessibility in System Settings, i.e. outside our process, and macOS sends
/// no reliable notification for it. So while a running module needs the permission and does not
/// have it, this polls — and only then: once granted, or once no module needs it, it stops.
///
/// The settings window additionally calls `check()` whenever it becomes active.
final class AccessibilityWatcher {
    static let shared = AccessibilityWatcher()

    private var timer: Timer?
    private(set) var lastKnown = Permissions.isAccessibilityTrusted

    private init() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(check),
            name: NSNotification.Name("com.apple.accessibility.api"), object: nil)
    }

    private var someoneIsWaiting: Bool {
        ModuleManager.shared.runningModules.contains { $0.needsAccessibility }
    }

    /// Starts or stops polling to match what the running modules need.
    func reevaluate() {
        check()
        let shouldPoll = someoneIsWaiting && !Permissions.isAccessibilityTrusted
        if shouldPoll, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                self?.check()
            }
        } else if !shouldPoll {
            timer?.invalidate()
            timer = nil
        }
    }

    @objc func check() {
        let now = Permissions.isAccessibilityTrusted
        guard now != lastKnown else { return }
        lastKnown = now
        for module in ModuleManager.shared.runningModules {
            module.accessibilityDidChange()
        }
        ModuleManager.shared.noteChange()
        // After the modules reacted: one of them may no longer need it.
        DispatchQueue.main.async { self.reevaluate() }
    }
}
