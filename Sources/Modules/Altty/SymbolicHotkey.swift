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

enum NativeSwitcher {
    private(set) static var isDisabledByUs = false

    static func setEnabled(_ enabled: Bool) {
        for key in [SymbolicHotkey.commandTab, .commandShiftTab] {
            CGSSetSymbolicHotKeyEnabled(key.rawValue, enabled)
        }
        isDisabledByUs = !enabled
    }

    /// Must run on quit, otherwise the user is left with no app switcher at all.
    static func restoreIfNeeded() {
        if isDisabledByUs { setEnabled(true) }
    }
}
