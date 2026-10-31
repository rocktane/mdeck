# Module contract

A mdeck module is a user-selectable utility implementing `Module`, registered once in
`ModuleManager.modules`. It owns its implementation, preferences, runtime resources and settings
view under `Sources/Modules/<Name>/`. `Shared/` holds behavior used by multiple modules.

## Lifecycle and ownership

Construction and settings display are inert: runtime resources are acquired only in `start()`.
`start()` and `stop()` are idempotent. Starting again after stopping must work.
`stop()` releases every timer, observer, hotkey, event tap, event monitor, status item and window,
cancels pending work, and restores system state changed by the utility.
Background collection is serialized and kept off the main thread. Stop drains or cancels work;
late callbacks are rejected using a lifecycle generation. UI mutation happens on the main thread.
A disabled module performs no recurring work. Settings controls may persist while disabled.

Each module owns any dedicated status item and panels it creates. Remove the item and close the
panels on stop, including pinned panels and their event monitors. Opening a panel does not alter
mdeck's application activation policy; settings remain responsible for that policy.

## Preferences, permissions and interface

Use a stable lowercase ID; prefix preferences with `<id>.`. ModuleManager owns enabled and menu
visibility flags. Default disabled. Apply settings changes immediately when running and persist
changes even while disabled. Keep settings geometry stable and use the shared settings controls.
All product text is English.

Declare Accessibility requirements through `needsAccessibility`; permission prompts are managed
by ModuleManager. Document any additional permission and request it when its feature is enabled.
Publish menu/sidebar status changes through `noteChange()`; frequent metric updates belong to
the module's own UI rather than the global notification.

Keep collection, aggregation and presentation separate when they have different responsibilities.
Document measurement units and limitations. Validate process identity before destructive actions;
request normal application termination first and offer explicit force termination with confirmation.
Never use a displayed name to select a process to terminate.

## Adding a module

1. Copy `templates/module/ExampleModule.swift.template` into a new module directory as a `.swift`
   file. Replace Example/example and supply metadata, behavior and settings.
2. Register the module in `ModuleManager.modules`. The sidebar, General page and main menu derive
   their entries from that registration; sources are discovered by the build script.
3. Extend `Debug.lifecycleTest()` with checks for every resource owned by the module. Verify
   start, duplicate start, stop, duplicate stop, and restart. Add meaningful behavioral checks for
   aggregation or system-state changes.
4. Build normal and debug versions. Run `--lifecycle-test`; inspect settings and any custom panel
   in both light and dark appearances. Check errors and empty/unavailable states.
5. Add the module, permissions and measurement limitations to README.

## Keep Awake

ID: `keepawake`; preferences: `keepawake.*`; default disabled; no permission required. The module
and its settings view are inert on construction. `start()` owns one NSStatusItem and one workspace
wake observer. A session owns at most one `PreventUserIdleSystemSleep` assertion and one
`PreventUserIdleDisplaySleep` assertion, acquired with `IOPMAssertionCreateWithDescription`.
The two choices are independent. Failure to acquire either requested assertion releases the
entire newly acquired set and exposes the IOKit error in settings/menu status. Both options off
means no session. Settings changes reconcile a running session without extending its deadline.

Only a timed session owns a recurring timer (1 second, common run-loop modes). Frequent countdown
updates refresh only local UI; starts, stops, errors and configuration changes call `noteChange()`.
Every timed assertion also uses `TimeoutActionRelease` so powerd releases it independently of
the UI run loop. The powerd timeout is rounded up to whole seconds to avoid early release when
reapplying settings, so the fallback can lag the deadline by less than a second. Duration
sessions use `mach_continuous_time`, including elapsed time asleep;
clock adjustments cannot extend them. End-time sessions also check the chosen wall-clock date:
moving the clock forward can end them early, moving it backward cannot extend the original
elapsed-time budget. A workspace wake callback reconciles expiration immediately after waking.
Timers reject old lifecycle generations and replaced sessions. UI may catch up on the next tick
after powerd's timeout; it does not promise subsecond countdown precision.

`stop()` invalidates the timer, releases owned assertions, removes the wake observer, closes and
discards the custom session panel, cancels menu tracking and removes the status item. Repeated
stop is safe and can retry a failed assertion release; restart recreates fresh resources. Expired
assertions already released by powerd are tolerated. The module never changes persistent power
settings or launches a helper. macOS releases a process's assertions when it exits, including on
crash. Neither an active session nor its deadline is persisted.

The dedicated cup remains available while the enabled module is idle. The main-menu visibility
flag is owned by ModuleManager and affects the entry in mdeck's menu. The custom session panel
does not change NSApp's activation policy and owns no monitors or observers. Its date/time picker
accepts a future date within 7 days; its duration field accepts whole minutes from 1 to 10,080.
Default duration and automatic start affect the next start, while system/display protection and
countdown visibility update immediately. Automatic start runs only on enable/launch, not expiry.

Reference examined: [Keepresso README](https://github.com/gyorgysh/keepresso/blob/e9d96264d9500e5c3b0bc904d303d13fb3be2d0d/README.md),
[PowerAssertion.swift](https://github.com/gyorgysh/keepresso/blob/e9d96264d9500e5c3b0bc904d303d13fb3be2d0d/Sources/KeepressoCore/PowerAssertion.swift)
and [SleepPreventionOptions.swift](https://github.com/gyorgysh/keepresso/blob/e9d96264d9500e5c3b0bc904d303d13fb3be2d0d/Sources/KeepressoCore/SleepPreventionOptions.swift),
commit `e9d96264d9500e5c3b0bc904d303d13fb3be2d0d` (1.26.0). These confirm independent system/display
assertions, indefinite/timed/end-time sessions, quick stop durations, countdown and optional
start on launch. mdeck implements that manual keep-awake workflow, not Keepresso's broader
trigger engine, presence simulation, automation or privileged closed-display/headless features.
Assertions prevent idle sleep only: explicit Sleep, lid closure and critical battery protection
can still put the Mac to sleep. Screen saver/lock and other applications' assertions remain under
macOS/their owners' control. Actual sleep behavior depends on hardware and power policy.

Agent mode (`keepawake.whileAgentsWork`, default on; `keepawake.agentGraceMinutes`, default 5) is
owned by `AgentActivityMonitor`, created only while the module runs and the option is on. It owns one
FSEvents stream per existing transcript folder (`~/.claude/projects`, `~/.codex/sessions`; a folder
created later is picked up on the next poll) and one 10-second timer. Process presence and CPU time
are not signals: idle sessions keep their process and MCP servers busy. Work is a transcript write
within the quiet period, or a non-zombie child of an agent process that is a shell or started more
than 30 seconds after the agent (MCP servers start with it). The native Claude installer runs
`~/.local/share/claude/versions/<version>`, whose kernel name is the version, so agents are also
matched by executable path. An agent hold acquires the selected assertions without a timeout and
without creating a session: `isActive` and the Start/Stop controls stay about manual sessions. A
timed session during agent work loses its powerd timeout; when agents go idle, the remaining
timeout is restored, or the assertions are released. Expiry of a manual session leaves the hold.
`stop()` stops the monitor before releasing assertions; its callbacks are generation-checked.

`--keepawake-test` and `--lifecycle-test` verify real assertion types/levels using
`IOPMAssertionCopyProperties`, independent modes, immediate settings, partial-failure rollback,
deadline preservation, invalid inputs, kernel timeout while the run loop is blocked, expiration,
replacement, panel ownership, repeated stop and restart, the agent hold (untimed assertion, timeout
lift/restore, expiry under the hold, protections off) and the monitor against a temporary folder
and a real shell child. `--keepawake-agents` reports live detection. Tests restore all changed Keep Awake
preferences, including previously absent keys. For a manual diagnostic, `pmset -g assertions`
shows names beginning with `mdeck Keep Awake`; they must disappear after stop/disable or timeout.
Inspect `--snapshot-settings … --page keepawake`, `--keepawake-snapshot …` and the diagnostic
menu-entry snapshot in light/dark appearances. Physical idle sleep, lid behavior and long sessions
require manual hardware validation; automated checks do not force this Mac to sleep.

## Ping

ID: `ping`; preferences: `ping.host` (raw text, default `1.1.1.1`),
`ping.interval` (seconds, 1–300, default 5), `ping.failuresBeforeAlert` (1, 2, 3
or 5, default 1) and `ping.color` (`StoredColor`, default green); default disabled; no
permission required. Construction and the settings view are inert.

`start()` owns one NSStatusItem (the dot, with its own menu), one repeating timer (common run-loop
modes) and one workspace wake observer. Checks run on a serial utility queue, at most one at a
time: a tick while a ping is in flight is skipped. `PingProbe` runs `/sbin/ping -c 1 -n -q -t`
(`/sbin/ping6` for IPv6 literals, which has no `-t`) with `--` before the host, and terminates
the process at timeout + 0.5 s, so name resolution is bounded too. `PingTarget.normalize` reduces
input to a host and rejects anything outside letters, digits and `.-_:%`, or starting with `-`.
Results return on the main thread and are rejected by lifecycle generation. A host change bumps
the generation, cancels the ping in flight and resets state; an interval change only restarts
the timer; colour and threshold changes apply at once. State transitions call `noteChange()`;
repeated results only redraw the dot and the open settings page.

The item is 14 pt wide with the 10 pt dot against its right edge. macOS leaves 4 pt between
status items, which no app can change; a variable-length neighbour would add its own 4 pt of
padding plus its image's inset. `StatusItemSpacing` therefore gives mdeck's image-only items
(the mdeck icon, App Monitor's gauges, Keep Awake's cup without countdown) a fixed length with
no leading padding while Ping runs; they re-apply it on `moduleStateDidChange`. A third-party
neighbour, after a ⌘-drag, keeps its own padding.

`stop()` invalidates the timer, removes the wake observer, cancels the probe (terminating any
running ping) and drains the queue, then removes the status item. Restart resumes the probe.
`--lifecycle-test` checks the parser, real pings to 127.0.0.1, ::1, TEST-NET-1 (192.0.2.1, no
reply within the timeout) and an `.invalid` name, cancellation, online/offline transitions,
the threshold, the invalid-host state, the chosen colour, stop during a ping and restart.

## App Monitor measurements

CPU lists use differences in cumulative user + system CPU time between samples, normalized by
logical processor count, after converting Mach ticks with the host timebase. The global CPU gauge uses host CPU tick differences. Both use 0–100%.
Memory per application sums process physical footprints. The global memory gauge uses active,
wired and compressed pages divided by physical RAM; it is utilization, not memory pressure.

Only running applications with a regular activation policy are listed. Processes inside an app
bundle attach to the outermost application bundle; other descendants attach through their parent
chain. Shared XPC services, orphaned helpers and processes macOS prevents reading may be absent:
this is best-effort attribution, not an exact reproduction of Activity Monitor. Unreadable metrics
are omitted from sums. Shared memory accounting can differ from other monitors.
Quit/Force Quit target the original NSRunningApplication roots, allowing application lifecycle
management to handle helpers; detached subprocesses may survive. mdeck's own termination buttons
are disabled. Force Quit does not broadcast signals to unrelated or shared services.

The refresh interval is configurable (1, 2, 5 or 10 seconds; default 2) and changes take effect
while running. Each ranking shows at most six applications, and the panel height fits its rows. The panel is
640 pt wide (two 296 pt columns): names and process counts truncate, values never do, and the
lifecycle test checks "100.0%" and "12.21 GB" beside a long name with and without the hovered
quit buttons.
The pinned panel stays above other windows across Spaces and remains visible when focus changes.
The borderless panel closes on outside clicks unless pinned; clicking its menu
bar item or pressing Escape closes it even while pinned. Row actions appear on hover.
