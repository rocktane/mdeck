import Cocoa

// Escape hatch: if mdeck ever dies without restoring the system switcher (SIGKILL, crash)
// while Altty had taken ⌘Tab over, `mdeck --restore` puts it back without launching the agent.
if CommandLine.arguments.contains("--restore") {
    NativeSwitcher.setEnabled(true)
    print("native Cmd+Tab restored")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// Symbolic hotkeys are process-global state in the WindowServer and Night Shift is system
// state: a signal would otherwise leave both as a module had set them. Stopping the modules is
// not async-signal-safe, so the signal is turned into a normal termination on the main queue.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    signalSources.append(source)
}

app.run()
