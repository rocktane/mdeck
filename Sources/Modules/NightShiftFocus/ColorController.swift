import Foundation

/// Turns Night Shift / True Tone off while a watched app is frontmost, then puts back exactly
/// what was there before.
final class ColorController {
    private(set) var nightShiftSuppressed = false
    private(set) var trueToneSuppressed = false
    private var baseline = Baseline()

    var manageNightShift = true
    var manageTrueTone = true

    var isSuppressing: Bool { nightShiftSuppressed || trueToneSuppressed }

    /// Repairs the display if mdeck died in the middle of a suspension.
    func recoverFromCrash() {
        guard let saved = NightShiftStore.loadBaseline() else { return }
        baseline = saved
        nightShiftSuppressed = saved.nightShiftEnabled != nil
        trueToneSuppressed = saved.trueToneEnabled != nil
        update(shouldSuppress: false)
    }

    /// Single entry point. Always rewrites the wanted state, which also catches the system
    /// resetting it behind our back (wake from sleep, display change).
    func update(shouldSuppress: Bool) {
        syncNightShift(wanted: shouldSuppress && manageNightShift && NightShift.isAvailable)
        syncTrueTone(wanted: shouldSuppress && manageTrueTone && TrueTone.isAvailable)
        NightShiftStore.save(isSuppressing ? baseline : nil)
    }

    private func syncNightShift(wanted: Bool) {
        if wanted {
            if !nightShiftSuppressed {
                if let status = NightShift.status() {
                    baseline.nightShiftEnabled = status.enabled
                    baseline.nightShiftMode = status.mode
                    baseline.nightShiftInWindow = status.inWindow()
                } else {
                    baseline.nightShiftEnabled = false
                }
                nightShiftSuppressed = true
            }
            NightShift.setEnabled(false)
        } else if nightShiftSuppressed {
            NightShift.setEnabled(nightShiftRestoreTarget())
            baseline.nightShiftEnabled = nil
            baseline.nightShiftMode = nil
            baseline.nightShiftInWindow = nil
            nightShiftSuppressed = false
        }
    }

    /// If Night Shift is scheduled, the schedule may have flipped during the suspension: follow
    /// the schedule, unless the user had forced the opposite themselves and the window has not
    /// changed since.
    private func nightShiftRestoreTarget() -> Bool {
        let saved = baseline.nightShiftEnabled ?? false
        guard let mode = baseline.nightShiftMode, mode != 0,
              let savedInWindow = baseline.nightShiftInWindow,
              let current = NightShift.status()
        else { return saved }

        let currentInWindow = current.inWindow()
        let userHadOverridden = saved != savedInWindow
        if userHadOverridden && currentInWindow == savedInWindow { return saved }
        return currentInWindow
    }

    private func syncTrueTone(wanted: Bool) {
        if wanted {
            if !trueToneSuppressed {
                baseline.trueToneEnabled = TrueTone.isEnabled
                trueToneSuppressed = true
            }
            TrueTone.setEnabled(false)
        } else if trueToneSuppressed {
            TrueTone.setEnabled(baseline.trueToneEnabled ?? true)
            baseline.trueToneEnabled = nil
            trueToneSuppressed = false
        }
    }
}
