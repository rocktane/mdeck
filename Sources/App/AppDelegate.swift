import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var statusMenu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--ax-status") {
            print("AXIsProcessTrusted:", Permissions.isAccessibilityTrusted)
            return NSApp.terminate(nil)
        }
        Theme.apply()
        AppMenu.install()
        LaunchAtLogin.reconcile()
        statusMenu = StatusMenu()
        ModuleManager.shared.startEnabledModules()

        #if DEBUG
        if Debug.handleFlags() { return }
        #endif

        // Everything starts off, so the very first launch opens the settings to pick modules.
        if !AppPrefs.didOnboard {
            AppPrefs.didOnboard = true
            SettingsWindowController.shared.show(page: "general")
        }
    }

    /// `open -a mdeck` on the running instance lands here instead of launching a second copy.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    /// Closing the settings window must not quit the agent.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        // Puts back the native ⌘Tab, Night Shift, … — whatever a module changed.
        ModuleManager.shared.stopAll()
    }
}
