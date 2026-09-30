import Cocoa

/// One feature of mdeck. Each module is a self-contained utility that the user switches on or
/// off in the settings; a module that is off must cost nothing — no observer, no hotkey, no
/// event tap, no timer. Everything it sets up in `start()` is torn down in `stop()`.
///
/// Adding a module:
///  1. a folder under `Sources/Modules/<Name>/` with a class conforming to `Module`;
///  2. its preferences prefixed with its `id` (see `Pref`);
///  3. one line in `ModuleManager.modules`.
/// The sidebar, the menu bar menu and the General page pick it up from there.
protocol Module: AnyObject {
    /// Stable identifier: preference keys and the settings page are derived from it. Never
    /// rename it once shipped, or the user's settings for that module are lost.
    var id: String { get }
    var name: String { get }
    /// One sentence, shown under the name on its settings page and in the General list.
    var summary: String { get }
    /// SF Symbol drawn on the module's coloured tile in the sidebar.
    var symbolName: String { get }
    var tint: NSColor { get }

    var isRunning: Bool { get }
    func start()
    func stop()

    /// Whether the module, as currently configured, needs the Accessibility permission to work.
    /// While it does and the permission is missing, mdeck watches for the grant and calls
    /// `accessibilityDidChange()` when it lands.
    var needsAccessibility: Bool { get }
    func accessibilityDidChange()

    /// A short live status for the module's settings page (“Night Shift off for Lightroom”).
    /// Only asked while running.
    var statusText: String? { get }
    /// Extra actions listed under the module in the menu bar menu. Only asked while running.
    func menuItems() -> [NSMenuItem]

    /// The module's own settings, below the header of its page. Built once, on first display.
    func makeSettingsView() -> NSView
}

extension Module {
    var needsAccessibility: Bool { false }
    func accessibilityDidChange() {}
    var statusText: String? { nil }
    func menuItems() -> [NSMenuItem] { [] }
}

extension Notification.Name {
    /// Posted on the main thread whenever a module is turned on or off, or reports that its
    /// status changed. The menu bar icon and the settings sidebar listen to it.
    static let moduleStateDidChange = Notification.Name("mdeck.moduleStateDidChange")
}

/// Owns the modules and the one bit of state mdeck keeps about each: whether it is enabled.
final class ModuleManager {
    static let shared = ModuleManager()

    /// Display order in the sidebar and the menu.
    let modules: [Module] = [
        NightShiftFocusModule(),
        AlttyModule(),
        DockLockModule(),
        AppMonitorModule(),
    ]

    private init() {}

    func module(id: String) -> Module? { modules.first { $0.id == id } }

    private func enabledKey(_ module: Module) -> String { "module.\(module.id).enabled" }

    /// Every module starts off: mdeck runs nothing the user didn't ask for.
    func isEnabled(_ module: Module) -> Bool {
        UserDefaults.standard.bool(forKey: enabledKey(module))
    }

    /// Whether the module is listed in the menu bar menu — independent of it running.
    func isShownInMenu(_ module: Module) -> Bool {
        UserDefaults.standard.object(forKey: "module.\(module.id).showInMenu") as? Bool ?? true
    }

    func setShownInMenu(_ module: Module, _ shown: Bool) {
        UserDefaults.standard.set(shown, forKey: "module.\(module.id).showInMenu")
        noteChange()
    }

    func setEnabled(_ module: Module, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey(module))
        if enabled, !module.isRunning {
            module.start()
            // Asked when the user turns the module on — never at launch, where a refusal
            // would bring the prompt back at every boot.
            if module.needsAccessibility && !Permissions.isAccessibilityTrusted {
                Permissions.requestAccessibility()
            }
        } else if !enabled, module.isRunning {
            module.stop()
        }
        AccessibilityWatcher.shared.reevaluate()
        noteChange()
    }

    /// At launch.
    func startEnabledModules() {
        for module in modules where isEnabled(module) && !module.isRunning {
            module.start()
        }
        AccessibilityWatcher.shared.reevaluate()
    }

    /// At quit. Modules put back whatever system state they changed (the native ⌘Tab,
    /// Night Shift, …).
    func stopAll() {
        for module in modules where module.isRunning {
            module.stop()
        }
    }

    var runningModules: [Module] { modules.filter(\.isRunning) }

    /// Modules call this when something shown in the menu or the sidebar changed.
    func noteChange() {
        let post = { NotificationCenter.default.post(name: .moduleStateDidChange, object: nil) }
        Thread.isMainThread ? post() : DispatchQueue.main.async(execute: post)
    }
}
