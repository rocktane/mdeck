import Cocoa

#if DEBUG
extension PingModule {
    /// Real pings to loopback (always answers) and TEST-NET-1 (never does), the host parser,
    /// state transitions and the module's own lifecycle. Changed preferences are restored,
    /// including keys originally absent.
    func debugRunChecks() -> Bool {
        let defaults = UserDefaults.standard
        let keys = ["host", "interval", "failuresBeforeAlert", "color"].map { "ping.\($0)" }
        let saved = Dictionary(uniqueKeysWithValues: keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
        var failures = 0
        func expect(_ ok: Bool, _ label: String) {
            print(ok ? "ok   Ping: \(label)" : "FAIL Ping: \(label)")
            if !ok { failures += 1 }
        }
        func wait(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return done()
        }
        stop()
        defer {
            stop()
            for key in keys {
                if let value = saved[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        let cases: [(String, String?)] = [
            ("1.1.1.1", "1.1.1.1"), ("  Example.COM ", "example.com"), ("https://example.com:8443/a?b", "example.com"),
            ("example.com/path", "example.com"), ("example.com:80", "example.com"), ("[::1]", "::1"),
            ("2606:4700:4700::1111", "2606:4700:4700::1111"), ("", nil), ("-c 5 host", nil), ("a b", nil),
            ("host;rm", nil),
        ]
        for (input, expected) in cases {
            expect(PingTarget.normalize(input) == expected, "normalize \"\(input)\" → \(expected ?? "nil")")
        }
        expect(PingProbe.latency(in: "round-trip min/avg/max/stddev = 4.969/5.500/6.0/nan ms") == 0.0055,
               "latency parsed from ping's summary")

        let probe = PingProbe()
        let loop = probe.run(host: "127.0.0.1", timeout: 1)
        expect(loop.ok && loop.latency != nil, "loopback replies with a latency")
        expect(probe.run(host: "::1", timeout: 1).ok, "IPv6 loopback replies through ping6")
        var began = Date()
        let lost = probe.run(host: "192.0.2.1", timeout: 1)
        expect(!lost.ok && Date().timeIntervalSince(began) < 2.5, "unreachable host fails within its timeout (\(lost.detail ?? "-"))")
        let unknown = probe.run(host: "nonexistent.invalid", timeout: 2)
        expect(!unknown.ok, "unknown host fails (\(unknown.detail ?? "-"))")
        began = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { probe.cancel() }
        let cancelled = probe.run(host: "192.0.2.1", timeout: 3)
        expect(!cancelled.ok && Date().timeIntervalSince(began) < 1.5 && !probe.isPinging, "cancel ends the ping in flight")
        expect(!probe.run(host: "127.0.0.1", timeout: 1).ok, "cancelled probe refuses new pings")
        probe.resume()
        expect(probe.run(host: "127.0.0.1", timeout: 1).ok, "resumed probe pings again")

        let inert = PingModule()
        let inertView = inert.makeSettingsView()
        expect(!inert.hasResources && inertView.subviews.count > 0, "construction and settings are inert")

        PingPrefs.host = "127.0.0.1"
        PingPrefs.interval = 1
        PingPrefs.failuresBeforeAlert = 1
        start()
        let firstItem = debugStatusItem
        start()
        expect(isRunning && firstItem != nil && debugStatusItem === firstItem, "duplicate start owns one status item")
        expect(wait(3) { state == .online } && debugStatusItem?.button?.image != nil, "reachable host turns online")

        PingPrefs.host = "192.0.2.1"
        settingsChanged(target: true)
        expect(state == .unknown, "changing the host forgets the previous result")
        expect(wait(4) { state == .offline }, "unreachable host turns offline")
        expect(dotColor == .systemRed, "offline dot is red")

        PingPrefs.failuresBeforeAlert = 5
        settingsChanged()
        expect(consecutiveFailures < 5 ? state == .online : state == .offline, "raising the threshold re-judges the streak")

        PingPrefs.host = "-c 9 1.1.1.1"
        settingsChanged(target: true)
        expect(state == .invalidHost && !debugIsChecking, "an invalid host is not pinged")

        PingPrefs.host = "127.0.0.1"
        PingPrefs.color = "blue"
        settingsChanged(target: true)
        expect(wait(3) { state == .online } && dotColor == .systemBlue, "online dot uses the chosen colour")

        PingPrefs.host = "192.0.2.1"
        settingsChanged(target: true)
        stop()
        expect(!hasResources && state == .unknown, "stop during a ping releases everything")
        stop()
        start()
        PingPrefs.host = "127.0.0.1"
        settingsChanged(target: true)
        expect(wait(3) { state == .online }, "restart pings again")
        stop()
        expect(!hasResources, "stop after restart releases everything")
        return failures == 0
    }
}
#endif
