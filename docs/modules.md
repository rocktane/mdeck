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
while running. Each ranking shows at most six applications, and the panel height fits its rows.
The pinned panel stays above other windows across Spaces and remains visible when focus changes.
The borderless panel closes on outside clicks unless pinned; clicking its menu
bar item or pressing Escape closes it even while pinned. Row actions appear on hover.
