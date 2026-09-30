import Cocoa
import Carbon.HIToolbox

/// Full keyboard control *inside* an open switcher session — arrows, Escape, quit/hide.
///
/// This needs the Accessibility permission, so it is only ever built when the user opted in.
/// Without it the switcher still works, it just responds to the trigger chord alone.
/// The tap stays disabled between sessions: Altty should not sit in the event stream of every
/// keystroke the user types all day.
final class SessionEventTap {
    enum Action { case next, previous, cancel, commit, quitSelected, hideSelected }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let onAction: (Action) -> Void
    /// What *we* want. The system reports its own disabling of the tap — including the one we
    /// asked for, as `.tapDisabledByUserInput` — and only a tap that should be on is re-armed;
    /// re-arming unconditionally left it swallowing Return and the arrows between sessions.
    private var shouldBeEnabled = false

    init?(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction

        // Key-down only. Modifier release is detected by `SwitcherController`'s poll, which
        // also works without the tap; asking for `flagsChanged` here would route every
        // modifier change through this process for nothing.
        let mask = 1 << CGEventType.keyDown.rawValue
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<SessionEventTap>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else { return nil }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false)
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    func setEnabled(_ enabled: Bool) {
        guard let tap else { return }
        shouldBeEnabled = enabled
        CGEvent.tapEnable(tap: tap, enable: enabled)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long; re-arm instead of dying silently —
        // but only during a session, see `shouldBeEnabled`.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if shouldBeEnabled, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard shouldBeEnabled else { return Unmanaged.passUnretained(event) }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let cmd = flags.contains(.maskCommand)

        switch code {
        case kVK_Escape:                       onAction(.cancel);       return nil
        case kVK_LeftArrow, kVK_UpArrow:       onAction(.previous);     return nil
        case kVK_RightArrow, kVK_DownArrow:    onAction(.next);         return nil
        case kVK_Return, kVK_ANSI_KeypadEnter: onAction(.commit);       return nil
        case kVK_ANSI_Q where cmd:             onAction(.quitSelected); return nil
        case kVK_ANSI_H where cmd:             onAction(.hideSelected); return nil
        default:
            // Tab is deliberately passed through: the Carbon hotkey handles it, and swallowing
            // it here would race with that.
            return Unmanaged.passUnretained(event)
        }
    }
}
