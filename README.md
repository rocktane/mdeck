# mdeck

One native macOS menu bar app, many small utilities. Each utility is a **module** you turn on
or off; a module that is off does not run at all — no observer, no shortcut, no event tap.

| Module | What it does | Permission |
|---|---|---|
| **Night Shift Focus** | Turns Night Shift and True Tone off while a colour-critical app (Lightroom, Photoshop, Figma…) is in front, and puts back exactly what was there when you leave it. | none |
| **Altty** | An app switcher (⌥⇥ by default, ⌘⇥ possible) that leaves out apps with no open window. | Accessibility only for “Detect windows on all Spaces” |
| **App Monitor** | Lists CPU and memory usage grouped by application, with menu bar gauges and an optional pinned panel. | none |
| **Dock Lock** | Keeps the Dock on one display — the MacBook’s screen by default — even with external screens connected. | Accessibility |
| **Keep Awake** | Prevents idle system and/or display sleep, indefinitely, for a duration, until a chosen time, or automatically while Claude Code or Codex works. | none |
| **Clean Links** | Removes trackers (utm_*, fbclid, affiliate tags…) from the links you copy, unwraps redirects and AMP, expands short links. | Accessibility only for the “Paste the original link” shortcut |
| **Ping** | Pings an IP or host (1.1.1.1 by default) every few seconds and shows a dot in the menu bar, in the colour you choose, that turns red when it stops replying. | none |

macOS 13+. Written in Swift/AppKit, built with `swiftc` alone: no Xcode project, no SwiftPM.

## Install

```sh
brew install --cask rocktane/tap/mdeck
```

Or download `mdeck.zip` from [GitHub Releases](https://github.com/rocktane/mdeck/releases),
unzip and move `mdeck.app` to `/Applications`. Release builds support Intel and Apple Silicon
on macOS 13+. They are self-signed, not notarized; right-click → Open on first launch.

To build locally:

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

### Keep Awake

Enable the module to add its cup to the menu bar. An outlined cup means idle; a filled cup means
a session is active. **Start Keep Awake** uses the default duration; **Start For** / **Stop In**
offers 5, 15 or 30 minutes, 1, 2, 4 or 8 hours, indefinitely, and a custom duration or end date/time.
Choosing a new duration replaces the current deadline. Custom sessions support 1 minute to 7 days.
Timed sessions show an optional countdown next to the cup. Controls also appear under Keep Awake
in mdeck's main menu, independently of the dedicated cup.

**Prevent system sleep** and **Prevent display sleep** are independent and apply immediately to
a running session. By default only the system is protected, so displays may sleep during downloads
or builds. Turning both protections off ends the session. Enabling the module starts idle unless
**Start a session when enabled** is selected; that option also starts a fresh session when mdeck
launches with the module enabled. Expiration does not disable the module or restart the session.
The default duration affects the next start, not an existing session. Sessions are not resumed
after quit or crash.

Inspired by [Keepresso](https://github.com/gyorgysh/keepresso), with an independent Swift/AppKit
implementation using public IOPM APIs. No Accessibility, administrator helper or permanent
`caffeinate` process is needed. Each timed assertion has a macOS release timeout as well as the
app's timer. Stop, disable and quit release the module's own assertions; other apps' assertions
remain in effect. This prevents **idle sleep**: explicit Sleep, lid closure and low-battery sleep
are not overridden. It does not simulate presence, control brightness, disable screen locking,
or provide Keepresso's triggers, automation, closed-display helper or headless tools.
See [ownership and timing details](docs/modules.md#keep-awake).

**Stay awake while Claude Code or Codex works** (on by default) holds the same protections, with no
session and no deadline, while an agent is answering or running a tool, then lets the Mac sleep
again. Open but idle sessions do not count. Detection needs no hook or configuration: a write to a
transcript (`~/.claude/projects`, `~/.codex/sessions`) counts for the **quiet period** (5 minutes
by default, to cover long model turns), and a command started by a `claude` or `codex` process
counts for as long as it runs. This covers the CLIs, the desktop apps and tools built on them.
A background command left running by an agent (a dev server, for instance) keeps the Mac awake
until it exits. A manual session ending during agent work leaves the agent hold in place.
### Clean Links

When the clipboard holds a single web link — and nothing else — Clean Links replaces it with the
same link minus its trackers, and shows a short notice at the bottom of the screen (can be
turned off). What it removes, each with its own switch:

- tracking parameters (`utm_*`, `fbclid`, `gclid`, YouTube’s `si`…) and affiliate tags, from
  the [ClearURLs](https://gitlab.com/ClearURLs/rules) rules (200-odd sites plus global rules) and a
  few additions of mdeck’s own (x.com, LinkedIn, Outlook Safe Links, Slack, Threads);
- tracking written into the path (Amazon’s `/ref=…`);
- redirect wrappers (`google.com/url?q=…`, `l.facebook.com`…), read from the link itself;
- AMP pages (Google’s viewer, the AMP cache), replaced by the publisher’s address;
- `#:~:text=` highlight fragments;
- short links (bit.ly, t.co, amzn.to… plus your own list), followed to where they lead with one
  cookie-less request whose body is never downloaded. The shortening service does see that
  request. Up to 3 s; on failure the link is left as it was.

Your own rules: sites never touched, parameters to keep or to remove (`utm_*`, `github.com:ref`),
extra shortener domains, and apps whose copies are left alone. Copies marked as secret by
password managers, and pastes from clipboard histories, are never touched. **⌃⌘V** (changeable)
pastes the original link into the front app and keeps the clean one in the clipboard; it posts
⌘V, hence the Accessibility permission.

The rules ship with the app and are refreshed weekly from `rules2.clearurls.xyz`: the download
must match the SHA-256 published next to it, and is kept in
`~/Library/Application Support/mdeck/CleanLinks/`. ClearURLs’ rules are LGPL-3.0
(see `Resources/ClearURLs/`).

macOS has no clipboard notification. While Tinycast runs with its
clipboard history on, Clean Links watches Tinycast’s history database instead of polling: it
cleans right after Tinycast saved the copy, so the history keeps both the original and the clean
link. Copies Tinycast does not save (apps excluded in Tinycast) are then not cleaned either.
Without Tinycast the clipboard is checked twice a second. Either way, a ⌘V within about half a
second of the ⌘C can still paste the original.

### Ping

Enable the module to add a dot to the menu bar, normally just left of mdeck's icon (⌘-drag to
move it). The dot takes the chosen colour (green by default; any preset or a colour from the
wheel) while the host replies, turns red when it does not, and is faded until the first reply.
Its menu shows the last result (latency, or the error and since when) and **Check Now**.
While the dot is shown, mdeck's other menu bar items (its icon, App Monitor's gauges, Keep Awake's
cup without countdown) drop their left padding, so the dot sits 4 pt from its neighbour, the
spacing macOS puts between any two items.

The host is an IPv4/IPv6 address or a host name, 1.1.1.1 by default; a pasted URL is reduced to
its host. The check runs every 1 s to 5 min (5 s by default), and the dot can wait for 2, 3 or 5
failed pings in a row before turning red, to ignore a lost packet. Each check is one ICMP echo
through the system's `/sbin/ping` (`ping6` for IPv6), with a timeout of 3 s or the interval if
shorter; a new check is also run on wake. No privilege is needed.
A ping proves the host answers ICMP echo, not that websites load: networks that block ping
(some captive portals and corporate firewalls) show red while browsing works.
See [ownership details](docs/modules.md#ping).

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
| `--snapshot-settings out.png [--page general\|nightshift\|altty\|docklock\|appmonitor\|cleanlinks\|keepawake] [--full-page]` | captures the settings window (no Screen Recording needed for our own windows); `--full-page` scrolls through the whole page, one `out-N.png` per screenful |
| `--altty-snapshot out.png` / `--altty-demo` | the switcher panel |
| `--appmonitor-test` / `--appmonitor-snapshot out.png` | checks real samples / captures the application rankings (drawn off screen, on a plain background, while the screen is locked) |
| `--keepawake-test` | checks real kernel assertions, rollback, deadlines, expiration and complete teardown; restores Keep Awake preferences |
| `--keepawake-agents` | prints which agents are working right now, from the real transcripts and process tree |
| `--keepawake-snapshot out.png` | captures the custom session panel |
| `--keepawake-menu-snapshot out.png [--keepawake-active]` | captures a diagnostic window listing the native menu entries, optionally during a timed session (not a screenshot of the system menu) |
| `--statusbar-gap [--no-icon]` | keeps mdeck's icon, App Monitor and Ping in the menu bar for 8 s and logs their button and image sizes, to measure the real gap from outside (Accessibility frames, a capture of the menu bar) |
| `--lifecycle-test` | starts and stops every module, checks nothing is left behind; also runs Clean Links’ cleaning, pasteboard and watcher checks |
| `--dock-info` | displays, Dock edge, where the Dock is |
| `--clean-url <url>` | what Clean Links does with a link, short-link expansion included |
| `--cleanlinks-hud out.png` | captures Clean Links’ notice |
| `--menu-size` | the menu bar menu's computed size |
| `--badge-contrast` | text colour and WCAG contrast chosen for each badge colour, light and dark |
| `--appearance dark\|light` | force a theme |

To test the running Altty instance with real Cmd+Tab input, keep two apps with windows open
on the current Space and pass their bundle IDs:

```sh
swift scripts/test-altty.swift com.t3tools.t3code com.mitchellh.ghostty 5 --settings-open
```

The test host needs Accessibility to read the switcher and permission to control System Events.
It checks actual foreground changes, quick and held shortcuts, Escape cancellation, and MRU
ordering after a failed activation. `--settings-open` also exercises switching while mdeck's
settings make it a regular app; omit it to test the current state. The test restores the
original foreground app and leaves settings open when that flag is used.

Adding a module: see [the module contract](docs/modules.md) and [the template](templates/module/ExampleModule.swift.template).

### App Monitor

Choose CPU, Memory or both menu bar gauges in settings. Click the gauges for two application
rankings, limited to six applications each; the panel fits the number of rows. Pin keeps it above
other windows across Spaces, even when another app has focus. Click the gauges again to hide it. Quit requests a normal exit; Force Quit asks for confirmation.
CPU is normalized to the Mac's total capacity, memory uses physical footprints, and samples
refresh at the selected interval (1, 2, 5 or 10 seconds). Hover a row to reveal its quit buttons.
App bundles and descendant processes are grouped; shared XPC services
and orphaned helpers may not be attributable. See [measurement details](docs/modules.md#app-monitor-measurements).

## Releases

Run `make release` to select a version, update the bundle version and push its tag.
GitHub Actions builds the universal signed app, publishes `mdeck.zip`, then updates
`Casks/mdeck.rb` in `rocktane/homebrew-tap` with the archive SHA256. CI uses
`SIGNING_CERT_P12`, `SIGNING_CERT_PASS` and `TAP_DEPLOY_KEY` repository secrets.
