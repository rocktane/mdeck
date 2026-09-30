# mdeck

One native macOS menu bar app, many small utilities. Each utility is a **module** you turn on
or off; a module that is off does not run at all — no observer, no shortcut, no event tap.

| Module | What it does | Permission |
|---|---|---|
| **Night Shift Focus** | Turns Night Shift and True Tone off while a colour-critical app (Lightroom, Photoshop, Figma…) is in front, and puts back exactly what was there when you leave it. | none |
| **Altty** | An app switcher (⌥⇥ by default, ⌘⇥ possible) that leaves out apps with no open window. | Accessibility only for “Detect windows on all Spaces” |
| **App Monitor** | Lists CPU and memory usage grouped by application, with menu bar gauges and an optional pinned panel. | none |
| **Dock Lock** | Keeps the Dock on one display — the MacBook’s screen by default — even with external screens connected. | Accessibility |

macOS 13+. Written in Swift/AppKit, built with `swiftc` alone: no Xcode project, no SwiftPM.

## Install

```sh
make cert      # one-time: the self-signed "mdeck Signing" certificate (see Signing)
make install   # builds, copies to /Applications, launches
```

The first launch opens the settings on **General**: switch on the modules you want. After that,
everything is in the menu bar item (the 2×2 grid, filled while a module runs): **Open mdeck**
(the settings), each module not hidden from the menu (a green dot on the running ones; click one
to open its page, where it is turned on or off and where “Show in the menu bar menu” lives), its
actions under it, and **Quit**. Running
`open -a mdeck` again also opens the settings.

If you used the standalone apps, quit them first: Altty and Night Shift Focus would otherwise
fight mdeck for ⌥⇥ and for the display colours. mdeck does not import their settings.

## Modules

### Night Shift Focus

Watched apps are listed in the module page (+ offers the running apps, then a file picker); the
menu also has **Add <front app> to watchlist** / **Remove <front app> from watchlist**. The list is pre-filled the
first time the module starts with the colour-critical apps found on the Mac.

Restoring is exact, not just “switch it back on”: if Night Shift runs on a schedule and the
schedule flipped while you were in Lightroom, the schedule wins — unless you had overridden it
yourself and the window has not changed since. While anything is suspended, the state to restore
is kept in `~/Library/Application Support/mdeck/NightShiftFocus/baseline.json`, so a crash or a
`kill -9` is repaired at the next start. Uses the private CoreBrightness framework.

### Altty

The Altty switcher, unchanged: shortcuts, icon size, names, badges, what counts as an open window,
exclusions. Derived from [AltTab](https://github.com/lwouis/alt-tab-macos) (GPL-3.0) — hence
mdeck’s licence. If mdeck dies while Altty had taken ⌘⇥ over, `mdeck --restore` gives it back:

```sh
/Applications/mdeck.app/Contents/MacOS/mdeck --restore
```

### Dock Lock

macOS moves the Dock to whichever display you push the pointer against at its Dock edge (bottom,
or the side the Dock is on). There is no setting for that, so Dock Lock:

1. **holds the pointer two points short of the Dock edge of every other display**, through a
   HID-level event tap on mouse moves and drags. Only outer edges are guarded: where another
   display continues past the edge (a screen stacked below), the pointer crosses freely.
2. **brings the Dock back** a couple of seconds after a display change (screen plugged in, wake,
   main display changed) by doing what a user would — pushing the pointer against the target
   display’s edge — then returns the pointer where it was. Also available as **Move Dock Now**.

The target display is chosen in the module page (built-in by default); an external display is
remembered by vendor/model/serial, so it survives unplugging. While the target is not connected,
Dock Lock stands aside.

## Signing

The Accessibility grant is bound to the app’s code identity. Ad hoc, that identity is the code
hash, and every rebuild is “a different app” whose grant silently stops applying. `make cert`
creates a self-signed certificate; `build.sh` signs with it when it exists, and the grant then
survives rebuilds. If the Accessibility list shows mdeck enabled while mdeck says it is not
granted, use **Request Permission…** (it clears the stale entry first) or
`./build.sh --reset-permission`.

## Development

```sh
make build              # native, signed → build/mdeck.app
make debug              # with the debug flags below
make uninstall          # app, preferences, Application Support, Accessibility grant
```

Debug build flags (`build/mdeck.app/Contents/MacOS/mdeck …`):

| Flag | |
|---|---|
| `--snapshot-settings out.png [--page general\|nightshift\|altty\|docklock]` | captures the settings window (no Screen Recording needed for our own windows) |
| `--altty-snapshot out.png` / `--altty-demo` | the switcher panel |
| `--appmonitor-test` / `--appmonitor-snapshot out.png` | checks real samples / captures the application rankings |
| `--lifecycle-test` | starts and stops every module, checks nothing is left behind |
| `--dock-info` | displays, Dock edge, where the Dock is |
| `--menu-size` | the menu bar menu's computed size |
| `--badge-contrast` | text colour and WCAG contrast chosen for each badge colour, light and dark |
| `--appearance dark\|light` | force a theme |

Adding a module: see [the module contract](docs/modules.md) and [the template](templates/module/ExampleModule.swift.template).

### App Monitor

Choose CPU, Memory or both menu bar gauges in settings. Click the gauges for two application
rankings, limited to six applications each; the panel fits the number of rows. Pin keeps it above
other windows across Spaces, even when another app has focus. Click the gauges again to hide it. Quit requests a normal exit; Force Quit asks for confirmation.
CPU is normalized to the Mac's total capacity, memory uses physical footprints, and samples
refresh at the selected interval (1, 2, 5 or 10 seconds). Hover a row to reveal its quit buttons.
App bundles and descendant processes are grouped; shared XPC services
and orphaned helpers may not be attributable. See [measurement details](docs/modules.md#app-monitor-measurements).
