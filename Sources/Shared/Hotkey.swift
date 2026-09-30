import Cocoa
import Carbon.HIToolbox

/// Global hotkeys via Carbon's `RegisterEventHotKey`, shared by every module.
///
/// Deliberately *not* a `CGEventTap`: an event tap would require the Accessibility permission,
/// and a hotkey alone should never need it. The trade-off is that we only get key-*down*;
/// a module that needs modifier release polls `NSEvent.modifierFlags`, which is also
/// permission-free.
///
/// A registered hotkey is swallowed system-wide for as long as it is registered, so anything
/// that only makes sense transiently (Escape during a switcher session) must be registered for
/// that moment only. Each module keeps the IDs it registered and releases exactly those —
/// never another module's.
final class HotkeyManager {
    typealias ID = UInt32

    static let shared = HotkeyManager()

    private var refs: [ID: EventHotKeyRef] = [:]
    private var handlers: [ID: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: ID = 1
    private let signature: OSType = 0x4D44434B // 'MDCK'

    private init() {}

    private func installEventHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ in
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard err == noErr else { return err }
            HotkeyManager.shared.handlers[hkID.id]?()
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, &eventHandler)
    }

    /// Returns nil when the system refuses the combination (typically: another app owns it).
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> ID? {
        installEventHandler()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        refs[id] = ref
        handlers[id] = handler
        return id
    }

    func unregister(_ id: ID?) {
        guard let id, let ref = refs.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
        handlers[id] = nil
    }

    func unregister(_ ids: [ID]) {
        ids.forEach { unregister($0) }
    }

    #if DEBUG
    var registeredCount: Int { refs.count }
    #endif
}
