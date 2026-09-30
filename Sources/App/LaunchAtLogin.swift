import Cocoa
import ServiceManagement

/// `SMAppService.mainApp.status` cannot be trusted as the source of truth: it answers
/// `.enabled` before anything is ever registered, and it forgets an explicit `unregister()`
/// as soon as the bundle is replaced or re-signed. So the user's intent lives in a preference
/// and `reconcile()` drags macOS back into line at every launch.
enum LaunchAtLogin {
    static var isEnabled: Bool { AppPrefs.launchAtLogin }

    /// Throws so the settings window can surface *why* it failed — with an ad-hoc signature
    /// or a bundle sitting outside /Applications, `register()` is routinely refused.
    static func set(_ enabled: Bool) throws {
        AppPrefs.launchAtLogin = enabled
        try apply(enabled)
    }

    /// Re-applies the preference unconditionally rather than comparing it to `status` first —
    /// `status` is exactly the thing that cannot be trusted. Both calls are idempotent, and a
    /// refusal here is not worth an alert at every boot.
    static func reconcile() {
        try? apply(AppPrefs.launchAtLogin)
    }

    private static func apply(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}
