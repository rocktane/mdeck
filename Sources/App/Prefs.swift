import Cocoa

/// One `UserDefaults` value with a default. Reading an unset key yields the default; there is
/// no separate `register(defaults:)` step to keep in sync with the property list.
///
/// Every module shares mdeck's defaults domain, so each one prefixes its keys with its own id
/// (`altty.iconSize`, `docklock.target`, …) — two modules can never collide on a key.
@propertyWrapper
struct Pref<Value> {
    let key: String
    let defaultValue: Value

    init(_ key: String, default defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: Value {
        get { UserDefaults.standard.object(forKey: key) as? Value ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// mdeck's own look — settings window, menu, Altty's switcher — independent of the system's
/// if the user wants.
enum Theme: Int, CaseIterable {
    case system = 0, light, dark

    var label: String { ["System", "Light", "Dark"][rawValue] }

    /// Nil follows the system.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static func apply() { NSApp.appearance = AppPrefs.theme.appearance }
}

/// Preferences that belong to mdeck itself rather than to a module.
enum AppPrefs {
    @Pref("app.theme", default: Theme.system.rawValue)
    private static var themeRaw: Int

    static var theme: Theme {
        get { Theme(rawValue: themeRaw) ?? .system }
        set { themeRaw = newValue.rawValue; Theme.apply() }
    }

    /// The user's intent, which `LaunchAtLogin` reconciles with macOS at every launch.
    @Pref("app.launchAtLogin", default: false)
    static var launchAtLogin: Bool

    /// Set once the settings window has been shown at first launch, so it only pops up
    /// unprompted that one time.
    @Pref("app.didOnboard", default: false)
    static var didOnboard: Bool

    /// The sidebar page the settings window reopens on.
    @Pref("app.lastSettingsPage", default: "general")
    static var lastSettingsPage: String
}
