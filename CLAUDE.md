# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Build & Run

```bash
make cert      # one-time: self-signed "mdeck Signing" certificate
make build     # native, signed → build/mdeck.app
make debug     # + debug flags (--snapshot-settings, --lifecycle-test, --dock-info, …)
make install   # copy to /Applications and launch
```

`./build.sh` is the whole build: one `swiftc -O -wmo` over every `.swift` under `Sources/`
(subfolders are for humans; it is a single compiler module), a hand-rolled bundle, the `.icns`
from `Assets/icon-1024.png` (drawn by `scripts/make-icon.swift`), `codesign` with "mdeck Signing"
if present. No Xcode (the machine only has the Command Line Tools), no SwiftPM.

Check UI without touching the user's screen: `make debug`, then
`build/mdeck.app/Contents/MacOS/mdeck --snapshot-settings out.png --page <id>` (add
`--appearance dark`). Check module teardown: `--lifecycle-test` (must print ALL PASSED).

UI text is English only. No localisation layer.

## Architecture

mdeck is an `LSUIElement` agent with a menu bar item. It becomes `.regular` (Dock icon + menu
bar) only while the settings window is open.

```
App/
  main.swift          — --restore escape hatch; SIGINT/TERM/HUP → NSApp.terminate (modules restore state)
  AppDelegate         — status menu, start enabled modules, first-launch onboarding, stopAll on quit
  Module.swift        — Module protocol + ModuleManager (enabled flags, start/stop, change notification)
  StatusMenu          — menu bar item, rebuilt on open from the modules
  Permissions         — AX helpers + AccessibilityWatcher (polls only while a running module waits for AX)
  Prefs               — @Pref wrapper, AppPrefs
Settings/             — split-view window: sidebar (General + modules), ModulePageView, GeneralPageView
Shared/               — SettingsRow/ActionSwitch/RowsView, AppListView, ShortcutRecorder, Shortcut, HotkeyManager
Modules/
  NightShiftFocus/    — CoreBrightness bridge (private API), ColorController (suspend/restore), store
  Altty/              — the Altty switcher (see ../altty/CLAUDE.md for its internals)
  DockLock/           — Displays (CG-space geometry), DockEdgeGuard (HID event tap), DockMover (AX + posted events)
```

### Module contract

When adding a module or changing lifecycle, preferences, permissions, status items or panels,
read `docs/modules.md` for the authoritative contract and validation steps. Start new modules
from `templates/module/ExampleModule.swift.template`.

### Key details

- **Code identity is the self-signed certificate**, so the Accessibility grant survives rebuilds.
  Don't sign releases ad hoc.
- Dock Lock works in global CG coordinates (top-left origin, y down) throughout — events and AX
  both use them; never mix in `NSScreen` frames. Only outer display edges are guarded.
- Altty is derived from AltTab (GPL-3.0): mdeck is GPL-3.0, keep the attribution.
