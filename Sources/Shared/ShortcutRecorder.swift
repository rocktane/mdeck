import Cocoa
import Carbon.HIToolbox

/// A button that shows a shortcut and, when clicked, records the next chord typed.
///
/// While it records, `onRecordingChange(true)` lets the controller drop its global hotkeys
/// (and the native ⌘Tab) so the chord actually reaches this window instead of starting a
/// session. Escape cancels; Delete clears when `allowsEmpty`.
final class ShortcutRecorder: NSButton {
    var shortcut: Shortcut? { didSet { updateTitle() } }
    var allowsEmpty = false
    var onChange: ((Shortcut?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    /// Refuses a chord already used elsewhere; the caller decides what "elsewhere" is.
    var isTaken: ((Shortcut) -> Bool)?

    private(set) var isRecording = false
    private var heldModifiers: NSEvent.ModifierFlags = []

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = .systemFont(ofSize: NSFont.systemFontSize)
        setContentHuggingPriority(.required, for: .horizontal)
        target = self
        action = #selector(clicked)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    // A button only takes keyboard focus when Full Keyboard Access is on; this one must
    // always be able to, that is its whole job.
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    @objc private func clicked() {
        isRecording ? stop() : start()
    }

    private func start() {
        guard window?.makeFirstResponder(self) == true else { return }
        isRecording = true
        heldModifiers = []
        onRecordingChange?(true)
        updateTitle()
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false
        heldModifiers = []
        onRecordingChange?(false)
        updateTitle()
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    override func resignFirstResponder() -> Bool {
        stop()
        return super.resignFirstResponder()
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        heldModifiers = event.modifierFlags.intersection(Shortcut.relevantModifiers)
        updateTitle()
    }

    /// ⌘-chords are offered as key equivalents before they reach `keyDown`; grab them here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        let mods = event.modifierFlags.intersection(Shortcut.relevantModifiers)
        let key = Int(event.keyCode)

        if mods.isEmpty && key == kVK_Escape { return stop() }
        if mods.isEmpty && (key == kVK_Delete || key == kVK_ForwardDelete) && allowsEmpty {
            shortcut = nil
            onChange?(nil)
            return stop()
        }
        // Shift alone would make the chord fire while typing capitals.
        guard !mods.subtracting(.shift).isEmpty else { return NSSound.beep() }

        let candidate = Shortcut(keyCode: UInt32(key), modifiers: mods)
        if isTaken?(candidate) == true { return NSSound.beep() }
        shortcut = candidate
        onChange?(candidate)
        stop()
    }

    private func updateTitle() {
        if isRecording {
            title = heldModifiers.isEmpty ? "Type a shortcut…" : Shortcut.symbols(for: heldModifiers) + "…"
        } else {
            title = shortcut?.display ?? "None"
        }
    }
}
