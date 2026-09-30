import Cocoa
import Carbon.HIToolbox

/// Icon size in the switcher. Large is what the native switcher draws at.
enum IconSize: Int, CaseIterable {
    case small = 0, medium, large

    var points: CGFloat { [64, 96, 128][rawValue] }
    var label: String { ["Small", "Medium", "Large"][rawValue] }
}

/// Badge size. Large is what the native switcher draws (0.39 × the icon size); the two below
/// step down by a fifth each.
enum BadgeSize: Int, CaseIterable {
    case small = 0, medium, large

    var scale: CGFloat { [0.6, 0.8, 1.0][rawValue] }
    var label: String { ["Small", "Medium", "Large"][rawValue] }
}

/// Every Altty preference, readable from anywhere. Nothing observes changes: the switcher reads
/// these at each summon, and the settings page re-syncs its own controls after each edit.
///
/// Defaults mirror the native switcher, except the one thing Altty exists for: windowless
/// apps are hidden.
enum AlttyPrefs {

    // MARK: Shortcuts

    @Pref("altty.appShortcut", default: "")
    private static var appShortcutRaw: String

    /// Cycles through apps. Always set: the switcher is nothing without it.
    static var appShortcut: Shortcut {
        get { Shortcut(stored: appShortcutRaw) ?? Shortcut(kVK_Tab, .option) }
        set { appShortcutRaw = newValue.stored }
    }

    @Pref("altty.windowShortcut", default: "default")
    private static var windowShortcutRaw: String

    /// Cycles through the windows of the frontmost app. Optional (an empty string means the
    /// user cleared it), defaults to ⌥` to mirror the native ⌘`. Needs Accessibility to raise
    /// a window, so it is only ever registered while that is granted.
    static var windowShortcut: Shortcut? {
        get {
            if windowShortcutRaw == "default" { return Shortcut(kVK_ANSI_Grave, .option) }
            return Shortcut(stored: windowShortcutRaw)
        }
        set { windowShortcutRaw = newValue?.stored ?? "" }
    }

    // MARK: Detection

    /// Look for windows beyond the current Space — on other desktops, and minimized.
    /// Opt-in, because it is the one capability that needs the Accessibility permission:
    /// while it is off, Altty never touches the AX API and never prompts.
    @Pref("altty.detectAcrossSpaces", default: false)
    static var detectAcrossSpaces: Bool

    /// The feature Altty exists for: an Electron app left running with every window closed.
    @Pref("altty.showWindowlessApps", default: false)
    static var showWindowlessApps: Bool

    /// Apps hidden with ⌘H. The native switcher shows them.
    @Pref("altty.showHiddenApps", default: true)
    static var showHiddenApps: Bool

    /// Apps whose windows are *all* minimized. Telling a minimized window apart from one on
    /// another Space needs the Accessibility API, so this is only honoured when it's granted.
    @Pref("altty.showMinimizedApps", default: true)
    static var showMinimizedApps: Bool

    /// Apps whose windows are *all* fullscreen.
    @Pref("altty.showFullscreenApps", default: true)
    static var showFullscreenApps: Bool

    /// Off restricts the switcher to apps with a window on the screen it appears on.
    /// AltTab's "Show windows from screens".
    @Pref("altty.showOtherScreenApps", default: true)
    static var showOtherScreenApps: Bool

    /// Off restricts the switcher to the current desktop. Only bites once
    /// `detectAcrossSpaces` is on, since nothing else ever sees another Space.
    /// AltTab's "Show windows from Spaces".
    @Pref("altty.showOtherSpaceApps", default: true)
    static var showOtherSpaceApps: Bool

    /// Bundle IDs that never appear in the switcher, whatever their windows.
    @Pref("altty.excludedBundleIDs", default: [])
    static var excludedBundleIDs: [String]

    // MARK: Appearance

    /// The selected app's name under the icon row. Off shortens the panel by that band.
    @Pref("altty.showAppNames", default: true)
    static var showAppNames: Bool

    @Pref("altty.iconSize", default: IconSize.large.rawValue)
    private static var iconSizeRaw: Int

    static var iconSize: IconSize {
        get { IconSize(rawValue: iconSizeRaw) ?? .large }
        set { iconSizeRaw = newValue.rawValue }
    }

    /// The Dock's red notification badges, top right of each icon, like the native switcher.
    /// Read from the Dock through Accessibility: without the permission there are none.
    @Pref("altty.showNotificationBadges", default: true)
    static var showNotificationBadges: Bool

    @Pref("altty.badgeSize", default: BadgeSize.large.rawValue)
    private static var badgeSizeRaw: Int

    /// One size for every badge; large is the native notification badge.
    static var badgeSize: BadgeSize {
        get { BadgeSize(rawValue: badgeSizeRaw) ?? .large }
        set { badgeSizeRaw = newValue.rawValue }
    }

    /// `StoredColor` values: a preset id or `#RRGGBB`.
    @Pref("altty.badgeColor.notifications", default: "red")
    static var notificationBadgeColor: String
    @Pref("altty.badgeColor.windows", default: "blue")
    static var windowBadgeColor: String
    @Pref("altty.badgeColor.state", default: "graphite")
    static var stateBadgeColor: String

    /// Window count and hidden/minimized markers on the icons.
    @Pref("altty.showWindowBadges", default: true)
    static var showWindowBadges: Bool

    /// Below this, a quick trigger+Tab tap swaps to the previous app without ever drawing the
    /// panel — same as the native switcher. No UI; `defaults write com.yohan.mdeck altty.showDelayMs 0`.
    @Pref("altty.showDelayMs", default: 150)
    private static var showDelayMs: Int

    static var showDelay: TimeInterval { Double(showDelayMs) / 1000 }
}
