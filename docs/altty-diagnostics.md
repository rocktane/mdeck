# Altty activation diagnosis — 2026-10-07

## Reproduction

On macOS 27.0.1, with Altty configured for Cmd+Tab, opening mdeck's settings can
prevent a selected app from becoming foreground. The next switcher session still
puts that app first, even though the previous foreground app never changed.

Run against an already-running mdeck and two apps with windows on the current Space:

```sh
swift scripts/test-altty.swift com.t3tools.t3code com.mitchellh.ghostty 5 --settings-open
```

The test sends real shortcuts through System Events and checks the foreground app
through NSWorkspace. It reads only the switcher's app labels through Accessibility.
Its host therefore needs Accessibility and permission to control System Events.

The installed 0.1.0 binary reproduced the symptom. For example:

```text
PASS panel shows source first and target second
FAIL round 1: held Cmd+Tab → com.mitchellh.ghostty (actual com.t3tools.t3code)
After failure: foreground=com.t3tools.t3code, switcher order=Ghostty → T3 Code (Nightly) → Arc → Notion
FAIL failed activation must not put the target first
```

Restarting the same binary temporarily restored switching. Closing its settings
also restored switching; reopening them reproduced the failure. Restarting alone
does not fix the underlying trigger.

## Cause and correction

`SettingsWindowController.show()` changes mdeck from an accessory to a regular app
until the settings window closes. Once mdeck is a background regular app, a plain
`NSRunningApplication.activate(options:)` request can leave the selected app in the
background. Returning true does not prove that the target became foreground.

`SwitcherController.commit()` additionally called `MRUTracker.touch()` regardless
of the outcome, explaining the misleading order in the following session.

The correction transfers activation explicitly from the current foreground app
using `activate(from:options:)` on macOS 14+, with the older force-activation option
for macOS 13. MRU now follows workspace activation notifications exclusively.

Both original code paths are present in the initial commit, `454b949` (2026-09-30).
This identifies their introduction, not when the user first encountered the symptom.

## Validation

The corrected debug and production builds each passed 23/23 integration checks
with settings open, using T3/Ghostty and T3/Arc respectively: ten real switches,
alternating quick and held shortcuts, focus preservation while Cmd is held, panel
ordering, and Escape cancellation. The test parks the pointer outside the panel
so hover cannot change the keyboard selection, then restores it. The module
lifecycle test also passed, including hotkey cleanup and restoration of native
Cmd+Tab.

Runtime validation was on macOS 27.0.1; the macOS 13 fallback was compiled but not
run on macOS 13.
