import Cocoa
import Carbon.HIToolbox

/// A key plus modifiers, as the user typed it into a `ShortcutRecorder`. Registered globally
/// through Carbon (`HotkeyManager`), so no permission is involved whatever the combination.
struct Shortcut: Equatable {
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevantModifiers)
    }

    init(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags) {
        self.init(keyCode: UInt32(keyCode), modifiers: modifiers)
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// The one combination the system owns: taking it needs the native switcher disabled.
    var isCommandTab: Bool { keyCode == UInt32(kVK_Tab) && modifiers.contains(.command) }

    /// Shift is how a session goes backwards, so a shortcut that already uses it has no
    /// reverse chord.
    var reversed: Shortcut? {
        modifiers.contains(.shift) ? nil : Shortcut(keyCode: keyCode, modifiers: modifiers.union(.shift))
    }

    // MARK: - Display

    var display: String { Self.symbols(for: modifiers) + Self.keyName(keyCode) }

    static func symbols(for modifiers: NSEvent.ModifierFlags) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s
    }

    /// Glyphs for the keys that have one, the layout's own character for the rest — so a
    /// French keyboard shows what is actually printed on the key.
    static func keyName(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Space: return "␣"
        case kVK_Return: return "↩"
        case kVK_ANSI_KeypadEnter: return "⌤"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"
        case kVK_F4: return "F4"; case kVK_F5: return "F5"; case kVK_F6: return "F6"
        case kVK_F7: return "F7"; case kVK_F8: return "F8"; case kVK_F9: return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default: break
        }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        let layout = unsafeBitCast(CFDataGetBytePtr(data), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                    &deadKeys, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    // MARK: - Storage ("keyCode:modifiers")

    var stored: String { "\(keyCode):\(modifiers.rawValue)" }

    init?(stored: String) {
        let parts = stored.split(separator: ":")
        guard parts.count == 2, let key = UInt32(parts[0]), let mods = UInt(parts[1]) else { return nil }
        self.init(keyCode: key, modifiers: NSEvent.ModifierFlags(rawValue: mods))
    }
}
