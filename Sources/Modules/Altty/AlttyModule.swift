import Cocoa

/// Altty: an app switcher that hides apps with no open window. Ported from the standalone
/// Altty (itself derived from AltTab, GPL-3.0); the switcher is unchanged, only its lifecycle
/// is now driven by mdeck.
final class AlttyModule: Module {
    let id = "altty"
    let name = "Altty"
    let summary = "An app switcher that leaves out apps with no open window."
    let symbolName = "rectangle.on.rectangle"
    let tint = NSColor.systemIndigo

    var isRunning: Bool { SwitcherController.shared.isRunning }

    func start() {
        SwitcherController.shared.start()
    }

    func stop() {
        SwitcherController.shared.stop()
    }

    /// Only the opt-in all-Spaces detection needs it; the switcher itself is permission-free.
    var needsAccessibility: Bool { AlttyPrefs.detectAcrossSpaces }

    func accessibilityDidChange() {
        SwitcherController.shared.refreshEventTap()
        SwitcherController.shared.registerHotkeys()
        AXStateCache.shared.refreshAll()
        settingsView?.sync()
    }

    var statusText: String? {
        "\(AlttyPrefs.appShortcut.display) to switch apps"
    }

    private weak var settingsView: AlttySettingsView?

    func makeSettingsView() -> NSView {
        let view = AlttySettingsView()
        settingsView = view
        return view
    }
}
