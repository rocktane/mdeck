import Cocoa

/// The system Cmd+Tab is a "symbolic hotkey" swallowed by the WindowServer before any app can
/// see it, so taking it over means asking SkyLight to disable it. This is a private API — the
/// one and only private call in Altty — and it needs no special permission.
///
/// Identifiers match the ones AltTab and yabai use.
enum SymbolicHotkey: Int32 {
    case commandTab = 1
    case commandShiftTab = 2
}

@_silgen_name("CGSSetSymbolicHotKeyEnabled") @discardableResult
private func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ isEnabled: Bool) -> CGError

@_silgen_name("CGSIsSymbolicHotKeyEnabled")
private func CGSIsSymbolicHotKeyEnabled(_ hotKey: Int32) -> Bool

enum NativeSwitcher {
    private(set) static var isDisabledByUs = false

    static func setEnabled(_ enabled: Bool) {
        for key in [SymbolicHotkey.commandTab, .commandShiftTab] {
            CGSSetSymbolicHotKeyEnabled(key.rawValue, enabled)
        }
        isDisabledByUs = !enabled
    }

    /// The WindowServer can turn the native switcher back on behind our back — wake, unlock,
    /// fast user switching, the Keyboard Shortcuts pane, another switcher or another mdeck
    /// quitting. Re-applies what we want; only writes when the live state drifted.
    @discardableResult
    static func reassertIfNeeded() -> Bool {
        guard isDisabledByUs else { return false }
        let drifted = [SymbolicHotkey.commandTab, .commandShiftTab]
            .contains { CGSIsSymbolicHotKeyEnabled($0.rawValue) }
        if drifted { setEnabled(false) }
        return drifted
    }

    /// Must run on quit, otherwise the user is left with no app switcher at all.
    static func restoreIfNeeded() {
        if isDisabledByUs { setEnabled(true) }
    }
}
